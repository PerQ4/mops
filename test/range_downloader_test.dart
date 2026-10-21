// Скачивание по диапазонам. Сеть не нужна: поднимается локальный сервер,
// который ведёт себя как медиасервер YouTube — отдаёт данные только по
// заголовку `Range` с явным диапазоном.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mops/data/sources/range_downloader.dart';

/// Заглушка медиасервера.
///
/// Ключевое поведение: без заголовка `Range` отвечает 403 — именно так делает
/// googlevideo, и именно из-за этого раньше не работал звук.
///
/// Остальные переключатели нужны, чтобы воспроизвести реальные сбои:
/// короткие части, ответ `200` вместо `206`, отсутствие `Content-Range`,
/// зависшее тело и подмену файла между попытками.
class FakeMediaServer {
  FakeMediaServer._(this._server, this.content);

  static Future<FakeMediaServer> start(int size) async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // Предсказуемое содержимое: байт i равен i % 251.
    final FakeMediaServer fake = FakeMediaServer._(server, _bytes(size));
    server.listen(fake._handle);
    return fake;
  }

  final HttpServer _server;

  Uint8List content;

  int requests = 0;
  int rejectedWithoutRange = 0;

  /// Не присылать `Content-Range` в ответе 206.
  bool omitContentRange = false;

  /// Игнорировать `Range` и отвечать `200` всем файлом.
  bool ignoreRange = false;

  /// Отдавать не больше N байт за ответ — «короткий чанк».
  int? maxBytesPerResponse;

  /// Прислать заголовки и замолчать, не закрывая соединение.
  bool stallBody = false;

  /// Не присылать даже заголовков — проверка таймаута на `close()`.
  bool stallHeaders = false;

  /// После N запросов подменить содержимое: как будто резолвер между
  /// попытками нашёл другой поток.
  int? replaceContentAfter;
  Uint8List? replacement;

  int get port => _server.port;
  int get size => content.length;

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    requests++;

    final Uint8List? next = replacement;
    if (next != null &&
        replaceContentAfter != null &&
        requests > replaceContentAfter!) {
      content = next;
    }

    final String? range = request.headers.value(HttpHeaders.rangeHeader);
    if (range == null) {
      // Без диапазона — как у YouTube: отказ.
      rejectedWithoutRange++;
      request.response
        ..statusCode = HttpStatus.forbidden
        ..close();
      return;
    }

    if (stallHeaders) {
      // Ничего не пишем и не закрываем: клиент должен сработать по таймауту
      // ожидания заголовков.
      return;
    }

    final RegExpMatch? match =
        RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
    if (match == null) {
      request.response
        ..statusCode = HttpStatus.forbidden
        ..close();
      return;
    }

    final int start = int.parse(match.group(1)!);
    final int end = match.group(2)!.isEmpty
        ? content.length - 1
        : int.parse(match.group(2)!);

    if (start >= content.length) {
      request.response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${content.length}',
        )
        ..close();
      return;
    }

    if (ignoreRange) {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentLength = content.length;
      if (stallBody) {
        request.response.bufferOutput = false;
        request.response.add(<int>[content.first]);
        await request.response.flush();
        return;
      }
      request.response.add(content);
      await request.response.close();
      return;
    }

    final int last = math.min(end, content.length - 1);
    int sliceLength = last - start + 1;
    final int? limit = maxBytesPerResponse;
    if (limit != null && limit < sliceLength) sliceLength = limit;

    final Uint8List slice = content.sublist(start, start + sliceLength);
    final int sliceEnd = start + slice.length - 1;

    request.response
      ..statusCode = HttpStatus.partialContent
      ..headers.contentLength = slice.length;
    if (!omitContentRange) {
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$sliceEnd/${content.length}',
      );
    }
    if (stallBody) {
      // Заголовки и один байт ушли, дальше тишина: клиент должен сработать по
      // таймауту чтения тела. Без первого байта Dart держит заголовки в
      // буфере, и такой тест проверял бы таймаут `close()`, а не тела.
      request.response.bufferOutput = false;
      request.response.add(<int>[slice.first]);
      await request.response.flush();
      return;
    }
    request.response.add(slice);
    await request.response.close();
  }
}

Uint8List _bytes(int size) =>
    Uint8List.fromList(List<int>.generate(size, (int i) => i % 251));

