import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'app_settings.dart';

/// Дисковый кэш найденных текстов: «id трека + источник» → текст.
///
/// Зачем: без него каждый трек опрашивает все базы заново при каждом открытии,
/// даже если текст уже находили. Хранится файлом, а не в `shared_preferences`:
/// тексты бывают по несколько килобайт, и держать их в одной строке настроек
/// дорого (её читают и пишут на каждое изменение любой настройки).
///
/// Срок жизни записи ограничен (как `LYRICS_CACHE_TTL_MS` в BetterLyrics):
/// базы правят тексты, и бессрочно старый ответ мог бы залипнуть навсегда.
/// Файл ограничен ещё и по числу записей — иначе он рос бы без предела.
class LyricsCache {
  LyricsCache({this.fileName = 'lyrics_cache.json'});

  final String fileName;

  /// Срок жизни записи: неделя. Просроченное выкидывается при чтении.
  static const Duration ttl = Duration(days: 7);

  /// Предел числа записей (пар «трек + источник»). При переполнении
  /// вытесняются самые старые — свежий текст нужнее давно забытого трека.
  static const int maxEntries = 500;

  File? _file;

  /// Записи в памяти: ключ — id трека, значение — источники этого трека.
  /// Нужны, чтобы повторные чтения не били по диску и чтобы запись одного
  /// источника не перечитывала файл целиком.
  Map<String, Map<LyricsSource, _CachedLyrics>>? _memory;

  /// Загрузка файла идёт один раз: параллельные чтения ждут её же.
  Future<void>? _loading;

  /// Запись на диск выстроена в очередь: параллельные `write` иначе
  /// перетирали бы снимки друг друга и часть текстов терялась бы.
  Future<void> _writing = Future<void>.value();

  /// Все сохранённые тексты трека — по одному на источник.
  ///
  /// Ошибки файла и JSON наружу не пробрасываются: недоступный кэш — это
  /// отсутствие кэша, а не повод не показать текст.
  Future<Map<LyricsSource, Lyrics>> read(String videoId) async {
    if (videoId.isEmpty) return const <LyricsSource, Lyrics>{};
    final Map<String, Map<LyricsSource, _CachedLyrics>> entries =
        await _entries();
    final Map<LyricsSource, _CachedLyrics>? forTrack = entries[videoId];
    if (forTrack == null || forTrack.isEmpty) {
      return const <LyricsSource, Lyrics>{};
    }
    return <LyricsSource, Lyrics>{
      for (final MapEntry<LyricsSource, _CachedLyrics> item
          in forTrack.entries)
        item.key: item.value.lyrics,
    };
  }

  /// Сохраняет результат одного источника.
  ///
  /// Пустой текст не пишется: им нельзя затирать уже найденный непустой —
  /// иначе разовый сбой базы стёр бы рабочий кэш.
  Future<void> write(String videoId, LyricsSource source, Lyrics lyrics) async {
    if (videoId.isEmpty || source == LyricsSource.auto || lyrics.isEmpty) {
      return;
    }
    final Map<String, Map<LyricsSource, _CachedLyrics>> entries =
        await _entries();
    entries.putIfAbsent(videoId, () => <LyricsSource, _CachedLyrics>{})[source] =
        _CachedLyrics(
      lyrics: lyrics,
      at: DateTime.now().millisecondsSinceEpoch,
    );
    _evictOldest(entries);
    await _persist(entries);
  }

  /// Полная очистка — и в памяти, и на диске.
  Future<void> clear() async {
    _memory = <String, Map<LyricsSource, _CachedLyrics>>{};
    try {
      final File file = await _cacheFile();
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // Цель — отсутствие файла; если не вышло, это не критично.
    } on Object catch (error) {
      debugPrint('[LyricsCache] не удалось очистить кэш: $error');
    }
  }

  /// Возвращает записи из памяти, загрузив файл при первом обращении.
  Future<Map<String, Map<LyricsSource, _CachedLyrics>>> _entries() async {
    final Map<String, Map<LyricsSource, _CachedLyrics>>? ready = _memory;
    if (ready != null) return ready;
    _loading ??= _loadFromDisk();
    await _loading;
    return _memory ?? <String, Map<LyricsSource, _CachedLyrics>>{};
  }

  Future<void> _loadFromDisk() async {
    final Map<String, Map<LyricsSource, _CachedLyrics>> parsed =
        <String, Map<LyricsSource, _CachedLyrics>>{};
    try {
      final File file = await _cacheFile();
      if (file.existsSync()) {
        final String raw = await file.readAsString();
        if (raw.trim().isNotEmpty) {
          _readEntries(jsonDecode(raw), parsed);
        }
      }
    } on FileSystemException {
      // Нет доступа к файлу — работаем без кэша.
    } on FormatException {
      // Повреждённый JSON — начнём файл заново при следующей записи.
    } on Object catch (error) {
      debugPrint('[LyricsCache] не удалось прочитать кэш: $error');
    }
    _pruneExpired(parsed);
    _memory = parsed;
  }

