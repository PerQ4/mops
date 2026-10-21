import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'json_store.dart';
import 'lyrics_cache.dart' show appDataDirectory;

/// Одно зачётное прослушивание (задача 8.1).
///
/// Запись создаётся только тогда, когда трек действительно слушали: набралось
/// не меньше четырёх минут или половины длительности. Событие хранит только то,
/// что нужно статистике, — имя, исполнителей, альбом и время. Ссылка на поток
/// и обложка не сохраняются: они устаревают, а для топов не нужны.
@immutable
class ListenEvent {
  const ListenEvent({
    required this.trackId,
    required this.title,
    required this.artists,
    required this.album,
    required this.at,
    required this.seconds,
  });

  /// Идентификатор трека — по нему считаются уникальные треки.
  final String trackId;
  final String title;

  /// Имена исполнителей. У трека их может быть несколько, и каждый получает
  /// зачёт: так «топ исполнителей» не теряет второго артиста дуэта.
  final List<String> artists;
  final String? album;

  /// Когда прослушивание было зачтено.
  final DateTime at;

  /// Сколько реально играло до зачёта, секунды. Это не длительность трека:
  /// в статистике времени учитывается только то, что прозвучало.
  final int seconds;

  String get artistLine =>
      artists.isEmpty ? 'Неизвестный исполнитель' : artists.join(', ');

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': trackId,
        'title': title,
        'artists': artists,
        'album': album,
        'at': at.millisecondsSinceEpoch,
        'seconds': seconds,
      };

  /// Разбирает запись; битая строка пропускается, а не обнуляет весь файл.
  static ListenEvent? fromJson(dynamic raw) {
    if (raw is! Map<String, dynamic>) return null;
    final dynamic id = raw['id'];
    final dynamic at = raw['at'];
    if (id is! String || id.isEmpty || at is! num) return null;

    final dynamic title = raw['title'];
    final dynamic artists = raw['artists'];
    final dynamic album = raw['album'];
    final List<String> names = artists is List
        ? artists
            .whereType<String>()
            .map((String name) => name.trim())
            .where((String name) => name.isNotEmpty)
            .toList(growable: false)
        : const <String>[];
    // Приведение `as num?` падало на строковом значении и обрывало разбор
    // всего журнала — поэтому проверяем тип, а не бросаем.
    final dynamic rawSeconds = raw['seconds'];
    final int seconds = (rawSeconds is num ? rawSeconds.toInt() : 0).clamp(
      0,
      24 * 60 * 60,
    );

    return ListenEvent(
      trackId: id,
      title: title is String && title.trim().isNotEmpty
          ? title.trim()
          : 'Без названия',
      artists: names,
      album: album is String && album.trim().isNotEmpty
          ? album.trim()
          : null,
      at: DateTime.fromMillisecondsSinceEpoch(at.toInt()),
      seconds: seconds,
    );
  }
}

/// Локальное хранилище прослушиваний — JSON-файл рядом с кэшем текстов.
///
/// Отдельно от `AppSettings`: настройки — одна небольшая строка, которую пишут
/// на каждое изменение любой опции, а журнал растёт и переписывается целиком.
/// Данные не покидают компьютер: файл читают только экран статистики и
/// контроллер плеера.
class ListeningStatsStore {
  ListeningStatsStore({this.fileName = 'listening_stats.json'});

  final String fileName;

  /// Предел журнала: старые записи обрезаются. Год и пять тысяч событий с
  /// запасом покрывают «всё время» в интерфейсе, но не дают файлу расти вечно.
  static const int maxEvents = 5000;
  static const Duration maxAge = Duration(days: 365);

  /// Общий файл: атомарная запись, копия повреждённого файла, запрет записи
  /// до успешного чтения (см. [JsonStore]).
  late final JsonStore _json = JsonStore(
    resolve: _storeFile,
    label: 'ListeningStatsStore',
  );

  List<ListenEvent>? _memory;
  Future<void>? _loading;

  /// Журнал с диска не прочитался: работаем в памяти и на диск не пишем,
  /// иначе первое же прослушивание стёрло бы файл пустым списком.
  bool get readFailed => _json.readFailed;

