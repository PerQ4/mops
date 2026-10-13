import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'fronting.dart';

/// ---------------------------------------------------------------------------
/// Настройки обхода DPI
/// ---------------------------------------------------------------------------

/// Тип прокси для обхода блокировок.
enum ProxyKind {
  none('Не использовать'),
  socks5('SOCKS5'),
  http('HTTP / HTTPS');

  const ProxyKind(this.label);

  final String label;

  static ProxyKind fromName(String? name) => ProxyKind.values.firstWhere(
        (ProxyKind k) => k.name == name,
        orElse: () => ProxyKind.none,
      );
}

/// Насколько агрессивно дробить TLS ClientHello.
///
/// Провайдер ищет имя домена (SNI) в первом пакете соединения. Если разбить
/// ClientHello на несколько TCP-сегментов, имя перестаёт попадать в один
/// пакет и правило не срабатывает.
enum FragmentationLevel {
  off('Выключено'),
  soft('Мягко — 4 сегмента', chunkSize: 1, maxBytes: 4),
  medium('Средне — 64 сегмента', chunkSize: 1, maxBytes: 64),
  aggressive('Агрессивно — 200 сегментов', chunkSize: 1, maxBytes: 200);

  const FragmentationLevel(
    this.label, {
    this.chunkSize = 1,
    this.maxBytes = 0,
  });

  final String label;

  /// Сколько байт отправлять за раз.
  final int chunkSize;

  /// Сколько первых байт ClientHello дробить (дальше — как обычно).
  final int maxBytes;

  bool get enabled => this != FragmentationLevel.off;

  static FragmentationLevel fromName(String? name) =>
      FragmentationLevel.values.firstWhere(
        (FragmentationLevel l) => l.name == name,
        orElse: () => FragmentationLevel.off,
      );
}

/// Полная конфигурация обхода.
class AntiDpiConfig {
  const AntiDpiConfig({
    this.fronting = const FrontingConfig(),
    this.fragmentation = FragmentationLevel.off,
    this.fragmentDelayMs = 1,
    this.proxyKind = ProxyKind.none,
    this.proxyHost = '',
    this.proxyPort = 1080,
    this.proxyUsername = '',
    this.proxyPassword = '',
  });

  /// Подмена хоста — основной механизм, не требует внешних сервисов.
  final FrontingConfig fronting;

  final FragmentationLevel fragmentation;

  /// Пауза между фрагментами. С `tcpNoDelay` даже 1 мс достаточно,
  /// чтобы сегменты не склеились обратно.
  final int fragmentDelayMs;

  final ProxyKind proxyKind;
  final String proxyHost;
  final int proxyPort;
  final String proxyUsername;
  final String proxyPassword;

  bool get fragments => fragmentation.enabled;
  bool get usesProxy =>
      proxyKind != ProxyKind.none && proxyHost.trim().isNotEmpty;

  /// Нужен ли локальный перенаправляющий узел.
  ///
  /// Он требуется, если мы дробим пакеты, либо если прокси — SOCKS5
  /// (dart:io умеет только HTTP-прокси, поэтому рукопожатие делаем сами).
  bool get needsRelay =>
      fragments || (usesProxy && proxyKind == ProxyKind.socks5);

  /// Нужен ли обход вообще.
  bool get isEnabled => fronting.enabled || usesProxy || fragments;

  Duration get fragmentDelay => Duration(milliseconds: fragmentDelayMs);

