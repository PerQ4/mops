import 'dart:convert';
import 'dart:io';

import '../models/models.dart';
import 'lyrics_format.dart';

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

  Future<Lyrics> _byVideoId(String videoId) async {
    final Map<String, dynamic>? json = await _get(
      Uri.parse('$_host/lyrics').replace(
        queryParameters: <String, String>{'v': videoId},
      ),
    );
    if (json == null || json['success'] != true) return Lyrics.none;
    final dynamic data = json['data'];
    return data is Map<String, dynamic> ? _fromEntry(data) : Lyrics.none;
  }

  Future<Lyrics> _byId(String id) async {
    final Map<String, dynamic>? json = await _get(Uri.parse('$_host/lyrics/$id'));
    if (json == null || json['success'] != true) return Lyrics.none;
    final dynamic data = json['data'];
    return data is Map<String, dynamic> ? _fromEntry(data) : Lyrics.none;
  }

  Lyrics _fromEntry(Map<String, dynamic> entry) {
    final String? lyrics = entry['lyrics'] as String?;
    if (lyrics != null && lyrics.trim().isNotEmpty) {
      return lyricsFromText(lyrics, 'Unison');
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
