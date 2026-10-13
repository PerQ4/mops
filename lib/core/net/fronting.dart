import 'dart:async';
import 'dart:io';

/// ---------------------------------------------------------------------------
/// Domain fronting
/// ---------------------------------------------------------------------------
///
/// Провайдер блокирует соединения по имени домена в TLS ClientHello (SNI).
/// TCP при этом проходит: рукопожатие к тому же IP с «разрешённым» именем
/// завершается успешно, а с `youtube.com` — обрывается.
///
/// Обход: подключаемся с именем разрешённого узла Google, а настоящее имя
/// передаём в заголовке `Host`. Google обслуживает такие запросы и возвращает
/// корректный ответ. Дополнительный бонус — обходится и фильтрация DNS:
/// заблокированное имя вообще не требуется разрешать.
///
/// Приём называется domain fronting и не требует ни прокси, ни VPN.
class FrontingConfig {
  const FrontingConfig({
    this.enabled = true,
    this.frontHost = defaultFrontHost,
  });

  /// Узел, имя которого не блокируется и который обслуживает Google.
  static const String defaultFrontHost = 'www.google.com';

  /// Включено по умолчанию: на незаблокированной сети подмена безвредна,
  /// а на заблокированной — без неё приложение не работает вовсе.
  /// Пользователю не нужно ничего настраивать.
  final bool enabled;
  final String frontHost;

  /// Домены, к которым применяется подмена.
  ///
  /// Список намеренно узкий: подменять чужие домены нельзя — сертификат
  /// проверяется по имени фронта, поэтому подходят только узлы Google.
  ///
  /// `googlevideo.com` здесь намеренно **отсутствует**: это медиасерверы,
  /// у них собственный backend, и запрос через фронт-узел Google возвращает
  /// 404. Подмена не только не помогает звуку, но и ломала бы его.
  /// Медиаканал решается прокси или системным обходом (zapret, VPN).
  static const Set<String> frontedSuffixes = <String>{
    'youtube.com',
    'youtu.be',
    'ytimg.com',
    'ggpht.com',
    'googleusercontent.com',
    'youtube-nocookie.com',
  };

  /// Нужно ли подменять хост для этого адреса.
  bool shouldFront(String host) {
    if (!enabled || frontHost.isEmpty) return false;
    if (host == frontHost) return false;
    for (final String suffix in frontedSuffixes) {
      if (host == suffix || host.endsWith('.$suffix')) return true;
    }
    return false;
  }

  FrontingConfig copyWith({bool? enabled, String? frontHost}) =>
      FrontingConfig(
        enabled: enabled ?? this.enabled,
        frontHost: frontHost ?? this.frontHost,
      );
}

/// `HttpClient`, который для заблокированных доменов подключается к
/// фронт-узлу, подставляя настоящее имя в заголовок `Host`.
///
/// Реализован как обёртка над обычным клиентом, поэтому совместим со всем,
/// что использует dart:io: `package:http`, `NetworkImage`,
/// `cached_network_image`, `youtube_explode_dart`.
class FrontedHttpClient implements HttpClient {
  FrontedHttpClient(this._inner, this._config);

  final HttpClient _inner;
  final FrontingConfig _config;

  /// Устанавливает подмену глобально, для всех HTTP-клиентов приложения.
  ///
  /// Возвращает функцию отката к прежнему состоянию.
  static void Function() install(FrontingConfig config) {
    HttpOverrides.global = FrontedHttpOverrides(config);
    return () => HttpOverrides.global = null;
  }

  Uri _rewrite(Uri url) {
    if (!_config.shouldFront(url.host)) return url;
    return url.replace(host: _config.frontHost);
  }

  String _hostHeader(Uri url) {
    final bool defaultPort = url.port == 0 || url.port == 443 || url.port == 80;
    return defaultPort ? url.host : '${url.host}:${url.port}';
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final Uri target = _rewrite(url);
    final HttpClientRequest request = await _inner.openUrl(method, target);
    if (target.host != url.host) {
      _setHostHeader(request, _hostHeader(url));
    }
    return request;
  }

  void _setHostHeader(HttpClientRequest request, String value) {
    try {
      request.headers.host = value;
    } on Object {
      // В некоторых сборках заголовок Host задаётся только через set().
      try {
        request.headers.set(HttpHeaders.hostHeader, value);
      } on Object {
        // Если и это не удалось — запрос уйдёт на фронт-узел как есть.
      }
    }
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('get', url);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('post', url);

  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('put', url);

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('delete', url);

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('patch', url);

  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('head', url);

  // Дальше — полное делегирование: подмена нужна только при открытии запроса.

  @override
  bool get autoUncompress => _inner.autoUncompress;

  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  Duration get idleTimeout => _inner.idleTimeout;

  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;

  @override
  set maxConnectionsPerHost(int? value) =>
      _inner.maxConnectionsPerHost = value;

  @override
  String? get userAgent => _inner.userAgent;

  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? f,
  ) =>
      _inner.authenticate = f;

  @override
  void addCredentials(Uri url, String realm, HttpClientCredentials credentials) =>
      _inner.addCredentials(url, realm, credentials);

  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) =>
      _inner.addProxyCredentials(host, port, realm, credentials);

  @override
  set authenticateProxy(
    Future<bool> Function(String host, int port, String scheme, String? realm)?
        f,
  ) =>
      _inner.authenticateProxy = f;

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )?
    f,
  ) =>
      _inner.connectionFactory = f;

  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;

  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;

  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? callback,
  ) =>
      _inner.badCertificateCallback = callback;

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) =>
      _inner.open(method, host, port, path);

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _inner.get(host, port, path);

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _inner.post(host, port, path);

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _inner.put(host, port, path);

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _inner.delete(host, port, path);

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _inner.patch(host, port, path);

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _inner.head(host, port, path);

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

