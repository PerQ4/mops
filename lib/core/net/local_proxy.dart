import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'anti_dpi.dart';

/// Найденный локальный прокси.
class LocalProxy {
  const LocalProxy({
    required this.kind,
    required this.host,
    required this.port,
    this.note,
  });

  final ProxyKind kind;
  final String host;
  final int port;

  /// Откуда узнали (для интерфейса): например «v2rayA».
  final String? note;

  String get label => '$host:$port';

  @override
  String toString() => '${kind.name} $label${note == null ? '' : " ($note)"}';
}

/// Ищет локальный прокси, через который доступен медиахост.
///
/// Зачем: провайдер блокирует YouTube по имени домена в TLS, и медиафайлы
/// (`*.googlevideo.com`) так же недоступны. Подмена хоста их не обходит —
/// у медиасервера собственный backend. Зато обычный локальный прокси решает
/// задачу целиком.
///
/// Многие клиенты (v2rayA, v2rayN, Clash, Tor и другие) при запуске поднимают
/// SOCKS5 или HTTP-прокси на предсказуемом порту. Приложение перебирает такие
/// порты и **проверяет каждый настоящим подключением** к медиахосту — то есть
/// находит только тот, который действительно работает.
abstract final class LocalProxyDetector {
  /// Хост, доступность которого проверяем. Это тот самый медиасервер,
  /// из-за которого звук не играет.
  static const String probeHost = 'redirector.googlevideo.com';
  static const int probePort = 443;

  /// Сколько ждать ответа от одного кандидата.
  static const Duration perCandidateTimeout = Duration(milliseconds: 1200);

  /// Известные пары «порт → тип прокси» с названием клиента.
  static const List<({int port, ProxyKind kind, String note})> candidates =
      <({int port, ProxyKind kind, String note})>[
    // v2rayA — самый частый случай на Linux.
    (port: 20170, kind: ProxyKind.socks5, note: 'v2rayA'),
    (port: 20171, kind: ProxyKind.http, note: 'v2rayA'),
    // v2rayN / v2rayNG
    (port: 10808, kind: ProxyKind.socks5, note: 'v2rayN'),
    (port: 10809, kind: ProxyKind.http, note: 'v2rayN'),
    // Clash / Mihomo
    (port: 7890, kind: ProxyKind.http, note: 'Clash'),
    (port: 7891, kind: ProxyKind.socks5, note: 'Clash'),
    (port: 7897, kind: ProxyKind.http, note: 'Clash Verge'),
    // Sing-box / Nekoray и прочие
    (port: 2080, kind: ProxyKind.socks5, note: 'Sing-box'),
    (port: 1080, kind: ProxyKind.socks5, note: 'SOCKS5'),
    (port: 1081, kind: ProxyKind.socks5, note: 'SOCKS5'),
    (port: 1087, kind: ProxyKind.http, note: 'HTTP'),
    (port: 8080, kind: ProxyKind.http, note: 'HTTP'),
    (port: 8118, kind: ProxyKind.http, note: 'Privoxy'),
    (port: 8888, kind: ProxyKind.http, note: 'HTTP'),
    (port: 3128, kind: ProxyKind.http, note: 'Squid'),
    // Tor
    (port: 9050, kind: ProxyKind.socks5, note: 'Tor'),
    (port: 9150, kind: ProxyKind.socks5, note: 'Tor Browser'),
  ];

  /// Перебирает кандидатов и возвращает первый рабочий.
  ///
  /// Проверки идут параллельно — иначе последовательный перебор известных
  /// портов занимал бы десятки секунд. Из сработавших выбирается самый
  /// приоритетный: список отсортирован по частоте встречаемости.
  ///
  /// [candidates] подменяется в тестах, чтобы не зависеть от портов машины.
  static Future<LocalProxy?> find({
    void Function(LocalProxy proxy)? onFound,
    List<({int port, ProxyKind kind, String note})>? candidates,
  }) async {
    final List<({int port, ProxyKind kind, String note})> list =
        candidates ?? LocalProxyDetector.candidates;

    final List<Future<bool>> checks = <Future<bool>>[
      for (final ({int port, ProxyKind kind, String note}) candidate in list)
        _tunnelWorks(
          kind: candidate.kind,
          proxyHost: '127.0.0.1',
          proxyPort: candidate.port,
        ),
    ];

    final List<bool> results = await Future.wait(checks);

    for (int i = 0; i < list.length; i++) {
      if (!results[i]) continue;
      final ({int port, ProxyKind kind, String note}) candidate = list[i];
      final LocalProxy proxy = LocalProxy(
        kind: candidate.kind,
        host: '127.0.0.1',
        port: candidate.port,
        note: candidate.note,
      );
      onFound?.call(proxy);
      return proxy;
    }
    return null;
  }

