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
  /// от 0 до 1, когда сервер сообщает общий размер; [onBytes] — сколько
  /// реально записано и сколько всего ожидается.
  ///
  /// [resume] продолжает уже начатый файл с его текущей длины, а не затирает
  /// его: обрыв связи не должен обнулять скачанное. [expectedBytes] — размер,
  /// который должен получиться в итоге; по нему проверяется, что файл не
  /// оборвался на середине, и что докачка уже закончена.
  Future<int> downloadTo(
    Uri url,
    File target, {
    void Function(double progress)? onProgress,
    void Function(int written, int? total)? onBytes,
    bool resume = false,
    int? expectedBytes,
  }) async {
    // Ожидаемый размер мог сохраниться от прежнего потока (ссылки на трек
    // живут часами). Тогда он не годится для проверки: доверяем ответу сервера.
    int? expected = expectedBytes;
    bool restart = false;

    // Не больше двух проходов: второй нужен, если сохранённый размер устарел
    // и сервер сообщил, что файл на самом деле короче остатка на диске.
    while (true) {
      int start = resume && !restart && target.existsSync()
          ? await target.length()
          : 0;
      // Остаток длиннее ожидаемого — он испорчен (например, от прежнего потока
      // другого качества): начинаем заново, иначе файл никогда не сойдётся.
      if (expected != null && start > expected) {
        start = 0;
        expected = null;
      }

      int written = start;
      int? total = expected;
      IOSink sink = start > 0
          ? target.openWrite(mode: FileMode.append)
          : target.openWrite();
      bool needRestart = false;

      void report() {
        onBytes?.call(written, total);
        final int? known = total;
        onProgress?.call(
          known == null || known <= 0
              ? 0
              : (written / known).clamp(0.0, 1.0),
        );
      }

      try {
        report();
        while (true) {
          if (total != null && written >= total) break;

          final int from = written;
          final int end = from + chunkBytes - 1;
          final _Chunk chunk = await _fetch(url, from, end);

          // 416 — запросили за концом файла. Если ждали больше, чем уже есть,
          // значит сохранённый размер относится к другому потоку.
          if (chunk.bytes.isEmpty) {
            if (expected != null) needRestart = true;
            break;
          }

          if (chunk.wholeFile) {
            // Сервер проигнорировал `Range` и отдал файл целиком с начала.
            // Дописывать его к остатку нельзя — переписываем файл заново.
            if (written > 0) {
              await sink.close();
              sink = target.openWrite();
              written = 0;
            }
            sink.add(chunk.bytes);
            written += chunk.bytes.length;
            total = chunk.bytes.length;
            // Тело ответа `200` и есть весь файл: сверять его с прежним
            // ожиданием нельзя, иначе докачка «оборвётся» на ровном месте.
            expected = written;
            report();
            break;
          }

          sink.add(chunk.bytes);
          written += chunk.bytes.length;

          total ??= chunk.total;
          report();

          // Часть короче запрошенной — файл закончился.
          if (chunk.bytes.length < chunkBytes) break;
        }

        await sink.flush();
        await sink.close();
      } on Object {
        // Сохраняем то, что успело дойти, — отсюда продолжится докачка.
        await _closeQuietly(sink);
        rethrow;
      }

      if (needRestart) {
        // Остаток на диске относится к другому потоку: удаляем его и качаем
        // заново в этом же вызове, иначе файл навсегда останется обрезанным.
        restart = true;
        expected = null;
        continue;
      }

      if (written == 0) {
        throw StreamDownloadException(
          'Сервер не отдал ни одного байта трека. Проверьте обход блокировок.',
        );
      }
      final int? awaited = expected ?? total;
      if (awaited != null && written < awaited) {
        throw StreamDownloadException(
          'Загрузка оборвалась: получено $written из $awaited байт. '
          'Повторите — докачка продолжится с этого места.',
        );
      }
      onBytes?.call(written, written);
      onProgress?.call(1);
      return written;
    }
  }

  /// Закрывает приёмник, не теряя уже записанное.
  Future<void> _closeQuietly(IOSink sink) async {
    try {
      await sink.flush();
    } on Object {
      // Файл всё равно закрываем ниже.
    }
    try {
      await sink.close();
    } on Object {
      // Ошибку записи уже несёт исходное исключение.
    }
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
    // `200` вместо `206` — диапазон не учтён, в ответе файл целиком.
    return _Chunk(
      builder.takeBytes(),
      total,
      wholeFile: response.statusCode == 200,
    );
  }

  /// Объясняет ошибку так, чтобы было понятно, что делать.
  ///
  /// На практике встречаются две разные причины, и путать их нельзя:
  /// сервер может быть просто недоступен (нужен обход), а может
  /// **сознательно ограничивать поток** — тогда обход не поможет.
  String _explain(int statusCode, int start) {
    if (statusCode == 403 && start == 0) {
      return 'YouTube не отдал этот поток (HTTP 403). Смените источник потока '
          'в настройках — рабочий вариант «visionOS» — или включите прокси.';
    }
    if (statusCode == 403) {
      return 'YouTube отдал только начало трека и отвечает 403 на остальное '
          '(смещение $start). Обычно помогает другой источник потока в '
          'настройках (visionOS) или прокси/VPN.';
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
  const _Chunk(this.bytes, this.total, {this.wholeFile = false});

  final List<int> bytes;
  final int? total;

  /// Сервер ответил `200` и отдал файл целиком, проигнорировав `Range`.
  final bool wholeFile;
}
