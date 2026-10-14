import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Ошибка загрузки потока с понятным пользователю текстом.
class StreamDownloadException implements Exception {
  StreamDownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Скачивает файл по частям с заголовком `Range`.
///
/// **Почему частями.** Медиасерверы YouTube отдают файл только по заголовку
/// `Range` с явно заданным диапазоном: запрос без него или с открытым
/// диапазоном (`bytes=0-`) получает `403 Forbidden`. Поэтому файл качается
/// кусками фиксированного размера.
///
/// Зависит только от `dart:io` — благодаря этому проверяется обычным
/// `dart run`, без запуска Flutter.
class RangeDownloader {
  RangeDownloader({
    HttpClient? client,
    this.chunkBytes = defaultChunkBytes,
    this.userAgent = defaultUserAgent,
    this.chunkTimeout = const Duration(seconds: 30),
  }) : _client = client ?? HttpClient();

  /// Размер части. Проверено на живом соединении: сервер принимает
  /// диапазоны до 1 МБ, а более крупные отвечает 403 — поэтому ровно 1 МБ.
  static const int defaultChunkBytes = 1024 * 1024;

  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0';

  final HttpClient _client;
  final int chunkBytes;
  final String userAgent;
  final Duration chunkTimeout;

  /// Скачивает [url] в файл [target].
  ///
  /// Возвращает число записанных байт. [onProgress] получает значение
  /// от 0 до 1, когда сервер сообщает общий размер.
  Future<int> downloadTo(
    Uri url,
    File target, {
    void Function(double progress)? onProgress,
  }) async {
    final IOSink sink = target.openWrite();

    int written = 0;
    int? total;

    try {
      while (true) {
        if (total != null && written >= total) break;

        final int start = written;
        final int end = start + chunkBytes - 1;
        final _Chunk chunk = await _fetch(url, start, end);

        if (chunk.bytes.isEmpty) break;

        sink.add(chunk.bytes);
        written += chunk.bytes.length;

        total ??= chunk.total;
        final int? known = total;
        onProgress?.call(known == null ? 0 : (written / known).clamp(0.0, 1.0));

        // Часть короче запрошенной — файл закончился.
        if (chunk.bytes.length < chunkBytes) break;
      }

      await sink.flush();
      await sink.close();
    } on Object {
      await sink.close();
      rethrow;
    }

    if (written == 0) {
      throw StreamDownloadException(
        'Сервер не отдал ни одного байта трека. Проверьте обход блокировок.',
      );
    }
    onProgress?.call(1);
    return written;
  }

  /// Запрашивает один диапазон.
  Future<_Chunk> _fetch(Uri url, int start, int end) async {
    final HttpClientRequest request = await _client.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    // Без явного диапазона медиасервер отвечает 403.
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');

    final HttpClientResponse response =
        await request.close().timeout(chunkTimeout);

    if (response.statusCode == 416) {
      // Запросили за концом файла — значит, он уже скачан целиком.
      await response.drain<void>();
      return const _Chunk(<int>[], null);
    }

    if (response.statusCode != 200 && response.statusCode != 206) {
      await response.drain<void>();
      throw StreamDownloadException(_explain(response.statusCode, start));
    }

    final int? total = _parseTotal(response.headers);
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> part in response) {
      builder.add(part);
    }
    return _Chunk(builder.takeBytes(), total);
  }

  /// Объясняет ошибку так, чтобы было понятно, что делать.
  ///
  /// На практике встречаются две разные причины, и путать их нельзя:
  /// сервер может быть просто недоступен (нужен обход), а может
  /// **сознательно ограничивать поток** — тогда обход не поможет.
  String _explain(int statusCode, int start) {
    if (statusCode == 403 && start == 0) {
      return 'YouTube не отдал этот поток: сервер ответил 403. '
          'Обычно помогает прокси или VPN.';
    }
    if (statusCode == 403) {
      return 'YouTube отдаёт только начало трека и отвечает 403 на остальное '
          '(смещение $start). Это ограничение для вашего адреса: проверено, '
          'что вход в аккаунт его не снимает, помогает прокси или VPN.';
    }
    if (statusCode == 404) {
      return 'Поток не найден (HTTP 404). Возможно, трек удалён, недоступен '
          'в регионе, или обход исказил запрос.';
    }
    return 'Сервер вернул HTTP $statusCode при загрузке трека.';
  }

  /// Достаёт общий размер файла из `Content-Range: bytes 0-1023/4096`.
  int? _parseTotal(HttpHeaders headers) {
    final String? range = headers.value(HttpHeaders.contentRangeHeader);
    if (range == null) {
      final int length = headers.contentLength;
      return length > 0 ? length : null;
    }
    final int slash = range.lastIndexOf('/');
    if (slash < 0) return null;
    return int.tryParse(range.substring(slash + 1));
  }

  void dispose() => _client.close(force: true);
}

/// Одна скачанная часть.
class _Chunk {
  const _Chunk(this.bytes, this.total);

  final List<int> bytes;
  final int? total;
}