  Future<List<ListenEvent>> readAll() async {
    await _ensureLoaded();
    return List<ListenEvent>.unmodifiable(
      _memory ?? const <ListenEvent>[],
    );
  }

  Future<void> writeAll(List<ListenEvent> events) async {
    await _ensureLoaded();
    final List<ListenEvent> next = _prune(events);
    _memory = next;

    final String payload = jsonEncode(<String, dynamic>{
      'version': 1,
      'events': <Map<String, dynamic>>[
        for (final ListenEvent event in next) event.toJson(),
      ],
    });
    final bool saved = await _json.writeString(payload);
    if (!saved) {
      debugPrint('[ListeningStatsStore] журнал остался только в памяти');
    }
  }

  Future<void> clear() async {
    await _ensureLoaded();
    _memory = const <ListenEvent>[];
    // Явная очистка должна работать и после ошибки чтения: пользователь
    // просит стереть журнал, а не переписать его пустым поверх непрочитанного.
    await _json.deleteFile();
  }

  List<ListenEvent> _prune(List<ListenEvent> events) {
    final DateTime cutoff = DateTime.now().subtract(maxAge);
    final List<ListenEvent> next = events
        .where((ListenEvent event) => !event.at.isBefore(cutoff))
        .toList()
      ..sort((ListenEvent a, ListenEvent b) => a.at.compareTo(b.at));
    if (next.length > maxEvents) {
      next.removeRange(0, next.length - maxEvents);
    }
    return next;
  }

  Future<void> _ensureLoaded() async {
    if (_memory != null) return;
    _loading ??= _loadFromDisk();
    await _loading;
  }

  Future<void> _loadFromDisk() async {
    final dynamic decoded = await _json.read();
    final List<ListenEvent> parsed = <ListenEvent>[];
    final dynamic events =
        decoded is Map<String, dynamic> ? decoded['events'] : null;
    if (events is List) {
      for (final dynamic item in events) {
        final ListenEvent? event = ListenEvent.fromJson(item);
        if (event != null) parsed.add(event);
      }
    }
    if (_json.readFailed) {
      // Пустая память здесь — не «журнала нет», а «файл не прочитан»:
      // запись запрещена, см. [readFailed].
      debugPrint('[ListeningStatsStore] журнал не прочитан, запись отключена');
    }
    _memory = _prune(parsed);
  }

  Future<File> _storeFile() async {
    final Directory dir = await appDataDirectory();
    return File('${dir.path}${Platform.pathSeparator}$fileName');
  }
}

/// Строка топа: имя, подпись и счётчики.
@immutable
class StatsEntry {
  const StatsEntry({
    required this.name,
    required this.subtitle,
    required this.plays,
    required this.seconds,
    required this.lastPlayed,
  });

  final String name;
  final String? subtitle;
  final int plays;
  final int seconds;
  final DateTime lastPlayed;
}

/// Итоги за выбранный период.
@immutable
class ListeningSummary {
  const ListeningSummary({
    required this.plays,
    required this.seconds,
    required this.uniqueTracks,
    required this.uniqueArtists,
    required this.repeats,
    required this.artists,
    required this.albums,
    required this.tracks,
    required this.repeatTrack,
    required this.forgottenArtist,
  });

  final int plays;
  final int seconds;
  final int uniqueTracks;
  final int uniqueArtists;

  /// Прослушивания сверх первого по каждому треку за период.
  final int repeats;

  final List<StatsEntry> artists;
  final List<StatsEntry> albums;
  final List<StatsEntry> tracks;

  /// Трек, который в периоде переслушивали чаще всего; `null` — повторов нет.
  final StatsEntry? repeatTrack;

  /// Исполнитель, которого давно не включали (по всей истории). `null` — таких
  /// нет: карточка не показывается, а не придумывается.
  final StatsEntry? forgottenArtist;