  AntiDpiConfig copyWith({
    FrontingConfig? fronting,
    FragmentationLevel? fragmentation,
    int? fragmentDelayMs,
    ProxyKind? proxyKind,
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
  }) {
    return AntiDpiConfig(
      fronting: fronting ?? this.fronting,
      fragmentation: fragmentation ?? this.fragmentation,
      fragmentDelayMs: fragmentDelayMs ?? this.fragmentDelayMs,
      proxyKind: proxyKind ?? this.proxyKind,
      proxyHost: proxyHost ?? this.proxyHost,
      proxyPort: proxyPort ?? this.proxyPort,
      proxyUsername: proxyUsername ?? this.proxyUsername,
      proxyPassword: proxyPassword ?? this.proxyPassword,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'frontingEnabled': fronting.enabled,
        'frontHost': fronting.frontHost,
        'fragmentation': fragmentation.name,
        'fragmentDelayMs': fragmentDelayMs,
        'proxyKind': proxyKind.name,
        'proxyHost': proxyHost,
        'proxyPort': proxyPort,
        'proxyUsername': proxyUsername,
        'proxyPassword': proxyPassword,
      };

  factory AntiDpiConfig.fromJson(Map<String, dynamic> json) {
    return AntiDpiConfig(
      fronting: FrontingConfig(
        enabled: json['frontingEnabled'] as bool? ?? false,
        frontHost: _string(json['frontHost'], FrontingConfig.defaultFrontHost),
      ),
      fragmentation:
          FragmentationLevel.fromName(json['fragmentation'] as String?),
      fragmentDelayMs: _int(json['fragmentDelayMs'], 1),
      proxyKind: ProxyKind.fromName(json['proxyKind'] as String?),
      proxyHost: _string(json['proxyHost'], ''),
      proxyPort: _int(json['proxyPort'], 1080),
      proxyUsername: _string(json['proxyUsername'], ''),
      proxyPassword: _string(json['proxyPassword'], ''),
    );
  }

  /// Читает строку, не падая на неожиданном типе.
  static String _string(Object? value, String fallback) =>
      value is String ? value : fallback;

  /// Читает число, не падая на неожиданном типе.
  static int _int(Object? value, int fallback) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }
}

/// ---------------------------------------------------------------------------
/// Локальный перенаправляющий узел
/// ---------------------------------------------------------------------------

/// Принимает соединения от приложения, устанавливает реальное соединение
/// (напрямую или через SOCKS5) и дробит первый пакет от клиента.
///
/// Зачем понадобился промежуточный узел: перехватить запись в сокет со стороны
/// `HttpClient` нельзя, а вот управлять потоком байтов на своей стороне —
/// можно. Поэтому приложение подключается к себе же на localhost, а узел
/// делает всё остальное.
///
/// Формат запроса (одна строка, сразу за ней идут данные):
/// ```
/// direct <host> <port>\n
/// socks5 <proxyHost> <proxyPort> <host> <port> [<user> <pass>]\n
/// ```
class FragmentingRelay {
  FragmentingRelay._(this._server, this._config);

  final ServerSocket _server;
  final AntiDpiConfig _config;

  final Set<Socket> _sockets = <Socket>{};

  /// Порт, на котором слушает узел (на localhost).
  int get port => _server.port;

  static Future<FragmentingRelay> start(AntiDpiConfig config) async {
    final ServerSocket server =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final FragmentingRelay relay = FragmentingRelay._(server, config);
    server.listen(
      relay._handleClient,
      onError: (Object _) {},
      cancelOnError: false,
    );
    return relay;
  }

  Future<void> close() async {
    for (final Socket socket in _sockets.toList()) {
      socket.destroy();
    }
    _sockets.clear();
    await _server.close();
  }

  Future<void> _handleClient(Socket client) async {
    _sockets.add(client);
    try {
      client.setOption(SocketOption.tcpNoDelay, true);
    } on SocketException {
      // Не критично: без tcpNoDelay сегменты могут слипаться.
    }

    final _RelaySession session = _RelaySession(
      client: client,
      config: _config,
      onClosed: (Socket socket) => _sockets.remove(socket),
    );
    await session.run();
  }
}

/// Одно соединение через узел.
class _RelaySession {
  _RelaySession({
    required this.client,
    required this.config,
    required this.onClosed,
  });

  final Socket client;
  final AntiDpiConfig config;
  final void Function(Socket socket) onClosed;

  final List<int> _buffer = <int>[];
  Socket? _target;
  StreamSubscription<List<int>>? _clientSub;
  StreamSubscription<List<int>>? _targetSub;

  bool _headerParsed = false;
  bool _firstPayloadSent = false;

  /// У `Socket` нет признака «разрушен», поэтому отмечаем закрытие сами.
  bool _clientClosed = false;
  bool _targetClosed = false;

  bool _finished = false;

