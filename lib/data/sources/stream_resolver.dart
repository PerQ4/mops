import 'dart:async';
import 'dart:io';

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
    this.localPath,
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

  /// Путь к скачанному файлу. Заполнен, только если трек уже есть на диске:
  /// тогда [url] — его `file:`-адрес, а сеть не нужна вовсе.
  final String? localPath;

  bool get isLocal => localPath != null;

  bool get isExpired => DateTime.now().isAfter(
        expiresAt.subtract(const Duration(minutes: 5)),
      );
}

/// Контракт получения потока. Реализации можно менять независимо от UI.
abstract class StreamResolver {
  Future<ResolvedStream> resolve(
    String videoId, {
    required AudioQuality quality,

    /// Предпочтительный контейнер (`m4a` для загрузок: у них фиксированное
    /// расширение файла). `null` — любой, как для обычного воспроизведения.
    String? preferContainer,
  });

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
    this.localFile,
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

  /// Куда смотреть скачанный файл до похода в сеть.
  ///
  /// Это колбэк, а не ссылка на хранилище: резолвер не должен зависеть от
  /// `path_provider` и каталога загрузок, а тесты могут подставить свой путь.
  final Future<String?> Function(String videoId)? localFile;

  final YoutubeExplode _library;

  /// Какой клиент YouTube использовать для получения ссылки.
  final StreamSource clientChoice;

  /// Кэш: ссылки живут часами, а запрос — довольно дорогая операция.
  final Map<String, ResolvedStream> _cache = <String, ResolvedStream>{};

  @override
  Future<ResolvedStream> resolve(
    String videoId, {
    required AudioQuality quality,
    String? preferContainer,
  }) async {
    // Сначала диск, потом сеть. Скачанный трек играет без интернета, а
    // обычный путь ниже остаётся ровно таким же, когда файла нет.
    final String? local = await _localPath(videoId);
    if (local != null) return _localStream(local);

    final String key = '$videoId:${quality.name}:${clientChoice.name}:'
        '${preferContainer ?? 'any'}';
    final ResolvedStream? cached = _cache[key];
    if (cached != null && !cached.isExpired) return cached;

    final List<String> failures = <String>[];
    // Сетевые сбои отличаем от отказов YouTube: во втором случае совет
    // «проверьте соединение» бесполезен, а в первом — важно сказать, что
    // трек не скачан.
    bool networkFailure = false;

    for (final YoutubeClientProfile profile
        in YoutubeClients.forChoice(clientChoice)) {
      try {
        final ResolvedStream? resolved = await _resolveWithProfile(
          profile,
          videoId,
          quality,
          preferContainer,
        );
        if (resolved != null) {
          _cache[key] = resolved;
          return resolved;
        }
        failures.add('${profile.label}: ссылок нет');
      } on Object catch (error) {
        if (_isNetworkError(error)) networkFailure = true;
        failures.add('${profile.label}: $error');
      }
    }

    // Запасной путь — библиотека с её клиентом по умолчанию.
    try {
      final ResolvedStream? resolved = await _resolveWithLibrary(
        videoId,
        quality,
        preferContainer,
      );
      if (resolved != null) {
        _cache[key] = resolved;
        return resolved;
      }
      failures.add('библиотека: ссылок нет');
    } on Object catch (error) {
      if (_isNetworkError(error)) networkFailure = true;
      failures.add('библиотека: $error');
    }

    debugPrint('Не удалось получить поток для $videoId: ${failures.join("; ")}');
    // YouTube на часть видео отвечает «войдите, чтобы подтвердить, что вы не
    // бот» — и тогда честнее сказать это прямо, чем отправлять человека
    // проверять соединение, которое в порядке.
    final bool needsLogin = failures.any((String f) =>
        f.contains('LOGIN_REQUIRED') ||
        f.contains('Войдите') ||
        f.contains('Sign in'));
    // Библиотека отвечает «видео недоступно», когда YouTube не отдал поток ни
    // одному клиенту: обычно это ограничение по региону или требование входа.
    final bool unavailable = failures.any((String f) =>
        f.contains('unavailable') || f.contains('недоступно'));
    // Ошибку сети ищем и в тексте: библиотека заворачивает свои исключения и
    // тип наружу не выходит.
    final bool offline = networkFailure ||
        failures.any((String f) => _looksLikeNetworkText(f));

    throw StreamResolutionException(
      needsLogin
          ? 'YouTube требует вход в аккаунт для этого видео. '
              'Войдите в приложении и попробуйте снова.'
          : unavailable
              ? 'YouTube не отдаёт это видео: оно недоступно в вашем регионе '
                  'или требует вход в аккаунт.'
              : offline
                  ? 'Не удалось получить поток: сети нет или соединение с '
                      'YouTube блокируется. Этот трек не скачан — скачайте '
                      'его заранее (меню трека → «Скачать»), и он сыграет '
                      'без интернета.'
                  : 'Не удалось получить аудиопоток. '
                      'Проверьте соединение и попробуйте снова.',
    );
  }

  /// Путь к скачанному файлу; ошибки хранилища не должны ломать сеть.
  Future<String?> _localPath(String videoId) async {
    final Future<String?> Function(String videoId)? lookup = localFile;
    if (lookup == null) return null;
    try {
      return await lookup(videoId);
    } on Object catch (error) {
      debugPrint('[Поток] не удалось проверить загрузку $videoId: $error');
      return null;
    }
  }

