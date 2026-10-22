import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../core/audio/audio_engine.dart';
import '../../core/innertube/innertube_client.dart';
import '../local/app_settings.dart';
import 'web_session_resolver.dart';
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
    this.httpHeaders,
    this.localPath,
  });

  final Uri url;
  final int? bitrateKbps;
  final String? container;
  final bool isLive;

  /// Пользовательский агент, с которым запрашивался поток.
  final String? userAgent;

  /// Заголовки, без которых сервер поток не отдаст.
  ///
  /// Заполнены только у ссылки из веб-сессии: там нужны `User-Agent` и
  /// `Cookie` страницы. Обычные ссылки YouTube работают без заголовков.
  final Map<String, String>? httpHeaders;

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

/// Что дала проверка ссылки на поток.
enum StreamLinkState {
  /// Сервер отдал данные — ссылку можно передавать плееру.
  ok,

  /// Явный отказ: HTTP-код вне 2xx или пустое тело.
  refused,

  /// Проверить не удалось (сеть, таймаут, прокси). О доступности самого
  /// трека это ничего не говорит.
  unchecked,
}

/// Итог проверки ссылки: состояние и HTTP-код отказа, если он был.
@immutable
class StreamLinkProbe {
  const StreamLinkProbe(this.state, {this.statusCode, this.detail});

  final StreamLinkState state;

  /// Код ответа, которым сервер отказал; `null` у успеха и сетевых сбоев.
  final int? statusCode;

  /// Текст сетевой ошибки — только для лога.
  final String? detail;
}

/// Проверка, что медиасервер действительно отдаёт поток.
///
/// googlevideo умеет отвечать на готовую ссылку `503` с пустым телом: URL
/// формально получен, но звука не будет, и ошибка всплывает уже в плеере без
/// понятного текста. Один запрос `Range: bytes=0-0` отличает такую ссылку от
/// рабочей за десятки миллисекунд.
///
/// Отказом считается только явный HTTP-ответ. Сетевую ошибку (таймаут, обрыв,
/// прокси не пустил) отказом считать нельзя: при работающем обходе блокировок
/// проверка может не пройти там, где плеер потом сыграет.
class StreamLinkChecker {
  StreamLinkChecker({this.timeout = const Duration(seconds: 4)});

  /// Сколько всего ждать проверку — соединение, заголовки и первый байт.
  ///
  /// Коротко намеренно: проверка не должна задерживать запуск трека, а
  /// медленный сервер — это не «трек удалён».
  final Duration timeout;

  HttpClient? _client;

  /// Настройки обхода, при которых создан [_client].
  ///
  /// Прокси и подмена хоста применяются глобально: клиент, созданный до
  /// включения прокси, о нём не узнает. Сверяем и пересоздаём — иначе
  /// проверка ходила бы мимо только что включённого прокси.
  HttpOverrides? _overrides;

  Future<StreamLinkProbe> check(
    Uri url, {
    String? userAgent,
    Map<String, String>? headers,
  }) async {
    // Не HTTP — проверять нечего: отказа сервера тут быть не может.
    if (url.scheme != 'http' && url.scheme != 'https') {
      return const StreamLinkProbe(StreamLinkState.unchecked);
    }

    // Общий срок на все шаги: иначе зависший на каждом из них сервер держал
    // бы запуск трека втрое дольше заявленного таймаута.
    final DateTime deadline = DateTime.now().add(timeout);
    Duration left() {
      final Duration remaining = deadline.difference(DateTime.now());
      return remaining.isNegative ? Duration.zero : remaining;
    }

    try {
      final HttpClient client = _clientForCurrentOverrides();
      final HttpClientRequest request =
          await client.getUrl(url).timeout(left());
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final String? agent = userAgent;
      if (agent != null && agent.isNotEmpty) {
        request.headers.set(HttpHeaders.userAgentHeader, agent);
      }
      // Ссылка из веб-сессии проверяется теми же заголовками, с которыми её
      // получит плеер: иначе проверка судила бы о другом запросе.
      headers?.forEach((String name, String value) {
        if (name.toLowerCase() == 'user-agent') return;
        if (value.isEmpty) return;
        request.headers.set(name, value);
      });

      final HttpClientResponse response =
          await request.close().timeout(left());
      final int code = response.statusCode;
      if (code < 200 || code >= 300) {
        await _drainQuietly(response, left());
        return StreamLinkProbe(StreamLinkState.refused, statusCode: code);
      }

      // 2xx с пустым телом — та же заглушка, что и 503: заголовки есть,
      // данных нет. Проверяем и явный нулевой размер, и пустой поток.
      if (response.contentLength == 0) {
        return StreamLinkProbe(StreamLinkState.refused, statusCode: code);
      }
      final bool hasData = await _firstChunk(response, left());
      return hasData
          ? const StreamLinkProbe(StreamLinkState.ok)
          : StreamLinkProbe(StreamLinkState.refused, statusCode: code);
    } on Object catch (error) {
      return StreamLinkProbe(StreamLinkState.unchecked, detail: '$error');
    }
  }

