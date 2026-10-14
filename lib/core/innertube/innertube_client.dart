import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/sapisid_hash.dart';

/// Публичный ключ веб-клиента YouTube Music.
///
/// Он присутствует в HTML главной страницы, но его извлечение может не
/// сработать — например, если страница отдалась не полностью. Ключ не
/// секретный: его использует и `ytmusicapi`, и другие неофициальные клиенты.
const String kPublicInnerTubeKey = 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';

/// Источник заголовков авторизации для InnerTube.
abstract class AuthProvider {
  /// Заголовки, которые добавляются к каждому запросу (или пустая карта).
  Map<String, String> get headers;
}

/// Анонимный доступ — без входа в аккаунт.
class AnonymousAuth implements AuthProvider {
  const AnonymousAuth();

  @override
  Map<String, String> get headers => const <String, String>{};
}

/// Авторизация по OAuth access token (`Authorization: Bearer ...`).
class BearerAuth implements AuthProvider {
  BearerAuth(this.token);

  String token;

  @override
  Map<String, String> get headers => <String, String>{'Authorization': 'Bearer $token'};
}

/// Авторизация по cookie браузера (`SAPISIDHASH`).
class CookieAuth implements AuthProvider {
  CookieAuth(
    this.cookieString, {
    this.origin = SapisidHash.defaultOrigin,
  }) : _sapisid = SapisidHash.extractSapisid(cookieString);

  final String cookieString;
  final String origin;
  final String? _sapisid;

  /// Достаточно ли cookie для подписи (есть ли `SAPISID`).
  bool get isUsable => _sapisid != null && _sapisid.isNotEmpty;

  @override
  Map<String, String> get headers {
    final Map<String, String> result = <String, String>{'Cookie': cookieString};
    // Локальная переменная нужна для promotion: поле-геттер Dart не уточняет.
    final String? sapisid = _sapisid;
    if (sapisid != null && sapisid.isNotEmpty) {
      result['Authorization'] = SapisidHash.build(sapisid, origin: origin);
    }
    return result;
  }
}

/// Конфигурация InnerTube, вытащенная из HTML главной страницы.
class InnerTubeConfig {
  const InnerTubeConfig({
    required this.apiKey,
    required this.apiVersion,
    required this.clientName,
    required this.clientVersion,
    required this.visitorData,
    required this.gl,
    required this.hl,
    this.sts = '',
  });

  final String apiKey;
  final String apiVersion;
  final String clientName;
  final String clientVersion;
  final String visitorData;
  final String gl;
  final String hl;

  /// Метка времени подписи (`STS`) со страницы YouTube Music.
  ///
  /// Веб-клиенту она обязательна: без неё `player` отвечает «видео недоступно».
  final String sts;

  InnerTubeConfig copyWith({String? gl, String? hl}) => InnerTubeConfig(
        apiKey: apiKey,
        apiVersion: apiVersion,
        clientName: clientName,
        clientVersion: clientVersion,
        visitorData: visitorData,
        gl: gl ?? this.gl,
        hl: hl ?? this.hl,
        sts: sts,
      );
}

/// Клиент InnerTube (внутренний API YouTube Music).
///
/// Отвечает за:
///  * получение и кэширование конфигурации (`key`, `clientVersion`, `visitorData`);
///  * подстановку заголовков авторизации;
///  * POST-запросы к `music.youtube.com/youtubei/v1/<endpoint>`.
class InnerTubeClient {
  InnerTubeClient({
    http.Client? httpClient,
    this.auth = const AnonymousAuth(),
    this.locale = 'ru',
    this.region = 'RU',
  }) : _http = httpClient ?? http.Client();

  static const String _origin = 'https://music.youtube.com';
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0';

  final http.Client _http;
  final String locale;
  final String region;

  /// Cookie, полученные от YouTube (VISITOR_INFO1_LIVE, SOCS и прочие).
  ///
  /// Реальный веб-клиент их присылает, и YouTube отвечает более полной
  /// разметкой. Без них, например, результаты поиска приходят «компактными»,
  /// без имени исполнителя.
  final Map<String, String> _cookies = <String, String>{};

  String get _cookieHeader {
    if (_cookies.isEmpty) return 'SOCS=CAI';
    return _cookies.entries
        .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
        .join('; ');
  }