  Future<void> run() async {
    final Completer<void> headerReady = Completer<void>();

    _clientSub = client.listen(
      (List<int> data) {
        if (!_headerParsed) {
          _buffer.addAll(data);
          final int newline = _buffer.indexOf(0x0A);
          if (newline < 0) return; // строка ещё не пришла целиком
          final String line = utf8.decode(_buffer.sublist(0, newline));
          final List<int> rest = _buffer.sublist(newline + 1);
          _buffer.clear();
          _headerParsed = true;
          _connect(line, rest).then((_) {
            if (!headerReady.isCompleted) headerReady.complete();
          }).catchError((Object error, StackTrace _) {
            if (!headerReady.isCompleted) headerReady.completeError(error);
          });
          return;
        }
        _forwardToTarget(data);
      },
      onDone: () {
        _clientClosed = true;
        _shutdown();
      },
      onError: (Object _) {
        _clientClosed = true;
        _shutdown();
      },
      cancelOnError: false,
    );

    try {
      await headerReady.future;
    } on Object {
      _shutdown();
    }
  }

  /// Устанавливает соединение с целевым сервером (при необходимости — через SOCKS5).
  Future<void> _connect(String header, List<int> rest) async {
    final List<String> parts = header.trim().split(RegExp(r'\s+'));

    late final String host;
    late final int port;
    Socket socket;

    if (parts.isNotEmpty && parts.first == 'socks5' && parts.length >= 5) {
      final String proxyHost = parts[1];
      final int proxyPort = int.parse(parts[2]);
      host = parts[3];
      port = int.parse(parts[4]);
      final String? user = parts.length > 5 ? parts[5] : null;
      final String? password = parts.length > 6 ? parts[6] : null;

      socket = await Socket.connect(
        proxyHost,
        proxyPort,
        timeout: const Duration(seconds: 15),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      await Socks5Client.negotiate(
        socket,
        targetHost: host,
        targetPort: port,
        username: user,
        password: password,
      );
    } else {
      // direct <host> <port>
      host = parts.length >= 3 ? parts[1] : parts[0];
      port = parts.length >= 3 ? int.parse(parts[2]) : 443;
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 15),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
    }

    _target = socket;
    _targetSub = socket.listen(
      (List<int> data) {
        if (!_clientClosed) client.add(data);
      },
      onDone: () {
        _targetClosed = true;
        _shutdown();
      },
      onError: (Object _) {
        _targetClosed = true;
        _shutdown();
      },
      cancelOnError: false,
    );

    // Байты, пришедшие вместе со строкой-заголовком, — это уже начало полезной
    // нагрузки (часто там сразу TLS ClientHello).
    if (rest.isNotEmpty) _forwardToTarget(rest);
  }

  /// Пересылает данные целевому серверу, дробя первый пакет.
  void _forwardToTarget(List<int> data) {
    final Socket? target = _target;
    if (target == null || _targetClosed) return;

    if (_firstPayloadSent || !config.fragments) {
      _firstPayloadSent = true;
      target.add(data);
      return;
    }

    _firstPayloadSent = true;
    _sendFragmented(target, data);
  }

  /// Дробит первый пакет: сначала мелкие части (в них попадает SNI),
  /// затем остаток одним куском.
  void _sendFragmented(Socket target, List<int> data) {
    final int chunk = config.fragmentation.chunkSize.clamp(1, 1024);
    final int limit = config.fragmentation.maxBytes.clamp(0, data.length);
    final Duration delay = config.fragmentDelay;

    // Отправка идёт цепочкой, чтобы порядок байтов не нарушился.
    Future<void> chain = Future<void>.value();

    for (int offset = 0; offset < limit; offset += chunk) {
      final int end = (offset + chunk).clamp(0, limit);
      final List<int> piece = data.sublist(offset, end);
      chain = chain.then((_) async {
        if (_targetClosed) return;
        target.add(piece);
        if (delay > Duration.zero) await Future<void>.delayed(delay);
      });
    }

    if (limit < data.length) {
      final List<int> tail = data.sublist(limit);
      chain = chain.then((_) {
        if (!_targetClosed) target.add(tail);
      });
    }
  }

  void _shutdown() {
    if (_finished) return;
    _finished = true;
    _clientSub?.cancel();
    _targetSub?.cancel();
    final Socket? target = _target;
    if (target != null) {
      onClosed(target);
      target.destroy();
    }
    if (!_clientClosed) {
      onClosed(client);
      client.destroy();
    }
  }
}

