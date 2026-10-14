import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Локальный посредник между плеером и медиасервером YouTube.
///
/// Зачем он нужен. Медиасервер отдаёт данные только на запрос с заголовком
/// `Range`: обычный GET (и открытый диапазон `bytes=0-`) получают `403`.
/// GStreamer, которым играет `audioplayers`, запрашивает поток обычным GET и
/// поэтому падает с «Internal data stream error».
///
/// Посредник принимает запросы GStreamer на `127.0.0.1` и сам качает поток у
/// YouTube кусками по мегабайту, отдавая данные по мере поступления. За счёт
/// этого трек начинает играть сразу — без полной загрузки файла, — и работает
/// перемотка: на запрос диапазона посредник качает нужный участок.
///
/// Отдельно есть предзагрузка ([warm]): пока играет текущий трек, посредник
/// заранее качает начало следующего, чтобы переключение шло без паузы.
class StreamProxy {
  StreamProxy({
    HttpClient? client,
    this.chunkSize = 1024 * 1024,
    this.warmBytes = 8 * 1024 * 1024,
    this.verbose = false,
  }) : _client = client ?? HttpClient() {
    // Keep-alive по умолчанию живёт 15 секунд. Пока плеер проигрывает уже
    // скачанный кусок, соединение с медиасервером успевает закрыться, и
    // следующий запрос падал бы на «мёртвом» сокете. Увеличиваем окно,
    // а от обрывов на той стороне страхует повтор в [_fetchWithRetry].
    _client.idleTimeout = const Duration(minutes: 2);
  }

  /// Печатать в журнал запросы плеера — для отладки.
  final bool verbose;

  /// Размер куска при загрузке у YouTube. Больше мегабайта сервер не отдаёт.
  final int chunkSize;

  /// Сколько байт следующего трека скачивать заранее. Ограничение важно:
  /// посредник держит их в памяти, а треки бывают и по часу.
  final int warmBytes;

  final HttpClient _client;

  /// Сколько раз повторять запрос куска при сбое. 403 у медиасервера бывает
  /// разовым, а соединение из пула — уже закрытым: одиночный сбой не должен
  /// обрывать звук.
  static const int _attempts = 5;

  /// Источники по токену (для обработчика запросов) и по ключу (чтобы
  /// повторный `serve` того же потока вернул тот же адрес и прогретое).
  final Map<String, _Source> _byToken = <String, _Source>{};
  final Map<String, _Source> _byKey = <String, _Source>{};

  HttpServer? _server;
  int _counter = 0;

  /// Публикует поток и возвращает локальный адрес для плеера.
  Future<Uri> serve(Uri source, {String? userAgent, String? mimeType}) async {
    final _Source published =
        await _ensureSource(source, userAgent: userAgent, mimeType: mimeType);
    return _localUri(published);
  }

  /// Заранее качает начало потока, не подключая плеер.
  ///
  /// Возвращает тот же локальный адрес, что и [serve]: при переключении трека
  /// первый запрос GStreamer застанет данные уже в памяти.
  Future<Uri> warm(Uri source, {String? userAgent, String? mimeType}) async {
    final _Source published =
        await _ensureSource(source, userAgent: userAgent, mimeType: mimeType);
    unawaited(_prefetch(published));
    return _localUri(published);
  }

  /// Забывает поток (после смены трека).
  void release(Uri local) {
    final String token =
        local.pathSegments.isEmpty ? '' : local.pathSegments.first;
    final _Source? source = _byToken.remove(token);
    if (source == null) return;
    // Ключ удаляем только если он всё ещё указывает на этот источник:
    // тот же адрес могли опубликовать повторно.
    if (identical(_byKey[source.key], source)) {
      _byKey.remove(source.key);
    }
  }

  Future<void> dispose() async {
    _byToken.clear();
    _byKey.clear();
    await _server?.close(force: true);
    _server = null;
    _client.close(force: true);
  }

  // ------------------------------------------------------------- внутреннее

  String _keyOf(Uri source, String? userAgent, String? mimeType) =>
      '${source.toString()}|${userAgent ?? ''}|${mimeType ?? ''}';

  Future<_Source> _ensureSource(
    Uri source, {
    String? userAgent,
    String? mimeType,
  }) async {
    final String key = _keyOf(source, userAgent, mimeType);
    final _Source? existing = _byKey[key];
    if (existing != null) return existing;

    await _ensureServer();
    final _Source created = _Source(
      url: source,
      key: key,
      userAgent: userAgent,
      mimeType: mimeType,
    );
    created.token = 's${_counter++}';
    _byKey[key] = created;
    _byToken[created.token!] = created;
    return created;
  }

  Uri _localUri(_Source source) {
    final int port = _server?.port ?? 0;
    return Uri.parse('http://127.0.0.1:$port/${source.token}');
  }

