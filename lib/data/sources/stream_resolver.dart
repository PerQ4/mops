import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../core/innertube/innertube_client.dart';
import '../local/app_settings.dart';
import 'youtube_clients.dart';

/// HTTP-клиент YouTube с добавленной авторизацией.
///
/// Библиотека не умеет авторизоваться сама, но позволяет подменить заголовки,
/// поэтому cookie (или токен) из настроек приложения добавляются к каждому
/// её запросу. Нужно это для запасного пути через `youtube_explode_dart`.
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
    this.userAgent,
    this.mimeType,
  });

  final Uri url;
  final int? bitrateKbps;
  final String? container;
  final bool isLive;

  /// Пользовательский агент, с которым запрашивался поток.
  final String? userAgent;

  /// Тип содержимого (`audio/webm`, `audio/mp4`) — нужен посреднику.
  final String? mimeType;

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

/// Один вариант аудиодорожки, приведённый к общему виду.
class _AudioCandidate {
  const _AudioCandidate({
    required this.url,
    required this.bitrateKbps,
    required this.container,
    this.mimeType,
    this.userAgent,
  });

  final Uri url;
  final int bitrateKbps;
  final String container;
  final String? mimeType;
  final String? userAgent;
}

/// Получение потока.
///
/// Основной путь — запрос `player` нашим InnerTube-клиентом с профилем
/// клиента YouTube (Android VR или iOS): эти профили не требуют ни входа,
/// ни PO-токена. Запасной путь — `youtube_explode_dart` со своим клиентом
/// по умолчанию: он работает всегда, но YouTube всё чаще требует для него
/// PO-токен.
class YoutubeStreamResolver implements StreamResolver {
  YoutubeStreamResolver({
    required this.innerTube,
    required this.locale,
    required this.region,
    this.clientChoice = StreamSource.auto,
    Map<String, String> authHeaders = const <String, String>{},
    YoutubeExplode? library,
  }) : _library = library ??
            YoutubeExplode(
              httpClient: AuthenticatedYoutubeClient(authHeaders),
            );

  /// Клиент InnerTube — им выполняется запрос `player`.
  final InnerTubeClient innerTube;

  /// Язык интерфейса YouTube в запросе.
  final String locale;

  /// Регион выдачи YouTube в запросе.
  final String region;

  final YoutubeExplode _library;

  /// Какой клиент YouTube использовать для получения ссылки.
  final StreamSource clientChoice;

  /// Кэш: ссылки живут часами, а запрос — довольно дорогая операция.
  final Map<String, ResolvedStream> _cache = <String, ResolvedStream>{};

  @override
  Future<ResolvedStream> resolve(
    String videoId, {
    required AudioQuality quality,
  }) async {
    final String key = '$videoId:${quality.name}:${clientChoice.name}';
    final ResolvedStream? cached = _cache[key];
    if (cached != null && !cached.isExpired) return cached;

    final List<String> failures = <String>[];

    for (final YoutubeClientProfile profile
        in YoutubeClients.forChoice(clientChoice)) {
      try {
        final ResolvedStream? resolved =
            await _resolveWithProfile(profile, videoId, quality);
        if (resolved != null) {
          _cache[key] = resolved;
          return resolved;
        }
        failures.add('${profile.label}: ссылок нет');
      } on Object catch (error) {
        failures.add('${profile.label}: $error');
      }
    }

    // Запасной путь — библиотека с её клиентом по умолчанию.
    try {
      final ResolvedStream? resolved =
          await _resolveWithLibrary(videoId, quality);
      if (resolved != null) {
        _cache[key] = resolved;
        return resolved;
      }
      failures.add('библиотека: ссылок нет');
    } on Object catch (error) {
      failures.add('библиотека: $error');
    }

    debugPrint('Не удалось получить поток для $videoId: ${failures.join("; ")}');
    throw StreamResolutionException(
      'Не удалось получить аудиопоток. Проверьте соединение и попробуйте снова.',
    );
  }

