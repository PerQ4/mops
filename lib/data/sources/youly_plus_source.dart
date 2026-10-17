import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'lyrics_format.dart';
import 'lyrics_match.dart';

/// Тексты из YouLy+ (`lyricsplus.*`).
///
/// Почему она: те же зеркала, что использует ArchiveTune, и она отдаёт TTML
/// (пословная разметка Apple Music) — то есть караоке, а не просто строки.
/// Первый путь — TTML, второй — обычный JSON со строками и временами слов.
///
/// Зеркала опрашиваются **параллельно**: раньше они перебирались по очереди, и
/// на мёртвом зеркале запрос висел до таймаута, из-за чего источник не успевал
/// ответить в общий бюджет поиска и текст пропадал. Теперь побеждает тот, кто
/// ответил первым с непустым результатом.
class YouLyPlusSource {
  YouLyPlusSource({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  /// Зеркала сервиса. Порядок — по фактической доступности: у `binimum`
  /// работает только `v2/lyrics/get`, у `prjktla.my.id` — и TTML тоже.
  static const List<String> _mirrors = <String>[
    'https://lyricsplus.prjktla.my.id',
    'https://lyricsplus.binimum.org',
    'https://lyricsplus.prjktla.workers.dev',
    'https://lyricsplus.atomix.one',
    'https://lyricsplus-seven.vercel.app',
  ];

  static const String _ttmlPath = '/v1/ttml/get';
  static const String _lrcPath = '/v2/lyrics/get';

  /// Сколько ждём одно зеркало. Короткий таймаут важнее полноты: молчащее
  /// зеркало всё равно ничего не отдаст, а поиск держать нельзя.
  static const Duration _mirrorTimeout = Duration(seconds: 6);

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

  /// Опрашивает все зеркала одного пути параллельно.
  Future<Lyrics> _fetchPath(
    String path,
    String title,
    String artist,
    String? album,
    Duration? duration,
  ) async {
    final Completer<Lyrics> winner = Completer<Lyrics>();
    int pending = _mirrors.length;

    for (final String mirror in _mirrors) {
      unawaited(
        _fetchMirror(mirror, path, title, artist, album, duration)
            .then((Lyrics lyrics) {
          if (!lyrics.isEmpty && !winner.isCompleted) {
            winner.complete(lyrics);
          }
        }).whenComplete(() {
          pending--;
          if (pending == 0 && !winner.isCompleted) {
            winner.complete(Lyrics.none);
          }
        }),
      );
    }

    // Страховка: даже если все зеркала «зависли», поиск не ждёт их вечно.
    return winner.future.timeout(
      _mirrorTimeout + const Duration(seconds: 1),
      onTimeout: () => Lyrics.none,
    );
  }

  Future<Lyrics> _fetchMirror(
    String mirror,
    String path,
    String title,
    String artist,
    String? album,
    Duration? duration,
  ) async {
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
    if (body == null) return Lyrics.none;
    return _decode(body, title, artist);
  }

  /// Разбирает ответ зеркала: TTML, JSON со строками или обычный LRC.
  ///
  /// Заодно проверяет, что сервис отдал текст ИМЕННО этого трека: зеркала
  /// ищут по метаданным и на редких записях подсовывают кавер или одноимённую
  /// песню. Если в ответе есть название или исполнитель и ни одно из них не
  /// совпало с запросом — результат отбрасываем, а не показываем чужой текст.
  Lyrics _decode(String body, String title, String artist) {
    final String trimmed = body.trim();
    if (trimmed.isEmpty) return Lyrics.none;

    if (_looksLikeTtml(trimmed)) {
      final Lyrics synced = _fromTtml(trimmed);
      if (!synced.isEmpty) return synced;
    }

    final dynamic decoded = _tryDecode(trimmed);
    if (decoded == null) {
      // Это мог быть обычный LRC без обёртки в JSON.
      return lyricsFromText(trimmed, 'YouLy+');
    }

    final _ResponseMeta meta = _readMeta(decoded);
    if (!_metaMatches(meta, title, artist)) {
      debugPrint('[YouLy+] ответ не о том треке: «${meta.title}» / '
          '«${meta.artist}» вместо «$title» / «$artist»');
      return Lyrics.none;
    }

    final String? ttml = _findString(decoded, 'ttml');
    if (ttml != null) {
      final Lyrics synced = _fromTtml(ttml, meta: meta);
      if (!synced.isEmpty) return synced;
    }

    final dynamic lyricsNode = _findValue(decoded, 'lyrics');
    if (lyricsNode is String) {
      // TTML приходит и строкой внутри JSON — тогда разбираем его как TTML.
      if (_looksLikeTtml(lyricsNode)) {
        final Lyrics synced = _fromTtml(lyricsNode, meta: meta);
        if (!synced.isEmpty) return synced;
      }
      return lyricsFromText(lyricsNode, 'YouLy+', match: meta.toMatch());
    }
    if (lyricsNode is List) {
      return _fromLineList(lyricsNode, decoded, meta);
    }
    return Lyrics.none;
  }

  /// Собирает [Lyrics] из TTML, отметив наличие перевода (для оценки).
  Lyrics _fromTtml(String ttml, {_ResponseMeta? meta}) => lyricsFromTimed(
        parseTtml(ttml),
        'YouLy+',
        match: LyricsMatch(
          title: meta?.title,
          artist: meta?.artist,
          duration: meta?.duration,
          hasTranslation: ttmlHasTranslation(ttml),
        ),
      );

  /// Собирает текст из списка строк вида `{time, text, syllabus:[...]}`.
  ///
  /// `syllabus` — разметка по словам: именно она делает текст караоке. Тип
  /// ответа (`type: "Word"`) означает, что времена пословные, и брать из строки
  /// только текст было бы потерей.
  Lyrics _fromLineList(List<dynamic> node, dynamic root, _ResponseMeta meta) {
    final bool wordTimed =
        _findString(root, 'type')?.toLowerCase() == 'word';

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
          words: wordTimed ? _words(item) : null,
        ));
      } else {
        plain.add(text.trim());
      }
    }

    if (timed.isNotEmpty) {
      timed.sort((TimedLyric a, TimedLyric b) => a.time.compareTo(b.time));
      return lyricsFromTimed(timed, 'YouLy+', match: meta.toMatch());
    }
    if (plain.isNotEmpty) {
      return Lyrics(
        plain: plain.join('\n'),
        source: 'YouLy+',
        match: meta.toMatch(),
      );
    }
    return Lyrics.none;
  }

  /// Метаданные ответа: зеркала кладут их в `metadata` (v2) или в
  /// `selectedSongMetadata` (v1).
  _ResponseMeta _readMeta(dynamic root) {
    final dynamic node =
        _findValue(root, 'metadata') ?? _findValue(root, 'selectedSongMetadata');
    if (node is! Map) return const _ResponseMeta();

    return _ResponseMeta(
      title: _string(node['title']) ?? _string(node['song']),
      artist: _string(node['artist']) ?? _string(node['singer']),
      duration: _durationOf(node['duration']),
    );
  }

  String? _string(dynamic value) {
    if (value is! String) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Длительность из ответа: короткие числа — секунды, длинные — миллисекунды.
  Duration? _durationOf(dynamic value) {
    if (value is! num || value <= 0) return null;
    return value < 10000
        ? Duration(seconds: value.toInt())
        : Duration(milliseconds: value.toInt());
  }

  /// Совпадает ли ответ с запросом.
  ///
  /// Молчание метаданных не считаем несовпадением: сервис отдаёт их не всегда,
  /// и терять из-за этого верный текст нельзя. Достаточно совпадения по
  /// названию ИЛИ по исполнителю: у каверов другое имя исполнителя, у
  /// ремиксов — наоборот.
  bool _metaMatches(_ResponseMeta meta, String title, String artist) {
    if (meta.title == null && meta.artist == null) return true;
    final bool titleOk = meta.title == null || _similar(meta.title!, title);
    final bool artistOk = meta.artist == null || _similar(meta.artist!, artist);
    return titleOk || artistOk;
  }

  /// Похожи ли строки: сравниваем нормализованный текст по вхождению, а затем
  /// по словам — так «Shape of You (Official Video)» совпадает с «Shape of You».
  bool _similar(String a, String b) {
    final String na = normalizeMatchText(a);
    final String nb = normalizeMatchText(b);
    if (na.isEmpty || nb.isEmpty) return false;
    if (na == nb || na.contains(nb) || nb.contains(na)) return true;

    final Set<String> ta = na.split(' ').toSet();
    final Set<String> tb = nb.split(' ').toSet();
    final Set<String> smaller = ta.length <= tb.length ? ta : tb;
    final Set<String> larger = identical(smaller, ta) ? tb : ta;
    return smaller.isNotEmpty && smaller.every(larger.contains);
  }

  /// Слова одной строки из `syllabus`.
  List<TimedWord>? _words(Map<dynamic, dynamic> line) {
    final dynamic syllabus = line['syllabus'];
    if (syllabus is! List) return null;

    final List<TimedWord> words = <TimedWord>[];
    for (final dynamic item in syllabus) {
      if (item is! Map) continue;
      final dynamic time = item['time'];
      final String? text = item['text'] is String ? item['text'] as String : null;
      if (time is! num || text == null) continue;
      final String trimmed = text.trim();
      if (trimmed.isEmpty) continue;
      final dynamic length = item['duration'];
      final Duration start = Duration(milliseconds: time.toInt());
      words.add(TimedWord(
        time: start,
        text: trimmed,
        end: length is num && length > 0
            ? start + Duration(milliseconds: length.toInt())
            : null,
      ));
    }
    return words.isEmpty ? null : words;
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
          await request.close().timeout(_mirrorTimeout);
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

/// Метаданные ответа зеркала — по ним проверяем, тот ли это трек.
///
/// Заодно уходят в общий поиск (`LyricsMatch`): по ним оценка совместимости
/// сверяет название, исполнителя и длительность с запросом.
class _ResponseMeta {
  const _ResponseMeta({this.title, this.artist, this.duration});

  final String? title;
  final String? artist;
  final Duration? duration;

  LyricsMatch toMatch() =>
      LyricsMatch(title: title, artist: artist, duration: duration);
}
