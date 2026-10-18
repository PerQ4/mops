import 'dart:convert';
import 'dart:io';

import '../../state/catalog_providers.dart';
import '../local/app_settings.dart';
import '../models/models.dart';
import 'lyrics_format.dart';
import 'lyrics_variants.dart';

/// Тексты из базы Unison (`unison.boidu.dev`).
///
/// Почему она: умеет искать и по метаданным (название, исполнитель, альбом,
/// длительность), и по id видео YouTube. Возвращает LRC или обычный текст —
/// синхронизацию определяем по меткам времени. Порядок запросов как у
/// ArchiveTune: сначала поиск по метаданным, и только если он пуст — по id.
class UnisonSource {
  UnisonSource({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  static const String _host = 'https://unison.boidu.dev';
  static const int _maxResults = 5;

  /// Ищет текст по метаданным, а при неудаче — по id видео.
  Future<Lyrics> fetch({
    required String videoId,
    String? title,
    String? artist,
    String? album,
    Duration? duration,
  }) async {
    final bool hasMetadata = (title?.trim().isNotEmpty ?? false) &&
        (artist?.trim().isNotEmpty ?? false);

    if (hasMetadata) {
      final Lyrics byMetadata = await _search(
        title: title!.trim(),
        artist: artist!.trim(),
        album: album,
        duration: duration,
      );
      if (!byMetadata.isEmpty) return byMetadata;
    }

    if (videoId.trim().isNotEmpty) {
      return _byVideoId(videoId.trim());
    }
    return Lyrics.none;
  }

  /// Ищет записи списком — для ручного выбора.
  ///
  /// Почему: [fetch] молча берёт первый подходящий результат, а база может
  /// знать несколько версий песни. Здесь отдаём весь список с метаданными.
  Future<List<LyricsTrackHit>> search({
    required String title,
    required String artist,
    String? album,
    Duration? duration,
    String? apiKey,
  }) async {
    final String trimmedTitle = title.trim();
    final String trimmedArtist = artist.trim();
    // Поиск Unison требует и название, и исполнителя.
    if (trimmedTitle.isEmpty || trimmedArtist.isEmpty) {
      return const <LyricsTrackHit>[];
    }

    final Map<String, dynamic>? json = await _get(
      Uri.parse('$_host/lyrics/search').replace(queryParameters: <String, String>{
        'song': trimmedTitle,
        'artist': trimmedArtist,
        if (album != null && album.trim().isNotEmpty) 'album': album.trim(),
        'limit': '10',
      }),
    );
    if (json == null || json['success'] != true) return const <LyricsTrackHit>[];

    final dynamic data = json['data'];
    if (data is! List) return const <LyricsTrackHit>[];

    final List<LyricsTrackHit> hits = <LyricsTrackHit>[];
    for (final dynamic item in data) {
      if (item is! Map<String, dynamic>) continue;
      // Для скачивания годится либо числовой id записи, либо id видео:
      // [fetchHit] сам поймёт, какой адрес использовать.
      final num? id = item['id'] as num?;
      final String? videoId = item['videoId'] as String?;
      final String key = id != null ? '${id.toInt()}' : (videoId?.trim() ?? '');
      if (key.isEmpty) continue;

      final num? seconds = item['durationSeconds'] as num?;
      hits.add(LyricsTrackHit(
        source: LyricsSource.unison,
        id: key,
        title: item['title'] as String?,
        artist: item['artist'] as String?,
        duration: seconds == null ? null : Duration(seconds: seconds.toInt()),
        // Список поиска не сообщает, есть ли времена, — честно оставляем
        // неизвестность, а не выдумываем ответ.
        hasSync: null,
      ));
    }
    return hits;
  }

  /// Достаёт текст ровно выбранной записи.
  /// Все совпадения с текстом — как `getAllLyrics` в ArchiveTune.
  ///
  /// Unison отдаёт текст отдельным запросом на запись, поэтому берём первые
  /// записи из поиска и качаем их параллельно (см. [kMaxLyricsVariants]).
  Future<List<Lyrics>> fetchAll({
    required String title,
    required String artist,
    String? album,
    Duration? duration,
  }) async {
    final List<LyricsTrackHit> hits = await search(
      title: title,
      artist: artist,
      album: album,
      duration: duration,
    );
    return fetchVariants(hits, fetchHit);
  }

  Future<Lyrics> fetchHit(LyricsTrackHit hit) async {
    final String id = hit.id.trim();
    if (id.isEmpty) return Lyrics.none;
    // Числовой id — запись базы; иначе это id видео YouTube.
    return int.tryParse(id) != null
        ? _byId(id, match: hit.match)
        : _byVideoId(id, match: hit.match);
  }

  Future<Lyrics> _search({
    required String title,
    required String artist,
    String? album,
    Duration? duration,
  }) async {
    final Map<String, dynamic>? json = await _get(
      Uri.parse('$_host/lyrics/search').replace(queryParameters: <String, String>{
        'song': title,
        'artist': artist,
        if (album != null && album.trim().isNotEmpty) 'album': album.trim(),
        if (duration != null && duration > Duration.zero)
          'duration': '${duration.inSeconds}',
        'limit': '$_maxResults',
      }),
    );
    if (json == null || json['success'] != true) return Lyrics.none;

    final dynamic data = json['data'];
    if (data is! List) return Lyrics.none;

    for (final dynamic item in data) {
      if (item is! Map<String, dynamic>) continue;

      final Lyrics direct = _fromEntry(item);
      if (!direct.isEmpty) return direct;

      // Список поиска бывает «лёгким»: без текста, но со ссылками на запись.
      final String? videoId = item['videoId'] as String?;
      if (videoId != null && videoId.trim().isNotEmpty) {
        final Lyrics byVideo = await _byVideoId(videoId.trim());
        if (!byVideo.isEmpty) return byVideo;
      }
      final num? id = item['id'] as num?;
      if (id != null) {
        final Lyrics byId = await _byId('${id.toInt()}');
        if (!byId.isEmpty) return byId;
      }
    }
    return Lyrics.none;
  }

  Future<Lyrics> _byVideoId(String videoId, {LyricsMatch? match}) async {
    final Map<String, dynamic>? json = await _get(
      Uri.parse('$_host/lyrics').replace(
        queryParameters: <String, String>{'v': videoId},
      ),
    );
    if (json == null || json['success'] != true) return Lyrics.none;
    final dynamic data = json['data'];
    return data is Map<String, dynamic>
        ? _fromEntry(data, match: match)
        : Lyrics.none;
  }

  Future<Lyrics> _byId(String id, {LyricsMatch? match}) async {
    final Map<String, dynamic>? json = await _get(Uri.parse('$_host/lyrics/$id'));
    if (json == null || json['success'] != true) return Lyrics.none;
    final dynamic data = json['data'];
    return data is Map<String, dynamic>
        ? _fromEntry(data, match: match)
        : Lyrics.none;
  }

  /// [match] — метаданные выбранной вручную записи: если они есть, оценка
  /// идёт по ним, а не по полям ответа.
  Lyrics _fromEntry(Map<String, dynamic> entry, {LyricsMatch? match}) {
    final String? lyrics = entry['lyrics'] as String?;
    if (lyrics != null && lyrics.trim().isNotEmpty) {
      final num? seconds = entry['durationSeconds'] as num?;
      return lyricsFromText(
        lyrics,
        'Unison',
        match: match ??
            LyricsMatch(
              title: entry['title'] as String?,
              artist: entry['artist'] as String?,
              duration:
                  seconds == null ? null : Duration(seconds: seconds.toInt()),
            ),
      );
    }
    return Lyrics.none;
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