  /// Запоминает cookie из ответа.
  ///
  /// Несколько значений приходят одной строкой, разделённой запятыми,
  /// но `Expires` тоже содержит запятую — поэтому делим только перед
  /// началом следующей пары «имя=значение».
  void _captureCookies(http.BaseResponse response) {
    final String? raw = response.headers['set-cookie'];
    if (raw == null || raw.isEmpty) return;

    for (final String part
        in raw.split(RegExp(r',\s*(?=[A-Za-z0-9_\-]+=)'))) {
      final String pair = part.split(';').first.trim();
      final int eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final String name = pair.substring(0, eq).trim();
      final String value = pair.substring(eq + 1).trim();
      if (name.isEmpty) continue;
      _cookies[name] = value;
    }
  }

  /// Текущая стратегия авторизации.
  AuthProvider auth;

  InnerTubeConfig? _config;

  /// Меняет стратегию авторизации (вход/выход) без пересоздания клиента.
  void setAuth(AuthProvider value) => auth = value;

  /// Есть ли сейчас авторизация (не гостевая).
  bool get hasAuth => auth is! AnonymousAuth;

  InnerTubeConfig? get config => _config;

  /// Загружает конфигурацию, если она ещё не загружена.
  Future<InnerTubeConfig> bootstrap({bool force = false}) async {
    if (_config != null && !force) return _config!;

    final http.Response res = await _http.get(
      Uri.parse('$_origin/'),
      headers: <String, String>{
        'User-Agent': _userAgent,
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': '$locale,en;q=0.9',
        'Cookie': _cookieHeader,
      },
    ).timeout(const Duration(seconds: 20));
    _captureCookies(res);

    if (res.statusCode != 200) {
      throw InnerTubeException(
        'Не удалось загрузить конфигурацию YouTube Music '
        '(HTTP ${res.statusCode}). Возможно, регион недоступен без VPN.',
      );
    }

    final String html = res.body;
    if (html.contains('not optimized for your browser')) {
      throw InnerTubeException(
        'YouTube отклонил запрос браузера. Попробуйте позже или смените регион.',
      );
    }

    final String apiKey = _grab(html, r'"INNERTUBE_API_KEY":"(.*?)"');
    final String apiVersion =
        _grab(html, r'"INNERTUBE_API_VERSION":"(.*?)"', fallback: 'v1');
    final String clientName =
        _grab(html, r'"INNERTUBE_CONTEXT_CLIENT_NAME":\s*"?(.*?)"?[,}]');
    final String clientVersion =
        _grab(html, r'"INNERTUBE_CLIENT_VERSION":"(.*?)"');
    final String visitorData = _grab(html, r'"VISITOR_DATA":"(.*?)"');
    final String sts = _grab(html, r'"STS":\s*(\d+)');

    if (apiKey.isEmpty) {
      // Публичный ключ веб-клиента YouTube Music, он не является секретом:
      // без него не обходится ни один неофициальный клиент.
      _config = InnerTubeConfig(
        apiKey: kPublicInnerTubeKey,
        apiVersion: 'v1',
        clientName: 'WEB_REMIX',
        clientVersion: '1.20240101.01.00',
        visitorData: visitorData,
        gl: region,
        hl: locale,
        sts: sts,
      );
      return _config!;
    }

    _config = InnerTubeConfig(
      apiKey: apiKey,
      apiVersion: apiVersion.isEmpty ? 'v1' : apiVersion,
      clientName: clientName.isEmpty ? 'WEB_REMIX' : clientName,
      clientVersion: clientVersion.isEmpty ? '1.20240101.01.00' : clientVersion,
      visitorData: visitorData,
      sts: sts,
      gl: region,
      hl: locale,
    );
    return _config!;
  }

  /// Полный POST к InnerTube-эндпоинту.
  Future<Map<String, dynamic>> post(
    String endpoint, {
    Map<String, dynamic> body = const <String, dynamic>{},
    Map<String, String> query = const <String, String>{},
    bool authenticated = false,
    Map<String, String> extraHeaders = const <String, String>{},
  }) async {
    final InnerTubeConfig cfg = await bootstrap();

    final Uri uri = Uri.parse('$_origin/youtubei/${cfg.apiVersion}/$endpoint')
        .replace(
      queryParameters: <String, String>{
        ...query,
        'alt': 'json',
        'key': cfg.apiKey,
      },
    );

    final Map<String, String> built = <String, String>{
      'User-Agent': _userAgent,
      'Accept': '*/*',
      'Accept-Language': '$locale,en;q=0.9',
      'Content-Type': 'application/json',
      'X-Origin': _origin,
      'X-Goog-Visitor-Id': cfg.visitorData,
      'X-YouTube-Client-Name': cfg.clientName,
      'X-YouTube-Client-Version': cfg.clientVersion,
      'X-YouTube-Utc-Offset':
          (-DateTime.now().timeZoneOffset.inMinutes).toString(),
      'Cookie': _cookieHeader,
    };

    // Дополнительные заголовки вызывающего перекрывают стандартные: так можно
    // подставить профиль другого клиента YouTube.
    final Map<String, String> headers = <String, String>{...built, ...extraHeaders};

    if (authenticated) {
      headers.addAll(auth.headers);
    }

    final Map<String, dynamic> payload = <String, dynamic>{
      'context': _context(cfg),
      ...body,
    };

    final http.Response res = await _http
        .post(uri, headers: headers, body: jsonEncode(payload))
        .timeout(const Duration(seconds: 30));

    _captureCookies(res);

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw InnerTubeException(
        'InnerTube $endpoint вернул HTTP ${res.statusCode}',
        statusCode: res.statusCode,
        body: res.body,
      );
    }