  /// Запрос `player` выбранным профилем клиента.
  Future<ResolvedStream?> _resolveWithProfile(
    YoutubeClientProfile profile,
    String videoId,
    AudioQuality quality,
  ) async {
    final Map<String, dynamic> response = await innerTube.post(
      'player',
      body: <String, dynamic>{
        'context': <String, dynamic>{
          'client': profile.context(locale: locale, region: region),
        },
        'videoId': videoId,
        'contentCheckOk': true,
        'racyCheckOk': true,
      },
      extraHeaders: profile.headers,
      authenticated: true,
    );

    final dynamic status = response['playabilityStatus'];
    final String state = status is Map ? '${status['status']}' : '?';
    if (state != 'OK') {
      debugPrint('[Поток] ${profile.label}: $state '
          '${status is Map ? status['reason'] ?? '' : ''}');
      return null;
    }

    return _pickFromPlayerResponse(response, quality, profile);
  }

  /// Запасной путь: библиотека со своим клиентом по умолчанию.
  Future<ResolvedStream?> _resolveWithLibrary(
    String videoId,
    AudioQuality quality,
  ) async {
    final StreamManifest manifest =
        await _library.videos.streamsClient.getManifest(videoId);

    final List<AudioOnlyStreamInfo> audio = manifest.audioOnly.toList();
    if (audio.isEmpty) return null;

    final List<_AudioCandidate> candidates = audio
        .map((AudioOnlyStreamInfo stream) => _AudioCandidate(
              url: stream.url,
              bitrateKbps: stream.bitrate.kiloBitsPerSecond.round(),
              container: stream.container.name,
              mimeType: stream.container.name == 'webm'
                  ? 'audio/webm'
                  : 'audio/mp4',
            ))
        .toList();

    return _pickCandidate(candidates, quality);
  }

  /// Разбирает ответ `player` и выбирает дорожку.
  ///
  /// Подходят только дорожки с готовой ссылкой (`url`): если YouTube вернул
  /// `signatureCipher`, расшифровать его мы не можем — тогда путь через
  /// профиль не годится, и сработает запасной через библиотеку.
  ResolvedStream? _pickFromPlayerResponse(
    Map<String, dynamic> response,
    AudioQuality quality,
    YoutubeClientProfile profile,
  ) {
    final dynamic data = response['streamingData'];
    if (data is! Map) return null;

    final List<Map<String, dynamic>> formats = <dynamic>[
      ...(data['adaptiveFormats'] as List<dynamic>? ?? <dynamic>[]),
      ...(data['formats'] as List<dynamic>? ?? <dynamic>[]),
    ].whereType<Map<String, dynamic>>().toList();

    final List<_AudioCandidate> candidates = <_AudioCandidate>[];
    for (final Map<String, dynamic> format in formats) {
      final String mime = '${format['mimeType']}';
      if (!mime.startsWith('audio')) continue;

      final Object? url = format['url'];
      if (url is! String || url.isEmpty) continue;

      // Битрейт в ответе — в битах в секунду.
      final int bitrate = ((format['bitrate'] as num?) ?? 0).toInt();
      candidates.add(_AudioCandidate(
        url: Uri.parse(url),
        bitrateKbps: bitrate ~/ 1000,
        container: mime.contains('webm') ? 'webm' : 'm4a',
        mimeType: mime.contains('webm') ? 'audio/webm' : 'audio/mp4',
        userAgent: profile.userAgent,
      ));
    }

    if (candidates.isEmpty) return null;
    return _pickCandidate(candidates, quality);
  }

  /// Выбирает дорожку под желаемое качество.
  ResolvedStream? _pickCandidate(
    List<_AudioCandidate> candidates,
    AudioQuality quality,
  ) {
    if (candidates.isEmpty) return null;

    candidates.sort((_AudioCandidate a, _AudioCandidate b) =>
        a.bitrateKbps.compareTo(b.bitrateKbps));

    _AudioCandidate chosen = candidates.first;
    if (quality == AudioQuality.high) {
      chosen = candidates.last;
    } else {
      for (final _AudioCandidate candidate in candidates) {
        if (candidate.bitrateKbps <= quality.targetKbps) {
          chosen = candidate;
        } else {
          break;
        }
      }
    }

    return ResolvedStream(
      url: chosen.url,
      bitrateKbps: chosen.bitrateKbps,
      container: chosen.container,
      mimeType: chosen.mimeType,
      userAgent: chosen.userAgent,
      expiresAt: DateTime.now().add(const Duration(hours: 5)),
    );
  }

  @override
  void dispose() {
    _cache.clear();
    _library.close();
  }
}