  Future<HttpServer> _ensureServer() async {
    final HttpServer? existing = _server;
    if (existing != null) return existing;

    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(
      _handle,
      onError: (Object _) {},
      cancelOnError: false,
    );
    return server;
  }

  Future<void> _handle(HttpRequest request) async {
    final String token =
        request.uri.pathSegments.isEmpty ? '' : request.uri.pathSegments.first;
    final _Source? source = _byToken[token];
    if (source == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    try {
      await _pipe(request, source);
    } on Object {
      // Плеер мог закрыть соединение при перемотке — это не ошибка.
      try {
        await request.response.close();
      } on Object {
        // уже закрыто
      }
    }
  }

  Future<void> _pipe(HttpRequest request, _Source source) async {
    // Качает у YouTube всё равно один поток, и это будет поток плеера.
    // Фоновый прогрев уступает, чтобы не тянуть один и тот же файл дважды.
    source.streaming = true;

    final int total = await _totalSize(source);

    int start = 0;
    int? requestedEnd;
    final String? rangeHeader =
        request.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null) {
      final RegExpMatch? match =
          RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
      if (match != null) {
        start = int.tryParse(match.group(1)!) ?? 0;
        final String end = match.group(2)!;
        if (end.isNotEmpty) requestedEnd = int.tryParse(end);
      }
    }

    final int last = requestedEnd ?? (total > 0 ? total - 1 : -1);
    final bool partial = rangeHeader != null;

    // Диапазон за концом файла: так бывает при перемотке в конец.
    if (total > 0 && start >= total) {
      request.response.statusCode =
          HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers
          .set(HttpHeaders.contentRangeHeader, 'bytes */$total');
      await request.response.close();
      return;
    }

    request.response.statusCode =
        partial ? HttpStatus.partialContent : HttpStatus.ok;
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (source.mimeType != null) {
      request.response.headers.contentType =
          ContentType.parse(source.mimeType!);
    }
    if (total > 0) {
      request.response.headers.set(
        HttpHeaders.contentLengthHeader,
        '${last - start + 1}',
      );
      if (partial) {
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$last/$total',
        );
      }
    }

    // Плеер может проверять доступность заголовком HEAD — тело ему не нужно.
    if (request.method == 'HEAD') {
      await request.response.close();
      return;
    }

    if (verbose) {
      // ignore: avoid_print
      print('[Proxy] ${request.method} range=$rangeHeader total=$total '
          'start=$start last=$last cached=${source.cached}');
    }

    int offset = start;
    String stopReason = 'дошли до конца';

    // Сначала отдаём то, что успели скачать заранее. Именно это убирает
    // паузу при переключении на прогретый трек.
    if (source.cached > offset) {
      final Uint8List buffered = source.cache.toBytes();
      int available = buffered.length;
      if (last >= 0 && available > last + 1) available = last + 1;
      if (available > offset) {
        request.response.add(Uint8List.sublistView(buffered, offset, available));
        await request.response.flush();
        offset = available;
      }
    }

    while (offset <= last || last < 0) {
      final int chunkEnd =
          last < 0 ? offset + chunkSize - 1 : math.min(offset + chunkSize - 1, last);
      final List<int> bytes = await _fetchWithRetry(source, offset, chunkEnd);
      if (bytes.isEmpty) {
        // Медиасервер кончился раньше обещанного размера: поток усечён.
        stopReason = 'пустой кусок на $offset';
        break;
      }
      request.response.add(bytes);
      await request.response.flush();
      offset += bytes.length;
    }

