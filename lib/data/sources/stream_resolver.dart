import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../local/app_settings.dart';
import 'youtube_clients.dart';

/// HTTP-клиент YouTube с добавленной авторизацией.
///
/// Зачем: неавторизованному клиенту YouTube отдаёт поток с ограничением —
/// сервер принимает только первые ~1 МБ трека, а на остальное отвечает 403.
/// С выполненным входом условия выдачи другие, и поток отдаётся целиком.
///
/// Библиотека не умеет авторизоваться сама, но позволяет подменить заголовки,
/// поэтому cookie (или токен) из настроек приложения добавляются к каждому
/// её запросу.
class AuthenticatedYoutubeClient extends YoutubeHttpClient {
  AuthenticatedYoutubeClient(this.authHeaders, [http.Client? inner])
      : super(inner);

  final Map<String, String> authHeaders;

  @override
  Map<String, String> get headers => <String, String>{
        ...super.headers,
        ...authHeaders,
      };

  /// Заголовки авторизации для текущей сессии.
  ///
  /// Cookie из браузера содержит всё нужное, но страховочную cookie согласия
  /// добавляем сами — без неё YouTube может показать страницу согласия
  /// вместо данных.
  static Map<String, String> headersForSession({
    required String? cookieString,
    required String? bearerToken,
  }) {
    final Map<String, String> result = <String, String>{};

    final String cookies = cookieString?.trim() ?? '';
    if (cookies.isNotEmpty) {
      result['cookie'] = cookies.toUpperCase().contains('CONSENT=')
          ? cookies
          : 'CONSENT=YES+cb; $cookies';
    }

    final String token = bearerToken?.trim() ?? '';
    if (token.isNotEmpty) {
      result['authorization'] = 'Bearer $token';
    }
    return result;
  }
}

/// Готовая к воспроизведению ссылка на аудиопоток.
@immutable
class ResolvedStream {
  const ResolvedStream({
    required this.url,
    required this.expiresAt,
    this.bitrateKbps,
    this.container,
    this.isLive = false,
  });

  final Uri url;
  final int? bitrateKbps;
  final String? container;
  final bool isLive;

  /// Ссылки googlevideo живут несколько часов; после этого нужен перезапрос.
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(
        expiresAt.subtract(const Duration(minutes: 5)),
      );
}

/// Контракт получения потока. Реализации можно менять независимо от UI.
abstract class StreamResolver {
  Future<ResolvedStream> resolve(String videoId, {required AudioQuality quality});
  void dispose();
}

/// Ошибка получения потока с понятным текстом.
class StreamResolutionException implements Exception {
  StreamResolutionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Реализация поверх `youtube_explode_dart`.
///
/// Библиотека сама разбирает `signatureCipher` (подпись ссылки), поэтому
/// приложение не зависит от внешних бинарников вроде `yt-dlp` — важно для
/// кроссплатформенности.
class YoutubeExplodeResolver implements StreamResolver {
  YoutubeExplodeResolver({
    YoutubeExplode? client,
    Map<String, String> authHeaders = const <String, String>{},
    this.clientChoice = StreamSource.auto,
  }) : _client = client ??
            YoutubeExplode(
              // Авторизация поднимает лимит на выдачу потока: без неё
              // медиасервер отдаёт только первые мегабайты трека.
              httpClient: AuthenticatedYoutubeClient(authHeaders),
            );

  final YoutubeExplode _client;

  /// Какой клиент YouTube использовать для получения ссылки.
  final StreamSource clientChoice;

  /// Кэш: видео-ссылки живут часами, а `getManifest` — довольно дорогая операция.
  final Map<String, ResolvedStream> _cache = <String, ResolvedStream>{};

  @override
  Future<ResolvedStream> resolve(
    String videoId, {
    required AudioQuality quality,
  }) async {
    final String key = '$videoId:${quality.name}:${clientChoice.name}';
    final ResolvedStream? cached = _cache[key];
    if (cached != null && !cached.isExpired) return cached;

    try {
      // Клиент выбирается в настройках. Пустой список означает клиент
      // библиотеки по умолчанию — тогда список не передаём вовсе.
      final List<YoutubeApiClient> clients =
          YoutubeClients.forChoice(clientChoice);
      final StreamManifest manifest = await _client.videos.streamsClient
          .getManifest(
        videoId,
        ytClients: clients.isEmpty ? null : clients,
      );

      final List<AudioOnlyStreamInfo> audio = manifest.audioOnly.toList();
      if (audio.isEmpty) {
        throw StreamResolutionException(
          'У этого трека нет аудиодорожки — возможно, это видео без звука.',
        );
      }

      // Выбираем поток, ближайший к желаемому битрейту снизу вверх.
      audio.sort((AudioOnlyStreamInfo a, AudioOnlyStreamInfo b) =>
          a.bitrate.kiloBitsPerSecond.compareTo(b.bitrate.kiloBitsPerSecond));

      final int target = quality.targetKbps;
      AudioOnlyStreamInfo chosen = audio.first;
      for (final AudioOnlyStreamInfo stream in audio) {
        if (stream.bitrate.kiloBitsPerSecond <= target) {
          chosen = stream;
        } else {
          break;
        }
      }
      if (quality == AudioQuality.high) {
        // Для «максимума» всегда берём лучший доступный.
        chosen = audio.last;
      }

      final ResolvedStream resolved = ResolvedStream(
        url: chosen.url,
        bitrateKbps: chosen.bitrate.kiloBitsPerSecond.round(),
        container: chosen.container.name,
        expiresAt: DateTime.now().add(const Duration(hours: 5)),
      );
      _cache[key] = resolved;
      return resolved;
    } on StreamResolutionException {
      rethrow;
    } on Exception catch (error) {
      debugPrint('Не удалось получить поток для $videoId: $error');
      throw StreamResolutionException(
        'Не удалось получить аудиопоток. Проверьте соединение и попробуйте снова.',
      );
    }
  }

  @override
  void dispose() {
    _cache.clear();
    _client.close();
  }
}
