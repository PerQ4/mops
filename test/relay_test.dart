// Проверка локального узла обхода: он должен туннелировать соединение
// и дробить первый пакет на отдельные порции.
//
// Сеть не используется: сервер и клиент живут на 127.0.0.1.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mops/core/net/anti_dpi.dart';

void main() {
  test('узел туннелирует данные в обе стороны', () async {
    final ServerSocket server =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);

    // Эхо-сервер: отвечает тем же, что получил.
    final Future<List<List<int>>> received = () async {
      final List<List<int>> chunks = <List<int>>[];
      final Completer<void> done = Completer<void>();
      server.listen((Socket socket) {
        socket.listen(
          (List<int> data) {
            chunks.add(data);
            socket.add(data);
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
        );
      });
      return chunks;
    }();

    final FragmentingRelay relay =
        await FragmentingRelay.start(const AntiDpiConfig());
    addTearDown(() async {
      await relay.close();
      await server.close();
    });

    final Socket client =
        await Socket.connect(InternetAddress.loopbackIPv4, relay.port);
    client.write('direct 127.0.0.1 ${server.port}\n');
    client.write('привет');
    await client.flush();

    final List<int> echoed = await client.first.timeout(
      const Duration(seconds: 5),
    );
    expect(echoed, equals(utf8.encode('привет')));

    client.destroy();
    await received.timeout(const Duration(seconds: 5), onTimeout: () => <List<int>>[]);
  });

  test('первый пакет дробится на несколько частей', () async {
    final List<int> received = <int>[];
    final Completer<void> gotData = Completer<void>();

    final ServerSocket server =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    int readCount = 0;
    server.listen((Socket socket) {
      // Читаем с задержкой: так ядро отдаёт данные теми порциями,
      // которыми они были записаны.
      late final StreamSubscription<List<int>> sub;
      sub = socket.listen((List<int> data) {
        readCount++;
        received.addAll(data);
        if (!gotData.isCompleted && received.length >= 200) {
          gotData.complete();
        }
        sub.pause(Future<void>.delayed(const Duration(milliseconds: 60)));
      });
    });

    final FragmentingRelay relay = await FragmentingRelay.start(
      const AntiDpiConfig(
        fragmentation: FragmentationLevel.medium,
        fragmentDelayMs: 2,
      ),
    );
    addTearDown(() async {
      await relay.close();
      await server.close();
    });

    final Socket client =
        await Socket.connect(InternetAddress.loopbackIPv4, relay.port);
    client.write('direct 127.0.0.1 ${server.port}\n');
    // Имитируем TLS ClientHello: 300 байт одним куском.
    client.add(List<int>.generate(300, (int i) => i % 256));
    await client.flush();

    await gotData.future.timeout(const Duration(seconds: 5));
    client.destroy();

    // Дробление не должно терять или менять данные.
    expect(received.length, 300);
    for (int i = 0; i < 300; i++) {
      expect(received[i], i % 256);
    }

    // И это действительно было несколько порций, а не одна.
    // Именно на этом основан обход: DPI должен видеть разрозненные куски.
    expect(readCount, greaterThan(1),
        reason: 'первый пакет не раздроблен: прочитано $readCount раз');
  });
}