  /// Разбирает содержимое файла. Битая запись пропускается целиком — один
  /// испорченный текст не должен обнулять весь кэш.
  void _readEntries(
    dynamic decoded,
    Map<String, Map<LyricsSource, _CachedLyrics>> into,
  ) {
    final dynamic raw = decoded is Map<String, dynamic> ? decoded['entries'] : null;
    if (raw is! List) return;

    final int now = DateTime.now().millisecondsSinceEpoch;
    for (final dynamic item in raw) {
      if (item is! Map<String, dynamic>) continue;
      final dynamic videoId = item['videoId'];
      final dynamic sourceName = item['source'];
      final dynamic lyricsJson = item['lyrics'];
      if (videoId is! String || videoId.isEmpty) continue;
      if (sourceName is! String || lyricsJson is! Map<String, dynamic>) continue;

      final LyricsSource? source = _sourceFromName(sourceName);
      if (source == null) continue;

      final Lyrics? lyrics = _lyricsFromJson(lyricsJson);
      if (lyrics == null || lyrics.isEmpty) continue;

      final dynamic at = item['at'];
      final int timestamp = at is num ? at.toInt() : now;
      // Просроченное не кладём даже в память: базы правят тексты.
      if (now - timestamp > ttl.inMilliseconds) continue;

      into.putIfAbsent(videoId, () => <LyricsSource, _CachedLyrics>{})[source] =
          _CachedLyrics(lyrics: lyrics, at: timestamp);
    }
  }

  /// Убирает записи старше [ttl] и пустые группы треков.
  void _pruneExpired(Map<String, Map<LyricsSource, _CachedLyrics>> entries) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    entries.removeWhere((String _, Map<LyricsSource, _CachedLyrics> bySource) {
      bySource.removeWhere((LyricsSource _, _CachedLyrics item) =>
          now - item.at > ttl.inMilliseconds);
      return bySource.isEmpty;
    });
  }

  /// Вытесняет самые старые записи, если пар стало больше [maxEntries].
  void _evictOldest(Map<String, Map<LyricsSource, _CachedLyrics>> entries) {
    final List<({String videoId, LyricsSource source, int at})> all =
        <({String videoId, LyricsSource source, int at})>[];
    for (final MapEntry<String, Map<LyricsSource, _CachedLyrics>> track
        in entries.entries) {
      for (final MapEntry<LyricsSource, _CachedLyrics> item
          in track.value.entries) {
        all.add((videoId: track.key, source: item.key, at: item.value.at));
      }
    }
    if (all.length <= maxEntries) return;

    all.sort((({String videoId, LyricsSource source, int at}) a,
            ({String videoId, LyricsSource source, int at}) b) =>
        a.at.compareTo(b.at));
    final int excess = all.length - maxEntries;
    for (int i = 0; i < excess; i++) {
      final Map<LyricsSource, _CachedLyrics>? bySource = entries[all[i].videoId];
      if (bySource == null) continue;
      bySource.remove(all[i].source);
      if (bySource.isEmpty) entries.remove(all[i].videoId);
    }
  }

  /// Пишет снимок в файл. Снимок кодируется сразу: пока ждём очередь, память
  /// могла измениться, а на диск должно попасть согласованное состояние.
  Future<void> _persist(Map<String, Map<LyricsSource, _CachedLyrics>> entries) {
    final List<Map<String, dynamic>> flat = <Map<String, dynamic>>[];
    for (final MapEntry<String, Map<LyricsSource, _CachedLyrics>> track
        in entries.entries) {
      for (final MapEntry<LyricsSource, _CachedLyrics> item
          in track.value.entries) {
        flat.add(<String, dynamic>{
          'videoId': track.key,
          'source': item.key.name,
          'at': item.value.at,
          'lyrics': _lyricsToJson(item.value.lyrics),
        });
      }
    }
    final String payload =
        jsonEncode(<String, dynamic>{'version': 1, 'entries': flat});
    _writing = _writing.then((_) => _writeFile(payload));
    return _writing;
  }

  Future<void> _writeFile(String payload) async {
    try {
      final File file = await _cacheFile();
      await file.writeAsString(payload, flush: true);
    } on FileSystemException {
      // Диск недоступен — кэш остаётся только в памяти.
    } on Object catch (error) {
      debugPrint('[LyricsCache] не удалось сохранить кэш: $error');
    }
  }

  Future<File> _cacheFile() async {
    final File? ready = _file;
    if (ready != null) return ready;
    // Тот же каталог, что у сессии (`getApplicationSupportDirectory`): рядом
    // с данными приложения, а не во временной папке, которую ОС чистит.
    final Directory dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final File file = File('${dir.path}${Platform.pathSeparator}$fileName');
    _file = file;
    return file;
  }

  /// Разбирает имя источника; `auto` не хранится — это режим, а не база.
  static LyricsSource? _sourceFromName(String name) {
    for (final LyricsSource source in LyricsSource.values) {
      if (source.name == name && source != LyricsSource.auto) return source;
    }
    return null;
  }
}