  HttpClient _clientForCurrentOverrides() {
    final HttpOverrides? overrides = HttpOverrides.current;
    final HttpClient? existing = _client;
    if (existing != null && identical(overrides, _overrides)) return existing;

    existing?.close(force: true);
    _overrides = overrides;
    return _client = HttpClient()..connectionTimeout = timeout;
  }

  /// Читает первый кусок тела и обрывает соединение: весь файл не нужен.
  ///
  /// Таймаут здесь — сетевая ошибка, а не отказ: его обрабатывает [check].
  Future<bool> _firstChunk(HttpClientResponse response, Duration limit) async {
    final Completer<bool> chunk = Completer<bool>();
    late final StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      (List<int> data) {
        if (!chunk.isCompleted && data.isNotEmpty) chunk.complete(true);
      },
      onError: (Object error) {
        if (!chunk.isCompleted) chunk.completeError(error);
      },
      onDone: () {
        if (!chunk.isCompleted) chunk.complete(false);
      },
      cancelOnError: true,
    );
    try {
      return await chunk.future.timeout(limit);
    } finally {
      await subscription.cancel();
    }
  }

  /// Дочитывает маленькое тело отказа, чтобы не оставлять соединение
  /// полуоткрытым в пуле клиента.
  Future<void> _drainQuietly(
    HttpClientResponse response,
    Duration limit,
  ) async {
    try {
      await response.drain<void>().timeout(limit);
    } on Object {
      // Код ответа уже получен; потеря тела отказа ничего не меняет.
    }
  }

  void dispose() {
    _client?.close(force: true);
    _client = null;
  }
}

/// Контракт получения потока. Реализации можно менять независимо от UI.
abstract class StreamResolver {
  /// Можно ли пользоваться этим источником сейчас.
  ///
  /// У веб-сессии путь зависит от подготовленного окружения WebView2: если
  /// его нет, поднимать браузер бессмысленно, и вызывающий пропускает источник
  /// вовсе, а не ждёт ошибку.
  bool get isAvailable => true;

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
  StreamResolutionException(this.message, {this.unavailable = false});

  final String message;

  /// Трек не отдаётся площадкой: удалён, скрыт или ограничен по региону.
  ///
  /// Признак ставит резолвер, когда сервер потока ответил явным отказом.
  /// По тексту такой случай от «недоступно» не отличить надёжно, а от него
  /// зависит, предложить ли замену трека.
  final bool unavailable;

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

/// Результат перебора ссылок источника.
@immutable
class _Verified {
  const _Verified(this.stream, {required this.checked});

  final ResolvedStream stream;

  /// Ссылка действительно проверена сервером.
  ///
  /// Непроверенную (сеть не дала) не кэшируем: иначе временный обрыв закрепил
  /// бы сомнительный адрес на часы, и повторная попытка не переспросила бы
  /// сервер.
  final bool checked;
}

/// Все проверенные ссылки одного источника получили явный отказ сервера.
///
/// Отдельное исключение, чтобы отказ не смешивался с сетевыми сбоями: только
/// он даёт право сказать «трек недоступен».
class _StreamRefused implements Exception {
  const _StreamRefused(this.statusCode);

  /// Код последнего отказа; `null`, если отказ был по пустому телу без кода.
  final int? statusCode;

