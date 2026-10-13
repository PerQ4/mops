import 'dart:async';
import 'dart:io';

import 'anti_dpi.dart';
import 'fronting.dart';

/// Применяет обход блокировок ко всему приложению.
///
/// Два независимых механизма:
///
///  * **Подмена хоста (domain fronting).** Соединение идёт на разрешённый узел
///    Google, а настоящее имя передаётся в заголовке `Host`. Обходит и
///    SNI-блокировку, и фильтрацию DNS. Не требует внешних сервисов.
///  * **Прокси SOCKS5 / HTTP.** Если у пользователя есть свой прокси, весь
///    трафик идёт через него.
///
/// Устанавливается глобально через `HttpOverrides`, поэтому действует на всё
/// сразу: `package:http`, загрузку обложек, `youtube_explode_dart`.
class BypassManager {
  BypassManager._();

  static final BypassManager instance = BypassManager._();

  FragmentingRelay? _relay;

  /// Что применено сейчас. `null` — ещё ничего не применялось.
  ///
  /// Важно отличать «не применялось» от «применены настройки по умолчанию»:
  /// иначе первый вызов `apply` с конфигурацией по умолчанию был бы пропущен
  /// как «уже применённый», и обход не установился бы вовсе.
  AntiDpiConfig? _applied;

  /// Что применяется сейчас.
  AntiDpiConfig get applied => _applied ?? const AntiDpiConfig();

  /// Активен ли обход.
  bool get isActive => _applied?.isEnabled ?? false;

  /// Порт локального узла (для SOCKS5), если он поднят.
  int? get relayPort => _relay?.port;

  /// Применяет конфигурацию. Можно вызывать повторно при смене настроек.
  Future<void> apply(AntiDpiConfig config) async {
    final AntiDpiConfig? previous = _applied;
    if (previous != null && _sameAs(previous, config)) return;

    // Снимаем прошлое состояние, чтобы не накладывать обходы друг на друга.
    await _teardown();
    _applied = config;

    if (!config.isEnabled) {
      return; // обход выключен — работает обычный стек
    }

    // Собираем цепочку: сначала прокси, поверх него — подмена хоста.
    HttpOverrides? chain;

    if (config.usesProxy && config.proxyKind == ProxyKind.http) {
      // HTTP-прокси (в том числе CONNECT для HTTPS) dart:io умеет сам.
      chain = _ProxyOverrides(config);
    } else if (config.usesProxy && config.proxyKind == ProxyKind.socks5) {
      // SOCKS5 dart:io не умеет — поднимаем локальный узел и ходим через него.
      final FragmentingRelay relay = await FragmentingRelay.start(config);
      _relay = relay;
      chain = _SocksOverrides(config, relay.port);
    }

    if (config.fronting.enabled) {
      chain = FrontedHttpOverrides(config.fronting, chain);
    }

    HttpOverrides.global = chain;
  }

  bool _sameAs(AntiDpiConfig a, AntiDpiConfig b) {
    return a.fronting.enabled == b.fronting.enabled &&
        a.fronting.frontHost == b.fronting.frontHost &&
        a.proxyKind == b.proxyKind &&
        a.proxyHost == b.proxyHost &&
        a.proxyPort == b.proxyPort &&
        a.proxyUsername == b.proxyUsername &&
        a.proxyPassword == b.proxyPassword &&
        a.fragmentation == b.fragmentation;
  }

  Future<void> _teardown() async {
    HttpOverrides.global = null;

    final FragmentingRelay? relay = _relay;
    _relay = null;
    if (relay != null) await relay.close();
  }

  Future<void> dispose() => _teardown();
}

/// SOCKS5 через локальный узел.
///
/// `dart:io` не поддерживает SOCKS, поэтому соединение заводится на локальный
/// узел, который сам делает рукопожатие с прокси.
class _SocksOverrides extends HttpOverrides {
  _SocksOverrides(this._config, this._relayPort);

  final AntiDpiConfig _config;
  final int _relayPort;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final HttpClient client = super.createHttpClient(context);
    client.findProxy = (Uri _) => 'DIRECT';

    client.connectionFactory = (
      Uri url,
      String? proxyHost,
      int? proxyPort,
    ) async {
      final Socket socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _relayPort,
        timeout: const Duration(seconds: 20),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);

      final StringBuffer header = StringBuffer()
        ..write('socks5 ${_config.proxyHost} ${_config.proxyPort} ')
        ..write('${url.host} ${url.port}');
      if (_config.proxyUsername.isNotEmpty) {
        header.write(' ${_config.proxyUsername} ${_config.proxyPassword}');
      }
      socket.write('$header\n');

      return ConnectionTask.fromSocket<Socket>(
        Future<Socket>.value(socket),
        socket.destroy,
      );
    };

    return client;
  }
}

/// Прокси через `findProxy` — для HTTP-прокси этого достаточно,
/// рукопожатие CONNECT для HTTPS dart:io делает сам.
class _ProxyOverrides extends HttpOverrides {
  _ProxyOverrides(this._config);

  final AntiDpiConfig _config;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final HttpClient client = super.createHttpClient(context);
    final String authority = '${_config.proxyHost}:${_config.proxyPort}';
    client.findProxy = (Uri _) => 'PROXY $authority';

    if (_config.proxyUsername.isNotEmpty) {
      client.authenticateProxy = (
        String host,
        int port,
        String scheme,
        String? realm,
      ) async {
        return true;
      };
      client.addProxyCredentials(
        _config.proxyHost,
        _config.proxyPort,
        '',
        HttpClientBasicCredentials(
          _config.proxyUsername,
          _config.proxyPassword,
        ),
      );
    }
    return client;
  }
}
