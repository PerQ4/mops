import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../state/catalog_providers.dart';
import '../local/app_settings.dart';
import '../models/models.dart';
import 'lyrics_format.dart';
import 'lyrics_match.dart';
import 'lyrics_variants.dart';

/// Результат проверки ключа Paxsenix — то, что показывает экран настроек.
///
/// `title` — короткая подпись для пользователя, `ok` — удалось ли
/// подтвердить ключ (для выбора цвета в UI).
enum PaxsenixKeyStatus {
  empty('Ключ не задан', false),
  valid('Ключ работает', true),
  rejected('Ключ не принят', false),
  unavailable('Сервис недоступен', false);

  const PaxsenixKeyStatus(this.title, this.ok);

  final String title;
  final bool ok;
}

/// Тексты через Paxsenix (`api.paxsenix.org`) — как в ArchiveTune.
///
/// Почему он: закрытые базы (Apple Music, Musixmatch) не отдают текст напрямую,
/// а Paxsenix проксирует их одним ключом. Главное — Apple Music приходит в
/// TTML-подобной разметке с временем **каждого слова**, то есть даёт караоке,
/// которого нет у обычных баз.
///
/// Ключ выдаётся на `https://lyrics.paxsenix.org/` и передаётся как
/// `Authorization: Bearer`. Без ключа сервис отвечает 401, поэтому источник
/// просто пропускается — остальные базы работают.
class PaxsenixSource {
  PaxsenixSource({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  static const String _host = 'https://api.paxsenix.org';

  /// Сначала Apple Music (пословная разметка), затем Musixmatch, затем общий
  /// поиск по базе lrcget. Каталоги включаются по отдельности: выключенный
  /// не спрашивается вовсе (как `paxsenixProviders` в ArchiveTune).
  Future<Lyrics> fetch({
    required String title,
    required String artist,
    required String apiKey,
    Duration? duration,
    PaxsenixOptions options = const PaxsenixOptions(),
  }) async {
    final String key = apiKey.trim();
    if (key.isEmpty) return Lyrics.none;
    if (title.trim().isEmpty || artist.trim().isEmpty) return Lyrics.none;
    // Все каталоги выключены — спрашивать нечего.
    if (!options.any) return Lyrics.none;

    if (options.appleMusic) {
      final Lyrics apple =
          await _appleMusic(title.trim(), artist.trim(), duration, key);
      if (!apple.isEmpty) return apple;
    }

    if (options.musixmatch) {
      final Lyrics musix =
          await _musixmatch(title.trim(), artist.trim(), duration, key);
      if (!musix.isEmpty) return musix;
    }

    return _lrcget(title.trim(), artist.trim(), key);
  }

  /// Ищет записи списком — для ручного выбора.
  ///
  /// Почему: Apple Music и Spotify — разные каталоги, и один и тот же трек
  /// может лежать в обоих. Отдаём объединённый список, а каталог каждой
  /// записи запоминаем в [LyricsTrackHit.provider], чтобы [fetchHit] знал,
  /// куда за текстом идти.
  Future<List<LyricsTrackHit>> search({
    required String title,
    required String artist,
    String? album,
    Duration? duration,
    String? apiKey,
    PaxsenixOptions options = const PaxsenixOptions(),
  }) async {
    final String key = (apiKey ?? '').trim();
    // Без ключа сервис отвечает 401 — источник просто пропускается.
    if (key.isEmpty) return const <LyricsTrackHit>[];

    final String trimmedTitle = title.trim();
    final String trimmedArtist = artist.trim();
    if (trimmedTitle.isEmpty && trimmedArtist.isEmpty) {
      return const <LyricsTrackHit>[];
    }

    // Каталоги независимы — спрашиваем включённые параллельно.
    final List<Future<List<LyricsTrackHit>>> requests =
        <Future<List<LyricsTrackHit>>>[
      if (options.appleMusic)
        _searchCatalog('apple-music/search', 'applemusic', trimmedTitle,
            trimmedArtist, key),
      if (options.spotify)
        _searchCatalog(
            'spotify/search', 'spotify', trimmedTitle, trimmedArtist, key),
    ];
    if (requests.isEmpty) return const <LyricsTrackHit>[];

    final List<List<LyricsTrackHit>> groups = await Future.wait(requests);

    final List<LyricsTrackHit> hits = <LyricsTrackHit>[];
    for (final List<LyricsTrackHit> group in groups) {
      hits.addAll(group);
    }
    return hits;
  }

  /// Все совпадения с текстом — как `getAllLyrics` в ArchiveTune.
  ///
  /// Текст каждой записи Paxsenix отдаёт отдельным запросом, поэтому берём
  /// первые записи из поиска и качаем их параллельно (см.
  /// [kMaxLyricsVariants]).
  Future<List<Lyrics>> fetchAll({
    required String title,
    required String artist,
    String apiKey = '',
    Duration? duration,
    PaxsenixOptions options = const PaxsenixOptions(),
  }) async {
    final String key = apiKey.trim();
    if (key.isEmpty) return const <Lyrics>[];
    final List<LyricsTrackHit> hits = await search(
      title: title,
      artist: artist,
      duration: duration,
      apiKey: key,
      options: options,
    );
    return fetchVariants(
      hits,
      (LyricsTrackHit hit) => fetchHit(hit, apiKey: key),
    );
  }

  /// Достаёт текст ровно выбранной записи.
  ///
  /// [provider] берётся из самой записи: Apple Music и Spotify живут на
  /// разных эндпоинтах одного хоста.
  Future<Lyrics> fetchHit(LyricsTrackHit hit, {String apiKey = ''}) async {
    final String key = apiKey.trim();
    if (key.isEmpty || hit.id.trim().isEmpty) return Lyrics.none;

    final String provider = hit.provider ?? 'applemusic';
    final Map<String, dynamic>? json = await _getJson(
      Uri.parse('$_host/lyrics/$provider').replace(
        queryParameters: <String, String>{'id': hit.id},
      ),
      key,
    );
    if (json == null) return Lyrics.none;

    if (provider == 'applemusic') {
      return _fromAppleMusic(json, hit.match);
    }
    // Spotify приходит обычным текстом или LRC. Формат ответа не
    // гарантирован, поэтому собираем текст из строк и массивов строк.
    final String? text = _looseLyricsText(json);
    if (text == null || text.trim().isEmpty) return Lyrics.none;
    return lyricsFromText(text, 'Paxsenix: Spotify', match: hit.match);
  }

  /// Достаёт текст из ответа Spotify произвольной формы.
  ///
  /// Почему не [_findText]: тот берёт первую найденную строку, а текст может
  /// прийти массивом строк — тогда вернулась бы только первая строка.
  String? _looseLyricsText(Map<String, dynamic> json) {
    for (final String key in <String>[
      'lyrics',
      'lrc',
      'syncedLyrics',
      'plainLyrics',
      'content',
      'text',
      'lines',
    ]) {
      final dynamic value = json[key];
      if (value is String && value.trim().isNotEmpty) return value;
      if (value is List) {
        final List<String> parts = <String>[];
        for (final dynamic item in value) {
          if (item is String && item.trim().isNotEmpty) {
            parts.add(item);
          } else if (item is Map) {
            final dynamic line = item['text'] ?? item['line'] ?? item['lyrics'];
            if (line is String && line.trim().isNotEmpty) parts.add(line);
          }
        }
        if (parts.isNotEmpty) return parts.join('\n');
      }
    }
    return null;
  }

  /// Ищет треки в одном каталоге Paxsenix и превращает их в записи списка.
  Future<List<LyricsTrackHit>> _searchCatalog(
    String path,
    String provider,
    String title,
    String artist,
    String key,
  ) async {
    final Map<String, dynamic>? json = await _getJson(
      Uri.parse('$_host/$path').replace(
        queryParameters: <String, String>{'q': '$title $artist'.trim()},
      ),
      key,
    );
    if (json == null) return const <LyricsTrackHit>[];

    final List<Map<String, dynamic>> tracks = <Map<String, dynamic>>[];
    _collectTracks(json, tracks, 0);

    final List<LyricsTrackHit> hits = <LyricsTrackHit>[];
    for (final Map<String, dynamic> track in tracks) {
      final String? id = _trackId(track);
      final String? name = _trackName(track);
      if (id == null || name == null) continue;
      hits.add(LyricsTrackHit(
        source: LyricsSource.musixmatch,
        id: id,
        provider: provider,
        title: name,
        artist: track['artistName'] as String? ??
            track['artist_name'] as String?,
        album: track['albumName'] as String? ??
            track['album_name'] as String?,
        duration: _durationOf(track),
        // Apple Music отдаёт TTML с временами — синхронизация точно есть.
        // По Spotify список этого не сообщает.
        hasSync: provider == 'applemusic' ? true : null,
      ));
    }
    return hits;
  }

  /// Лёгкая проверка ключа: один запрос к базе lrcget с заведомо известным
  /// треком. Исключения наружу не выходят — только понятный статус, чтобы
  /// настройки могли объяснить, принят ключ или нет.
  Future<PaxsenixKeyStatus> checkKey(String apiKey) async {
    final String key = apiKey.trim();
    if (key.isEmpty) return PaxsenixKeyStatus.empty;

    try {
      final Uri uri = Uri.parse('$_host/lyrics/lrcget').replace(
        queryParameters: <String, String>{'q': 'radiohead creep'},
      );
      final HttpClientRequest request = await _client.getUrl(uri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/json, text/plain, */*',
      );
      final HttpClientResponse response =
          await request.close().timeout(const Duration(seconds: 12));
      final String body = await response.transform(utf8.decoder).join();

      // 401/403 — ключ не принят; остальные не-200 — сервис недоступен.
      if (response.statusCode == HttpStatus.unauthorized ||
          response.statusCode == HttpStatus.forbidden) {
        return PaxsenixKeyStatus.rejected;
      }
      if (response.statusCode != HttpStatus.ok) {
        return PaxsenixKeyStatus.unavailable;
      }

      // Даже при 200 сервис может вернуть ошибку ключа в теле.
      final dynamic decoded = _tryDecode(body);
      if (decoded is Map) {
        final dynamic error = decoded['error'];
        if (error is String && _isKeyError(error)) {
          return PaxsenixKeyStatus.rejected;
        }
      }
      // Любой неошибочный ответ означает, что ключ принят.
      return PaxsenixKeyStatus.valid;
    } on Object {
      return PaxsenixKeyStatus.unavailable;
    }
  }

  /// Похоже ли сообщение об ошибке на отказ по ключу.
  bool _isKeyError(String error) {
    final String value = error.toLowerCase();
    return value.contains('key_required') ||
        value.contains('key_invalid') ||
        value.contains('invalid_key') ||
        value.contains('unauthorized');
  }

  // --- Apple Music ---------------------------------------------------------

  Future<Lyrics> _appleMusic(
    String title,
    String artist,
    Duration? duration,
    String key,
  ) async {
    final Map<String, dynamic>? found = await _findTrack(
      path: 'apple-music/search',
      title: title,
      artist: artist,
      duration: duration,
      apiKey: key,
    );
    if (found == null) return Lyrics.none;

    final String? id = _trackId(found);
    if (id == null) return Lyrics.none;

    final Map<String, dynamic>? json = await _getJson(
      Uri.parse('$_host/lyrics/applemusic').replace(
        queryParameters: <String, String>{'id': id},
      ),
      key,
    );
    if (json == null) return Lyrics.none;

    final LyricsMatch match = LyricsMatch(
      title: found['name'] as String? ?? found['title'] as String?,
      artist: found['artistName'] as String? ?? artist,
      duration: _durationOf(found),
    );
    return _fromAppleMusic(json, match);
  }

  /// Разбирает ответ Apple Music: строки со временем и словами внутри.
  Lyrics _fromAppleMusic(Map<String, dynamic> json, LyricsMatch match) {
    final List<dynamic> content = json['content'] as List<dynamic>? ?? <dynamic>[];
    final List<TimedLyric> lines = <TimedLyric>[];

    for (final dynamic rawLine in content) {
      if (rawLine is! Map) continue;
      final int lineTime = (rawLine['timestamp'] as num?)?.toInt() ?? 0;
      final List<dynamic> words = rawLine['text'] as List<dynamic>? ?? <dynamic>[];

      final StringBuffer buffer = StringBuffer();
      final List<TimedWord> timedWords = <TimedWord>[];
      for (final dynamic rawWord in words) {
        if (rawWord is! Map) continue;
        final String word = rawWord['text'] as String? ?? '';
        if (word.isEmpty) continue;
        buffer.write(word);
        final int? wordTime = (rawWord['timestamp'] as num?)?.toInt();
        final String trimmed = word.trim();
        if (wordTime != null && trimmed.isNotEmpty) {
          timedWords.add(TimedWord(
            time: Duration(milliseconds: wordTime),
            text: trimmed,
          ));
        }
      }

      String text = buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      // Если сервис отдал слова без пробелов («Theclubisn't»), собираем строку
      // из слов через пробел — иначе текст нечитаем.
      if (words.length > 1 && !text.contains(' ')) {
        text = timedWords.map((TimedWord w) => w.text).join(' ').trim();
      }
      if (text.isEmpty) continue;

      lines.add(TimedLyric(
        time: Duration(milliseconds: lineTime),
        text: text,
        words: timedWords.isEmpty ? null : timedWords,
      ));
    }

    if (lines.isEmpty) return Lyrics.none;
    lines.sort((TimedLyric a, TimedLyric b) => a.time.compareTo(b.time));
    return Lyrics(
      timed: lines,
      plain: lines.map((TimedLyric l) => l.text).join('\n'),
      source: 'Paxsenix: Apple Music',
      match: match,
    );
  }

  // --- Musixmatch ----------------------------------------------------------

  Future<Lyrics> _musixmatch(
    String title,
    String artist,
    Duration? duration,
    String key,
  ) async {
    final String? body = await _getText(
      Uri.parse('$_host/lyrics/musixmatch').replace(
        queryParameters: <String, String>{
          't': title,
          'a': artist,
          if (duration != null && duration > Duration.zero)
            'd': '${duration.inSeconds}',
        },
      ),
      key,
    );
    if (body == null) return Lyrics.none;
    return _lyricsFromLooseBody(body, 'Paxsenix: Musixmatch');
  }

  // --- lrcget --------------------------------------------------------------

  Future<Lyrics> _lrcget(String title, String artist, String key) async {
    final String? body = await _getText(
      Uri.parse('$_host/lyrics/lrcget').replace(
        queryParameters: <String, String>{'q': '$title $artist'},
      ),
      key,
    );
    if (body == null) return Lyrics.none;
    return _lyricsFromLooseBody(body, 'Paxsenix: lrcget');
  }

  // --- Общее ---------------------------------------------------------------

  /// Достаёт текст из ответа произвольной формы: готовая LRC-строка, строка
  /// внутри JSON или вложенный объект с текстом.
  Lyrics _lyricsFromLooseBody(String body, String source) {
    final String trimmed = body.trim();
    if (trimmed.isEmpty) return Lyrics.none;

    final dynamic decoded = _tryDecode(trimmed);
    if (decoded is Map && _isError(decoded)) return Lyrics.none;

    final String extracted = _findText(decoded) ?? trimmed;
    if (extracted.trim().isEmpty) return Lyrics.none;
    return lyricsFromText(extracted, source);
  }

  /// Ошибка сервиса (нет ключа, не найдено) — это не текст.
  bool _isError(Map<dynamic, dynamic> json) {
    if (json['ok'] == false) return true;
    if (json['isError'] == true) return true;
    final dynamic error = json['error'];
    if (error is String && error.trim().isNotEmpty) return true;
    if (error is Map && error.isNotEmpty) return true;
    if (error is List && error.isNotEmpty) return true;
    return false;
  }

  String? _findText(dynamic node, [int depth = 0]) {
    if (depth > 4) return null;
    if (node is String) {
      final String value = node.trim();
      return value.isEmpty ? null : value;
    }
    if (node is List) {
      for (final dynamic child in node) {
        final String? found = _findText(child, depth + 1);
        if (found != null) return found;
      }
      return null;
    }
    if (node is Map) {
      for (final String key in <String>[
        'lyrics',
        'lrc',
        'content',
        'syncedLyrics',
        'plainLyrics',
        'lines',
        'text',
      ]) {
        final dynamic value = node[key];
        if (value == null) continue;
        final String? found = _findText(value, depth + 1);
        if (found != null) return found;
      }
    }
    return null;
  }

  /// Ищет трек в поиске Paxsenix и выбирает ближайший по метаданным.
  Future<Map<String, dynamic>?> _findTrack({
    required String path,
    required String title,
    required String artist,
    required Duration? duration,
    required String apiKey,
  }) async {
    final Map<String, dynamic>? json = await _getJson(
      Uri.parse('$_host/$path').replace(
        queryParameters: <String, String>{'q': '$title $artist'},
      ),
      apiKey,
    );
    if (json == null) return null;

    final List<Map<String, dynamic>> candidates = <Map<String, dynamic>>[];
    _collectTracks(json, candidates, 0);
    if (candidates.isEmpty) return null;

    candidates.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        _score(b, title, artist, duration)
            .compareTo(_score(a, title, artist, duration)));
    return candidates.first;
  }

  void _collectTracks(dynamic node, List<Map<String, dynamic>> out, int depth) {
    if (depth > 5) return;
    if (node is List) {
      for (final dynamic child in node) {
        _collectTracks(child, out, depth + 1);
      }
      return;
    }
    if (node is! Map) return;
    final Map<String, dynamic> details = node['attributes'] is Map
        ? Map<String, dynamic>.from(node['attributes'] as Map)
        : Map<String, dynamic>.from(node);
    if (_trackId(details) != null && _trackName(details) != null) {
      out.add(details);
    }
    for (final dynamic value in node.values) {
      _collectTracks(value, out, depth + 1);
    }
  }

  String? _trackId(Map<dynamic, dynamic> track) {
    for (final String key in <String>['id', 'trackId', 'track_id', 'realId']) {
      final dynamic value = track[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is num) return '${value.toInt()}';
    }
    return null;
  }

  String? _trackName(Map<dynamic, dynamic> track) {
    for (final String key in <String>['name', 'title', 'trackName', 'track_name']) {
      final dynamic value = track[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  Duration? _durationOf(Map<dynamic, dynamic> track) {
    for (final String key in <String>[
      'durationInMillis',
      'durationMs',
      'duration_ms',
      'duration',
    ]) {
      final dynamic value = track[key];
      if (value is num && value > 0) {
        // Короткие значения — секунды, длинные — миллисекунды.
        return value < 10000
            ? Duration(seconds: value.toInt())
            : Duration(milliseconds: value.toInt());
      }
    }
    return null;
  }

  int _score(
    Map<String, dynamic> track,
    String title,
    String artist,
    Duration? duration,
  ) {
    int score = 0;
    final String? name = _trackName(track);
    if (name != null && normalizeMatchText(name) == normalizeMatchText(title)) {
      score += 20;
    } else if (name != null &&
        normalizeMatchText(name).contains(normalizeMatchText(title))) {
      score += 10;
    }

    final dynamic trackArtist = track['artistName'] ?? track['artist_name'];
    if (trackArtist is String) {
      if (normalizeMatchText(trackArtist) == normalizeMatchText(artist)) {
        score += 15;
      } else if (normalizeMatchText(trackArtist)
          .contains(normalizeMatchText(artist))) {
        score += 5;
      }
    }

    final Duration? trackDuration = _durationOf(track);
    if (duration != null && duration > Duration.zero && trackDuration != null) {
      final int diff = (trackDuration - duration).inSeconds.abs();
      if (diff <= 3) {
        score += 10;
      } else if (diff <= 10) {
        score += 5;
      }
    }
    return score;
  }

  dynamic _tryDecode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _getJson(Uri uri, String apiKey) async {
    final String? body = await _getText(uri, apiKey);
    if (body == null) return null;
    final dynamic decoded = _tryDecode(body);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  Future<String?> _getText(Uri uri, String apiKey) async {
    try {
      final HttpClientRequest request = await _client.getUrl(uri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/json, text/plain, */*',
      );
      final HttpClientResponse response =
          await request.close().timeout(const Duration(seconds: 12));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      return await response.transform(utf8.decoder).join();
    } on Object {
      // Сервис может быть недоступен или ключ неверен — это не ошибка
      // приложения, за текст отвечают остальные базы.
      return null;
    }
  }

  void dispose() => _client.close(force: true);
}
