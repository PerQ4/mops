import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'lyrics_cache.dart';

/// Исполнитель, которого пользователь заблокировал.
///
/// Хранится пара «id + имя»: по id идёт вся фильтрация, а имя нужно только
/// для экрана управления блокировками, чтобы список можно было прочитать
/// глазами. Никакие решения по имени не принимаются — YouTube отдаёт одного
/// и того же исполнителя под разными написаниями, и блокировка «по строке»
/// промахивалась бы.
@immutable
class BlockedArtist {
  const BlockedArtist({required this.id, required this.name});

  /// Идентификатор канала (`UC…`) — единственный ключ блокировки.
  final String id;

  /// Имя на момент блокировки — только для показа в настройках.
  final String name;

  Map<String, dynamic> toJson() => <String, dynamic>{'id': id, 'name': name};
}

/// Локальный список заблокированных исполнителей.
///
/// Живёт отдельно от `AppSettings`: настройки — это одна небольшая строка,
/// которую читают и пишут на каждое изменение любой опции, а список
/// блокировок растёт и меняется целиком. Файл лежит рядом с кэшем текстов
/// ([appDataDirectory]) и переживает перезапуск — иначе блокировка
/// действовала бы только до закрытия приложения.
///
/// TTL и предела числа записей нет: это ручное решение пользователя, оно не
/// устаревает само по себе.
class BlockedArtistsStore {
  BlockedArtistsStore({this.fileName = 'blocked_artists.json'});

  final String fileName;

  File? _file;

  /// Список в памяти: повторные чтения не бьют по диску.
  List<BlockedArtist>? _memory;

  /// Загрузка файла идёт один раз: параллельные чтения ждут её же.
  Future<void>? _loading;

  /// Запись выстроена в очередь: параллельные `write` иначе перетирали бы
  /// снимки друг друга и часть блокировок терялась бы.
  Future<void> _writing = Future<void>.value();

  /// Все сохранённые блокировки.
  ///
  /// Ошибки файла и JSON наружу не пробрасываются: недоступное хранилище —
  /// это отсутствие блокировок, а не повод не показать каталог.
  Future<List<BlockedArtist>> readAll() async {
    await _ensureLoaded();
    return _memory ?? <BlockedArtist>[];
  }

  /// Заменяет список целиком — и в памяти, и на диске.
  ///
  /// Список маленький и меняется по одному элементу, поэтому снимок целиком
  /// проще и надёжнее, чем точечные операции: не бывает «наполовину
  /// записанного» состояния.
  Future<void> writeAll(List<BlockedArtist> artists) async {
    final List<BlockedArtist> clean = <BlockedArtist>[];
    final Set<String> seen = <String>{};
    for (final BlockedArtist artist in artists) {
      if (artist.id.isEmpty || !seen.add(artist.id)) continue;
      clean.add(artist);
    }

    // Дожидаемся чтения: иначе `_loadFromDisk` мог бы завершиться уже после
    // записи и затереть в памяти только что заблокированное.
    await _ensureLoaded();
    _memory = clean;

    final String payload = jsonEncode(<String, dynamic>{
      'version': 1,
      'artists': clean.map((BlockedArtist a) => a.toJson()).toList(),
    });
    _writing = _writing.then((_) => _writeFile(payload));
    await _writing;
  }

  /// Полная очистка — и в памяти, и на диске.
  ///
  /// Через [writeAll], а не удалением файла: запись идёт очередью, и прямое
  /// удаление могло бы обогнать уже начатую запись — файл вернулся бы со
  /// старым списком.
  Future<void> clear() => writeAll(const <BlockedArtist>[]);

  Future<void> _ensureLoaded() async {
    if (_memory != null) return;
    _loading ??= _loadFromDisk();
    await _loading;
  }

  Future<void> _loadFromDisk() async {
    final List<BlockedArtist> parsed = <BlockedArtist>[];
    try {
      final File file = await _storeFile();
      if (file.existsSync()) {
        final String raw = await file.readAsString();
        if (raw.trim().isNotEmpty) _readArtists(jsonDecode(raw), parsed);
      }
    } on FileSystemException {
      // Нет доступа к файлу — работаем без сохранённых блокировок.
    } on FormatException {
      // Повреждённый JSON — начнём файл заново при следующей записи.
    } on Object catch (error) {
      debugPrint('[BlockedArtistsStore] не удалось прочитать список: $error');
    }
    _memory = parsed;
  }

  /// Разбирает содержимое файла. Битая запись пропускается целиком — одна
  /// испорченная строка не должна обнулять остальные блокировки.
  void _readArtists(dynamic decoded, List<BlockedArtist> into) {
    final dynamic raw =
        decoded is Map<String, dynamic> ? decoded['artists'] : null;
    if (raw is! List) return;

    final Set<String> seen = <String>{};
    for (final dynamic item in raw) {
      if (item is! Map<String, dynamic>) continue;
      final dynamic id = item['id'];
      if (id is! String || id.isEmpty || !seen.add(id)) continue;
      final dynamic name = item['name'];
      into.add(BlockedArtist(
        id: id,
        name: name is String && name.trim().isNotEmpty ? name.trim() : id,
      ));
    }
  }

  Future<void> _writeFile(String payload) async {
    try {
      final File file = await _storeFile();
      await file.writeAsString(payload, flush: true);
    } on FileSystemException {
      // Диск недоступен — блокировки остаются только в памяти.
    } on Object catch (error) {
      debugPrint('[BlockedArtistsStore] не удалось сохранить список: $error');
    }
  }

  Future<File> _storeFile() async {
    final File? ready = _file;
    if (ready != null) return ready;
    final Directory dir = await appDataDirectory();
    final File file = File('${dir.path}${Platform.pathSeparator}$fileName');
    _file = file;
    return file;
  }
}
