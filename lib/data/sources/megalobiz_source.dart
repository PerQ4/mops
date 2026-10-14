import 'dart:convert';
import 'dart:io';

import '../models/models.dart';
import 'lyrics_format.dart';

/// Тексты из Megalobiz (`megalobiz.com`).
///
/// Почему она: сайт отдаёт текст в формате LRC, то есть **с временами**.
/// Отдельного API нет, поэтому как в ArchiveTune разбираем страницы: по
/// запросу находим ссылку на скачивание LRC, затем вытаскиваем сам текст из
/// разметки. Обычный текст без времён здесь не берём — ради синхронизации
/// источник и нужен.
class MegalobizSource {
  MegalobizSource({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  static const String _host = 'https://www.megalobiz.com';
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64)';

  static final RegExp _downloadPath =
      RegExp(r'''href=["'](/lrc/maker/download/[^"']+)["']''');
  static final RegExp _lrcSpan = RegExp(
    r'''id=["']lrc_[^"']*_details["'][^>]*>(.*?)</span>''',
    dotAll: true,
  );
  static final RegExp _brTag = RegExp(r'<br\s*/?>', caseSensitive: false);
  static final RegExp _anyTag = RegExp('<[^>]+>');

  /// Ищет текст по исполнителю и названию.
  Future<Lyrics> fetch({required String title, required String artist}) async {
    if (title.trim().isEmpty) return Lyrics.none;

    final String query = artist.trim().isEmpty
        ? title.trim()
        : '${artist.trim()} ${title.trim()}';

    final String? search = await _getText(
      Uri.parse('$_host/searchall').replace(
        queryParameters: <String, String>{'qry': query},
      ),
    );
    if (search == null) return Lyrics.none;

    final RegExpMatch? path = _downloadPath.firstMatch(search);
    if (path == null) return Lyrics.none;

    final String? detail = await _getText(Uri.parse('$_host${path.group(1)}'));
    if (detail == null) return Lyrics.none;

    final String raw = _lrcSpan.firstMatch(detail)?.group(1) ?? detail;
    final String text = raw
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll(_brTag, '\n')
        .replaceAll(_anyTag, '');

    final Lyrics lyrics = lyricsFromText(unescapeEntities(text), 'Megalobiz');
    // Megalobiz умеет отдавать и обычный текст; нам он нужен только с
    // временами — иначе источник не лучше вкладки YouTube Music.
    return lyrics.isSynced ? lyrics : Lyrics.none;
  }

  Future<String?> _getText(Uri uri) async {
    try {
      final HttpClientRequest request = await _client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final HttpClientResponse response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      return await response.transform(utf8.decoder).join();
    } on Object {
      // Сайт может быть недоступен — это не ошибка приложения.
      return null;
    }
  }

  void dispose() => _client.close(force: true);
}
