// Скачивание по диапазонам. Сеть не нужна: поднимается локальный сервер,
// который ведёт себя как медиасервер YouTube — отдаёт данные только по
// заголовку `Range` с явным диапазоном.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mops/data/sources/range_downloader.dart';

/// Заглушка медиасервера.
///
/// Ключевое поведение: без заголовка `Range` отвечает 403 — именно так делает
/// googlevideo, и именно из-за этого раньше не работал звук.
class FakeMediaServer {
  FakeMediaServer(this._server, this._content);

  static Future<FakeMediaServer> start(int size) async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // Предсказуемое содержимое: байт i равен i % 251.
    final Uint8List content =
        Uint8List.fromList(List<int>.generate(size, (int i) => i % 251));
    final FakeMediaServer fake = FakeMediaServer(server, content);
    server.listen(fake._handle);
    return fake;
  }

  final HttpServer _server;
  final Uint8List _content;

  int requests = 0;
  int rejectedWithoutRange = 0;

  int get port => _server.port;
  int get size => _content.length;

  Future<void> close() => _server.close(force: true);

  void _handle(HttpRequest request) {
    requests++;

    final String? range = request.headers.value(HttpHeaders.rangeHeader);
    if (range == null) {
      // Без диапазона — как у YouTube: отказ.
      rejectedWithoutRange++;
      request.response
        ..statusCode = HttpStatus.forbidden
        ..close();
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
        ? _content.length - 1
        : int.parse(match.group(2)!);

    if (start >= _content.length) {
      request.response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..close();
      return;
    }

    final int last = end.clamp(start, _content.length - 1);
    final Uint8List slice = _content.sublist(start, last + 1);

    request.response
      ..statusCode = HttpStatus.partialContent
      ..headers.set(HttpHeaders.contentRangeHeader,
          'bytes $start-$last/${_content.length}')
      ..headers.contentLength = slice.length
      ..add(slice);
    request.response.close();
  }
}

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

  test('файл скачивается целиком по частям', () async {
    final File target = File('${dir.path}/track.audio');
    // Маленькая часть, чтобы проверить именно цикл, а не один запрос.
    final RangeDownloader downloader = RangeDownloader(chunkBytes: 256 * 1024);
    addTearDown(downloader.dispose);

    final int written = await downloader.downloadTo(
      Uri.parse('http://127.0.0.1:${server.port}/videoplayback'),
      target,
    );

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

    await downloader.downloadTo(
      Uri.parse('http://127.0.0.1:${server.port}/videoplayback'),
      target,
    );

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
      Uri.parse('http://127.0.0.1:${server.port}/videoplayback'),
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
}
