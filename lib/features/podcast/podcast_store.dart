import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../data/local/lyrics_cache.dart';
import 'podcast_models.dart';

/// Что лежит в файле локальной истории подкастов.
@immutable
class PodcastStoredData {
  const PodcastStoredData({
    this.progress = const <PodcastEntry>[],
    this.recent = const <PodcastEntry>[],
  });

  /// Незаконченные эпизоды: по ним предлагается «Продолжить».
  final List<PodcastEntry> progress;

  /// Недавно игравшие эпизоды, самые свежие первыми.
  final List<PodcastEntry> recent;

  static const PodcastStoredData empty = PodcastStoredData();
}

/// Локальный прогресс эпизодов и история прослушивания.
///
/// Серверного прогресса у подкастов в доступном API нет: `browse` страницы
/// шоу отдаёт эпизоды без отметки «дослушано до», а `next` — только плеер.
/// Поэтому прогресс считаем и храним сами, рядом с кэшем текстов
/// ([appDataDirectory]). Файл переживает перезапуск — в этом весь смысл.
///
/// Формат повторяет `PlaylistTagsStore`: снимок в памяти, ленивое чтение,
/// очередь записи. Ошибки диска глотаются: недоступная история — это пустая
/// история, а не повод не открыть подкаст.
class PodcastStore {
  PodcastStore({this.fileName = 'podcasts.json'});

  final String fileName;

  /// Сколько незаконченных эпизодов помнить. Дальше вытесняются самые
  /// давние: к ним всё равно уже не вернутся.
  static const int maxProgress = 100;

  /// Сколько эпизодов показывать в «Недавно игравших».
  static const int maxRecent = 12;

  File? _file;
  PodcastStoredData _memory = PodcastStoredData.empty;
  bool _loaded = false;
  Future<void>? _loading;

  /// Запись выстроена в очередь: параллельные снимки иначе перетирали бы
  /// друг друга, и часть истории терялась бы.
  Future<void> _writing = Future<void>.value();

  Future<PodcastStoredData> read() async {
    if (_loaded) return _memory;
    _loading ??= _loadFromDisk();
    await _loading;
    return _memory;
  }

  /// Сохраняет историю целиком. Списки обрезаются до пределов и
  /// упорядочиваются здесь, чтобы вызывающий не мог записать мусор.
  Future<void> writeAll(PodcastStoredData data) {
    final PodcastStoredData trimmed = _trim(data);
    _memory = trimmed;
    _loaded = true;

    final String payload = jsonEncode(<String, dynamic>{
      'version': 1,
      'progress': trimmed.progress.map((PodcastEntry e) => e.toJson()).toList(),
      'recent': trimmed.recent.map((PodcastEntry e) => e.toJson()).toList(),
    });
    _writing = _writing.then((_) => _writeFile(payload));
    return _writing;
  }

  /// Полная очистка — и памяти, и файла.
  Future<void> clear() async {
    _memory = PodcastStoredData.empty;
    _loaded = true;
    try {
      final File file = await _fileHandle();
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // Цель — отсутствие файла; не вышло — не критично.
    } on Object catch (error) {
      debugPrint('[PodcastStore] не удалось очистить историю: $error');
    }
  }

  Future<void> _loadFromDisk() async {
    final List<PodcastEntry> progress = <PodcastEntry>[];
    final List<PodcastEntry> recent = <PodcastEntry>[];
    try {
      final File file = await _fileHandle();
      if (file.existsSync()) {
        final String raw = await file.readAsString();
        if (raw.trim().isNotEmpty) {
          final dynamic decoded = jsonDecode(raw);
          _readList(decoded, 'progress', progress);
          _readList(decoded, 'recent', recent);
        }
      }
    } on FileSystemException {
      // Нет доступа к файлу — истории просто нет.
    } on FormatException {
      // Повреждённый JSON начнём заново при следующей записи.
    } on Object catch (error) {
      debugPrint('[PodcastStore] не удалось прочитать историю: $error');
    }
    _memory = _trim(PodcastStoredData(progress: progress, recent: recent));
    _loaded = true;
  }

  /// Разбирает один список файла: битая запись пропускается, остальные
  /// остаются. Один испорченный эпизод не должен обнулять всю историю.
  void _readList(
    dynamic decoded,
    String key,
    List<PodcastEntry> into,
  ) {
    if (decoded is! Map<String, dynamic>) return;
    final dynamic raw = decoded[key];
    if (raw is! List) return;
    for (final dynamic item in raw) {
      if (item is! Map<String, dynamic>) continue;
      try {
        into.add(PodcastEntry.fromJson(item));
      } on FormatException {
        continue;
      }
    }
  }

  /// Убирает повторы (оставляет самую свежую запись), сортирует и обрезает.
  PodcastStoredData _trim(PodcastStoredData data) {
    return PodcastStoredData(
      progress: _uniqueSorted(data.progress, limit: maxProgress),
      recent: _uniqueSorted(data.recent, limit: maxRecent),
    );
  }

  List<PodcastEntry> _uniqueSorted(
    List<PodcastEntry> entries, {
    required int limit,
  }) {
    final Map<String, PodcastEntry> byEpisode = <String, PodcastEntry>{};
    for (final PodcastEntry entry in entries) {
      if (entry.episodeId.isEmpty) continue;
      final PodcastEntry? previous = byEpisode[entry.episodeId];
      if (previous == null || entry.at >= previous.at) {
        byEpisode[entry.episodeId] = entry;
      }
    }
    final List<PodcastEntry> sorted = byEpisode.values.toList()
      ..sort((PodcastEntry a, PodcastEntry b) => b.at.compareTo(a.at));
    if (sorted.length <= limit) return sorted;
    return sorted.take(limit).toList(growable: false);
  }

  Future<void> _writeFile(String payload) async {
    try {
      final File file = await _fileHandle();
      await file.writeAsString(payload, flush: true);
    } on FileSystemException {
      // Диск недоступен — история осталась в памяти.
    } on Object catch (error) {
      debugPrint('[PodcastStore] не удалось сохранить историю: $error');
    }
  }

  Future<File> _fileHandle() async {
    final File? ready = _file;
    if (ready != null) return ready;
    final Directory dir = await appDataDirectory();
    final File file =
        File('${dir.path}${Platform.pathSeparator}$fileName');
    _file = file;
    return file;
  }
}