  @override
  String toString() => 'сервер не отдаёт поток (${statusCode ?? '?'})';
}

/// Сколько вариантов одной ссылки проверять, прежде чем признать источник
/// отказавшим.
///
/// Отказ приходит быстро (503 на любой формат), а вот медленный ответ — это
/// сетевая ошибка, после которой проверка прекращается сама. Предел нужен на
/// случай, когда сервер отвечает отказом, но не сразу: трек не должен
/// «висеть» на десятке таймаутов.
const int _kMaxProbesPerSource = 4;

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
    this.fallbackLinks,
    StreamResolver? webSession,
  })  : _library = library ??
            YoutubeExplode(
              httpClient: AuthenticatedYoutubeClient(authHeaders),
            ),
        // Последний рубеж — плеер веб-сессии приложения. Создаётся сразу, но
        // WebView поднимает только явный отказ сервера (см. [resolve]).
        _webSession = webSession ?? WebSessionResolver();

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

  /// Запасной источник ссылок вместо библиотеки.
  ///
  /// Нужен тестам: перебор и проверка ссылок при этом остаются боевыми, а
  /// сеть подменяется локальным сервером. `null` — обычный путь через
  /// `youtube_explode_dart`. Ссылки должны идти в порядке предпочтения.
  final Future<List<ResolvedStream>> Function(String videoId)? fallbackLinks;

  final YoutubeExplode _library;

  /// Запасной резолвер через веб-сессию (WebView2 с cookie пользователя).
  ///
  /// Приходит из конструктора, чтобы тесты могли подставить заглушку; по
  /// умолчанию — [WebSessionResolver].
  final StreamResolver? _webSession;

  /// Какой клиент YouTube использовать для получения ссылки.
  final StreamSource clientChoice;

  /// Кэш: ссылки живут часами, а запрос — довольно дорогая операция.
  final Map<String, ResolvedStream> _cache = <String, ResolvedStream>{};

  /// Проверка ссылки перед выдачей: один клиент на резолвер, чтобы его пул
  /// соединений переиспользовался между треками.
  final StreamLinkChecker _checker = StreamLinkChecker();

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
    if (cached != null && !cached.isExpired) {
      // Заголовки могли вытесниться из хранилища движка, а ссылка из кэша
      // осталась: без них плеер сходит за потоком как гость.
      return _rememberHeaders(cached);
    }

    final List<String> failures = <String>[];
    // Сетевые сбои отличаем от отказов YouTube: во втором случае совет
    // «проверьте соединение» бесполезен, а в первом — важно сказать, что
    // трек не скачан.
    bool networkFailure = false;
    // Последний явный отказ медиасервера. Именно он, а не текст ошибки,
    // решает, что трек недоступен.
    int? refusedCode;

    for (final YoutubeClientProfile profile
        in YoutubeClients.forChoice(clientChoice)) {
      try {
        final List<_AudioCandidate> candidates =
            await _candidatesWithProfile(profile, videoId);
        if (candidates.isEmpty) {
          failures.add('${profile.label}: ссылок нет');
          continue;
        }
        final _Verified pick = await _verifiedPick(
          _linksFrom(candidates, quality, preferContainer),
          source: profile.label,
        );
        if (pick.checked) _cache[key] = pick.stream;
        return _rememberHeaders(pick.stream);
      } on _StreamRefused catch (refusal) {
        refusedCode = refusal.statusCode;
        failures.add('${profile.label}: $refusal');
      } on Object catch (error) {
        if (_isNetworkError(error)) networkFailure = true;
        failures.add('${profile.label}: $error');
      }
    }

    // Запасной путь — библиотека с её клиентом по умолчанию.
    try {
      final List<ResolvedStream> links = fallbackLinks != null
          ? await fallbackLinks!(videoId)
          : await _libraryLinks(videoId, quality, preferContainer);
      if (links.isEmpty) {
        failures.add('библиотека: ссылок нет');
      } else {
        final _Verified pick = await _verifiedPick(
          links,
          source: 'библиотека',
        );
        if (pick.checked) _cache[key] = pick.stream;
        return _rememberHeaders(pick.stream);
      }
    } on _StreamRefused catch (refusal) {
      refusedCode = refusal.statusCode;
      failures.add('библиотека: $refusal');
    } on Object catch (error) {
      if (_isNetworkError(error)) networkFailure = true;
      failures.add('библиотека: $error');
    }

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

    // Последний рубеж — веб-сессия приложения: она играет тот же трек в
    // браузере, поэтому её ссылка срабатывает там, где сервер отказал всем
    // клиентам. Запускаем только при явном отказе сервера: при обрыве сети
    // браузер не поможет, а поднимать WebView на каждый трек недопустимо.
    if (!offline && (refusedCode != null || unavailable)) {
      final ResolvedStream? fromWeb = await _resolveViaWebSession(
        videoId,
        quality: quality,
        preferContainer: preferContainer,
        failures: failures,
      );
      if (fromWeb != null) {
        _cache[key] = _rememberHeaders(fromWeb);
        return fromWeb;
      }
    }

    debugPrint('Не удалось получить поток для $videoId: ${failures.join("; ")}');

    throw StreamResolutionException(
      needsLogin
          ? 'YouTube требует вход в аккаунт для этого видео. '
              'Войдите в приложении и попробуйте снова.'
          : refusedCode != null
              // Явный отказ важнее прочих догадок: сервер ответил, а не
              // пропал, и повторять запрос бессмысленно — нужна замена.
              ? 'Сервер не отдаёт этот трек ($refusedCode) — возможно, он '
                  'недоступен в регионе или удалён.'
              : unavailable
                  ? 'YouTube не отдаёт это видео: оно недоступно в вашем '
                      'регионе или требует вход в аккаунт.'
                  : offline
                      ? 'Не удалось получить поток: сети нет или соединение с '
                          'YouTube блокируется. Этот трек не скачан — скачайте '
                          'его заранее (меню трека → «Скачать»), и он сыграет '
                          'без интернета.'
                      : 'Не удалось получить аудиопоток. '
                          'Проверьте соединение и попробуйте снова.',
      unavailable: refusedCode != null || unavailable,
    );
  }

  /// Пробует добыть ссылку через веб-сессию приложения.
  ///
  /// Возвращает `null`, если источник недоступен или не справился: тогда
  /// ошибка остаётся прежней, ведь браузер не отменяет отказ сервера —
  /// просто не смог его обойти.
  Future<ResolvedStream?> _resolveViaWebSession(
    String videoId, {
    required AudioQuality quality,
    String? preferContainer,
    required List<String> failures,
  }) async {
    final StreamResolver? web = _webSession;
    if (web == null || !web.isAvailable) return null;

    try {
      final ResolvedStream stream = await web.resolve(
        videoId,
        quality: quality,
        preferContainer: preferContainer,
      );
      debugPrint('[Поток] веб-сессия дала ссылку для $videoId');
      return stream;
    } on Object catch (error) {
      failures.add('веб-сессия: $error');
      debugPrint('[Поток] веб-сессия не помогла для $videoId: $error');
      return null;
    }
  }

  /// Запоминает заголовки ссылки для движка и возвращает её же.
  ///
  /// Движок получает от контроллера только адрес (см. `StreamRequestHeaders`),
  /// поэтому заголовки нужно положить в общее хранилище на каждом пути, где
  /// ссылка может уйти в плеер, — в том числе при выдаче из кэша.
  ResolvedStream _rememberHeaders(ResolvedStream stream) {
    StreamRequestHeaders.remember(stream.url, stream.httpHeaders);
    return stream;
  }

  @override
  bool get isAvailable => true;

  /// Проверяет ссылки по очереди и возвращает первую, которую сервер отдаёт.
  ///
  /// Отказ — только явный HTTP-ответ (не 2xx) или пустое тело. Если проверка
  /// не удалась по сети, ссылка уходит плееру как есть: иначе сломанный прокси
  /// или временный обрыв выглядели бы как «трек удалён».
  ///
  /// Бросает [_StreamRefused], когда отказали все проверенные варианты, — это
  /// и есть повод перейти к следующему клиенту или источнику.
  Future<_Verified> _verifiedPick(
    List<ResolvedStream> links, {
    required String source,
  }) async {
    int? refusedCode;
    final int limit = links.length < _kMaxProbesPerSource
        ? links.length
        : _kMaxProbesPerSource;

    for (int i = 0; i < limit; i++) {
      final ResolvedStream link = links[i];
      final StreamLinkProbe probe = await _checker.check(
        link.url,
        userAgent: link.userAgent,
        headers: link.httpHeaders,
      );
      switch (probe.state) {
        case StreamLinkState.ok:
          return _Verified(link, checked: true);
        case StreamLinkState.unchecked:
          // Сеть не дала проверить — не наше дело судить о доступности.
          debugPrint('[Поток] $source: проверка ссылки не удалась '
              '(${probe.detail}) — отдаю без проверки');
          return _Verified(link, checked: false);
        case StreamLinkState.refused:
          refusedCode = probe.statusCode;
          debugPrint('[Поток] $source: отказ ${probe.statusCode ?? '?'} для '
              '${link.container ?? '?'} ${link.bitrateKbps ?? '?'} kbps');
      }
    }
    throw _StreamRefused(refusedCode);
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
  Future<List<_AudioCandidate>> _candidatesWithProfile(
    YoutubeClientProfile profile,
    String videoId,
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
      return const <_AudioCandidate>[];
    }

    return _candidatesFromPlayerResponse(response, profile);
  }

  /// Запасной путь: библиотека со своим клиентом по умолчанию.
  Future<List<ResolvedStream>> _libraryLinks(
    String videoId,
    AudioQuality quality,
    String? preferContainer,
  ) async {
    final StreamManifest manifest =
        await _library.videos.streamsClient.getManifest(videoId);

    final List<AudioOnlyStreamInfo> audio = manifest.audioOnly.toList();
    if (audio.isEmpty) return const <ResolvedStream>[];

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

    return _linksFrom(candidates, quality, preferContainer);
  }

  /// Разбирает ответ `player` и отдаёт все аудиодорожки с готовой ссылкой.
  ///
  /// Подходят только дорожки с готовой ссылкой (`url`): если YouTube вернул
  /// `signatureCipher`, расшифровать его мы не можем — тогда путь через
  /// профиль не годится, и сработает запасной через библиотеку.
  List<_AudioCandidate> _candidatesFromPlayerResponse(
    Map<String, dynamic> response,
    YoutubeClientProfile profile,
  ) {
    final dynamic data = response['streamingData'];
    if (data is! Map) return const <_AudioCandidate>[];

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
    return candidates;
  }

  /// Дорожки в виде ссылок в порядке предпочтения — их и проверяем.
  ///
  /// Срок годности один на все: ссылки получены одним ответом YouTube и живут
  /// одинаково. Проверяем не только желаемое качество, поэтому при отказе
  /// сервера остаётся чем его заменить.
  List<ResolvedStream> _linksFrom(
    List<_AudioCandidate> candidates,
    AudioQuality quality,
    String? preferContainer,
  ) {
    final DateTime expiresAt = DateTime.now().add(const Duration(hours: 5));
    return <ResolvedStream>[
      for (final _AudioCandidate candidate
          in _orderedCandidates(candidates, quality, preferContainer))
        ResolvedStream(
          url: candidate.url,
          bitrateKbps: candidate.bitrateKbps,
          container: candidate.container,
          mimeType: candidate.mimeType,
          userAgent: candidate.userAgent,
          expiresAt: expiresAt,
        ),
    ];
  }

  /// Дорожки под желаемое качество, лучшая первой.
  ///
  /// «Максимум» — лучшая доступная дорожка, «экономия» — самая дешёвая,
  /// «среднее» — ближайшая к целевым 128 kbps. Для «среднего» важна именно
  /// близость, а не «строго не выше цели»: YouTube отдаёт фактический битрейт
  /// дорожки, а не номинальный, — у itag 140 это 130–131 kbps при номинале 128,
  /// и отбор «не выше 128» промахивался мимо него, роняя «среднее» до
  /// ~70 kbps Opus, хотя рядом лежала дорожка ~128 kbps.
  ///
  /// Дальше в списке идут остальные дорожки — тем ближе по битрейту, чем
  /// лучше: если сервер отказал на выбранной, следующей пробуем ближайшую к
  /// ней по качеству. Для загрузки контейнер важнее: файл называется `.m4a`,
  /// и сначала пробуем его, а другие контейнеры — в конце, когда m4a не
  /// отдаётся вовсе.
  List<_AudioCandidate> _orderedCandidates(
    List<_AudioCandidate> candidates,
    AudioQuality quality,
    String? preferContainer,
  ) {
    if (candidates.isEmpty) return const <_AudioCandidate>[];

    int byBitrate(_AudioCandidate a, _AudioCandidate b) =>
        a.bitrateKbps.compareTo(b.bitrateKbps);
    bool sameContainer(_AudioCandidate c) =>
        preferContainer == null || c.container == preferContainer;

    final List<_AudioCandidate> preferred =
        candidates.where(sameContainer).toList()..sort(byBitrate);
    final List<_AudioCandidate> others =
        candidates.where((_AudioCandidate c) => !sameContainer(c)).toList()
          ..sort(byBitrate);

    return <_AudioCandidate>[
      ..._byQuality(preferred, quality),
      ..._byQuality(others, quality),
    ];
  }

  /// Один набор дорожек (уже по возрастанию битрейта), ближайшая к качеству
  /// первой.
  List<_AudioCandidate> _byQuality(
    List<_AudioCandidate> pool,
    AudioQuality quality,
  ) {
    if (pool.isEmpty) return const <_AudioCandidate>[];

    // Список отсортирован по возрастанию, поэтому «экономия» — это первый.
    final _AudioCandidate first = quality == AudioQuality.high
        ? pool.last
        : quality == AudioQuality.medium
            ? _nearestToTarget(pool, quality.targetKbps)
            : pool.first;

    final List<_AudioCandidate> rest = pool
        .where((_AudioCandidate c) => !identical(c, first))
        .toList()
      ..sort((_AudioCandidate a, _AudioCandidate b) {
        final int left = (a.bitrateKbps - first.bitrateKbps).abs();
        final int right = (b.bitrateKbps - first.bitrateKbps).abs();
        return left.compareTo(right);
      });

    return <_AudioCandidate>[first, ...rest];
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
    _checker.dispose();
    _library.close();
    _webSession?.dispose();
  }
}
