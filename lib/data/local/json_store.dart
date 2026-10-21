import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Состояние файла в [JsonStore].
///
/// Отдельное значение «ошибка чтения» — это и есть главный смысл класса:
/// раньше все хранилища превращали любую ошибку в «пусто», а следующая запись
/// стирала то, что прочитать не удалось.
enum JsonStoreStatus {
  /// Файл ещё не читали; писать нельзя — старое содержимое потеряется.
  notLoaded,

  /// Файл прочитан (или его нет) — запись разрешена.
  loaded,

  /// Файл есть, но прочитать/разобрать его не вышло. Запись запрещена,
  /// пока пользователь явно не очистит хранилище.
  readError,
}

/// Общий JSON-файл для локальных хранилищ.
///
/// Правила, одинаковые для всех:
/// * **атомарная запись** — сначала временный файл рядом, потом `rename` на
///   место целевого; падение процесса не оставляет половину JSON;
/// * **повреждённый файл не теряется** — перед тем как начать с чистого листа,
///   он копируется в `<имя>.corrupt`;
/// * **явное состояние** — см. [JsonStoreStatus]; запись до успешного чтения
///   запрещена, иначе молча затирала бы старое содержимое;
/// * **ошибка чтения не равна «пусто»** — она попадает в лог и в [readFailed],
///   а не только в пустой список.
///
/// Класс не знает ни о моделях, ни о формате: он отдаёт разобранный `jsonDecode`
/// и принимает готовую строку. Разбор записей остаётся у хранилища, потому что
/// только оно знает, что считать битой строкой, а что — нет.
class JsonStore {
  JsonStore({
    required Future<File> Function() resolve,
    this.label = 'JsonStore',
  }) : _file = resolve;

  /// Откуда брать файл. Функция, а не `File`: каталог данных приложения
  /// доступен только асинхронно, а в тестах путь вообще другой.
  final Future<File> Function() _file;

  /// Имя хранилища в сообщениях журнала.
  final String label;

  JsonStoreStatus _status = JsonStoreStatus.notLoaded;
  Object? _readError;
  dynamic _value;
  Future<void>? _loading;

  /// Запись выстроена в очередь: параллельные снимки иначе перетирали бы
  /// друг друга, и на диск попадал бы не последний.
  Future<void> _writing = Future<void>.value();

  /// Счётчик временных файлов: два хранилища с одним именем (бывает в тестах)
  /// не должны писать в один `.tmp`.
  static int _tempCounter = 0;

  /// Номер «поколения» файла. Увеличивается при очистке: запись, поставленная
  /// в очередь до неё, не должна воскресить уже удалённое содержимое.
  int _generation = 0;

  JsonStoreStatus get status => _status;

  /// Чтение уже закончилось — неважно, успешно или нет.
  bool get isLoaded => _status != JsonStoreStatus.notLoaded;

  /// Файл есть, но не прочитался. Запись в него запрещена.
  bool get readFailed => _status == JsonStoreStatus.readError;

  /// Исключение чтения — для журнала и диагностики.
  Object? get readError => _readError;

  /// Разобранное содержимое; `null` — файла нет, он пуст или не прочитан.
  dynamic get value => _value;

  /// Читает файл один раз. Параллельные вызовы ждут одно и то же чтение.
  ///
  /// Ошибка не бросается: вызывающее хранилище должно продолжить работу
  /// (без данных), но увидеть [readFailed] и не писать.
  Future<dynamic> read() async {
    if (_status == JsonStoreStatus.notLoaded) {
      _loading ??= _load();
      await _loading;
    }
    return _value;
  }

