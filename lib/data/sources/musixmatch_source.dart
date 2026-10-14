import 'dart:convert';
import 'dart:io';

import '../models/models.dart';
import 'lyrics_format.dart';

/// Тексты Musixmatch — через сервис Paxsenix (как в ArchiveTune).
///
/// У Musixmatch нет открытого доступа: гостевой API отдаёт заглушку и путает
/// треки («NOKIA / Drake» вместо запрошенного). ArchiveTune ходит через
/// Paxsenix с ключом — так же делаем и мы. Ключ задаётся в настройках и
/// передаётся в запрос как `Authorization: Bearer`.
class MusixmatchSource {
  MusixmatchSource({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  static const String _host = 'https://api.paxsenix.org';
  static const String _path = '/lyrics/musixmatch';

  /// Ищет текст Musixmatch. Без ключа источник ничего не спрашивает.
  Future<Lyrics> fetch({
    required String title,
    required String artist,
    required String apiKey,
    Duration? duration,
  }) async {
    if (apiKey.trim().isEmpty) return Lyrics.none;
    if (title.trim().isEmpty || artist.trim().isEmpty) return Lyrics.none;

    final Uri uri = Uri.parse('$_host$_path').replace(
      queryParameters: <String, String>{
        't': title.trim(),
        'a': artist.trim(),
        if (duration != null && duration > Duration.zero)
          'd': '${duration.inSeconds}',
      },
    );

    final String? body = await _getText(uri, apiKey.trim());
    if (body == null) return Lyrics.none;

    // Ответ бывает готовым LRC/текстом, а бывает JSON с полем текста.
    final String? extracted = _extract(body);
    if (extracted != null) {
      final Lyrics fromJson = lyricsFromText(extracted, 'Musixmatch');
      if (!fromJson.isEmpty) return fromJson;
    }
    return lyricsFromText(body, 'Musixmatch');
  }

  /// Ищет строку с текстом в JSON-ответе, не завязываясь на его форму.
  String? _extract(String body) {
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return null;
    }
    return _find(decoded, 0);
  }

  String? _find(dynamic node, int depth) {
    if (depth > 4) return null;

    if (node is String) {
      final String value = node.trim();
      return value.isEmpty ? null : value;
    }
    if (node is List) {
      for (final dynamic child in node) {
        final String? found = _find(child, depth + 1);
        if (found != null) return found;
      }
      return null;
    }
    if (node is Map) {
      for (final String key in <String>[
        'lyrics',
        'lrc',
        'content',
        'text',
        'syncedLyrics',
        'plainLyrics',
        'lines',
      ]) {
        final dynamic value = node[key];
        if (value == null) continue;
        final String? found = _find(value, depth + 1);
        if (found != null) return found;
      }
    }
    return null;
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
          await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      return await response.transform(utf8.decoder).join();
    } on Object {
      // Сервис может быть недоступен — это не ошибка приложения.
      return null;
    }
  }

  void dispose() => _client.close(force: true);
}