  /// Результат для файла на диске: срок не истекает, качества из заголовков
  /// нет — их покажет подпись «офлайн».
  ResolvedStream _localStream(String path) => ResolvedStream(
        url: Uri.file(path),
        expiresAt: DateTime.now().add(const Duration(days: 3650)),
        container: 'm4a',
        localPath: path,
      );

  /// Ошибка похожа на «сети нет», а не на отказ сервера.
  bool _isNetworkError(Object error) =>
      error is SocketException ||
      error is TimeoutException ||
      error is HandshakeException ||
      error is HttpException ||
      error is http.ClientException;

  /// То же, но по тексту: тип исключения мог потеряться по пути.
  bool _looksLikeNetworkText(String text) {
    final String lower = text.toLowerCase();
    return lower.contains('socketexception') ||
        lower.contains('clientexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('connection closed') ||
        lower.contains('connection refused') ||
        lower.contains('connection reset') ||
        lower.contains('network is unreachable') ||
        lower.contains('timed out') ||
        lower.contains('timeout');
  }

  /// Запрос `player` выбранным профилем клиента.
  Future<ResolvedStream?> _resolveWithProfile(
    YoutubeClientProfile profile,
    String videoId,
    AudioQuality quality,
    String? preferContainer,
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
      // Вход здесь НЕ нужен, и с ним нельзя: если есть сессия, YouTube
      // отвечает на этот запрос с VR-профилями (visionOS, Android VR, iOS)
      // ошибкой 400. Без авторизации те же профили отдают ссылку, которая
      // открывается обычным GET — именно так играют ArchiveTune и Metrolist.
      authenticated: false,
    );

    final dynamic status = response['playabilityStatus'];
    final String state = status is Map ? '${status['status']}' : '?';
    if (state != 'OK') {
      debugPrint('[Поток] ${profile.label}: $state '
          '${status is Map ? status['reason'] ?? '' : ''}');
      return null;
    }

    return _pickFromPlayerResponse(
      response,
      quality,
      profile,
      preferContainer,
    );
  }

  /// Запасной путь: библиотека со своим клиентом по умолчанию.
  Future<ResolvedStream?> _resolveWithLibrary(
    String videoId,
    AudioQuality quality,
    String? preferContainer,
  ) async {
    final StreamManifest manifest =
        await _library.videos.streamsClient.getManifest(videoId);

    final List<AudioOnlyStreamInfo> audio = manifest.audioOnly.toList();
    if (audio.isEmpty) return null;

    final List<_AudioCandidate> candidates = audio
        .map((AudioOnlyStreamInfo stream) => _AudioCandidate(
              url: stream.url,
              bitrateKbps: stream.bitrate.kiloBitsPerSecond.round(),
              // Библиотека называет контейнер `mp4`, а приложение везде
              // говорит `m4a` — приводим к одному имени, иначе предпочтение
              // контейнера при загрузке не совпадёт.
              container: stream.container.name == 'webm' ? 'webm' : 'm4a',
              mimeType: stream.container.name == 'webm'
                  ? 'audio/webm'
                  : 'audio/mp4',
            ))
        .toList();

    return _pickCandidate(candidates, quality, preferContainer);
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
    String? preferContainer,
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
    return _pickCandidate(candidates, quality, preferContainer);
  }

  /// Выбирает дорожку под желаемое качество.
  ///
  /// «Максимум» — лучшая доступная дорожка, «экономия» — самая дешёвая,
  /// «среднее» — ближайшая к целевым 128 kbps. Для «среднего» важна именно
  /// близость, а не «строго не выше цели»: YouTube отдаёт фактический битрейт
  /// дорожки, а не номинальный, — у itag 140 это 130–131 kbps при номинале 128,
  /// и отбор «не выше 128» промахивался мимо него, роняя «среднее» до
  /// ~70 kbps Opus, хотя рядом лежала дорожка ~128 kbps.
  ResolvedStream? _pickCandidate(
    List<_AudioCandidate> candidates,
    AudioQuality quality,
    String? preferContainer,
  ) {
    if (candidates.isEmpty) return null;

    // Для загрузки контейнер важен: файл называется `.m4a`, и лучше, чтобы
    // содержимое соответствовало имени. Если m4a у видео нет — берём как
    // есть: плеер определяет формат по содержимому.
    final List<_AudioCandidate> matching = preferContainer == null
        ? candidates
        : candidates
            .where((_AudioCandidate c) => c.container == preferContainer)
            .toList();
    final List<_AudioCandidate> pool =
        matching.isEmpty ? candidates : matching;

    pool.sort((_AudioCandidate a, _AudioCandidate b) =>
        a.bitrateKbps.compareTo(b.bitrateKbps));

    // Список отсортирован по возрастанию, поэтому «экономия» — это первый.
    _AudioCandidate chosen = pool.first;
    if (quality == AudioQuality.high) {
      chosen = pool.last;
    } else if (quality == AudioQuality.medium) {
      chosen = _nearestToTarget(pool, quality.targetKbps);
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

  /// Дорожка, ближайшая к целевому битрейту; при равной близости — дешевле
  /// (список отсортирован по возрастанию, строгое «<» оставляет прежнюю).
  _AudioCandidate _nearestToTarget(
    List<_AudioCandidate> candidates,
    int targetKbps,
  ) {
    _AudioCandidate best = candidates.first;
    for (final _AudioCandidate candidate in candidates) {
      if ((candidate.bitrateKbps - targetKbps).abs() <
          (best.bitrateKbps - targetKbps).abs()) {
        best = candidate;
      }
    }
    return best;
  }

  @override
  void dispose() {
    _cache.clear();
    _library.close();
  }
}