  Future<void> _load() async {
    File? file;
    try {
      file = await _file();
      if (!file.existsSync()) {
        _status = JsonStoreStatus.loaded;
        return;
      }
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        _status = JsonStoreStatus.loaded;
        return;
      }
      _value = jsonDecode(raw);
      _status = JsonStoreStatus.loaded;
    } on FormatException catch (error) {
      await _fail(file, error, 'файл повреждён: не разбирается JSON');
    } on Object catch (error) {
      await _fail(file, error, 'не удалось прочитать файл');
    }
  }

  /// Переводит хранилище в «ошибка чтения» и сохраняет копию файла.
  Future<void> _fail(File? file, Object error, String what) async {
    _status = JsonStoreStatus.readError;
    _readError = error;
    _value = null;
    debugPrint('[$label] $what: $error');
    if (file == null) return;
    try {
      if (!file.existsSync()) return;
      final File backup = File('${file.path}.corrupt');
      await file.copy(backup.path);
      debugPrint('[$label] копия сохранена: ${backup.path}');
    } on Object catch (copyError) {
      // Копию сделать не вышло (нет прав, диск) — запись всё равно запрещена,
      // поэтому оригинал не пострадает.
      debugPrint('[$label] не удалось сохранить копию: $copyError');
    }
  }

  /// Записывает [payload] на диск.
  ///
  /// Возвращает `false`, если запись не состоялась: файл не был прочитан
  /// ([readFailed]) или диск не дал. Молча «получилось» не бывает — вызывающий
  /// должен решить, показывать ли ошибку.
  ///
  /// Чтение выполняется здесь же: запись до загрузки не затирает старое
  /// содержимое, а сначала выясняет, можно ли его трогать.
  Future<bool> writeString(String payload) async {
    // Поколение запоминаем до ожидания: если за это время файл очистят,
    // снимок относится к удалённым данным и писать его нельзя.
    final int generation = _generation;
    await read();
    if (_status != JsonStoreStatus.loaded) {
      debugPrint(
        '[$label] запись отменена: файл не прочитан '
        '(${_status.name}), старое содержимое не трогаем',
      );
      return false;
    }
    if (generation != _generation) {
      debugPrint('[$label] запись отменена: файл был очищен');
      return false;
    }

    final Future<bool> task = _writing.then((_) {
      if (generation != _generation) {
        // Файл успели очистить: этот снимок относится к удалённым данным.
        debugPrint('[$label] запись отменена: файл был очищен');
        return false;
      }
      return _writeAtomic(payload);
    });
    // Сбой одного снимка не должен ломать очередь следующих.
    _writing = task.then<void>(
      (bool _) {},
      onError: (Object error, StackTrace stack) {
        debugPrint('[$label] запись не удалась: $error');
      },
    );
    return task;
  }

  /// Удаляет файл — для явного `clear()` пользователем.
  ///
  /// Запрет записи здесь не действует: стереть нечитаемый файл — осознанное
  /// действие, а не «запись поверх того, что не смогли прочитать».
  Future<bool> deleteFile() async {
    // Всё, что было поставлено в очередь до очистки, на диск уже не попадёт.
    _generation++;
    await read();
    final Future<bool> task = _writing.then((_) async {
      try {
        final File target = await _file();
        if (target.existsSync()) await target.delete();
        _value = null;
        _readError = null;
        _status = JsonStoreStatus.loaded;
        return true;
      } on Object catch (error) {
        debugPrint('[$label] не удалось удалить файл: $error');
        return false;
      }
    });
    _writing = task.then<void>(
      (bool _) {},
      onError: (Object error, StackTrace stack) {
        debugPrint('[$label] удаление не удалось: $error');
      },
    );
    return task;
  }

  Future<bool> _writeAtomic(String payload) async {
    File? temp;
    try {
      final File target = await _file();
      final Directory dir = target.parent;
      if (!dir.existsSync()) await dir.create(recursive: true);

      temp = File('${target.path}.${_tempCounter++}.tmp');
      await temp.writeAsString(payload, flush: true);
      try {
        await temp.rename(target.path);
      } on FileSystemException catch (error) {
        // На Windows `rename` поверх существующего файла обычно работает
        // (MoveFileEx с заменой), но не всегда: файл может быть занят
        // антивирусом или индексатором. Тогда остаётся delete + rename —
        // окно, в котором файла нет. Риск короткий и только при сбое записи;
        // альтернатива — потерять новый снимок целиком.
        if (!target.existsSync()) rethrow;
        debugPrint('[$label] rename поверх файла не удался, пишу через '
            'удаление: $error');
        await target.delete();
        await temp.rename(target.path);
      }
      return true;
    } on Object catch (error) {
      debugPrint('[$label] не удалось сохранить файл: $error');
      return false;
    } finally {
      try {
        if (temp != null && temp.existsSync()) await temp.delete();
      } on Object {
        // Временный файл мог не создаться или уже переименоваться.
      }
    }
  }
}
