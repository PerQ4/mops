// Поиск локального прокси. Сеть не нужна: заглушки SOCKS5 и HTTP-прокси
// поднимаются на localhost, а детектору подставляются их порты.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/local_proxy.dart';

/// Заглушка SOCKS5: отвечает на приветствие и на CONNECT.
///
/// [allowConnect] имитирует прокси, который не может дойти до медиахоста.
Future<ServerSocket> startSocks5({bool allowConnect = true}) async {
  final ServerSocket server =
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((Socket socket) {
    final List<int> buffer = <int>[];
    socket.listen((List<int> data) {
      buffer.addAll(data);
      // Приветствие: 05 01 00 → отвечаем выбором метода без авторизации.
      if (buffer.length == 3 && buffer[0] == 0x05) {
        socket.add(<int>[0x05, 0x00]);
        buffer.clear();
        return;
      }
      // Запрос CONNECT: он заметно длиннее приветствия.
      if (buffer.length >= 7 && buffer[0] == 0x05 && buffer[1] == 0x01) {
        final String host = String.fromCharCodes(buffer.sublist(5, buffer.length - 2));
        socket.add(<int>[
          0x05,
          allowConnect ? 0x00 : 0x01,
          0x00,
          0x01,
          127,
          0,
          0,
          1,
          0,
          80,
        ]);
        buffer.clear();
        // Заглядываем в запрос, чтобы тест мог убедиться, какой хост спросили.
        _lastRequestedHost = host;
      }
    });
  });
  return server;
}

/// Заглушка HTTP-прокси, отвечающая на CONNECT.
Future<ServerSocket> startHttpProxy({bool allowConnect = true}) async {
  final ServerSocket server =
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((Socket socket) {
    final List<int> buffer = <int>[];
    socket.listen((List<int> data) {
      buffer.addAll(data);
      if (buffer.contains(0x0A) && buffer.contains(0x0D)) {
        final String request = String.fromCharCodes(buffer);
        socket.write(allowConnect
            ? 'HTTP/1.1 200 Connection established\r\n\r\n'
            : 'HTTP/1.1 403 Forbidden\r\n\r\n');
        _lastRequestedHost = request.split('\r\n').first;
        buffer.clear();
      }
    });
  });
  return server;
}

String? _lastRequestedHost;

void main() {
  setUp(() => _lastRequestedHost = null);

  test('находит SOCKS5-прокси', () async {
    final ServerSocket server = await startSocks5();
    addTearDown(server.close);

    final LocalProxy? proxy = await LocalProxyDetector.find(
      candidates: <({int port, ProxyKind kind, String note})>[
        (port: server.port, kind: ProxyKind.socks5, note: 'тест'),
      ],
    );

    expect(proxy, isNotNull);
    expect(proxy!.kind, ProxyKind.socks5);
    expect(proxy.port, server.port);
    expect(proxy.note, 'тест');
  });

  test('SOCKS5 спрашивает именно медиахост', () async {
    final ServerSocket server = await startSocks5();
    addTearDown(server.close);

    await LocalProxyDetector.find(
      candidates: <({int port, ProxyKind kind, String note})>[
        (port: server.port, kind: ProxyKind.socks5, note: 'тест'),
      ],
    );

    expect(_lastRequestedHost, LocalProxyDetector.probeHost);
  });

  test('находит HTTP-прокси', () async {
    final ServerSocket server = await startHttpProxy();
    addTearDown(server.close);

    final LocalProxy? proxy = await LocalProxyDetector.find(
      candidates: <({int port, ProxyKind kind, String note})>[
        (port: server.port, kind: ProxyKind.http, note: 'тест'),
      ],
    );

    expect(proxy, isNotNull);
    expect(proxy!.kind, ProxyKind.http);
  });

  test('прокси, не доходящий до медиахоста, не подходит', () async {
    final ServerSocket server = await startSocks5(allowConnect: false);
    addTearDown(server.close);

    final LocalProxy? proxy = await LocalProxyDetector.find(
      candidates: <({int port, ProxyKind kind, String note})>[
        (port: server.port, kind: ProxyKind.socks5, note: 'тест'),
      ],
    );

    expect(proxy, isNull);
  });

  test('закрытый порт не считается прокси', () async {
    // Порт, который наверняка свободен: привязываем и сразу закрываем.
    final ServerSocket free =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final int port = free.port;
    await free.close();

    final LocalProxy? proxy = await LocalProxyDetector.find(
      candidates: <({int port, ProxyKind kind, String note})>[
        (port: port, kind: ProxyKind.socks5, note: 'пусто'),
      ],
    );

    expect(proxy, isNull);
  });

  test('из нескольких рабочих выбирается первый по приоритету', () async {
    final ServerSocket priority = await startSocks5();
    final ServerSocket spare = await startHttpProxy();
    addTearDown(priority.close);
    addTearDown(spare.close);

    final LocalProxy? proxy = await LocalProxyDetector.find(
      candidates: <({int port, ProxyKind kind, String note})>[
        // Порядок списка задаёт приоритет: первый рабочий и побеждает.
        (port: priority.port, kind: ProxyKind.socks5, note: 'приоритетный'),
        (port: spare.port, kind: ProxyKind.http, note: 'запасной'),
      ],
    );

    expect(proxy, isNotNull);
    expect(proxy!.note, 'приоритетный');
  });

  test('если первый кандидат не работает, берётся следующий', () async {
    final ServerSocket broken = await startSocks5(allowConnect: false);
    final ServerSocket working = await startHttpProxy();
    addTearDown(broken.close);
    addTearDown(working.close);

    final LocalProxy? proxy = await LocalProxyDetector.find(
      candidates: <({int port, ProxyKind kind, String note})>[
        (port: broken.port, kind: ProxyKind.socks5, note: 'сломанный'),
        (port: working.port, kind: ProxyKind.http, note: 'рабочий'),
      ],
    );

    expect(proxy, isNotNull);
    expect(proxy!.note, 'рабочий');
  });

  test('список кандидатов покрывает частые клиенты', () {
    final Set<int> ports =
        LocalProxyDetector.candidates.map((c) => c.port).toSet();
    // Порт v2rayA: у пользователя на Linux это самый частый случай.
    expect(ports, contains(20170));
    expect(ports, contains(20171));
    expect(ports, contains(10808));
    expect(ports, contains(7890));
    expect(ports, contains(9050));
    // Дубликаты портов недопустимы.
    expect(ports.length, LocalProxyDetector.candidates.length);
  });
}