/// Запись кэша: текст и время записи (мс от эпохи) — по нему считается TTL
/// и выбираются самые старые при вытеснении.
@immutable
class _CachedLyrics {
  const _CachedLyrics({required this.lyrics, required this.at});

  final Lyrics lyrics;
  final int at;
}

// Сериализация моделей живёт здесь, а не в `models.dart`: кэш — единственное
// место, которому нужен именно этот формат, и менять ради него модели незачем.

Map<String, dynamic> _lyricsToJson(Lyrics lyrics) {
  final List<TimedLyric>? timed = lyrics.timed;
  final LyricsMatch? match = lyrics.match;
  return <String, dynamic>{
    if (lyrics.plain != null) 'plain': lyrics.plain,
    if (lyrics.source != null) 'source': lyrics.source,
    if (match != null) 'match': _matchToJson(match),
    if (timed != null) 'timed': timed.map(_timedLyricToJson).toList(),
  };
}

Lyrics? _lyricsFromJson(Map<String, dynamic> json) {
  try {
    final Lyrics lyrics = Lyrics(
      plain: json['plain'] as String?,
      source: json['source'] as String?,
      match: _matchFromJson(json['match']),
      timed: _timedListFromJson(json['timed']),
    );
    // Пустое в кэше смысла не имеет — считаем запись битой.
    return lyrics.isEmpty ? null : lyrics;
  } on Object {
    return null;
  }
}

Map<String, dynamic> _timedLyricToJson(TimedLyric line) {
  final List<TimedWord>? words = line.words;
  return <String, dynamic>{
    'time': line.time.inMilliseconds,
    'text': line.text,
    if (words != null) 'words': words.map(_timedWordToJson).toList(),
  };
}

Map<String, dynamic> _timedWordToJson(TimedWord word) {
  final Duration? end = word.end;
  return <String, dynamic>{
    'time': word.time.inMilliseconds,
    if (end != null) 'end': end.inMilliseconds,
    'text': word.text,
  };
}

Map<String, dynamic> _matchToJson(LyricsMatch match) {
  final Duration? duration = match.duration;
  return <String, dynamic>{
    if (match.title != null) 'title': match.title,
    if (match.artist != null) 'artist': match.artist,
    if (duration != null) 'duration': duration.inMilliseconds,
    'hasTranslation': match.hasTranslation,
  };
}

List<TimedLyric>? _timedListFromJson(dynamic raw) {
  if (raw is! List) return null;
  final List<TimedLyric> lines = <TimedLyric>[];
  for (final dynamic item in raw) {
    if (item is! Map<String, dynamic>) continue;
    final dynamic time = item['time'];
    final dynamic text = item['text'];
    if (time is! num || text is! String) continue;
    lines.add(TimedLyric(
      time: Duration(milliseconds: time.toInt()),
      text: text,
      words: _wordListFromJson(item['words']),
    ));
  }
  return lines.isEmpty ? null : lines;
}

List<TimedWord>? _wordListFromJson(dynamic raw) {
  if (raw is! List) return null;
  final List<TimedWord> words = <TimedWord>[];
  for (final dynamic item in raw) {
    if (item is! Map<String, dynamic>) continue;
    final dynamic time = item['time'];
    final dynamic text = item['text'];
    if (time is! num || text is! String) continue;
    final dynamic end = item['end'];
    words.add(TimedWord(
      time: Duration(milliseconds: time.toInt()),
      text: text,
      end: end is num ? Duration(milliseconds: end.toInt()) : null,
    ));
  }
  return words.isEmpty ? null : words;
}

LyricsMatch? _matchFromJson(dynamic raw) {
  if (raw is! Map<String, dynamic>) return null;
  final dynamic duration = raw['duration'];
  return LyricsMatch(
    title: raw['title'] as String?,
    artist: raw['artist'] as String?,
    duration: duration is num ? Duration(milliseconds: duration.toInt()) : null,
    hasTranslation: raw['hasTranslation'] as bool? ?? false,
  );
}
