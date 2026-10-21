// Контракт общего JSON-хранилища: атомарная запись, копия повреждённого
// файла и запрет записи до успешного чтения.
//
// Это страховка от главной ошибки прежних хранилищ: «не прочиталось» молча
// превращалось в «пусто», а следующая запись стирала единственную копию.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mops/data/local/json_store.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mops-json-store-');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File fileIn(String name) =>
      File('${dir.path}${Platform.pathSeparator}$name');

  JsonStore storeFor(String name) => JsonStore(
        resolve: () async => fileIn(name),
        label: 'test',
      );

  test('новая запись атомарна: файл на месте, временных не осталось', () async {
    final JsonStore store = storeFor('ok.json');
    expect(await store.read(), isNull);
    expect(store.status, JsonStoreStatus.loaded);

    expect(await store.writeString('{"a":1}'), isTrue);
    expect(fileIn('ok.json').readAsStringSync(), '{"a":1}');
    expect(
      dir.listSync().where((FileSystemEntity e) => e.path.endsWith('.tmp')),
      isEmpty,
    );
    // Второй снимок заменяет первый, а не дописывается к нему.
    expect(await store.writeString('{"a":2}'), isTrue);
    expect(jsonDecode(fileIn('ok.json').readAsStringSync()), {'a': 2});
  });

  test('повреждённый файл уезжает в .corrupt, а не стирается', () async {
    final File file = fileIn('broken.json');
    const String broken = '{"events": [битый';
    file.writeAsStringSync(broken);

    final JsonStore store = storeFor('broken.json');
    expect(await store.read(), isNull);
    expect(store.status, JsonStoreStatus.readError);
    expect(store.readFailed, isTrue);

    // Запись запрещена: пустой снимок не затирает повреждённый файл.
    expect(await store.writeString('{"events":[]}'), isFalse);
    expect(file.readAsStringSync(), broken);

    final File backup = File('${file.path}.corrupt');
    expect(backup.existsSync(), isTrue);
    expect(backup.readAsStringSync(), broken);
  });

  test('запись до загрузки не затирает старое', () async {
    // writeString вызывается сразу, без read(): хранилище обязано сначала
    // само прочитать файл и увидеть, что он битый.
    final File file = fileIn('direct.json');
    const String broken = 'не json';
    file.writeAsStringSync(broken);

    final JsonStore store = storeFor('direct.json');
    expect(await store.writeString('{"new":true}'), isFalse);

    expect(file.readAsStringSync(), broken);
    expect(File('${file.path}.corrupt').readAsStringSync(), broken);
  });

  test('ошибка чтения не даёт «пусто и перезаписать»', () async {
    // Резолвер падает так же, как диск без прав: файл есть, но недоступен.
    final JsonStore store = JsonStore(
      resolve: () async => throw const FileSystemException('нет доступа'),
      label: 'test',
    );

    expect(await store.read(), isNull);
    expect(store.readFailed, isTrue);
    expect(store.status, JsonStoreStatus.readError);
    expect(await store.writeString('{"a":1}'), isFalse);
    // На диск ничего не попало — ни файла, ни временного.
    expect(dir.listSync(), isEmpty);
  });

  test('пустой и отсутствующий файл — это «загружено», а не ошибка', () async {
    final JsonStore missing = storeFor('missing.json');
    expect(await missing.read(), isNull);
    expect(missing.readFailed, isFalse);

    final JsonStore empty = storeFor('empty.json');
    fileIn('empty.json').writeAsStringSync('  \n');
    expect(await empty.read(), isNull);
    expect(empty.readFailed, isFalse);
  });

  test('явная очистка работает и после ошибки чтения', () async {
    final File file = fileIn('clear.json')..writeAsStringSync('битый');
    final JsonStore store = storeFor('clear.json');

    expect(await store.read(), isNull);
    expect(store.readFailed, isTrue);

    expect(await store.deleteFile(), isTrue);
    expect(file.existsSync(), isFalse);
    expect(store.status, JsonStoreStatus.loaded);
    expect(store.readFailed, isFalse);
    // После явной очистки запись снова разрешена.
    expect(await store.writeString('{"a":1}'), isTrue);
  });

  test('очередь записи сохраняет последний снимок', () async {
    final JsonStore store = storeFor('queue.json');
    await store.read();

    await Future.wait<bool>(<Future<bool>>[
      store.writeString('{"n":1}'),
      store.writeString('{"n":2}'),
      store.writeString('{"n":3}'),
    ]);

    expect(jsonDecode(fileIn('queue.json').readAsStringSync()), {'n': 3});
    expect(
      dir.listSync().where((FileSystemEntity e) => e.path.endsWith('.tmp')),
      isEmpty,
    );
  });

  test('очистка отменяет снимок, поставленный в очередь раньше неё', () async {
    final JsonStore store = storeFor('clear-race.json');
    await store.read();

    // Запись и очистка вызываются подряд, без ожидания: снимок не должен
    // воскресить файл после удаления.
    final Future<bool> write = store.writeString('{"old":true}');
    final Future<bool> clear = store.deleteFile();

    expect(await write, isFalse);
    expect(await clear, isTrue);
    expect(fileIn('clear-race.json').existsSync(), isFalse);
  });
}

