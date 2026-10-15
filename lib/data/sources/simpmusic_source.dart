import 'dart:convert';
import 'dart:io';

import '../models/models.dart';
import 'lyrics_format.dart';

/// Тексты из базы SimpMusic (`api-lyrics.simpmusic.org`).
///
/// Почему она: индексируется по id видео YouTube, поэтому не зависит от того,
/// насколько точно совпали название и исполнитель. База наполняется вручную и
/// отдаёт как синхронизированный LRC, так и обычный текст.
///
/// Порядок запросов как у ArchiveTune: один запрос по id, затем выбор
/// кандидата, ближайшего по длительности (у одной песни бывают дубликаты).
class SimpMusicSource {
  SimpMusicSource({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  static const String _host = 'https://api-lyrics.simpmusic.org/v1';
  static const String _userAgent = 'SimpMusicLyrics/1.0';

  /// Ищет текст по id видео и, если знаем, по длительности.
  Future<Lyrics> fetch({required String videoId, Duration? duration}) async {
    if (videoId.trim().isEmpty) return Lyrics.none;

    final Map<String, dynamic>? json = await _get(
      Uri.parse('$_host/${Uri.encodeComponent(videoId.trim())}'),
    );
    if (json == null || json['success'] != true) return Lyrics.none;

    final List<dynamic> tracks = json['data'] as List<dynamic>? ?? <dynamic>[];
    if (tracks.isEmpty) return Lyrics.none;

    final Map<String, dynamic> best = _bestMatch(tracks, duration);
    if (best.isEmpty) return Lyrics.none;

    final String? synced = best['syncedLyrics'] as String?;
    final LyricsMatch match = _matchFrom(best);
    if (synced != null && synced.trim().isNotEmpty) {
      return lyricsFromText(synced, 'SimpMusic', match: match);
    }

    final String? plain = (best['plainLyric'] ?? best['plainLyrics']) as String?;
    if (plain != null && plain.trim().isNotEmpty) {
      return Lyrics(plain: plain.trim(), source: 'SimpMusic', match: match);
    }
    return Lyrics.none;
  }

  /// Метаданные кандидата для оценки совместимости.
  ///
  /// Поля у SimpMusic называются `songTitle`/`artistName`/`durationSeconds`
  /// (а не `title`/`duration`) — раньше сравнение по длительности из-за этого
  /// не работало вовсе и всегда давало «неизвестно».
  LyricsMatch _matchFrom(Map<String, dynamic> entry) {
    final num? seconds =
        (entry['durationSeconds'] ?? entry['duration']) as num?;
    return LyricsMatch(
      title: entry['songTitle'] as String?,
      artist: entry['artistName'] as String?,
      duration: seconds == null ? null : Duration(seconds: seconds.toInt()),
    );
  }

  /// Выбирает запись, ближайшую по длительности: так одноимённые версии
  /// (радио-редакция, лайв) не подменяют нужный текст.
  Map<String, dynamic> _bestMatch(List<dynamic> tracks, Duration? duration) {
    final List<Map<String, dynamic>> maps =
        tracks.whereType<Map<String, dynamic>>().toList();
    if (maps.isEmpty) return <String, dynamic>{};
    if (duration == null || duration <= Duration.zero) return maps.first;

    maps.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        _delta(a, duration).compareTo(_delta(b, duration)));
    return maps.first;
  }

  int _delta(Map<String, dynamic> track, Duration want) {
    final num? seconds =
        (track['durationSeconds'] ?? track['duration']) as num?;
    if (seconds == null) return 1 << 30;
    return (seconds.toInt() - want.inSeconds).abs();
  }

  Future<Map<String, dynamic>?> _get(Uri uri) async {
    try {
      final HttpClientRequest request = await _client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final HttpClientResponse response =
          await request.close().timeout(const Duration(seconds: 15));
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
