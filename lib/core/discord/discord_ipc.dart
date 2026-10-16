import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Низкоуровневый клиент локального Discord IPC (Rich Presence).
///
/// Discord слушает именованный пайп (Windows) или unix-сокет (Linux, macOS) и
/// общается кадрами: 4 байта opcode + 4 байта длины (оба little-endian), затем
/// JSON в UTF-8. Поддерживаются opcodes: 0 — handshake, 1 — frame, 2 — close,
/// 3 — ping, 4 — pong.
///
/// Пакет `discord_rpc` заброшен и тянет нативную библиотеку через FFI, поэтому
/// протокол реализован здесь напрямую на `dart:io` — без лишних зависимостей.

/// Коды операций Discord RPC.
abstract final class DiscordOpcode {
  static const int handshake = 0;
  static const int frame = 1;
  static const int close = 2;
  static const int ping = 3;
  static const int pong = 4;
}

/// Ошибка протокола или соединения с Discord.
class DiscordIpcException implements Exception {
  const DiscordIpcException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Один кадр протокола.
class _Frame {
  const _Frame(this.opcode, this.payload);

  final int opcode;
  final Map<String, dynamic> payload;
}

/// Транспорт кадров: пайп или сокет. Абстракция нужна, чтобы клиент не знал
/// о различиях платформ.
abstract class DiscordIpcTransport {
  Future<void> connect();
  Future<Uint8List> read(int length);
  Future<void> write(List<int> bytes);
  Future<void> close();
}

/// Windows: именованный пайп через `dart:io`.
///
/// Работает только форма `\\?\pipe\<имя>`: обычный `\\.\pipe\<имя>` движок
/// принимает за сетевой путь и падает с errno 53. Режим `FileMode.write`
/// открывает пайп на чтение и запись — этого достаточно для протокола.
class _WindowsPipeTransport implements DiscordIpcTransport {
  _WindowsPipeTransport(this.path);

  final String path;
  RandomAccessFile? _file;

  @override
  Future<void> connect() async {
    _file = await File(path).open(mode: FileMode.write);
  }