    final dynamic decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is Map<String, dynamic>) return decoded;
    throw InnerTubeException('Неожиданный ответ InnerTube для $endpoint');
  }

  /// Удобные обёртки над частыми эндпоинтами.
  Future<Map<String, dynamic>> browse(
    String browseId, {
    Map<String, dynamic> extra = const <String, dynamic>{},
    String? continuation,
    bool authenticated = false,
  }) {
    return post(
      'browse',
      body: <String, dynamic>{
        if (continuation != null)
          'continuation': continuation
        else
          'browseId': browseId,
        ...extra,
      },
      authenticated: authenticated,
    );
  }
  Future<Map<String, dynamic>> search(
    String query, {
    String? params,
    bool authenticated = false,
  }) {
    return post(
      'search',
      body: <String, dynamic>{'query': query, 'params': params},
      authenticated: authenticated,
    );
  }

  Future<Map<String, dynamic>> next(
    String videoId, {
    String? playlistId,
    bool authenticated = true,
  }) {
    return post(
      'next',
      body: <String, dynamic>{
        'videoId': videoId,
        'playlistId': ?playlistId,
        'isAudioOnly': true,
      },
      authenticated: authenticated,
    );
  }

  /// Мутации (лайк, подписка, плейлисты) — всегда требуют входа.
  Future<Map<String, dynamic>> mutate(
    String endpoint,
    Map<String, dynamic> body,
  ) {
    return post(endpoint, body: body, authenticated: true);
  }

  Map<String, dynamic> _context(InnerTubeConfig cfg) => <String, dynamic>{
        'capabilities': <String, dynamic>{},
        'client': <String, dynamic>{
          'clientName': cfg.clientName,
          'clientVersion': cfg.clientVersion,
          'gl': cfg.gl,
          'hl': cfg.hl,
          'visitorData': cfg.visitorData,
          'utcOffsetMinutes': -DateTime.now().timeZoneOffset.inMinutes,
          'musicAppInfo': <String, dynamic>{
            'musicActivityMasterSwitch':
                'MUSIC_ACTIVITY_MASTER_SWITCH_INDETERMINATE',
            'musicLocationMasterSwitch':
                'MUSIC_LOCATION_MASTER_SWITCH_INDETERMINATE',
            'pwaInstallabilityStatus': 'PWA_INSTALLABILITY_STATUS_UNKNOWN',
          },
        },
        'user': <String, dynamic>{'enableSafetyMode': false},
        'request': <String, dynamic>{
          'internalExperimentFlags': <Map<String, String>>[
            <String, String>{
              'key': 'force_music_enable_outertube_tastebuilder_browse',
              'value': 'true',
            },
            <String, String>{
              'key': 'force_music_enable_outertube_playlist_detail_browse',
              'value': 'true',
            },
            <String, String>{
              'key': 'force_music_enable_outertube_search_suggestions',
              'value': 'true',
            },
          ],
          'sessionIndex': <String, dynamic>{},
        },
      };

  static String _grab(String html, String pattern, {String fallback = ''}) {
    final RegExpMatch? m = RegExp(pattern, dotAll: true).firstMatch(html);
    if (m == null) return fallback;
    final String? value = m.groupCount >= 1 ? m.group(1) : null;
    return (value == null || value.isEmpty) ? fallback : value;
  }

  void dispose() => _http.close();
}

/// Ошибка обращения к InnerTube.
class InnerTubeException implements Exception {
  InnerTubeException(this.message, {this.statusCode, this.body});

  final String message;
  final int? statusCode;
  final String? body;

  bool get isUnauthorized => statusCode == 401 || statusCode == 403;

  @override
  String toString() => message;
}