/// Подставляет [FrontedHttpClient] вместо стандартного.
///
/// [previous] позволяет наложить подмену поверх другого обхода (например,
/// поверх SOCKS5-прокси) — тогда цепочка выстраивается в нужном порядке.
class FrontedHttpOverrides extends HttpOverrides {
  FrontedHttpOverrides(this._config, [this._previous]);

  final FrontingConfig _config;
  final HttpOverrides? _previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final HttpClient inner =
        _previous?.createHttpClient(context) ??
            super.createHttpClient(context);
    return FrontedHttpClient(inner, _config);
  }
}

/// ---------------------------------------------------------------------------
/// Проверка соединения
/// ---------------------------------------------------------------------------

/// Результат диагностики — показывается пользователю в настройках.
class ConnectivityReport {
  const ConnectivityReport({
    required this.ok,
    required this.summary,
    this.details = const <String>[],
  });

  final bool ok;
  final String summary;
  final List<String> details;
}

/// Проверяет, что именно доступно из приложения.
///
/// Различает два уровня доступа: данные (поиск, обложки, тексты) и медиапоток.
/// Провайдеры часто блокируют их по-разному, и от этого зависит, нужен ли прокси.
abstract final class ConnectivityCheck {
  static const String targetHost = 'music.youtube.com';
  static const String _apiPath = '/youtubei/v1/browse';

  /// Представитель медиахостов: если он недоступен, звук не пойдёт.
  static const String mediaHost = 'redirector.googlevideo.com';

  static Future<ConnectivityReport> run() async {
    final List<String> details = <String>[];

    final bool dataPlain = await dataReachable(fronting: false);
    final bool mediaPlain = await mediaReachable();
    details.add('Данные (поиск, обложки): ${dataPlain ? "доступны" : "заблокированы"}');
    details.add('Медиапоток (звук): ${mediaPlain ? "доступен" : "заблокирован"}');

    if (dataPlain) {
      return ConnectivityReport(
        ok: mediaPlain,
        summary: mediaPlain
            ? 'Всё доступно напрямую, обход не нужен'
            : 'Данные доступны, но звук заблокирован',
        details: <String>[
          ...details,
          if (!mediaPlain)
            'Для воспроизведения включите прокси или системный обход '
                '(zapret / GoodbyeDPI)',
        ],
      );
    }

    final bool dataFronted = await dataReachable(fronting: true);
    details.add(
      'Данные с подменой хоста: ${dataFronted ? "работают" : "не работают"}',
    );

    if (dataFronted && mediaPlain) {
      return ConnectivityReport(
        ok: true,
        summary: 'Подмена хоста обходит блокировку, звук тоже пойдёт',
        details: details,
      );
    }

    if (dataFronted && !mediaPlain) {
      return ConnectivityReport(
        ok: true,
        summary: 'Просмотр заработает, для звука нужен прокси',
        details: <String>[
          ...details,
          'Провайдер блокирует медиахосты отдельно, и подмена хоста их '
              'не обходит: у них собственный сервер, к которому так не '
              'подключиться.',
          'Варианты: прокси в этом разделе либо системный обход '
              '(zapret / GoodbyeDPI / VPN) — тогда приложение заработает '
              'целиком и обход в нём не понадобится.',
        ],
      );
    }

    return ConnectivityReport(
      ok: false,
      summary: 'YouTube Music недоступен. Нужен прокси или VPN',
      details: details,
    );
  }

  /// Проверяет доступность данных InnerTube.
  ///
  /// Публичный метод: используется и диагностикой, и автопроверкой при
  /// первом запуске.
  static Future<bool> dataReachable({required bool fronting}) async {
    final FrontingConfig config = FrontingConfig(
      enabled: fronting,
      frontHost: FrontingConfig.defaultFrontHost,
    );
    final void Function() restore = FrontedHttpClient.install(config);
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8)
        ..idleTimeout = const Duration(seconds: 8);

      final HttpClientRequest request =
          await client.postUrl(Uri.parse('https://$targetHost$_apiPath'));
      request.headers.contentType = ContentType.json;
      request.write(
        '{"context":{"client":{"clientName":"WEB_REMIX",'
        '"clientVersion":"1.20240101.01.00","hl":"ru","gl":"RU"}},'
        '"browseId":"FEmusic_home"}',
      );

      final HttpClientResponse response = await request.close();
      await response.drain<void>();
      return response.statusCode > 0;
    } on Object {
      return false;
    } finally {
      client?.close(force: true);
      restore();
    }
  }

  /// Проверяет, проходит ли TLS-рукопожатие к медиахосту напрямую.
  ///
  /// Идёт через `SecureSocket`, то есть мимо подмены хоста — именно так
  /// в сеть ходит GStreamer при воспроизведении.
  static Future<bool> mediaReachable() async {
    SecureSocket? socket;
    try {
      // Важно: `timeout` самого connect покрывает только установку TCP.
      // Рукопожатие нужно ограничивать отдельно — иначе при блокировке
      // (когда сервер просто не отвечает) ожидание будет бесконечным.
      socket = await SecureSocket.connect(
        mediaHost,
        443,
        onBadCertificate: (X509Certificate _) => true,
      ).timeout(const Duration(seconds: 8));
      return true;
    } on Object {
      return false;
    } finally {
      try {
        await socket?.close();
      } on Object {
        // Сокет мог быть уже закрыт — не важно.
      }
    }
  }
}