  @override
  Future<Uint8List> read(int length) async {
    final RandomAccessFile file = _file!;
    final BytesBuilder builder = BytesBuilder(copy: false);
    while (builder.length < length) {
      final Uint8List chunk = await file.read(length - builder.length);
      if (chunk.isEmpty) {
        throw const DiscordIpcException('Discord закрыл соединение');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<void> write(List<int> bytes) async {
    final RandomAccessFile file = _file!;
    await file.writeFrom(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
  }

  @override
  Future<void> close() async {
    final RandomAccessFile? file = _file;
    _file = null;
    if (file == null) return;
    try {
      await file.close();
    } on Object {
      // Пайп уже мог закрыться со стороны Discord — это не ошибка.
    }
  }
}

/// Linux и macOS: unix-сокет через `dart:io`.
class _UnixSocketTransport implements DiscordIpcTransport {
  _UnixSocketTransport(this.path);

  final String path;
  Socket? _socket;
  StreamIterator<Uint8List>? _iterator;
  final List<int> _buffer = <int>[];

  @override
  Future<void> connect() async {
    final Socket socket = await Socket.connect(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    _socket = socket;
    final StreamController<Uint8List> incoming =
        StreamController<Uint8List>();
    socket.listen(
      (Uint8List data) => incoming.add(data),
      onError: (Object error) => incoming.addError(error),
      onDone: () => incoming.close(),
      cancelOnError: false,
    );
    _iterator = StreamIterator<Uint8List>(incoming.stream);
  }

  @override
  Future<Uint8List> read(int length) async {
    final StreamIterator<Uint8List> iterator = _iterator!;
    while (_buffer.length < length) {
      if (!await iterator.moveNext()) {
        throw const DiscordIpcException('Discord закрыл соединение');
      }
      _buffer.addAll(iterator.current);
    }
    final Uint8List result = Uint8List.fromList(_buffer.sublist(0, length));
    _buffer.removeRange(0, length);
    return result;
  }

  @override
  Future<void> write(List<int> bytes) async {
    final Socket? socket = _socket;
    if (socket == null) throw const DiscordIpcException('Нет соединения');
    socket.add(bytes);
    await socket.flush();
  }

  @override
  Future<void> close() async {
    final Socket? socket = _socket;
    _socket = null;
    _iterator = null;
    _buffer.clear();
    if (socket == null) return;
    try {
      await socket.close();
    } on Object {
      // Сокет уже мог закрыться — это не ошибка.
    }
  }
}

/// Клиент Discord IPC: подключение, рукопожатие, отправка активности.
///
/// Чтение и запись строго чередуются: `RandomAccessFile` (пайп Windows) не
/// допускает две одновременные операции на одном дескрипторе, поэтому фонового
/// читателя нет — ответ читается сразу после каждой команды.
class DiscordIpcClient {
  DiscordIpcClient(this.applicationId, {this.paths});

  /// Application ID приложения из Discord Developer Portal.
  final String applicationId;

  /// Явные пути пайпов/сокетов — для тестов; иначе перебираются стандартные.
  final List<String>? paths;

  DiscordIpcTransport? _transport;
  bool _connected = false;
  int _nonce = 0;

  bool get isConnected => _connected;

  /// Подключается к Discord и выполняет рукопожатие.
  Future<void> connect() async {
    final DiscordIpcTransport transport = await _openTransport();
    _transport = transport;
    await _send(DiscordOpcode.handshake, <String, dynamic>{
      'v': 1,
      'client_id': applicationId,
    });

    // Discord отвечает кадром READY. Если пришёл close — рукопожатие отклонено.
    final _Frame ready = await _readFrame(
      timeout: const Duration(seconds: 10),
    );
    if (ready.opcode == DiscordOpcode.close) {
      throw const DiscordIpcException('Discord отклонил подключение');
    }
    _connected = true;
  }

  /// Отправляет активность; `null` очищает presence.
  Future<void> setActivity(Map<String, dynamic>? activity) async {
    if (!_connected) {
      throw const DiscordIpcException('Нет соединения с Discord');
    }
    final String nonce = _nextNonce();
    await _send(DiscordOpcode.frame, <String, dynamic>{
      'cmd': 'SET_ACTIVITY',
      'args': <String, dynamic>{
        'pid': pid,
        'activity': activity,
      },
      'nonce': nonce,
    });
    await _awaitResponse(nonce);
  }

  /// Закрывает соединение. Идемпотентно.
  Future<void> close() async {
    _connected = false;
    final DiscordIpcTransport? transport = _transport;
    _transport = null;
    if (transport != null) await transport.close();
  }

  // ------------------------------------------------------------- private

  /// Читает кадры до ответа на [nonce]; попутно отвечает на ping.
  Future<void> _awaitResponse(String nonce) async {
    while (true) {
      final _Frame frame = await _readFrame(
        timeout: const Duration(seconds: 10),
      );
      if (frame.opcode == DiscordOpcode.ping) {
        await _send(DiscordOpcode.pong, frame.payload);
        continue;
      }
      if (frame.opcode == DiscordOpcode.close) {
        throw const DiscordIpcException('Discord закрыл соединение');
      }
      if (frame.opcode == DiscordOpcode.frame) {
        final Object? responseNonce = frame.payload['nonce'];
        if (responseNonce == null || responseNonce == nonce) return;
      }
    }
  }

  Future<DiscordIpcTransport> _openTransport() async {
    Object? lastError;
    for (final String path in paths ?? _candidatePaths()) {
      final DiscordIpcTransport transport = _transportFor(path);
      try {
        await transport.connect();
        return transport;
      } on Object catch (error) {
        lastError = error;
        await transport.close();
      }
    }
    throw DiscordIpcException('Discord IPC недоступен: $lastError');
  }

  DiscordIpcTransport _transportFor(String path) => Platform.isWindows
      ? _WindowsPipeTransport(path)
      : _UnixSocketTransport(path);

  /// Пути пайпов/сокетов Discord: индексы 0..9 для нескольких запущенных
  /// клиентов, а также каталоги snap и flatpak.
  Iterable<String> _candidatePaths() sync* {
    if (Platform.isWindows) {
      for (int i = 0; i < 10; i++) {
        yield '\\\\?\\pipe\\discord-ipc-$i';
      }
      return;
    }

    final String? runtime = Platform.environment['XDG_RUNTIME_DIR'];
    final List<String> directories = <String>[
      if (runtime != null && runtime.isNotEmpty) runtime,
      if (Platform.environment['TMPDIR']?.isNotEmpty ?? false)
        Platform.environment['TMPDIR']!,
      if (Platform.environment['TMP']?.isNotEmpty ?? false)
        Platform.environment['TMP']!,
      if (Platform.environment['TEMP']?.isNotEmpty ?? false)
        Platform.environment['TEMP']!,
      '/tmp',
      // Snap и Flatpak держат сокет в своём каталоге.
      if (runtime != null && runtime.isNotEmpty) '$runtime/snap.discord',
      if (runtime != null && runtime.isNotEmpty)
        '$runtime/app/com.discordapp.Discord',
    ];
    for (final String directory in directories) {
      for (int i = 0; i < 10; i++) {
        yield '$directory/discord-ipc-$i';
      }
    }
  }

  Future<void> _send(int opcode, Map<String, dynamic> payload) async {
    final DiscordIpcTransport? transport = _transport;
    if (transport == null) throw const DiscordIpcException('Нет соединения');

    final Uint8List body =
        Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final Uint8List header = Uint8List(8);
    final ByteData view = ByteData.sublistView(header);
    view.setUint32(0, opcode, Endian.little);
    view.setUint32(4, body.length, Endian.little);

    final BytesBuilder builder = BytesBuilder(copy: false)
      ..add(header)
      ..add(body);
    await transport.write(builder.takeBytes());
  }

  Future<_Frame> _readFrame({Duration? timeout}) {
    final Future<_Frame> future = _readFrameRaw();
    if (timeout == null) return future;
    return future.timeout(timeout, onTimeout: () {
      // Зависшее чтение снимаем закрытием соединения — иначе следующая
      // операция на дескрипторе упадёт с «async operation is pending».
      unawaited(close());
      throw const DiscordIpcException('Discord не ответил вовремя');
    });
  }

  Future<_Frame> _readFrameRaw() async {
    final DiscordIpcTransport transport = _transport!;
    final Uint8List header = await transport.read(8);
    final ByteData view = ByteData.sublistView(header);
    final int opcode = view.getUint32(0, Endian.little);
    final int length = view.getUint32(4, Endian.little);

    Map<String, dynamic> payload = <String, dynamic>{};
    if (length > 0) {
      final Uint8List body = await transport.read(length);
      final dynamic decoded = jsonDecode(utf8.decode(body));
      if (decoded is Map<String, dynamic>) payload = decoded;
    }
    return _Frame(opcode, payload);
  }

  String _nextNonce() {
    _nonce++;
    return '${DateTime.now().microsecondsSinceEpoch}-$_nonce';
  }
}
