import 'dart:convert';
import 'dart:io';

import '../../state/catalog_providers.dart';
import '../local/app_settings.dart';
import '../models/models.dart';
import 'lrclib_source.dart';
import 'lyrics_variants.dart';

/// Тексты из базы KuGou.
///
/// Почему она: из этой сети LRCLIB отвечает заглушкой, Megalobiz недоступен,
/// а KuGou отвечает и на русские запросы, и на английские, и отдаёт текст
/// в формате LRC — то есть **с временами**, а значит с автопрокруткой и
/// подсветкой строки. Тексты YouTube Music синхронизации не содержат вовсе.
///
/// Порядок запросов как у ArchiveTune: сначала поиск кандидатов, затем
/// скачивание выбранного текста (содержимое приходит в base64).
class KugouSource {
  KugouSource({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  static const String _searchHost = 'https://lyrics.kugou.com/search';
  static const String _downloadHost = 'https://lyrics.kugou.com/download';

  /// Ищет текст по исполнителю, названию и длительности.
  Future<Lyrics> fetch({
    required String title,
    required String artist,
    Duration? duration,
  }) async {
    if (title.trim().isEmpty) return Lyrics.none;

    final String keyword = artist.trim().isEmpty
        ? title.trim()
        : '${artist.trim()} - ${title.trim()}';

    final Map<String, dynamic>? search = await _get(
      Uri.parse(_searchHost).replace(queryParameters: <String, String>{
        'ver': '1',
        'man': 'yes',
        'client': 'mobi',
        'keyword': keyword,
        if (duration != null && duration > Duration.zero)
          'duration': '${duration.inMilliseconds}',
      }),
    );
    if (search == null) return Lyrics.none;

    final List<dynamic> candidates =
        search['candidates'] as List<dynamic>? ?? <dynamic>[];
    if (candidates.isEmpty) return Lyrics.none;

    // Берём первого кандидата: KuGou сортирует выдачу по совпадению, а
    // сравнение по длительности уже учтено в самом запросе.
    for (final dynamic item in candidates) {
      if (item is! Map<String, dynamic>) continue;
      final String id = '${item['id'] ?? ''}';
      final String? key = item['accesskey'] as String?;
      if (id.isEmpty || key == null || key.isEmpty) continue;

      // KuGou присылает длительность в миллисекундах (как и в запросе) и
      // название/исполнителя кандидата — по ним потом оценивается совместимость.
      final num? duration = item['duration'] as num?;
      final LyricsMatch match = LyricsMatch(
        title: item['song'] as String?,
        artist: item['singer'] as String?,
        duration:
            duration == null ? null : Duration(milliseconds: duration.toInt()),
      );

      final Lyrics lyrics = await _download(id, key, match: match);
      if (!lyrics.isEmpty) return lyrics;
    }
    return Lyrics.none;
  }

  /// Ищет кандидатов списком — для ручного выбора.
  ///
  /// Почему: [fetch] берёт первого кандидата, а KuGou часто отдаёт первым
  /// кавер или live-версию. Здесь отдаём всех кандидатов с метаданными, чтобы
  /// пользователь выбрал нужную запись.
  Future<List<LyricsTrackHit>> search({
    required String title,
    required String artist,
    String? album,
    Duration? duration,
    String? apiKey,
  }) async {
    final String trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) return const <LyricsTrackHit>[];

    final String keyword = artist.trim().isEmpty
        ? trimmedTitle
        : '${artist.trim()} - $trimmedTitle';

    final Map<String, dynamic>? search = await _get(
      Uri.parse(_searchHost).replace(queryParameters: <String, String>{
        'ver': '1',
        'man': 'yes',
        'client': 'mobi',
        'keyword': keyword,
        if (duration != null && duration > Duration.zero)
          'duration': '${duration.inMilliseconds}',
      }),
    );
    if (search == null) return const <LyricsTrackHit>[];

    final List<dynamic> candidates =
        search['candidates'] as List<dynamic>? ?? <dynamic>[];
    final List<LyricsTrackHit> hits = <LyricsTrackHit>[];
    for (final dynamic item in candidates) {
      if (item is! Map<String, dynamic>) continue;
      final String id = '${item['id'] ?? ''}';
      final String? key = item['accesskey'] as String?;
      // Без id и ключа текст не скачать — такая запись бесполезна.
      if (id.isEmpty || key == null || key.isEmpty) continue;

      final num? ms = item['duration'] as num?;
      hits.add(LyricsTrackHit(
        source: LyricsSource.kugou,
        id: id,
        accessKey: key,
        title: item['song'] as String?,
        artist: item['singer'] as String?,
        duration: ms == null ? null : Duration(milliseconds: ms.toInt()),
        // KuGou отдаёт LRC — времена строк есть всегда.
        hasSync: true,
      ));
    }
    return hits;
  }

  /// Все совпадения с текстом — как `getAllLyrics` в ArchiveTune.
  ///
  /// KuGou отдаёт текст отдельным запросом на запись, поэтому берём первые
  /// записи из поиска и качаем их параллельно (см. [kMaxLyricsVariants]).
  Future<List<Lyrics>> fetchAll({
    required String title,
    required String artist,
    Duration? duration,
  }) async {
    final List<LyricsTrackHit> hits = await search(
      title: title,
      artist: artist,
      duration: duration,
    );
    return fetchVariants(hits, fetchHit);
  }

  /// Достаёт текст ровно выбранной записи по её id и ключу.
  Future<Lyrics> fetchHit(LyricsTrackHit hit) async {
    final String? key = hit.accessKey;
    if (hit.id.trim().isEmpty || key == null || key.isEmpty) {
      return Lyrics.none;
    }
    return _download(hit.id, key, match: hit.match);
  }

  Future<Lyrics> _download(
    String id,
    String accessKey, {
    LyricsMatch? match,
  }) async {
    final Map<String, dynamic>? json = await _get(
      Uri.parse(_downloadHost).replace(queryParameters: <String, String>{
        'ver': '1',
        'client': 'pc',
        'id': id,
        'accesskey': accessKey,
        'fmt': 'lrc',
        'charset': 'utf8',
      }),
    );
    if (json == null) return Lyrics.none;

    final String? content = json['content'] as String?;
    if (content == null || content.isEmpty) return Lyrics.none;

    final String lrc;
    try {
      // Содержимое приходит в base64.
      lrc = utf8.decode(base64.decode(content));
    } on Object {
      return Lyrics.none;
    }

    final List<TimedLyric> timed = LrclibSource.parseLrc(lrc);
    if (timed.isEmpty) return Lyrics.none;
    return Lyrics(
      timed: timed,
      plain: timed.map((TimedLyric l) => l.text).join('\n'),
      source: 'KuGou',
      match: match,
    );
  }

  Future<Map<String, dynamic>?> _get(Uri uri) async {
    try {
      final HttpClientRequest request = await _client.getUrl(uri);
      final HttpClientResponse response =
          await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final String body = await response.transform(utf8.decoder).join();
      final dynamic decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      // База может быть недоступна — это не ошибка приложения.
      return null;
    }
  }

  void dispose() => _client.close(force: true);
}