  /// Проверяет, что через прокси устанавливается туннель до медиахоста.
  ///
  /// Успешный ответ прокси означает, что он сам подключился к медиасерверу —
  /// этого достаточно, чтобы утверждать: звук пойдёт.
  static Future<bool> _tunnelWorks({
    required ProxyKind kind,
    required String proxyHost,
    required int proxyPort,
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        proxyHost,
        proxyPort,
        timeout: perCandidateTimeout,
      );
      socket.setOption(SocketOption.tcpNoDelay, true);

      return kind == ProxyKind.socks5
          ? await _socks5Tunnel(socket, perCandidateTimeout)
          : await _httpTunnel(socket, perCandidateTimeout);
    } on Object {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  /// SOCKS5: приветствие, затем CONNECT на медиахост.
  static Future<bool> _socks5Tunnel(Socket socket, Duration timeout) async {
    final _Reader reader = _Reader(socket);

    socket.add(<int>[0x05, 0x01, 0x00]);
    await socket.flush();

    final List<int> greeting =
        await reader.read(2).timeout(timeout, onTimeout: () => <int>[]);
    if (greeting.length < 2 || greeting[0] != 0x05 || greeting[1] != 0x00) {
      return false;
    }

    final List<int> host = utf8.encode(probeHost);
    socket.add(<int>[
      0x05,
      0x01,
      0x00,
      0x03,
      host.length,
      ...host,
      (probePort >> 8) & 0xFF,
      probePort & 0xFF,
    ]);
    await socket.flush();

    final List<int> reply =
        await reader.read(4).timeout(timeout, onTimeout: () => <int>[]);
    // Код ответа 0 — соединение установлено.
    return reply.length >= 2 && reply[0] == 0x05 && reply[1] == 0x00;
  }

  /// HTTP: CONNECT на медиахост, ожидаем 200.
  static Future<bool> _httpTunnel(Socket socket, Duration timeout) async {
    socket.write('CONNECT $probeHost:$probePort HTTP/1.1\r\n'
        'Host: $probeHost:$probePort\r\n'
        'Proxy-Connection: keep-alive\r\n\r\n');
    await socket.flush();

    final _Reader reader = _Reader(socket);
    final List<int> head =
        await reader.readUntil((List<int> buffer) => buffer.contains(0x0A))
            .timeout(timeout, onTimeout: () => <int>[]);

    final String line = String.fromCharCodes(head);
    final RegExpMatch? status =
        RegExp(r'HTTP/\d\.\d\s+(\d{3})').firstMatch(line);
    return status != null && status.group(1) == '200';
  }
}

/// Буферизованное чтение из сокета ровно столько байт, сколько нужно.
class _Reader {
  _Reader(Socket socket) {
    _subscription = socket.listen(
      (List<int> data) {
        _buffer.addAll(data);
        _notify();
      },
      onDone: () {
        _closed = true;
        _notify();
      },
      onError: (Object _) {
        _closed = true;
        _notify();
      },
      cancelOnError: false,
    );
  }

  final List<int> _buffer = <int>[];
  late final StreamSubscription<List<int>> _subscription;
  Completer<void>? _waiter;
  bool _closed = false;

  Future<List<int>> read(int count) async {
    while (_buffer.length < count) {
      if (_closed) return <int>[];
      _waiter = Completer<void>();
      await _waiter!.future;
      _waiter = null;
    }
    final List<int> result = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return result;
  }

  /// Читает до тех пор, пока [isDone] не вернёт true (для строк HTTP).
  Future<List<int>> readUntil(bool Function(List<int>) isDone) async {
    while (!isDone(_buffer)) {
      if (_closed) break;
      _waiter = Completer<void>();
      await _waiter!.future;
      _waiter = null;
    }
    final List<int> result = List<int>.of(_buffer);
    _buffer.clear();
    unawaited(_subscription.cancel());
    return result;
  }

  void _notify() {
    final Completer<void>? waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }
}
