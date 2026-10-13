import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/sapisid_hash.dart';

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
  CookieAuth(this.cookieString, {String origin = SapisidHash.defaultOrigin})
      : _origin = origin,
        _sapisid = SapisidHash.extractSapisid(cookieString);

  final String cookieString;
  final String _origin;
  final String? _sapisid;

  /// Достаточно ли cookie для подписи (есть ли `SAPISID`).
  bool get isUsable => _sapisid != null && _sapisid.isNotEmpty;

  @override
  Map<String, String> get headers {
    final Map<String, String> result = <String, String>{'Cookie': cookieString};
    if (isUsable) {
      result['Authorization'] =
          SapisidHash.build(_sapisid, origin: _origin);
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
  });

  final String apiKey;
  final String apiVersion;
  final String clientName;
  final String clientVersion;
  final String visitorData;
  final String gl;
  final String hl;

  InnerTubeConfig copyWith({String? gl, String? hl}) => InnerTubeConfig(
        apiKey: apiKey,
        apiVersion: apiVersion,
        clientName: clientName,
        clientVersion: clientVersion,
        visitorData: visitorData,
        gl: gl ?? this.gl,
        hl: hl ?? this.hl,
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
    AuthProvider auth = const AnonymousAuth(),
    this.locale = 'ru',
    this.region = 'RU',
  })  : _http = httpClient ?? http.Client(),
        _auth = auth;

  static const String _origin = 'https://music.youtube.com';
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0';

  final http.Client _http;
  final String locale;
  final String region;

  AuthProvider _auth;
  InnerTubeConfig? _config;

  /// Меняет стратегию авторизации (вход/выход) без пересоздания клиента.
  void setAuth(AuthProvider auth) => _auth = auth;

  /// Есть ли сейчас авторизация (не гостевая).
  bool get hasAuth => _auth is! AnonymousAuth;

  InnerTubeConfig? get config => _config;

  /// Загружает конфигурацию, если она ещё не загружена.
  Future<InnerTubeConfig> bootstrap({bool force = false}) async {
    if (_config != null && !force) return _config!;

    final http.Response res = await _http.get(
      Uri.parse('$_origin/'),
      headers: <String, String>{
        'User-Agent': _userAgent,
        'Accept-Language': '$locale,en;q=0.9',
        'Cookie': 'SOCS=CAI',
      },
    );

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

    if (apiKey.isEmpty) {
      throw InnerTubeException(
        'Не удалось извлечь API-ключ YouTube Music. Изменился формат страницы.',
      );
    }

    _config = InnerTubeConfig(
      apiKey: apiKey,
      apiVersion: apiVersion.isEmpty ? 'v1' : apiVersion,
      clientName: clientName.isEmpty ? 'WEB_REMIX' : clientName,
      clientVersion: clientVersion.isEmpty ? '1.20240101.01.00' : clientVersion,
      visitorData: visitorData,
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

    final Map<String, String> headers = <String, String>{
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
    };

    if (authenticated) {
      headers.addAll(_auth.headers);
    }

    final Map<String, dynamic> payload = <String, dynamic>{
      'context': _context(cfg),
      ...body,
    };

    final http.Response res = await _http
        .post(uri, headers: headers, body: jsonEncode(payload))
        .timeout(const Duration(seconds: 30));

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
        if (playlistId != null) 'playlistId': playlistId,
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
