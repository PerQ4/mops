import 'dart:convert';
import 'dart:io';

import '../models/models.dart';
import 'lyrics_format.dart';

/// Тексты из YouLy+ (`lyricsplus.*`).
///
/// Почему она: те же зеркала, что использует ArchiveTune. Сначала пробуем TTML
/// (пословная разметка Apple Music), затем обычный JSON со строками и
/// временами. Зеркал несколько: если одно недоступно, запрос идёт к следующему.
class YouLyPlusSource {
  YouLyPlusSource({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  /// Зеркала сервиса — на случай, если одно из них заблокировано или лежит.
  static const List<String> _mirrors = <String>[
    'https://lyricsplus.binimum.org',
    'https://lyricsplus.prjktla.my.id',
    'https://lyricsplus.prjktla.workers.dev',
    'https://lyricsplus.atomix.one',
    'https://lyricsplus-seven.vercel.app',
  ];

  static const String _ttmlPath = '/v1/ttml/get';
  static const String _lrcPath = '/v2/lyrics/get';

  static final RegExp _ttmlRoot =
      RegExp(r'<(?:[A-Za-z_][\w.-]*:)?tt[\s>]', caseSensitive: false);

  /// Ищет текст по названию, исполнителю, альбому и длительности.
  Future<Lyrics> fetch({
    required String title,
    required String artist,
    String? album,
    Duration? duration,
  }) async {
    if (title.trim().isEmpty || artist.trim().isEmpty) return Lyrics.none;

    for (final String path in <String>[_ttmlPath, _lrcPath]) {
      final Lyrics lyrics =
          await _fetchPath(path, title.trim(), artist.trim(), album, duration);
      if (!lyrics.isEmpty) return lyrics;
    }
    return Lyrics.none;
  }

  Future<Lyrics> _fetchPath(
    String path,
    String title,
    String artist,
    String? album,
    Duration? duration,
  ) async {
    for (final String mirror in _mirrors) {
      final Uri uri = Uri.parse('$mirror$path').replace(
        queryParameters: <String, String>{
          'title': title,
          'artist': artist,
          if (album != null && album.trim().isNotEmpty) 'album': album.trim(),
          if (duration != null && duration > Duration.zero)
            'duration': '${duration.inSeconds}',
        },
      );

      final String? body = await _getText(uri);
      if (body == null) continue;

      final Lyrics lyrics = _decode(body);
      if (!lyrics.isEmpty) return lyrics;
    }
    return Lyrics.none;
  }

  /// Разбирает ответ зеркала: TTML, JSON со строками или обычный LRC.
  Lyrics _decode(String body) {
    final String trimmed = body.trim();
    if (trimmed.isEmpty) return Lyrics.none;

    if (_looksLikeTtml(trimmed)) {
      final Lyrics synced = lyricsFromTimed(parseTtml(trimmed), 'YouLy+');
      if (!synced.isEmpty) return synced;
    }

    final dynamic decoded = _tryDecode(trimmed);
    if (decoded == null) {
      // Это мог быть обычный LRC без обёртки в JSON.
      return lyricsFromText(trimmed, 'YouLy+');
    }

    final String? ttml = _findString(decoded, 'ttml');
    if (ttml != null) {
      final Lyrics synced = lyricsFromTimed(parseTtml(ttml), 'YouLy+');
      if (!synced.isEmpty) return synced;
    }

    final dynamic lyricsNode = _findValue(decoded, 'lyrics');
    if (lyricsNode is String) {
      return lyricsFromText(lyricsNode, 'YouLy+');
    }
    if (lyricsNode is List) {
      return _fromLineList(lyricsNode);
    }
    return Lyrics.none;
  }

  /// Собирает текст из списка строк вида `{time, text}`.
  Lyrics _fromLineList(List<dynamic> node) {
    final List<TimedLyric> timed = <TimedLyric>[];
    final List<String> plain = <String>[];
    for (final dynamic item in node) {
      if (item is! Map) continue;
      final String? text =
          item['text'] is String ? item['text'] as String : null;
      if (text == null || text.trim().isEmpty) continue;

      final dynamic time = item['time'];
      if (time is num) {
        timed.add(TimedLyric(
          time: Duration(milliseconds: time.toInt()),
          text: text.trim(),
        ));
      } else {
        plain.add(text.trim());
      }
    }

    if (timed.isNotEmpty) {
      timed.sort((TimedLyric a, TimedLyric b) => a.time.compareTo(b.time));
      return lyricsFromTimed(timed, 'YouLy+');
    }
    if (plain.isNotEmpty) {
      return Lyrics(plain: plain.join('\n'), source: 'YouLy+');
    }
    return Lyrics.none;
  }

  bool _looksLikeTtml(String value) {
    final String head =
        value.length > 4096 ? value.substring(0, 4096) : value;
    return _ttmlRoot.hasMatch(head);
  }

  dynamic _findValue(dynamic node, String key, [int depth = 0]) {
    if (depth > 4) return null;
    if (node is Map) {
      if (node.containsKey(key)) return node[key];
      for (final dynamic value in node.values) {
        final dynamic found = _findValue(value, key, depth + 1);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final dynamic child in node) {
        final dynamic found = _findValue(child, key, depth + 1);
        if (found != null) return found;
      }
    }
    return null;
  }

  String? _findString(dynamic node, String key) {
    final dynamic value = _findValue(node, key);
    if (value is String && value.trim().isNotEmpty) return value;
    return null;
  }

  dynamic _tryDecode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  Future<String?> _getText(Uri uri) async {
    try {
      final HttpClientRequest request = await _client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final HttpClientResponse response =
          await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      return await response.transform(utf8.decoder).join();
    } on Object {
      // Зеркало может быть недоступно — это не ошибка приложения.
      return null;
    }
  }

  void dispose() => _client.close(force: true);
}
