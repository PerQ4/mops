// Сквозная проверка цепочки прокси от настроек до запроса.
//
// Сеть не нужна: поднимаются настоящий SOCKS5-туннель и локальный HTTP-сервер,
// а приложение ходит к серверу «через прокси». Это тот самый путь, которым
// при обходе скачивается звук.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:mops/core/net/fronting.dart';

/// Настоящий SOCKS5-прокси: выполняет рукопожатие и туннелирует трафик.
///
/// Написан на одном обработчике с фазами: у `Socket` только одна подписка,
/// поэтому и рукопожатие, и туннель обслуживает один и тот же слушатель.
class TestSocks5Proxy {
  TestSocks5Proxy(this._server);

  static Future<TestSocks5Proxy> start() async {
    final ServerSocket server =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final TestSocks5Proxy proxy = TestSocks5Proxy(server);
    server.listen(proxy._handle);
    return proxy;
  }

  static const int _greeting = 0;
  static const int _request = 1;
  static const int _tunnel = 2;

  final ServerSocket _server;
  final List<Socket> _opened = <Socket>[];

  /// Сколько раз прокси попросили соединиться — доказательство, что он
  /// действительно использовался.
  int connectCount = 0;

  int get port => _server.port;

  Future<void> close() async {
    for (final Socket socket in _opened) {
      socket.destroy();
    }
    await _server.close();
  }

  void _handle(Socket client) {
    _opened.add(client);

    final List<int> buffer = <int>[];
    final List<List<int>> pending = <List<int>>[];
    int phase = _greeting;
    Socket? target;

    client.listen(
      (List<int> data) {
        if (phase == _tunnel) {
          // Данные приложения — целевому серверу. Пока соединение
          // устанавливается, копим их, чтобы ничего не потерять.
          final Socket? current = target;
          if (current != null) {
            current.add(data);
          } else {
            pending.add(data);
          }
          return;
        }

        buffer.addAll(data);

        if (phase == _greeting) {
          if (buffer.length < 2) return;
          if (buffer[0] != 0x05) {
            client.destroy();
            return;
          }
          final int methods = buffer[1];
          if (buffer.length < 2 + methods) return;
          buffer.removeRange(0, 2 + methods);
          client.add(<int>[0x05, 0x00]); // выбран метод без авторизации
          phase = _request;
        }

        if (phase != _request) return;
        if (buffer.length < 5) return;

        final int atyp = buffer[3];
        final int addressLength;
        if (atyp == 0x01) {
          addressLength = 4;
        } else if (atyp == 0x03) {
          addressLength = 1 + buffer[4];
        } else {
          client.destroy();
          return;
        }

        final int needed = 4 + addressLength + 2;
        if (buffer.length < needed) return;

        final String host = atyp == 0x01
            ? buffer.sublist(4, 8).join('.')
            : utf8.decode(buffer.sublist(5, 5 + buffer[4]));
        final int port = (buffer[needed - 2] << 8) | buffer[needed - 1];

        final List<int> leftover = buffer.length > needed
            ? buffer.sublist(needed)
            : const <int>[];
        buffer.clear();
        phase = _tunnel;

        connectCount++;
        _connectAndTunnel(
          client,
          host,
          port,
          leftover,
          onReady: (Socket established) {
            target = established;
            for (final List<int> chunk in pending) {
              established.add(chunk);
            }
            pending.clear();
          },
        );
      },
      onDone: () => target?.destroy(),
      onError: (Object _) => target?.destroy(),
      cancelOnError: false,
    );
  }

  Future<void> _connectAndTunnel(
    Socket client,
    String host,
    int port,
    List<int> leftover, {
    required void Function(Socket target) onReady,
  }) async {
    Socket established;
    try {
      established = await Socket.connect(host, port,
          timeout: const Duration(seconds: 5));
    } on Object {
      // Код 1 — общий сбой.
      client.add(<int>[0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
      await client.flush();
      client.destroy();
      return;
    }

    _opened.add(established);
    client.add(<int>[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
    await client.flush();
    onReady(established);

    if (leftover.isNotEmpty) established.add(leftover);

    established.listen(
      (List<int> data) => client.add(data),
      onDone: client.destroy,
      onError: (Object _) => client.destroy(),
      cancelOnError: false,
    );
  }
}

void main() {
  late TestSocks5Proxy proxy;
  late HttpServer server;

  setUp(() async {
    proxy = await TestSocks5Proxy.start();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      request.response
        ..statusCode = 200
        ..write('звук доставлен');
      await request.response.close();
    });
  });

  tearDown(() async {
    await BypassManager.instance.dispose();
    await proxy.close();
    await server.close(force: true);
  });

  test('SOCKS5 из настроек действительно используется для запросов', () async {
    await BypassManager.instance.apply(
      AntiDpiConfig(
        fronting: const FrontingConfig(enabled: false),
        proxyKind: ProxyKind.socks5,
        proxyHost: '127.0.0.1',
        proxyPort: proxy.port,
      ),
    );

    expect(BypassManager.instance.isActive, isTrue);

    final HttpClient client = HttpClient();
    final HttpClientRequest request = await client
        .getUrl(Uri.parse('http://127.0.0.1:${server.port}/track'));
    final HttpClientResponse response = await request.close();
    final String body = await response.transform(utf8.decoder).join();
    client.close(force: true);

    expect(response.statusCode, 200);
    expect(body, 'звук доставлен');
    // Главное: соединение шло через прокси, а не напрямую.
    expect(proxy.connectCount, greaterThan(0));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('при выключенном обходе прокси не задействован', () async {
    await BypassManager.instance
        .apply(const AntiDpiConfig(fronting: FrontingConfig(enabled: false)));

    final HttpClient client = HttpClient();
    final HttpClientRequest request = await client
        .getUrl(Uri.parse('http://127.0.0.1:${server.port}/direct'));
    final HttpClientResponse response = await request.close();
    await response.drain<void>();
    client.close(force: true);

    expect(response.statusCode, 200);
    expect(proxy.connectCount, 0);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