/// ---------------------------------------------------------------------------
/// SOCKS5
/// ---------------------------------------------------------------------------

/// Минимальный клиент SOCKS5: dart:io не умеет SOCKS, поэтому рукопожатие
/// делаем вручную.
abstract final class Socks5Client {
  static const int _version = 0x05;
  static const int _noAuth = 0x00;
  static const int _userPass = 0x02;

  /// Выполняет рукопожатие и CONNECT на уже открытом сокете.
  static Future<void> negotiate(
    Socket socket, {
    required String targetHost,
    required int targetPort,
    String? username,
    String? password,
  }) async {
    final _SocketReader reader = _SocketReader(socket);

    final bool useAuth =
        username != null && username.isNotEmpty && password != null;

    // 1. Приветствие: какие методы поддерживаем.
    socket.add(<int>[
      _version,
      useAuth ? 2 : 1,
      _noAuth,
      if (useAuth) _userPass,
    ]);
    await socket.flush();

    final List<int> greeting = await reader.read(2);
    if (greeting[0] != _version) {
      throw const SocketException('SOCKS5: неверная версия ответа');
    }
    final int method = greeting[1];
    if (method == 0xFF) {
      throw const SocketException(
        'SOCKS5: прокси не принял ни один способ авторизации',
      );
    }

    // 2. Авторизация по логину и паролю (если выбрана).
    if (method == _userPass) {
      if (!useAuth) {
        throw const SocketException('SOCKS5: прокси требует логин и пароль');
      }
      final List<int> user = utf8.encode(username);
      final List<int> pass = utf8.encode(password);
      socket.add(<int>[
        0x01,
        user.length,
        ...user,
        pass.length,
        ...pass,
      ]);
      await socket.flush();

      final List<int> authReply = await reader.read(2);
      if (authReply[1] != 0x00) {
        throw const SocketException('SOCKS5: неверный логин или пароль');
      }
    } else if (method != _noAuth) {
      throw SocketException('SOCKS5: неподдерживаемый метод $method');
    }

    // 3. Запрос на соединение. Домен шлём как имя — так прокси сам его разрешит.
    final List<int> host = utf8.encode(targetHost);
    socket.add(<int>[
      _version,
      0x01, // CONNECT
      0x00, // зарезервировано
      0x03, // тип адреса: доменное имя
      host.length,
      ...host,
      (targetPort >> 8) & 0xFF,
      targetPort & 0xFF,
    ]);
    await socket.flush();

    // 4. Ответ: 4 байта заголовка + адрес + порт.
    final List<int> reply = await reader.read(4);
    if (reply[1] != 0x00) {
      throw SocketException('SOCKS5: отказ в соединении (код ${reply[1]})');
    }

    switch (reply[3]) {
      case 0x01:
        await reader.read(4 + 2);
      case 0x04:
        await reader.read(16 + 2);
      case 0x03:
        final List<int> length = await reader.read(1);
        await reader.read(length[0] + 2);
      default:
        throw const SocketException('SOCKS5: неизвестный тип адреса в ответе');
    }
  }
}

/// Читает ровно N байт из сокета, сохраняя излишек в буфере.
///
/// Нужен потому, что сокет отдаёт данные произвольными порциями, а протокол
/// SOCKS5 требует точных размеров.
class _SocketReader {
  _SocketReader(Socket socket) {
    _subscription = socket.listen(
      (List<int> data) {
        _buffer.addAll(data);
        _notify();
      },
      onDone: () {
        _closed = true;
        _notify();
      },
      onError: (Object error) {
        _error = error;
        _notify();
      },
      cancelOnError: false,
    );
  }

  final List<int> _buffer = <int>[];
  late final StreamSubscription<List<int>> _subscription;
  Completer<void>? _waiter;
  bool _closed = false;
  Object? _error;

  void _notify() {
    final Completer<void>? waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  Future<List<int>> read(int count) async {
    while (_buffer.length < count) {
      if (_error != null) throw _error!;
      if (_closed) {
        throw const SocketException('SOCKS5: соединение закрыто прокси');
      }
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    final List<int> result = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return result;
  }

  Future<void> cancel() => _subscription.cancel();
}