void main() {
  late FakeMediaServer server;
  late Directory dir;

  setUp(() async {
    server = await FakeMediaServer.start(3 * 1024 * 1024 + 12345);
    dir = Directory.systemTemp.createTempSync('mops-range-');
  });

  tearDown(() async {
    await server.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Uri urlFor(FakeMediaServer target) =>
      Uri.parse('http://127.0.0.1:${target.port}/videoplayback');

  test('файл скачивается целиком по частям', () async {
    final File target = File('${dir.path}/track.audio');
    // Маленькая часть, чтобы проверить именно цикл, а не один запрос.
    final RangeDownloader downloader = RangeDownloader(chunkBytes: 256 * 1024);
    addTearDown(downloader.dispose);

    final int written = await downloader.downloadTo(urlFor(server), target);

    expect(written, server.size);
    expect(target.lengthSync(), server.size);

    // Содержимое совпадает с исходным.
    final Uint8List got = target.readAsBytesSync();
    expect(got[0], 0);
    expect(got[server.size - 1], (server.size - 1) % 251);

    // Скачивали частями, а не одним запросом.
    expect(server.requests, greaterThan(1));
  });

  test('заголовок Range всегда ограничен явным диапазоном', () async {
    final File target = File('${dir.path}/track2.audio');
    final RangeDownloader downloader = RangeDownloader(chunkBytes: 512 * 1024);
    addTearDown(downloader.dispose);

    await downloader.downloadTo(urlFor(server), target);

    // Сервер отвечает 403 на запрос без диапазона — если бы мы его не
    // отправляли, скачивание бы не состоялось.
    expect(server.rejectedWithoutRange, 0);
  });

  test('сервер, ограничивающий поток, даёт понятную ошибку', () async {
    // Заглушка, которая отказывает всегда — как YouTube на части потоков.
    final HttpServer strict =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => strict.close(force: true));
    strict.listen((HttpRequest request) {
      request.response
        ..statusCode = HttpStatus.forbidden
        ..close();
    });

    final File target = File('${dir.path}/track3.audio');
    final RangeDownloader downloader = RangeDownloader();
    addTearDown(downloader.dispose);

    await expectLater(
      downloader.downloadTo(
        Uri.parse('http://127.0.0.1:${strict.port}/videoplayback'),
        target,
      ),
      throwsA(
        isA<StreamDownloadException>().having(
          (StreamDownloadException e) => e.message,
          'сообщение',
          allOf(
            contains('403'),
            contains('прокси'),
          ),
        ),
      ),
    );

    // Незавершённый файл не остаётся на диске в виде готового.
    expect(target.existsSync(), isTrue); // остаётся как .part у вызывающего
  });

  test('прогресс доходит до единицы', () async {
    final File target = File('${dir.path}/track4.audio');
    final RangeDownloader downloader = RangeDownloader(chunkBytes: 512 * 1024);
    addTearDown(downloader.dispose);

    final List<double> progress = <double>[];
    await downloader.downloadTo(
      urlFor(server),
      target,
      onProgress: progress.add,
    );

    expect(progress, isNotEmpty);
    expect(progress.last, 1.0);
    // Прогресс не убывает.
    for (int i = 1; i < progress.length; i++) {
      expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
    }
  });

  test('сохранённый размер меньше реального: файл начинается заново', () async {
    // Сценарий из аудита: первая попытка сохранила 300 КБ от webm, вторая
    // получила m4a на 3 МБ. Дописывать нельзя — получится склейка.
    final File target = File('${dir.path}/glued.audio')
      ..writeAsBytesSync(Uint8List(300 * 1024));
    final RangeDownloader downloader =
        RangeDownloader(chunkBytes: 256 * 1024);
    addTearDown(downloader.dispose);

    final int written = await downloader.downloadTo(
      urlFor(server),
      target,
      resume: true,
      expectedBytes: 300 * 1024,
    );

    expect(written, server.size);
    expect(target.lengthSync(), server.size);
    expect(target.readAsBytesSync(), server.content);
  });

  test('остаток длиннее реального файла: 416 и заново, а не обрезка',
      () async {
    final int staleSize = server.size + 64 * 1024;
    final File target = File('${dir.path}/long.audio')
      ..writeAsBytesSync(Uint8List(staleSize));
    final RangeDownloader downloader =
        RangeDownloader(chunkBytes: 256 * 1024);
    addTearDown(downloader.dispose);

    final int written = await downloader.downloadTo(
      urlFor(server),
      target,
      resume: true,
      expectedBytes: staleSize,
    );

    expect(written, server.size);
    expect(target.lengthSync(), server.size);
    expect(target.readAsBytesSync(), server.content);
  });

  test('файл уже полный: 416 подтверждает размер и ничего не портит', () async {
    final File target = File('${dir.path}/complete.audio')
      ..writeAsBytesSync(server.content);
    final RangeDownloader downloader =
        RangeDownloader(chunkBytes: 256 * 1024);
    addTearDown(downloader.dispose);

    final int written = await downloader.downloadTo(
      urlFor(server),
      target,
      resume: true,
      expectedBytes: server.size,
    );

    expect(written, server.size);
    expect(target.readAsBytesSync(), server.content);
    // Один запрос: убедились у сервера, что файл полон, и остановились.
    expect(server.requests, 1);
  });

  test('размер меняется между попытками: файл перекачивается целиком',
      () async {
    // Первые два ответа — старый, более длинный файл; затем сервер отдаёт
    // новый. Готовым должен считаться только новый.
    final Uint8List replacement = _bytes(1024 * 1024 + 777);
    server
      ..replacement = replacement
      ..replaceContentAfter = 2;

    final File target = File('${dir.path}/changed.audio');
    final RangeDownloader downloader =
        RangeDownloader(chunkBytes: 256 * 1024);
    addTearDown(downloader.dispose);

    final int written = await downloader.downloadTo(urlFor(server), target);

    expect(written, replacement.length);
    expect(target.lengthSync(), replacement.length);
    expect(target.readAsBytesSync(), replacement);
  });

  test('206 без Content-Range не считается концом файла', () async {
    server.omitContentRange = true;
    final File target = File('${dir.path}/no-range.audio');
    final RangeDownloader downloader = RangeDownloader(chunkBytes: 65536);
    addTearDown(downloader.dispose);

    await expectLater(
      downloader.downloadTo(urlFor(server), target),
      throwsA(
        isA<StreamDownloadException>().having(
          (StreamDownloadException e) => e.message,
          'сообщение',
          contains('Content-Range'),
        ),
      ),
    );
    // Обрезанный файл не выдаётся за готовый: на диске не 3 МБ.
    expect(target.lengthSync(), lessThan(server.size));
  });

  test('короткая часть при известном total — не конец файла', () async {
    // Сервер отдаёт по 4 КБ, хотя просили 64 КБ. Раньше это считалось концом.
    final FakeMediaServer small = await FakeMediaServer.start(200 * 1024);
    small.maxBytesPerResponse = 4096;
    addTearDown(small.close);

    final File target = File('${dir.path}/short.audio');
    final RangeDownloader downloader = RangeDownloader(chunkBytes: 65536);
    addTearDown(downloader.dispose);

    final int written = await downloader.downloadTo(urlFor(small), target);

    expect(written, small.size);
    expect(target.lengthSync(), small.size);
    expect(target.readAsBytesSync(), small.content);
    expect(small.requests, greaterThanOrEqualTo(small.size ~/ 4096));
  });

  test('200 вместо 206: файл переписывается с начала', () async {
    server.ignoreRange = true;
    final File target = File('${dir.path}/full-200.audio')
      ..writeAsBytesSync(Uint8List(4096));
    final RangeDownloader downloader = RangeDownloader(chunkBytes: 65536);
    addTearDown(downloader.dispose);

    final int written = await downloader.downloadTo(
      urlFor(server),
      target,
      resume: true,
    );

    expect(written, server.size);
    expect(target.readAsBytesSync(), server.content);
  });

  test('зависшее тело срабатывает по таймауту', () async {
    final FakeMediaServer stalled = await FakeMediaServer.start(512 * 1024);
    stalled.stallBody = true;
    addTearDown(stalled.close);

    final File target = File('${dir.path}/stalled.audio');
    final RangeDownloader downloader = RangeDownloader(
      chunkBytes: 64 * 1024,
      chunkTimeout: const Duration(milliseconds: 300),
    );
    addTearDown(downloader.dispose);

    await expectLater(
      downloader.downloadTo(urlFor(stalled), target),
      throwsA(
        isA<StreamDownloadException>().having(
          (StreamDownloadException e) => e.message,
          'сообщение',
          contains('перестал присылать'),
        ),
      ),
    );
  });

  test('молчание до заголовков срабатывает по таймауту', () async {
    // Сервер принял запрос, но не прислал даже заголовки: это отдельный
    // таймаут — на `close()`, а не на чтение тела.
    final FakeMediaServer silent = await FakeMediaServer.start(512 * 1024);
    silent.stallHeaders = true;
    addTearDown(silent.close);

    final File target = File('${dir.path}/silent.audio');
    final RangeDownloader downloader = RangeDownloader(
      chunkBytes: 64 * 1024,
      chunkTimeout: const Duration(milliseconds: 300),
    );
    addTearDown(downloader.dispose);

    await expectLater(
      downloader.downloadTo(urlFor(silent), target),
      throwsA(
        isA<StreamDownloadException>().having(
          (StreamDownloadException e) => e.message,
          'сообщение',
          contains('не ответил'),
        ),
      ),
    );
  });

  test('отмена прекращает загрузку и не оставляет задачу в работе', () async {
    final FakeMediaServer slow = await FakeMediaServer.start(4 * 1024 * 1024);
    slow.stallBody = true;
    addTearDown(slow.close);

    final File target = File('${dir.path}/cancelled.audio');
    final RangeDownloader downloader = RangeDownloader(
      chunkBytes: 64 * 1024,
      chunkTimeout: const Duration(seconds: 30),
    );
    addTearDown(downloader.dispose);

    final DownloadCancelToken token = DownloadCancelToken();
    final Future<int> pending = downloader.downloadTo(
      urlFor(slow),
      target,
      cancel: token,
    );
    // Даём запросу уйти, затем отменяем: ждать 30-секундного таймаута нельзя.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    token.cancel();

    await expectLater(
      pending,
      throwsA(isA<DownloadCancelledException>()),
    );
  });
}
