import 'dart:convert';
import 'dart:io';

import '../../state/catalog_providers.dart';
import '../local/app_settings.dart';
import '../models/models.dart';
import 'lyrics_variants.dart';

/// Тексты из открытой базы LRCLIB.
///
/// Почему именно она: база бесплатная, без ключей и регистрации, а главное —
/// отдаёт **синхронизированный** текст в формате LRC. Именно синхронизация
/// даёт то, чего не хватает текстам YouTube Music: автопрокрутку и подсветку
/// текущей строки. Тексты в базу добавляют пользователи, поэтому для редких
/// записей её может не оказаться — тогда приложение берёт другой источник.
///
/// Адреса: `https://lrclib.net/api/get` (точное совпадение) и
/// `https://lrclib.net/api/search` (поиск). База просит идентифицировать
/// приложение в `User-Agent` — так и делаем.
class LrclibSource {
  LrclibSource({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  static const String _host = 'https://lrclib.net/api';

  /// Только ASCII: заголовки HTTP кодируются как latin-1, и кириллица в
  /// `User-Agent` приводила к исключению при отправке — запрос молча падал,
  /// и база всегда выглядела пустой.
  static const String _userAgent = 'mOps/1.0 (YouTube Music client)';

  /// Ищет текст по исполнителю, названию, альбому и длительности.
  ///
  /// Сначала пробуем точное совпадение: так меньше шансов взять чужой текст
  /// у одноимённых песен. Если не нашлось — идём в поиск и берём первый
  /// результат, у которого есть синхронизация.
  Future<Lyrics> fetch({
    required String title,
    required String artist,
    String? album,
    Duration? duration,
  }) async {
    if (title.trim().isEmpty || artist.trim().isEmpty) return Lyrics.none;

    final Lyrics exact = await _get(
      title: title,
      artist: artist,
      album: album,
      duration: duration,
    );
    if (!exact.isEmpty) return exact;

    return _search('$artist $title');
  }

  /// Ищет записи списком — для ручного выбора.
  ///
  /// Почему: обычный [fetch] отдаёт один вариант, и если база выбрала не ту
  /// запись, пользователю нечего возразить. Здесь отдаём все совпадения с
  /// метаданными, чтобы он сам выбрал нужный трек.
  Future<List<LyricsTrackHit>> search({
    required String title,
    required String artist,
    String? album,
    Duration? duration,
    String? apiKey,
  }) async {
    final String query = '$artist $title'.trim();
    if (query.isEmpty) return const <LyricsTrackHit>[];

    final Map<String, dynamic>? json = await _request(
      Uri.parse('$_host/search').replace(
        queryParameters: <String, String>{'q': query},
      ),
    );
    if (json == null) return const <LyricsTrackHit>[];

    final List<dynamic> results =
        json['results'] as List<dynamic>? ?? <dynamic>[];
    final List<LyricsTrackHit> hits = <LyricsTrackHit>[];
    for (final dynamic item in results) {
      if (item is! Map<String, dynamic>) continue;
      final String id = '${item['id'] ?? ''}';
      if (id.isEmpty) continue;
      final num? seconds = item['duration'] as num?;
      final String? synced = item['syncedLyrics'] as String?;
      hits.add(LyricsTrackHit(
        source: LyricsSource.lrclib,
        id: id,
        title: item['trackName'] as String?,
        artist: item['artistName'] as String?,
        album: item['albumName'] as String?,
        duration: seconds == null ? null : Duration(seconds: seconds.toInt()),
        // Пустой `syncedLyrics` — синхронизации нет, но запись всё равно
        // годится: отдадим обычный текст.
        hasSync: synced != null && synced.trim().isNotEmpty,
      ));
    }
    return hits;
  }

  /// Все совпадения с текстом — как `getAllLyrics` в ArchiveTune.
  ///
  /// Почему одним запросом: `/search` уже отдаёт и `syncedLyrics`, и
  /// `plainLyrics`, поэтому каждый вариант обходится без отдельного обращения —
  /// в отличие от остальных баз, где текст приходится тянуть по записи.
  Future<List<Lyrics>> fetchAll({
    required String title,
    required String artist,
    String? album,
    Duration? duration,
  }) async {
    final String query = '$artist $title'.trim();
    if (query.isEmpty) return const <Lyrics>[];

    final Map<String, dynamic>? json = await _request(
      Uri.parse('$_host/search').replace(
        queryParameters: <String, String>{'q': query},
      ),
    );
    if (json == null) return const <Lyrics>[];

    final List<dynamic> results =
        json['results'] as List<dynamic>? ?? <dynamic>[];
    final List<Lyrics> variants = <Lyrics>[];
    for (final dynamic item in results) {
      if (item is! Map<String, dynamic>) continue;
      final Lyrics lyrics = _fromJson(item);
      if (lyrics.isEmpty) continue;
      variants.add(lyrics);
      if (variants.length >= kMaxLyricsVariants) break;
    }
    return variants;
  }

  /// Достаёт текст ровно выбранной записи по её id.
  Future<Lyrics> fetchHit(LyricsTrackHit hit) async {
    final String id = hit.id.trim();
    if (id.isEmpty) return Lyrics.none;
    final Map<String, dynamic>? json =
        await _request(Uri.parse('$_host/get/$id'));
    if (json == null) return Lyrics.none;
    // Метаданные берём из выбранной записи: по ним работает оценка.
    return _fromJson(json, match: hit.match);
  }

  Future<Lyrics> _get({
    required String title,
    required String artist,
    String? album,
    Duration? duration,
  }) async {
    final Map<String, String> query = <String, String>{
      'artist_name': artist,
      'track_name': title,
      if (album != null && album.isNotEmpty) 'album_name': album,
      if (duration != null && duration > Duration.zero)
        'duration': '${duration.inSeconds}',
    };

    final Map<String, dynamic>? json = await _request(
      Uri.parse('$_host/get').replace(queryParameters: query),
    );
    if (json == null) return Lyrics.none;
    return _fromJson(json);
  }

  Future<Lyrics> _search(String query) async {
    final Map<String, dynamic>? json = await _request(
      Uri.parse('$_host/search').replace(
        queryParameters: <String, String>{'q': query},
      ),
    );
    if (json == null) return Lyrics.none;

    // Поиск отдаёт список: берём первый результат с синхронизацией, иначе
    // первый с обычным текстом.
    final List<dynamic> results = json['results'] as List<dynamic>? ?? <dynamic>[];
    Lyrics fallback = Lyrics.none;
    for (final dynamic item in results) {
      if (item is! Map<String, dynamic>) continue;
      final Lyrics lyrics = _fromJson(item);
      if (lyrics.isSynced) return lyrics;
      if (fallback.isEmpty) fallback = lyrics;
    }
    return fallback;
  }

  /// Превращает ответ базы в наш [Lyrics].
  ///
  /// [match] — метаданные выбранной вручную записи: если они есть, оценка
  /// совместимости идёт по ним, а не по полям ответа.
  Lyrics _fromJson(Map<String, dynamic> json, {LyricsMatch? match}) {
    // Метаданные нужны оценке совместимости: у LRCLIB это название,
    // исполнитель и длительность в секундах.
    final num? duration = json['duration'] as num?;
    final LyricsMatch resolved = match ??
        LyricsMatch(
          title: json['trackName'] as String?,
          artist: json['artistName'] as String?,
          duration:
              duration == null ? null : Duration(seconds: duration.toInt()),
        );

    final String? synced = json['syncedLyrics'] as String?;
    if (synced != null && synced.trim().isNotEmpty) {
      final List<TimedLyric> timed = parseLrc(synced);
      if (timed.isNotEmpty) {
        return Lyrics(
          timed: timed,
          plain: timed.map((TimedLyric l) => l.text).join('\n'),
          source: 'LRCLIB',
          match: resolved,
        );
      }
    }

    final String? plain = json['plainLyrics'] as String?;
    if (plain != null && plain.trim().isNotEmpty) {
      return Lyrics(plain: plain.trim(), source: 'LRCLIB', match: resolved);
    }
    return Lyrics.none;
  }

  /// Разбирает формат LRC: `[00:12.34] строка`.
  ///
  /// В одной строке может стоять несколько меток времени (припев) — тогда
  /// текст повторяется для каждой, чтобы подсветка работала.
  static List<TimedLyric> parseLrc(String lrc) {
    final RegExp stamp = RegExp(r'\[(\d+):(\d+(?:[.,]\d+)?)\]');
    final List<TimedLyric> lines = <TimedLyric>[];

    for (final String raw in lrc.split('\n')) {
      final String text = raw.replaceAll(stamp, '').trim();
      if (text.isEmpty) continue;
      for (final RegExpMatch match in stamp.allMatches(raw)) {
        final int minutes = int.parse(match.group(1)!);
        final double seconds =
            double.parse(match.group(2)!.replaceAll(',', '.'));
        lines.add(TimedLyric(
          time: Duration(
            milliseconds: (minutes * 60000 + seconds * 1000).round(),
          ),
          text: text,
        ));
      }
    }

    lines.sort((TimedLyric a, TimedLyric b) => a.time.compareTo(b.time));
    return lines;
  }

  Future<Map<String, dynamic>?> _request(Uri uri) async {
    try {
      final HttpClientRequest request = await _client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final HttpClientResponse response =
          await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final String body = await response.transform(utf8.decoder).join();
      final dynamic decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is List<dynamic>) {
        return <String, dynamic>{'results': decoded};
      }
      return null;
    } on Object {
      // База может быть недоступна — это не ошибка приложения.
      return null;
    }
  }

  void dispose() => _client.close(force: true);
}