    if (verbose) {
      // Счётчик отданного вместе с ожидаемым `clen`: если `отдано` меньше,
      // поток усечён (медиасервер не отдал весь файл), и виноват не плеер.
      // ignore: avoid_print
      print('[Proxy] итог start=$start last=$last total=$total '
          'отдано=${offset - start} причина=$stopReason');
    }
    await request.response.close();
  }

  /// Фоновая докачка начала файла в память источника.
  Future<void> _prefetch(_Source source) async {
    if (source.warming || source.streaming) return;
    source.warming = true;
    try {
      final int total = await _totalSize(source);
      final int limit = total > 0 ? math.min(total, warmBytes) : warmBytes;
      while (!source.streaming && source.cached < limit) {
        final int start = source.cached;
        final int end = math.min(start + chunkSize - 1, limit - 1);
        final List<int> bytes = await _fetchWithRetry(source, start, end);
        if (bytes.isEmpty) break;
        source.cache.add(bytes);
        // Отдаём управление циклу событий: пока прогрев идёт, посредник
        // должен успевать обслуживать запросы плеера.
        await Future<void>.delayed(Duration.zero);
      }
      if (verbose) {
        // ignore: avoid_print
        print('[Proxy] прогрето ${source.cached} байт');
      }
    } on Object catch (error) {
      // Предзагрузка не критична: если не вышло, трек начнётся как обычно.
      if (verbose) {
        // ignore: avoid_print
        print('[Proxy] прогрев прерван: $error');
      }
    } finally {
      source.warming = false;
    }
  }

  /// Скачивает участок с медиасервера, повторяя запрос при сбое.
  ///
  /// Диапазон обязан быть закрытым. Одиночный сбой куска (403, обрыв,
  /// протухшее keep-alive-соединение) не должен закрывать ответ плееру:
  /// иначе поток оборвётся на середине — это и давало «минуту и тишину».
  Future<List<int>> _fetchWithRetry(_Source source, int start, int end) async {
    Object? lastError;
    for (int attempt = 1; attempt <= _attempts; attempt++) {
      try {
        return await _fetch(source, start, end);
      } on Object catch (error) {
        lastError = error;
        if (verbose) {
          // ignore: avoid_print
          print('[Proxy] повтор $attempt/$_attempts '
              '($start-$end): ${error.toString().split('\n').first}');
        }
        // Пауза растёт: разовый 403 обычно проходит со второй попытки.
        await Future<void>.delayed(Duration(milliseconds: 150 * attempt));
      }
    }
    throw lastError ?? HttpException('Медиасервер не отдал диапазон $start-$end');
  }

  /// Скачивает участок с медиасервера. Диапазон обязан быть закрытым.
  Future<List<int>> _fetch(_Source source, int start, int end) async {
    final HttpClientRequest request = await _client.getUrl(source.url);
    if (source.userAgent != null) {
      request.headers.set(HttpHeaders.userAgentHeader, source.userAgent!);
    }
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');

    final HttpClientResponse response =
        await request.close().timeout(const Duration(seconds: 30));

    if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
      // Запросили за концом файла — данных больше нет.
      await response.drain<void>();
      return const <int>[];
    }

    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>();
      throw HttpException('Медиасервер вернул ${response.statusCode}');
    }

    // Ответ 200 на запрос со смещением означает, что диапазон проигнорирован.
    // Принять такие данные нельзя: они придут не с того места, и звук
    // «съедет». Считаем это сбоем и пробуем ещё раз.
    if (response.statusCode == HttpStatus.ok && start > 0) {
      await response.drain<void>();
      throw HttpException('Медиасервер проигнорировал диапазон $start-$end');
    }

    final BytesBuilder builder = BytesBuilder(copy: false);
    // Таймаут на каждый пакет тела: медиасервер отдаёт кусок за секунды,
    // а если он завис — запрос надо повторить, а не ждать вечно.
    await for (final List<int> part
        in response.timeout(const Duration(seconds: 30))) {
      builder.add(part);
    }
    return builder.takeBytes();
  }

  /// Полный размер трека: из ссылки, а если там нет — отдельным запросом.
  Future<int> _totalSize(_Source source) async {
    final int? known = source.total;
    if (known != null) return known;

    final String? fromUrl = source.url.queryParameters['clen'];
    final int? parsed = fromUrl == null ? null : int.tryParse(fromUrl);
    if (parsed != null && parsed > 0) {
      source.total = parsed;
      return parsed;
    }

    // Пробуем узнать размер из заголовка Content-Range. Запрос повторяем:
    // первый заход может упасть на протухшем соединении из пула.
    for (int attempt = 1; attempt <= _attempts; attempt++) {
      try {
        final int size = await _probeTotalSize(source);
        if (size > 0) {
          source.total = size;
          return size;
        }
        break;
      } on Object {
        await Future<void>.delayed(Duration(milliseconds: 150 * attempt));
      }
    }
    return 0;
  }

  Future<int> _probeTotalSize(_Source source) async {
    final HttpClientRequest request = await _client.getUrl(source.url);
    if (source.userAgent != null) {
      request.headers.set(HttpHeaders.userAgentHeader, source.userAgent!);
    }
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
    final HttpClientResponse response = await request.close();
    await response.drain<void>();
    final String? contentRange =
        response.headers.value(HttpHeaders.contentRangeHeader);
    final int slash = contentRange?.lastIndexOf('/') ?? -1;
    if (slash >= 0) {
      final int? size = int.tryParse(contentRange!.substring(slash + 1));
      if (size != null && size > 0) return size;
    }
    return 0;
  }
}

/// Опубликованный поток.
class _Source {
  _Source({
    required this.url,
    required this.key,
    this.userAgent,
    this.mimeType,
  });

  final Uri url;
  final String key;
  final String? userAgent;
  final String? mimeType;

  /// Токен в локальном адресе.
  String? token;

  /// Полный размер, узнаётся один раз.
  int? total;

  /// Байты с начала файла, скачанные заранее. Плеер забирает их первым делом,
  /// поэтому прогретый трек начинает звучать без паузы.
  final BytesBuilder cache = BytesBuilder(copy: false);

  /// Плеер уже подключился: фоновый прогрев больше не нужен.
  bool streaming = false;

  /// Прогрев уже идёт — второй запускать нельзя.
  bool warming = false;

  /// Сколько байт с начала уже в [cache].
  int get cached => cache.length;
}
