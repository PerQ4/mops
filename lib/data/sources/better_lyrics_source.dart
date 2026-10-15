import 'dart:convert';
import 'dart:io';

import '../models/models.dart';
import 'lyrics_format.dart';

/// Тексты из BetterLyrics (`api.betterlyrics.org`).
///
/// Почему она: отдаёт TTML — формат Apple Music с пословной синхронизацией,
/// из которого мы берём строчную разметку. Тот же сервис проксирует KuGou,
/// поэтому запасной запрос идёт на `kugou/getLyrics`, если TTML не нашёлся.
///
/// ВАЖНО про ключ. Сервис работает по модели «сначала кэш»: уже
/// закэшированную песню отдаёт без ключа, а свежий запрос требует заголовок
/// `X-API-Key` — и отвечает 401. Ключи сейчас не выдают, поэтому для песен,
/// которых нет в кэше, источник молчит; это не наша ошибка и не повод
/// считать текст ненайденным — за него отвечают остальные базы.
///
/// Ключ кэша включает альбом и длительность, поэтому их нужно передавать
/// всегда, когда они известны: без них даже закэшированная песня «промахнётся».
/// По той же причине адрес — `api.betterlyrics.org`: старый
/// (`lyrics-api.boidu.dev`) отвечает 401 почти на всё.
class BetterLyricsSource {
  BetterLyricsSource({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  static const String _host = 'https://api.betterlyrics.org';
  static const String _ttmlPath = '/getLyrics';
  static const String _kugouPath = '/kugou/getLyrics';

  /// Ключи, за которыми в ответе может прятаться текст (в том числе вложенно).
  static const List<String> _contentKeys = <String>[
    'ttml',
    'lyrics',
    'data',
    'result',
    'response',
  ];

  /// Корень TTML-документа; по нему отличаем разметку от обычного текста.
  static final RegExp _ttmlRoot =
      RegExp(r'<(?:[A-Za-z_][\w.-]*:)?tt[\s>]', caseSensitive: false);

  /// Ищет текст по исполнителю, названию, альбому и длительности.
  ///
  /// `videoId` не обязателен, но сервис использует его для привязки песни к
  /// видео, поэтому передаём, когда он есть.
  Future<Lyrics> fetch({
    required String title,
    required String artist,
    String? album,
    Duration? duration,
    String? videoId,
    String? apiKey,
  }) async {
    if (title.trim().isEmpty || artist.trim().isEmpty) return Lyrics.none;

    for (final String path in <String>[_ttmlPath, _kugouPath]) {
      final Lyrics lyrics = await _fetchOne(
        path,
        title.trim(),
        artist.trim(),
        album,
        duration,
        videoId,
        apiKey,
      );
      if (!lyrics.isEmpty) return lyrics;
    }
    return Lyrics.none;
  }

  Future<Lyrics> _fetchOne(
    String path,
    String title,
    String artist,
    String? album,
    Duration? duration,
    String? videoId,
    String? apiKey,
  ) async {
    final Uri uri = Uri.parse('$_host$path').replace(
      queryParameters: <String, String>{
        's': title,
        'a': artist,
        if (album != null && album.trim().isNotEmpty) 'al': album.trim(),
        if (duration != null && duration > Duration.zero)
          'd': '${duration.inSeconds}',
        if (videoId != null && videoId.isNotEmpty) 'v': videoId,
      },
    );

    final String? body = await _getText(uri, apiKey: apiKey);
    if (body == null) return Lyrics.none;

    // Некоторые ответы приходят готовым TTML-документом, без обёртки в JSON.
    if (_looksLikeTtml(body)) {
      final Lyrics direct = _fromTtml(body);
      if (!direct.isEmpty) return direct;
    }

    final dynamic decoded = _tryDecode(body);
    if (decoded == null) return Lyrics.none;

    final String? ttml = _extractString(decoded, ttml: true, depth: 0);
    if (ttml != null) {
      final Lyrics synced = _fromTtml(ttml);
      if (!synced.isEmpty) return synced;
    }

    final String? raw = _extractString(decoded, ttml: false, depth: 0);
    if (raw != null) {
      final Lyrics lyrics = lyricsFromText(raw, 'BetterLyrics');
      if (!lyrics.isEmpty) return lyrics;
    }
    return Lyrics.none;
  }

  /// Собирает [Lyrics] из TTML, отметив наличие перевода (для оценки).
  Lyrics _fromTtml(String ttml) => lyricsFromTimed(
        parseTtml(ttml),
        'BetterLyrics',
        match: LyricsMatch(hasTranslation: ttmlHasTranslation(ttml)),
      );

  bool _looksLikeTtml(String value) {
    final String head =
        value.length > 4096 ? value.substring(0, 4096) : value;
    return _ttmlRoot.hasMatch(head);
  }

  /// Рекурсивно ищет в ответе строку с TTML или с обычным текстом.
  String? _extractString(dynamic node, {required bool ttml, required int depth}) {
    if (depth > 3) return null;

    if (node is String) {
      final String value = node.trim();
      if (value.isEmpty) return null;
      final bool isTtml = _looksLikeTtml(value);
      if (ttml) return isTtml ? value : null;
      // TTML разбирается отдельным проходом, здесь — только обычный текст.
      return isTtml ? null : value;
    }

    if (node is List) {
      for (final dynamic child in node) {
        final String? found = _extractString(child, ttml: ttml, depth: depth + 1);
        if (found != null) return found;
      }
      return null;
    }

    if (node is Map) {
      for (final String key in _contentKeys) {
        final dynamic value = node[key];
        if (value == null) continue;
        final String? found =
            _extractString(value, ttml: ttml, depth: depth + 1);
        if (found != null) return found;
      }
      return null;
    }
    return null;
  }

  dynamic _tryDecode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  Future<String?> _getText(Uri uri, {String? apiKey}) async {
    try {
      final HttpClientRequest request = await _client.getUrl(uri);
      if (apiKey != null && apiKey.trim().isNotEmpty) {
        request.headers.set('X-API-Key', apiKey.trim());
      }
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
