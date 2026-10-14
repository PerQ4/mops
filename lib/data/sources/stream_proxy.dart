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
class StreamProxy {
  StreamProxy({
    HttpClient? client,
    this.chunkSize = 1024 * 1024,
    this.verbose = false,
  }) : _client = client ?? HttpClient();

  /// Печатать в журнал запросы плеера — для отладки.
  final bool verbose;

  /// Размер куска при загрузке у YouTube. Больше мегабайта сервер не отдаёт.
  final int chunkSize;

  final HttpClient _client;

  /// Источники по токенам: `token -> ссылка googlevideo`.
  final Map<String, _Source> _sources = <String, _Source>{};

  HttpServer? _server;
  int _counter = 0;

  /// Публикует поток и возвращает локальный адрес для плеера.
  Future<Uri> serve(Uri source, {String? userAgent, String? mimeType}) async {
    final HttpServer server = await _ensureServer();
    final String token = 's${_counter++}';
    _sources[token] = _Source(
      url: source,
      userAgent: userAgent,
      mimeType: mimeType,
    );
    return Uri.parse('http://127.0.0.1:${server.port}/$token');
  }

  /// Забывает поток (после смены трека).
  void release(Uri local) {
    _sources.remove(local.pathSegments.isEmpty ? '' : local.pathSegments.first);
  }

  Future<void> dispose() async {
    _sources.clear();
    await _server?.close(force: true);
    _server = null;
    _client.close(force: true);
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
    final _Source? source = _sources[token];
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
          'start=$start last=$last');
    }

    int offset = start;
    while (offset <= last || last < 0) {
      final int chunkEnd =
          last < 0 ? offset + chunkSize - 1 : math.min(offset + chunkSize - 1, last);
      final List<int> bytes = await _fetch(source, offset, chunkEnd);
      if (bytes.isEmpty) break;
      request.response.add(bytes);
      await request.response.flush();
      offset += bytes.length;
    }

    if (verbose) {
      // ignore: avoid_print
      print('[Proxy] отдано ${offset - start} байт');
    }
    await request.response.close();
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
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>();
      throw HttpException('Медиасервер вернул ${response.statusCode}');
    }

    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> part in response) {
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

    // Пробуем узнать размер из заголовка Content-Range.
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
      if (size != null && size > 0) {
        source.total = size;
        return size;
      }
    }
    return 0;
  }
}

/// Опубликованный поток.
class _Source {
  _Source({required this.url, this.userAgent, this.mimeType});

  final Uri url;
  final String? userAgent;
  final String? mimeType;

  /// Полный размер, узнаётся один раз.
  int? total;
}
