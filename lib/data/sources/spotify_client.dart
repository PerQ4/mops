import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Клиент Spotify — для переноса библиотеки в YouTube Music.
///
/// Ключей Spotify не требуется. Механизм тот же, что в ArchiveTune (и в
/// Spotube, откуда он взят):
///
/// 1. секрет TOTP берётся из публичного гиста сообщества;
/// 2. у Spotify запрашивается время сервера (важно: локальные часы могут
///    отличаться, а код TOTP живёт 30 секунд);
/// 3. считается шестизначный код (SHA1, шаг 30 с);
/// 4. по этому коду и cookie `sp_dc` (она появляется после входа на
///    open.spotify.com) выдаётся токен доступа.
///
/// Cookie `sp_dc` добывается входом в Spotify во встроенном браузере
/// приложения — так же, как вход в Google для аккаунта YouTube Music.
class SpotifyClient {
  SpotifyClient({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  static const String _tokenUrl = 'https://open.spotify.com/api/token';
  static const String _serverTimeUrl = 'https://open.spotify.com/api/server-time';
  // Секреты TOTP: словарь «версия → массив чисел». Старый гист с одним
  // секретом больше не используется — из него получался неверный код.
  static const String _secretsUrl =
      'https://raw.githubusercontent.com/xyloflake/spot-secrets-go/'
      'main/secrets/secretDict.json';
  static const String _api = 'https://api.spotify.com/v1';

  /// Адрес страницы входа Spotify — открывается во встроенном браузере.
  static const String loginUrl =
      'https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F';

  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  String? _token;
  DateTime? _tokenExpiry;
  // Cookie сессии храним, чтобы обновить токен, когда он истечёт: без неё
  // придётся заново открывать браузер посреди переноса.
  String? _spDc;
  String? _nuanceSecret;
  String? _nuanceVersion;

  /// Готов ли клиент к работе (есть ли действующий токен).
  bool get isAuthorized => _token != null && !_isExpired;

  bool get _isExpired =>
      _tokenExpiry == null || DateTime.now().isAfter(_tokenExpiry!);

  /// Получает токен по cookie `sp_dc`.
  Future<void> authorize(String spDc) async {
    final ({String secret, String version})? nuance = await _fetchNuance();
    if (nuance == null) {
      throw const SpotifyException(
        'Не удалось получить секрет для входа в Spotify. Попробуйте позже.',
      );
    }

    final int? serverTime = await _fetchServerTime();
    if (serverTime == null) {
      throw const SpotifyException('Spotify не ответил. Проверьте соединение.');
    }

    final String totp = _totp(nuance.secret, serverTime);

    // Так делает рабочий клиент: `reason=transport`, `productType=web-player`
    // (через дефис), код и его версия в параметрах, метка времени — и НИКАКОГО
    // заголовка Authorization. Прежний вариант с `reason=init`, `web_player` и
    // `Authorization` сервер отклонял, и токен не выдавался.
    final Uri tokenUri = Uri.parse(_tokenUrl).replace(
      queryParameters: <String, String>{
        'reason': 'transport',
        'productType': 'web-player',
        'totp': totp,
        'totpVer': nuance.version,
        'ts': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      },
    );

    final Map<String, dynamic>? json = await _request(
      tokenUri,
      method: 'GET',
      headers: <String, String>{
        'Cookie': 'sp_dc=$spDc',
      },
    );

    final String? token = json?['accessToken'] as String?;
    if (token == null || token.isEmpty || json?['isAnonymous'] == true) {
      throw const SpotifyException(
        'Spotify не выдал токен. Проверьте, что вход выполнен.',
      );
    }

    _token = token;
    _spDc = spDc;
    _tokenExpiry = DateTime.now().add(
      Duration(seconds: (json?['accessTokenExpirationTimestampMs'] as num?)
                  ?.toInt() !=
              null
          ? (((json!['accessTokenExpirationTimestampMs'] as num).toInt() -
                      DateTime.now().millisecondsSinceEpoch) ~/
                  1000)
                  .clamp(60, 3600)
          : 3000),
    );
  }

  /// Плейлисты пользователя.
  Future<List<SpotifyPlaylist>> playlists() async {
    final List<SpotifyPlaylist> result = <SpotifyPlaylist>[];
    String? url = '$_api/me/playlists?limit=50';
    while (url != null) {
      final Map<String, dynamic>? page = await _getJson(url);
      if (page == null) break;
      for (final dynamic item
          in page['items'] as List<dynamic>? ?? <dynamic>[]) {
        if (item is! Map<String, dynamic>) continue;
        final String? id = item['id'] as String?;
        final String? name = item['name'] as String?;
        if (id == null || name == null) continue;
        // `tracks` у плейлиста объявлено устаревшим, актуальное имя —
        // `items`; читаем новое, на старое оставляем запас.
        final dynamic collection = item['items'] ?? item['tracks'];
        result.add(SpotifyPlaylist(
          id: id,
          name: name,
          trackCount:
              (collection is Map ? collection['total'] as num? : null)?.toInt() ?? 0,
        ));
      }
      url = page['next'] as String?;
    }
    return result;
  }

  /// Треки плейлиста и число пропущенных записей.
  ///
  /// Пропускаем то, что нельзя перенести как песню: эпизоды подкастов,
  /// локальные файлы и удалённые из Spotify записи (`null` вместо трека).
  /// Счётчик `skipped` нужен, чтобы отличить «плейлист пуст» от «в плейлисте
  /// только подкасты и локальные файлы» — сообщения об этом разные.
  Future<({List<SpotifyTrack> tracks, int skipped})> playlistTracks(
    String playlistId,
  ) async {
    final List<SpotifyTrack> tracks = <SpotifyTrack>[];
    int skipped = 0;
    // `/items` — актуальный адрес: `/tracks` (и имя поля `track`) Spotify
    // объявил устаревшими. Максимум `limit` у этого эндпоинта — 50 (раньше
    // было 100), дальше страницы идут по `next`.
    String? url = '$_api/playlists/$playlistId/items?limit=50';
    while (url != null) {
      final Map<String, dynamic>? page = await _getJson(url);
      if (page == null) break;
      for (final dynamic item
          in page['items'] as List<dynamic>? ?? <dynamic>[]) {
        if (item is! Map<String, dynamic>) continue;
        // Запись лежит в `item`; `track` — устаревшее имя того же объекта.
        final dynamic entry = item['item'] ?? item['track'];
        if (entry is! Map<String, dynamic>) {
          skipped++;
          continue;
        }
        final SpotifyTrack? parsed = _parseTrack(entry);
        if (parsed == null) {
          skipped++;
          continue;
        }
        tracks.add(parsed);
      }
      url = page['next'] as String?;
    }
    return (tracks: tracks, skipped: skipped);
  }

  /// Лайкнутые треки пользователя.
  Future<List<SpotifyTrack>> likedSongs() async {
    final List<SpotifyTrack> result = <SpotifyTrack>[];
    String? url = '$_api/me/tracks?limit=50';
    while (url != null) {
      final Map<String, dynamic>? page = await _getJson(url);
      if (page == null) break;
      for (final dynamic item
          in page['items'] as List<dynamic>? ?? <dynamic>[]) {
        if (item is! Map<String, dynamic>) continue;
        final dynamic track = item['track'];
        if (track is! Map<String, dynamic>) continue;
        final SpotifyTrack? parsed = _parseTrack(track);
        if (parsed != null) result.add(parsed);
      }
      url = page['next'] as String?;
    }
    return result;
  }

  SpotifyTrack? _parseTrack(Map<String, dynamic> json) {
    // Эпизод подкаста — тоже объект с `id` и `name`, но в YouTube Music это
    // не песня: искать его по названию значит тянуть в плейлист случайный
    // трек. Признак — тип `episode` (плюс поле `show`, которого у трека нет).
    if (json['type'] == 'episode' || json['show'] != null) return null;

    final String? id = json['id'] as String?;
    final String? name = json['name'] as String?;
    // У локальных файлов (`is_local`) `id` пуст — переносить нечего.
    if (id == null || id.isEmpty || name == null || name.isEmpty) return null;

    final List<String> artists = <String>[
      for (final dynamic a in json['artists'] as List<dynamic>? ?? <dynamic>[])
        if (a is Map && a['name'] is String) a['name'] as String,
    ];
    final dynamic album = json['album'];
    final int? durationMs = (json['duration_ms'] as num?)?.toInt();

    return SpotifyTrack(
      id: id,
      title: name,
      artists: artists,
      album: album is Map ? album['name'] as String? : null,
      duration: durationMs == null
          ? null
          : Duration(milliseconds: durationMs),
    );
  }

  /// Запрос к Web API с авторизацией.
  ///
  /// Токен Spotify живёт около часа, а перенос большого плейлиста легко его
  /// переживает: при 401 один раз перезапрашиваем токен по сохранённой cookie
  /// `sp_dc` и повторяем запрос. Прочие отказы переводим в понятный текст —
  /// раньше любой не-200 молча возвращал `null`, и вставший на середине
  /// перенос выглядел как «в плейлисте нет треков».
  Future<Map<String, dynamic>?> _getJson(
    String url, {
    bool canRetry = true,
  }) async {
    final ({int status, Map<String, dynamic>? body}) response = await _send(
      Uri.parse(url),
      headers: <String, String>{'Authorization': 'Bearer $_token'},
    );
    if (response.status >= 200 && response.status < 300) return response.body;
    if (response.status == 401 && canRetry && _spDc != null) {
      await authorize(_spDc!);
      return _getJson(url, canRetry: false);
    }
    throw SpotifyException(_errorText(response.status));
  }

  static String _errorText(int status) => switch (status) {
        401 => 'Сессия Spotify истекла. Войдите заново.',
        403 => 'Spotify не дал доступ к этим данным.',
        404 => 'Spotify не нашёл запрошенную страницу.',
        429 => 'Spotify ограничил частоту запросов. Подождите минуту.',
        0 => 'Spotify не ответил. Проверьте соединение.',
        _ => 'Spotify ответил ошибкой ($status).',
      };

  /// Секрет TOTP и его версия (кэшируются на время работы).
  ///
  /// Источник — словарь «версия → массив чисел». Секрет — не строка: каждый
  /// байт получается XOR-преобразованием `value ^ ((i % 33) + 9)`, как в
  /// рабочих клиентах. Версия берётся наибольшая: старая даёт код, который
  /// Spotify уже не принимает.
  Future<({String secret, String version})?> _fetchNuance() async {
    if (_nuanceSecret != null && _nuanceVersion != null) {
      return (secret: _nuanceSecret!, version: _nuanceVersion!);
    }

    final Map<String, dynamic>? json = await _request(Uri.parse(_secretsUrl));
    if (json == null || json.isEmpty) return null;

    final List<String> versions = json.keys.toList()
      ..sort(
        (String a, String b) =>
            (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0),
      );
    final String version = versions.last;
    final dynamic raw = json[version];
    if (raw is! List) return null;

    final StringBuffer secret = StringBuffer();
    for (int i = 0; i < raw.length; i++) {
      final dynamic item = raw[i];
      if (item is! num) return null;
      secret.writeCharCode(item.toInt() ^ ((i % 33) + 9));
    }

    _nuanceSecret = secret.toString();
    _nuanceVersion = version;
    return (secret: _nuanceSecret!, version: _nuanceVersion!);
  }

  Future<int?> _fetchServerTime() async {
    final Map<String, dynamic>? json = await _request(
      Uri.parse(_serverTimeUrl),
      headers: <String, String>{'User-Agent': _userAgent},
    );
    final dynamic value = json?['serverTime'];
    if (value is num) return (value / 1000).floor();
    return null;
  }

  /// Шестизначный код TOTP: SHA1, шаг 30 секунд, 6 цифр.
  ///
  /// Ключ — сами байты секрета (он приходит уже «раскодированным» из
  /// XOR-преобразования), а не base32: HMAC считается по сырым байтам.
  static String _totp(String secret, int serverTimeSeconds) {
    final Uint8List key = Uint8List.fromList(secret.codeUnits);
    final int counter = serverTimeSeconds ~/ 30;

    // Счётчик — 8 байт (RFC 6238). С четырьмя байтами код не совпадает
    // с эталонными реализациями, и Spotify его не принимает.
    final List<int> message = <int>[
      for (int shift = 56; shift >= 0; shift -= 8)
        (counter >> shift) & 0xff,
    ];

    final List<int> digest =
        Hmac(sha1, key).convert(message).bytes;
    final int offset = digest[digest.length - 1] & 0x0f;
    final int binary = ((digest[offset] & 0x7f) << 24) |
        ((digest[offset + 1] & 0xff) << 16) |
        ((digest[offset + 2] & 0xff) << 8) |
        (digest[offset + 3] & 0xff);

    return (binary % 1000000).toString().padLeft(6, '0');
  }

  /// Разбор base32 больше не нужен: секрет приходит в виде чисел.
  Future<Map<String, dynamic>?> _request(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const <String, String>{},
  }) async =>
      (await _send(uri, method: method, headers: headers)).body;

  /// Выполняет HTTP-запрос и отдаёт код ответа вместе с разобранным телом.
  ///
  /// Тело — `null` при не-2xx и при ответе без JSON. Ошибки сети не
  /// пробрасываем: их заменяет код 0, чтобы вызывающий сам решал, что делать
  /// (для токена и времени сервера сбой — это просто `null`, для Web API —
  /// понятное сообщение).
  Future<({int status, Map<String, dynamic>? body})> _send(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const <String, String>{},
  }) async {
    try {
      final HttpClientRequest request =
          method == 'POST' ? await _client.postUrl(uri) : await _client.getUrl(uri);
      headers.forEach(request.headers.set);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final HttpClientResponse response =
          await request.close().timeout(const Duration(seconds: 20));
      final int status = response.statusCode;
      final String body = await response.transform(utf8.decoder).join();
      if (status < 200 || status >= 300 || body.isEmpty) {
        return (status: status, body: null);
      }
      final dynamic decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return (status: status, body: decoded);
      }
      if (decoded is List<dynamic>) {
        return (status: status, body: <String, dynamic>{'items': decoded});
      }
      return (status: status, body: null);
    } on Object {
      return (status: 0, body: null);
    }
  }

  /// Диагностика: секрет, время сервера и посчитанный код.
  Future<String?> debugTotp() async {
    final ({String secret, String version})? nuance = await _fetchNuance();
    final int? time = await _fetchServerTime();
    if (nuance == null || time == null) return null;
    return 'версия=${nuance.version} время=$time '
        'код=${_totp(nuance.secret, time)}';
  }

  void dispose() => _client.close(force: true);
}

/// Плейлист Spotify (для выбора при переносе).
class SpotifyPlaylist {
  const SpotifyPlaylist({
    required this.id,
    required this.name,
    required this.trackCount,
  });

  final String id;
  final String name;
  final int trackCount;
}

/// Трек Spotify — то, что мы ищем в YouTube Music.
class SpotifyTrack {
  const SpotifyTrack({
    required this.id,
    required this.title,
    required this.artists,
    this.album,
    this.duration,
  });

  final String id;
  final String title;
  final List<String> artists;
  final String? album;
  final Duration? duration;

  String get artistLine => artists.join(', ');

  /// Строка для поиска в YouTube Music.
  String get query =>
      artists.isEmpty ? title : '${artists.first} $title';
}

/// Ошибка обращения к Spotify с понятным текстом.
class SpotifyException implements Exception {
  const SpotifyException(this.message);

  final String message;

  @override
  String toString() => message;
}
