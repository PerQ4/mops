import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../data/local/json_store.dart';
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
/// Формат повторяет `PlaylistTagsStore`: снимок в памяти, ленивое чтение.
/// Ошибка диска не превращается в «пустую историю»: файл копируется в
/// `.corrupt`, а запись в него запрещается до перезапуска (см. [JsonStore]).
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

  /// Файл истории: атомарная запись и запрет записи до чтения.
  late final JsonStore _json = JsonStore(
    resolve: _fileHandle,
    label: 'PodcastStore',
  );

  /// История не прочиталась: показываем пустую, но на диск не пишем, иначе
  /// первое же сохранение прогресса стёрло бы файл целиком.
  bool get readFailed => _json.readFailed;

  Future<PodcastStoredData> read() async {
    await _ensureLoaded();
    return _memory;
  }

  /// Сохраняет историю целиком. Списки обрезаются до пределов и
  /// упорядочиваются здесь, чтобы вызывающий не мог записать мусор.
  ///
  /// Чтение ждём до записи: раньше `_memory` и `_loaded` ставились сразу, и
  /// снимок, сделанный до конца загрузки, затирал историю с диска.
  Future<void> writeAll(PodcastStoredData data) async {
    await _ensureLoaded();
    final PodcastStoredData trimmed = _trim(data);
    _memory = trimmed;

    final String payload = jsonEncode(<String, dynamic>{
      'version': 1,
      'progress': trimmed.progress.map((PodcastEntry e) => e.toJson()).toList(),
      'recent': trimmed.recent.map((PodcastEntry e) => e.toJson()).toList(),
    });
    if (!await _json.writeString(payload)) {
      debugPrint('[PodcastStore] история осталась только в памяти');
    }
  }

  /// Полная очистка — и памяти, и файла.
  Future<void> clear() async {
    await _ensureLoaded();
    _memory = PodcastStoredData.empty;
    await _json.deleteFile();
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loading ??= _loadFromDisk();
    await _loading;
  }

  Future<void> _loadFromDisk() async {
    final List<PodcastEntry> progress = <PodcastEntry>[];
    final List<PodcastEntry> recent = <PodcastEntry>[];
    final dynamic decoded = await _json.read();
    if (decoded != null) {
      _readList(decoded, 'progress', progress);
      _readList(decoded, 'recent', recent);
    }
    if (_json.readFailed) {
      debugPrint('[PodcastStore] история не прочитана — запись отключена');
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
