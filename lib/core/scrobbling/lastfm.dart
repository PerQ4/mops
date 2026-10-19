import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Адрес API Last.fm (совместим и с libre.fm — тот же протокол).
const String kLastFmEndpoint = 'https://ws.audioscrobbler.com/2.0/';

/// Страница подтверждения входа: сюда пользователь идёт после `auth.getToken`.
const String kLastFmAuthPage = 'https://www.last.fm/api/auth/';

/// Ключи приложения Last.fm (api_key и shared secret).
///
/// Регистрируются один раз на владельца сборки:
/// https://www.last.fm/api/account/create. В исходник не вшиваются: ключ
/// подставляется при сборке (`--dart-define=LASTFM_API_KEY=...` и
/// `--dart-define=LASTFM_SECRET=...`). Пустые значения — интеграция просто
/// не настроена, экран скажет об этом словами.
const String kLastFmApiKey = String.fromEnvironment('LASTFM_API_KEY');
const String kLastFmApiSecret = String.fromEnvironment('LASTFM_SECRET');

/// Ошибка Last.fm с текстом, который не стыдно показать пользователю.
class LastFmException implements Exception {
  const LastFmException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => message;
}

/// Сессия Last.fm: имя пользователя и ключ для подписанных запросов.
class LastFmSession {
  const LastFmSession({required this.username, required this.key});

  final String username;
  final String key;
}

/// Подпись запроса Last.fm: md5 от склейки «имя+значение» всех параметров
/// (в порядке имён), к которой приписан секрет.
///
/// Параметры `format` и `callback` в подпись не входят — их в передаваемую
/// карту не кладут. Функция вынесена наружу, чтобы подпись можно было
/// проверить тестом без сети.
String lastFmSignature(Map<String, String> params, String secret) {
  final List<String> keys = params.keys.toList()..sort();
  final StringBuffer buffer = StringBuffer();
  for (final String key in keys) {
    buffer
      ..write(key)
      ..write(params[key]);
  }
  buffer.write(secret);
  return md5.convert(utf8.encode(buffer.toString())).toString();
}

/// Клиент Last.fm: вход по токену и отправка прослушиваний.
///
/// Сеть здесь не влияет на воспроизведение: вызывающий код оборачивает
/// запросы в `unawaited(...).catchError(...)`, а ошибки летят только в лог.
class LastFmClient {
  LastFmClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;

  String _apiKey = '';
  String _apiSecret = '';
  String? _sessionKey;

  /// Ключи заданы (можно запрашивать токен).
  bool get isConfigured => _apiKey.isNotEmpty && _apiSecret.isNotEmpty;

  /// Есть ключ сессии — запросы от имени пользователя разрешены.
  bool get isAuthorized => (_sessionKey ?? '').isNotEmpty;

  /// Задаёт ключи приложения и (после входа) ключ сессии.
  void configure({
    required String apiKey,
    required String apiSecret,
    String? sessionKey,
  }) {
    _apiKey = apiKey.trim();
    _apiSecret = apiSecret.trim();
    _sessionKey = sessionKey == null || sessionKey.isEmpty ? null : sessionKey;
  }

  /// Адрес, на котором пользователь подтверждает доступ приложению.
  String authUrl(String token) =>
      '$kLastFmAuthPage?api_key=$_apiKey&token=$token';

  /// Шаг 1: одноразовый токен для входа.
  Future<String> getToken() async {
    final Map<String, dynamic> json = await _post('auth.getToken');
    final Object? token = json['token'];
    if (token is! String || token.isEmpty) {
      throw const LastFmException('Last.fm не выдал токен входа.');
    }
    return token;
  }

  /// Шаг 3: обмен подтверждённого токена на постоянный ключ сессии.
  Future<LastFmSession> getSession(String token) async {
    final Map<String, dynamic> json =
        await _post('auth.getSession', params: <String, String>{'token': token});
    final Object? session = json['session'];
    if (session is! Map<String, dynamic>) {
      throw const LastFmException('Last.fm не выдал сессию.');
    }
    final Object? name = session['name'];
    final Object? key = session['key'];
    if (name is! String || key is! String || key.isEmpty) {
      throw const LastFmException('Last.fm вернул пустую сессию.');
    }
    return LastFmSession(username: name, key: key);
  }

  /// «Сейчас играет» — статус в профиле, без занесения в статистику.
  Future<void> updateNowPlaying({
    required String artist,
    required String track,
    String? album,
    int? duration,
  }) {
    return _post(
      'track.updateNowPlaying',
      session: true,
      params: <String, String>{
        'artist': artist,
        'track': track,
        if (album != null && album.isNotEmpty) 'album': album,
        if (duration != null && duration > 0) 'duration': '$duration',
      },
    );
  }

  /// Заносит прослушивание в статистику.
  ///
  /// [startedAt] — когда трек начал играть: Last.fm хранит именно это время,
  /// а не момент отправки. Поля с индексом `[0]` — формат пакетной отправки,
  /// который API ожидает даже для одного трека.
  Future<void> scrobble({
    required String artist,
    required String track,
    required DateTime startedAt,
    String? album,
    int? duration,
  }) {
    return _post(
      'track.scrobble',
      session: true,
      params: <String, String>{
        'artist[0]': artist,
        'track[0]': track,
        'timestamp[0]': '${startedAt.millisecondsSinceEpoch ~/ 1000}',
        if (album != null && album.isNotEmpty) 'album[0]': album,
        if (duration != null && duration > 0) 'duration[0]': '$duration',
      },
    );
  }

  /// Общий путь любого метода: собрать параметры, подписать, разобрать ответ.
  Future<Map<String, dynamic>> _post(
    String method, {
    Map<String, String> params = const <String, String>{},
    bool session = false,
  }) async {
    if (!isConfigured) {
      throw const LastFmException('Ключи Last.fm не заданы.');
    }
    if (session && !isAuthorized) {
      throw const LastFmException('Вы не вошли в Last.fm.');
    }

    // Карта для подписи: `format` в неё не входит — так требует API.
    final Map<String, String> signable = <String, String>{
      'method': method,
      'api_key': _apiKey,
      if (session) 'sk': _sessionKey!,
      ...params,
    };

    final Map<String, String> body = <String, String>{
      ...signable,
      'api_sig': lastFmSignature(signable, _apiSecret),
      'format': 'json',
    };

    final http.Response response = await _http
        .post(Uri.parse(kLastFmEndpoint), body: body)
        .timeout(const Duration(seconds: 12));

    final Map<String, dynamic>? json = _decode(response.body);
    // Ошибку Last.fm кладёт в тело даже при коде 200 — проверяем раньше кода.
    final Object? error = json?['error'];
    if (error != null) {
      throw LastFmException(
        json?['message']?.toString() ?? 'Ошибка Last.fm',
        code: error is num ? error.toInt() : null,
      );
    }
    if (response.statusCode != 200) {
      throw LastFmException('Last.fm ответил кодом ${response.statusCode}.');
    }
    if (json == null) {
      throw const LastFmException('Last.fm вернул непонятный ответ.');
    }
    return json;
  }

  Map<String, dynamic>? _decode(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  void dispose() => _http.close();
}