  /// Считает итоги по уже зачтённым прослушиваниям.
  ///
  /// [since] — начало периода; `null` — всё время. Все значения выводятся из
  /// событий: «повторно» — это прослушивания сверх первого по треку, «давно не
  /// слушали» — реальная дата последнего включения.
  static ListeningSummary fromEvents(
    List<ListenEvent> events, {
    DateTime? since,
    DateTime? now,
    int limit = 8,
  }) {
    final DateTime at = now ?? DateTime.now();
    final List<ListenEvent> period = since == null
        ? events
        : events
            .where((ListenEvent event) => !event.at.isBefore(since))
            .toList(growable: false);

    final _Buckets artists = _Buckets();
    final _Buckets albums = _Buckets();
    final _Buckets tracks = _Buckets();
    final Set<String> uniqueTrackIds = <String>{};
    int seconds = 0;

    for (final ListenEvent event in period) {
      seconds += event.seconds;
      uniqueTrackIds.add(event.trackId);
      tracks.add(
        key: event.trackId,
        name: event.title,
        subtitle: event.artistLine,
        event: event,
      );
      for (final String artist in event.artists) {
        artists.add(
          key: artist.toLowerCase(),
          name: artist,
          event: event,
        );
      }
      final String? album = event.album;
      if (album != null) {
        albums.add(
          key: album.toLowerCase(),
          name: album,
          event: event,
        );
      }
    }

    StatsEntry? repeatTrack;
    for (final StatsEntry entry in tracks.all) {
      if (entry.plays >= 2) {
        repeatTrack = entry;
        break;
      }
    }

    // «Давно не слушали» ищется по всей истории, а не по выбранному периоду:
    // иначе за «7 дней» карточка всегда была бы пустой.
    final _Buckets allArtists = _Buckets();
    for (final ListenEvent event in events) {
      for (final String artist in event.artists) {
        allArtists.add(
          key: artist.toLowerCase(),
          name: artist,
          event: event,
        );
      }
    }
    final DateTime forgottenBefore = at.subtract(const Duration(days: 30));
    StatsEntry? forgottenArtist;
    for (final StatsEntry entry in allArtists.all) {
      if (entry.plays >= 2 && entry.lastPlayed.isBefore(forgottenBefore)) {
        forgottenArtist = entry;
        break;
      }
    }

    return ListeningSummary(
      plays: period.length,
      seconds: seconds,
      uniqueTracks: uniqueTrackIds.length,
      uniqueArtists: artists.length,
      repeats: period.length - uniqueTrackIds.length,
      artists: artists.top(limit),
      albums: albums.top(limit),
      tracks: tracks.top(limit),
      repeatTrack: repeatTrack,
      forgottenArtist: forgottenArtist,
    );
  }
}

/// Накопитель по одному ключу (исполнитель, альбом, трек).
class _Buckets {
  final Map<String, _Bucket> _items = <String, _Bucket>{};

  int get length => _items.length;

  void add({
    required String key,
    required String name,
    String? subtitle,
    required ListenEvent event,
  }) {
    final _Bucket bucket = _items.putIfAbsent(
      key,
      () => _Bucket(name: name, subtitle: subtitle),
    );
    bucket.plays++;
    bucket.seconds += event.seconds;
    if (event.at.isAfter(bucket.lastPlayed)) bucket.lastPlayed = event.at;
  }

  /// Все строки, отсортированные по числу прослушиваний.
  List<StatsEntry> get all {
    final List<StatsEntry> entries = <StatsEntry>[
      for (final _Bucket bucket in _items.values) bucket.toEntry(),
    ];
    entries.sort((StatsEntry a, StatsEntry b) {
      final int byPlays = b.plays.compareTo(a.plays);
      if (byPlays != 0) return byPlays;
      return b.lastPlayed.compareTo(a.lastPlayed);
    });
    return entries;
  }

  List<StatsEntry> top(int limit) => all.take(limit).toList(growable: false);
}

class _Bucket {
  _Bucket({required this.name, required this.subtitle});

  final String name;
  final String? subtitle;
  int plays = 0;
  int seconds = 0;
  DateTime lastPlayed = DateTime.fromMillisecondsSinceEpoch(0);

  StatsEntry toEntry() => StatsEntry(
        name: name,
        subtitle: subtitle,
        plays: plays,
        seconds: seconds,
        lastPlayed: lastPlayed,
      );
}
