import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/audio/audio_engine.dart';
import '../../core/webview/webview_environment.dart';
import '../local/app_settings.dart';
import 'stream_resolver.dart';

/// Ссылка на медиапоток, которую нашла веб-сессия.
@immutable
class SessionMediaLink {
  const SessionMediaLink({
    required this.url,
    required this.mimeType,
    required this.expiresAt,
    this.bitrateKbps,
  });

  final Uri url;

  /// Тип потока без параметров кодека (`audio/webm`, `audio/mp4`).
  final String mimeType;

  final DateTime expiresAt;

  /// Битрейт в кбит/с; `null` — в ссылке его не было.
  final int? bitrateKbps;

  String get container => mimeType.contains('webm') ? 'webm' : 'm4a';
}

/// Получение потока через веб-сессию приложения.
///
/// Зачем. Часть треков сервер не отдаёт ни одному клиенту InnerTube: на все
/// форматы приходит 503, хотя в браузере тот же трек играет. У приложения есть
/// WebView2 с профилем и cookie пользователя, поэтому последний рубеж — открыть
/// страницу трека в невидимом `HeadlessInAppWebView` и забрать ссылку, которую
/// запросил сам веб-плеер.
///
/// Приоритет у перехвата запросов (`shouldInterceptRequest`): только ссылка,
/// которую браузер реально дёрнул, содержит актуальный токен и параметры
/// сессии. JS-путь через `getPlayerResponse()` — запасной: там ссылка может
/// оказаться без подписи или с `signatureCipher`.
///
/// Ссылка отдаётся вместе с `User-Agent` и `Cookie` страницы: без них
/// медиасервер отвечает отказом. Заголовки попадают и в проверку ссылки, и в
/// движок (см. [StreamRequestHeaders]).
class WebSessionResolver implements StreamResolver {
  WebSessionResolver({
    this.timeout = const Duration(seconds: 12),
    StreamLinkChecker? checker,
  }) : _checker =
            checker ?? StreamLinkChecker(timeout: const Duration(seconds: 4));

  /// Сколько всего ждать ссылку: загрузка страницы, старт плеера и перехват.
  ///
  /// Двенадцать секунд — это заметно для человека, но веб-путь включается
  /// только там, где другие способы уже получили отказ.
  final Duration timeout;

  final StreamLinkChecker _checker;

  /// Ссылки живут часами, а подъём WebView — самая дорогая операция здесь.
  final Map<String, ResolvedStream> _cache = <String, ResolvedStream>{};

  /// Очередь WebView: одновременно работает не больше одного.
  ///
  /// WebView2 — тяжёлый процесс, и несколько невидимых страниц сразу боролись
  /// бы за тот же профиль и звуковое устройство. Очередь живёт на классе:
  /// резолверов в приложении может быть несколько.
  static Future<void> _queue = Future<void>.value();

  /// Окружение WebView2 должно быть подготовлено при старте приложения.
  ///
  /// Без него WebView2 создал бы профиль рядом с exe (в `Program Files` без
  /// прав на запись), поэтому на Windows честнее не пытаться. На других
  /// системах окружения нет по определению — там плагин использует свой движок.
  @override
  bool get isAvailable => !Platform.isWindows || mopsWebViewEnvironment != null;

  @override
  Future<ResolvedStream> resolve(
    String videoId, {
    required AudioQuality quality,
    String? preferContainer,
  }) async {
    final ResolvedStream? cached = _cache[videoId];
    if (cached != null && !cached.isExpired) return cached;

    if (!isAvailable) {
      throw StreamResolutionException(
        'Веб-сессия недоступна: встроенный браузер не подготовлен.',
        unavailable: true,
      );
    }

    // Один WebView за раз. Ждём предыдущий, даже если он завершился ошибкой:
    // очередь хранит только завершение, а не результат.
    final Completer<void> release = Completer<void>();
    final Future<void> previous = _queue;
    _queue = release.future;
    await previous;

    try {
      // Пока ждали очередь, этот же трек мог разрешиться.
      final ResolvedStream? ready = _cache[videoId];
      if (ready != null && !ready.isExpired) return ready;

      final ResolvedStream stream = await _resolveInSession(
        videoId,
        quality: quality,
        preferContainer: preferContainer,
      );
      _cache[videoId] = stream;
      _trimCache();
      return stream;
    } finally {
      release.complete();
    }
  }

  /// Открывает невидимую страницу трека и ждёт ссылку на медиа.
  Future<ResolvedStream> _resolveInSession(
    String videoId, {
    required AudioQuality quality,
    String? preferContainer,
  }) async {
    final Completer<_SessionCapture> captured = Completer<_SessionCapture>();
    final List<InAppWebViewController?> controller =
        <InAppWebViewController?>[null];
    HeadlessInAppWebView? webView;
    final DateTime deadline = DateTime.now().add(timeout);

    void complete(SessionMediaLink link, {required bool intercepted}) {
      if (captured.isCompleted) return;
      captured.complete(_SessionCapture(link, intercepted: intercepted));
    }

    try {
      webView = HeadlessInAppWebView(
        initialSize: const Size(480, 270),
        // То же окружение, что у окна входа: там лежат cookie пользователя,
        // и только с ними сервер считает нас тем же клиентом.
        webViewEnvironment: Platform.isWindows ? mopsWebViewEnvironment : null,
        initialUrlRequest: URLRequest(
          url: WebUri('https://music.youtube.com/watch?v=$videoId'),
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          // Плееру некому нажать «играть»: без этого Chromium ждал бы жеста.
          mediaPlaybackRequiresUserGesture: false,
          // Слушаем запросы страницы — это главный путь.
          useShouldInterceptRequest: true,
          cacheEnabled: true,
        ),
        // Глушим страницу до того, как её скрипты создадут плеер: невидимая
        // страница делит звуковое устройство с плеером приложения.
        initialUserScripts: UnmodifiableListView<UserScript>(<UserScript>[
          UserScript(
            source: _muteScript,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
        ]),
        onWebViewCreated: (InAppWebViewController created) {
          controller[0] = created;
        },
        onLoadStop: (InAppWebViewController created, WebUri? url) {
          unawaited(_nudgePlayer(created));
        },
        shouldInterceptRequest: (
          InAppWebViewController created,
          WebResourceRequest request,
        ) async {
          final SessionMediaLink? link =
              mediaRequestLink(request.url.toString());
          if (link != null) complete(link, intercepted: true);
          // `null` — запрос идёт как обычно: мы только слушаем, а не подменяем.
          return null;
        },
      );
      await webView.run();

      // Перехват обычно срабатывает в первые секунды. Если нет — пробуем
      // ответ плеера, но реже: он весит мегабайты, и дёргать его на каждом
      // шаге ожидания незачем.
      int round = 0;
      while (!captured.isCompleted && DateTime.now().isBefore(deadline)) {
        final InAppWebViewController? created = controller[0];
        if (created != null && round % 5 == 0) {
          final SessionMediaLink? fromPlayer = await _linkFromPlayer(
            created,
            quality: quality,
            preferContainer: preferContainer,
          );
          if (fromPlayer != null) {
            complete(fromPlayer, intercepted: false);
            break;
          }
        }
        if (created != null && round % 4 == 3) {
          unawaited(_nudgePlayer(created));
        }
        round++;
        await _waitForCapture(captured, deadline);
      }

      if (!captured.isCompleted) {
        throw StreamResolutionException(
          'Веб-сессия не отдала ссылку на поток: страница не начала '
          'воспроизведение.',
          unavailable: true,
        );
      }

      final _SessionCapture result = await captured.future;
      // Заголовки читаем, пока страница открыта: после закрытия cookie и
      // User-Agent уже не спросить.
      final Map<String, String> headers = await _sessionHeaders(controller[0]);
      final ResolvedStream stream = ResolvedStream(
        url: result.link.url,
        bitrateKbps: result.link.bitrateKbps,
        container: result.link.container,
        mimeType: result.link.mimeType,
        userAgent: headers['User-Agent'],
        httpHeaders: headers.isEmpty ? null : headers,
        expiresAt: result.link.expiresAt,
      );

      // Ссылку из чужой сессии проверяем теми же заголовками, с которыми её
      // получит плеер: иначе проверка судила бы о другом запросе.
      final StreamLinkProbe probe = await _checker.check(
        stream.url,
        userAgent: stream.userAgent,
        headers: stream.httpHeaders,
      );
      if (probe.state == StreamLinkState.refused) {
        throw StreamResolutionException(
          'Веб-сессия получила ссылку, но медиасервер её не отдал '
          '(${probe.statusCode ?? '?'}).',
          unavailable: true,
        );
      }

      StreamRequestHeaders.remember(stream.url, stream.httpHeaders);
      debugPrint(
        '[WebView] ${result.intercepted ? 'перехват' : 'JS'}: '
        '${stream.container ?? '?'} ${stream.bitrateKbps ?? '?'} kbps',
      );
      return stream;
    } on StreamResolutionException {
      rethrow;
    } on Object catch (error) {
      throw StreamResolutionException(
        'Веб-сессия не смогла получить поток: $error',
        unavailable: true,
      );
    } finally {
      // Закрываем всегда: и при успехе, и при таймауте, и при ошибке.
      final HeadlessInAppWebView? closing = webView;
      if (closing != null) {
        try {
          await closing.dispose();
        } on Object catch (error) {
          debugPrint('[WebView] не удалось закрыть невидимую страницу: $error');
        }
      }
    }
  }

  /// Ждёт ссылку один шаг, но не дольше дедлайна.
  Future<void> _waitForCapture(
    Completer<_SessionCapture> captured,
    DateTime deadline,
  ) async {
    final Duration left = deadline.difference(DateTime.now());
    if (left.isNegative) return;

    const Duration step = Duration(milliseconds: 700);
    final Duration wait = left < step ? left : step;
    await Future.any<void>(<Future<void>>[
      captured.future.then((_) {}),
      Future<void>.delayed(wait),
    ]);
  }

  /// Запускает воспроизведение и глушит звук страницы.
  ///
  /// Невидимая страница использует то же звуковое устройство, что и плеер, —
  /// без глушения трек слышался бы дважды. Приглушённый поток Chromium
  /// разрешает запускать без жеста пользователя.
  Future<void> _nudgePlayer(InAppWebViewController controller) async {
    try {
      await controller
          .evaluateJavascript(source: _nudgeScript)
          .timeout(const Duration(seconds: 2));
    } on Object catch (error) {
      debugPrint('[WebView] не удалось запустить веб-плеер: $error');
    }
  }

  /// Запасной путь: ответ плеера со списком аудиодорожек.
  Future<SessionMediaLink?> _linkFromPlayer(
    InAppWebViewController controller, {
    required AudioQuality quality,
    String? preferContainer,
  }) async {
    try {
      final dynamic raw = await controller
          .evaluateJavascript(source: _playerResponseScript)
          .timeout(const Duration(seconds: 3));
      if (raw is! String || raw.isEmpty) return null;

      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return pickFromPlayerResponse(
        Map<String, dynamic>.from(decoded),
        quality: quality,
        preferContainer: preferContainer,
      );
    } on Object catch (error) {
      debugPrint('[WebView] не удалось прочитать ответ веб-плеера: $error');
      return null;
    }
  }

  /// `User-Agent` и cookie страницы — то, с чем сервер пускает к потоку.
  Future<Map<String, String>> _sessionHeaders(
    InAppWebViewController? controller,
  ) async {
    String? userAgent;
    if (controller != null) {
      try {
        final dynamic raw = await controller
            .evaluateJavascript(source: 'navigator.userAgent')
            .timeout(const Duration(seconds: 2));
        if (raw is String && raw.trim().isNotEmpty) {
          userAgent = raw.trim();
        }
      } on Object catch (error) {
        debugPrint('[WebView] не удалось прочитать User-Agent: $error');
      }
    }

    // Оба хоста: часть cookie привязана к `music.youtube.com`, часть — к
    // `.youtube.com`, а странице нужны все.
    final Map<String, String> cookies = <String, String>{};
    for (final String host in <String>[
      'https://music.youtube.com',
      'https://www.youtube.com',
    ]) {
      try {
        final List<Cookie> found = await cookieManager()
            .getCookies(url: WebUri(host))
            .timeout(const Duration(seconds: 2));
        for (final Cookie cookie in found) {
          if (cookie.value.isEmpty) continue;
          cookies[cookie.name] = cookie.value;
        }
      } on Object catch (error) {
        debugPrint('[WebView] не удалось прочитать cookie $host: $error');
      }
    }

    return <String, String>{
      'User-Agent': ?userAgent,
      if (cookies.isNotEmpty)
        'Cookie': cookies.entries
            .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
            .join('; '),
    };
  }

  /// Разбирает запрос, который сделал веб-плеер.
  ///
  /// Подходит только аудио с `googlevideo.com`: видеодорожки клипов нам не
  /// нужны, а прочие запросы страницы — тем более. Параметр `range` убирается:
  /// браузер просит им отдельный кусок, а плееру нужен весь поток.
  @visibleForTesting
  static SessionMediaLink? mediaRequestLink(String raw, {DateTime? now}) {
    final Uri? uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (!_isMediaHost(uri.host)) return null;
    if (!uri.path.contains('videoplayback')) return null;

    final String mime = uri.queryParameters['mime'] ?? '';
    if (!mime.startsWith('audio')) return null;

    final int? bitrate = int.tryParse(uri.queryParameters['bitrate'] ?? '');
    return SessionMediaLink(
      url: _withoutRange(uri),
      mimeType: mime,
      bitrateKbps: bitrate == null || bitrate <= 0 ? null : bitrate ~/ 1000,
      expiresAt: _expiryOf(uri) ??
          (now ?? DateTime.now()).add(const Duration(hours: 5)),
    );
  }

  /// Выбирает аудиодорожку из ответа веб-плеера (`ytInitialPlayerResponse`).
  ///
  /// Дорожки без готовой `url` пропускаются: `signatureCipher` расшифровать
  /// здесь нечем, и честнее вернуть `null`, чем ссылку, которая не заиграет.
  @visibleForTesting
  static SessionMediaLink? pickFromPlayerResponse(
    Map<String, dynamic> response, {
    required AudioQuality quality,
    String? preferContainer,
    DateTime? now,
  }) {
    final dynamic data = response['streamingData'];
    if (data is! Map) return null;

    final List<dynamic> formats = <dynamic>[
      ...(data['adaptiveFormats'] as List<dynamic>? ?? <dynamic>[]),
      ...(data['formats'] as List<dynamic>? ?? <dynamic>[]),
    ];

    final List<SessionMediaLink> audio = <SessionMediaLink>[];
    for (final dynamic item in formats) {
      if (item is! Map) continue;
      final String mime = '${item['mimeType']}';
      if (!mime.startsWith('audio')) continue;

      final Object? url = item['url'];
      if (url is! String || url.isEmpty) continue;

      final Uri parsed = Uri.parse(url);
      final int bitrate = ((item['bitrate'] as num?) ?? 0).toInt();
      audio.add(SessionMediaLink(
        url: parsed,
        mimeType: mime.split(';').first.trim(),
        bitrateKbps: bitrate <= 0 ? null : bitrate ~/ 1000,
        expiresAt: _expiryOf(parsed) ??
            (now ?? DateTime.now()).add(const Duration(hours: 5)),
      ));
    }
    if (audio.isEmpty) return null;

    int bitrateOf(SessionMediaLink link) => link.bitrateKbps ?? 0;
    audio.sort(
      (SessionMediaLink a, SessionMediaLink b) =>
          bitrateOf(a).compareTo(bitrateOf(b)),
    );

    final List<SessionMediaLink> preferred = preferContainer == null
        ? audio
        : audio
            .where((SessionMediaLink l) => l.container == preferContainer)
            .toList();
    final List<SessionMediaLink> pool = preferred.isEmpty ? audio : preferred;

    return switch (quality) {
      AudioQuality.high => pool.last,
      AudioQuality.low => pool.first,
      AudioQuality.medium => _nearestToTarget(pool, quality.targetKbps),
    };
  }

  /// Дорожка, ближайшая к целевому битрейту (как в обычном резолвере).
  static SessionMediaLink _nearestToTarget(
    List<SessionMediaLink> pool,
    int targetKbps,
  ) {
    int bitrateOf(SessionMediaLink link) => link.bitrateKbps ?? 0;
    SessionMediaLink best = pool.first;
    for (final SessionMediaLink link in pool) {
      if ((bitrateOf(link) - targetKbps).abs() <
          (bitrateOf(best) - targetKbps).abs()) {
        best = link;
      }
    }
    return best;
  }

  static bool _isMediaHost(String host) =>
      host == 'googlevideo.com' || host.endsWith('.googlevideo.com');

  static Uri _withoutRange(Uri uri) {
    if (!uri.queryParameters.containsKey('range')) return uri;
    final Map<String, String> query =
        Map<String, String>.of(uri.queryParameters);
    query.remove('range');
    return uri.replace(queryParameters: query);
  }

  /// Срок годности ссылки — параметр `expire` (секунды Unix).
  static DateTime? _expiryOf(Uri uri) {
    final int? seconds = int.tryParse(uri.queryParameters['expire'] ?? '');
    if (seconds == null || seconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }

  void _trimCache() {
    _cache.removeWhere(
      (String _, ResolvedStream stream) => stream.isExpired,
    );
    while (_cache.length > 8) {
      _cache.remove(_cache.keys.first);
    }
  }

  @override
  void dispose() {
    _cache.clear();
    _checker.dispose();
  }
}

/// Что дал перехват: ссылка и каким путём она получена (для журнала).
class _SessionCapture {
  const _SessionCapture(this.link, {required this.intercepted});

  final SessionMediaLink link;
  final bool intercepted;
}

/// Запускает веб-плеер и глушит страницу.
const String _nudgeScript = '''
(function () {
  try {
    var media = document.querySelectorAll('video, audio');
    for (var i = 0; i < media.length; i++) {
      media[i].muted = true;
      var started = media[i].play();
      if (started && started.catch) started.catch(function () {});
    }
    var player = document.querySelector('#movie_player');
    if (player && player.playVideo) player.playVideo();
    return 'ok';
  } catch (error) {
    return String(error);
  }
})()
''';

/// Выполняется до скриптов страницы: новые элементы плеера тоже должны быть
/// беззвучными, иначе трек слышно дважды — из браузера и из mpv.
const String _muteScript = '''
(function () {
  function mute() {
    var media = document.querySelectorAll('video, audio');
    for (var i = 0; i < media.length; i++) {
      media[i].muted = true;
      media[i].volume = 0;
    }
  }
  mute();
  if (document.addEventListener) {
    document.addEventListener('DOMContentLoaded', mute);
  }
  setInterval(mute, 250);
})();
''';

/// Отдаёт ответ плеера строкой: так его можно разобрать в Dart.
const String _playerResponseScript = '''
(function () {
  try {
    var player = document.querySelector('#movie_player');
    if (player && player.getPlayerResponse) {
      var response = player.getPlayerResponse();
      if (response) return JSON.stringify(response);
    }
    if (window.ytInitialPlayerResponse) {
      return JSON.stringify(window.ytInitialPlayerResponse);
    }
    return '';
  } catch (error) {
    return '';
  }
})()
''';
