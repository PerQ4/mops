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

/// Загрузку отменили снаружи: пользователь удалил трек, закрыл экран или
/// запустил другую. Это не ошибка — показывать её нельзя.
class DownloadCancelledException implements Exception {
  const DownloadCancelledException();

  @override
  String toString() => 'Загрузка отменена';
}

/// Признак отмены, общий для вызывающего кода и загрузчика.
///
/// Загрузчик проверяет его между частями, а также подписывается на
/// [whenCancelled], чтобы оборвать чтение тела, которое уже началось:
/// иначе отмена ждала бы конца зависшего ответа.
class DownloadCancelToken {
  bool _cancelled = false;
  final Completer<void> _cancelledSignal = Completer<void>();

  bool get isCancelled => _cancelled;

  /// Завершается при отмене. Если отмены не будет — не завершится никогда.
  Future<void> get whenCancelled => _cancelledSignal.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelledSignal.complete();
  }

  void throwIfCancelled() {
    if (_cancelled) throw const DownloadCancelledException();
  }
}

/// Итог скачивания.
class DownloadResult {
  const DownloadResult({required this.bytes, this.total});

  /// Сколько байт в файле.
  final int bytes;

  /// Полный размер, который назвал сервер; `null` — сервер его не сообщил.
  final int? total;
}

/// Скачивает файл по частям с заголовком `Range`.
///
/// **Почему частями.** Медиасерверы YouTube отдают файл только по заголовку
/// `Range` с явно заданным диапазоном: запрос без него или с открытым
/// диапазоном (`bytes=0-`) получает `403 Forbidden`. Поэтому файл качается
/// кусками фиксированного размера.
///
/// **Почему размер берётся у сервера.** Сохранённый `expectedBytes` мог
/// относиться к другому потоку (ссылки живут часами, а контейнер между
/// попытками меняется). Дописывать новый поток к старому остатку — значит
/// получить склеенный файл, который формально «полный». Поэтому при каждом
/// ответе сверяется `Content-Range`, и при расхождении файл начинается заново.
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

  /// Сколько ждать соединения, заголовков и данных. Отдельно на каждую часть:
  /// зависшее тело не должно держать загрузку вечно.
  final Duration chunkTimeout;

  final HttpClient _client;
  final int chunkBytes;
  final String userAgent;

  /// Скачивает [url] в файл [target] и возвращает число записанных байт.
  Future<int> downloadTo(
    Uri url,
    File target, {
    void Function(double progress)? onProgress,
    void Function(int written, int? total)? onBytes,
    bool resume = false,
    int? expectedBytes,
    DownloadCancelToken? cancel,
  }) async {
    final DownloadResult result = await download(
      url,
      target,
      onProgress: onProgress,
      onBytes: onBytes,
      resume: resume,
      expectedBytes: expectedBytes,
      cancel: cancel,
    );
    return result.bytes;
  }

  /// Скачивает [url] в [target], возвращая ещё и подтверждённый сервером
  /// полный размер.
  ///
  /// [resume] продолжает уже начатый файл с его текущей длины. [expectedBytes] —
  /// размер из прошлой попытки: он только подсказка для прогресса. Если сервер
  /// назвал другой размер, остаток с диска отбрасывается и файл качается
  /// заново.
  Future<DownloadResult> download(
    Uri url,
    File target, {
    void Function(double progress)? onProgress,
    void Function(int written, int? total)? onBytes,
    bool resume = false,
    int? expectedBytes,
    DownloadCancelToken? cancel,
  }) async {
    int? expected = expectedBytes;
    bool restart = false;
    int passes = 0;

    // Серверный размер, подтверждённый в этой попытке.
    int? serverTotal;

    while (true) {
      // Больше трёх проходов не нужно: первый — докачка, второй — после
      // расхождения размера. Третий — запас на гонку «сервер снова сменил
      // размер», после него честнее сказать об ошибке, чем крутиться вечно.
      if (++passes > 3) {
        throw StreamDownloadException(
          'Сервер несколько раз менял размер файла. Повторите загрузку: '
          'видимо, поток между попытками отдаётся разный.',
        );
      }
      cancel?.throwIfCancelled();

      final int start = (resume && !restart && target.existsSync())
          ? await target.length()
          : 0;
      int written = start;
      bool needRestart = false;
      int? total = serverTotal;

      IOSink sink = start > 0
          ? target.openWrite(mode: FileMode.append)
          : target.openWrite();

      void report() {
        onBytes?.call(written, total);
        onProgress?.call(
          total == null || total <= 0
              ? 0
              : (written / total).clamp(0.0, 1.0),
        );
      }

      try {
        report();
        while (true) {
          cancel?.throwIfCancelled();
          if (total != null && written >= total) break;

          final int from = written;
          final int end = total == null
              ? from + chunkBytes - 1
              : (from + chunkBytes - 1).clamp(from, total - 1);
          final _Chunk chunk = await _fetch(
            url,
            from,
            end,
            cancel: cancel,
          );

          if (chunk.unsatisfiable) {
            // 416 — запросили за концом файла. Сервер обычно сообщает
            // настоящий размер в `Content-Range: bytes */N`.
            final int? real = chunk.total;
            if (real == null) {
              throw StreamDownloadException(
                'Сервер ответил 416 (диапазон за концом файла) и не сообщил '
                'размер. Начать заново не с чего — повторите загрузку.',
              );
            }
            serverTotal = real;
            if (real == 0) {
              throw StreamDownloadException(
                'Сервер сообщил, что файл пустой: скачивать нечего. '
                'Смените источник потока в настройках.',
              );
            }
            if (written > 0 && written == real) {
              // Файл на диске ровно того размера, что отдаёт сервер.
              total = real;
              report();
              break;
            }
            // Остаток длиннее или короче настоящего файла — он от другого
            // потока. Начинаем заново, иначе файл не сойдётся никогда.
            needRestart = true;
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
            serverTotal = chunk.total ?? written;
            total = serverTotal;
            report();
            break;
          }

          final int? realTotal = chunk.total;
          if (realTotal == null || chunk.rangeStart == null) {
            // 206 без `Content-Range` — файл мог быть обрезан, и понять это
            // нечем. Молча считать такой ответ концом нельзя.
            throw StreamDownloadException(
              'Сервер ответил 206 без Content-Range: невозможно проверить, '
              'скачан файл целиком или оборван. Повторите загрузку или '
              'смените источник потока в настройках.',
            );
          }
          if (chunk.rangeStart != from) {
            // Сервер начал не с того места, которое просили: собранный файл
            // получил бы дыру или наложение.
            needRestart = true;
            break;
          }
          if (written == start && start > 0) {
            final bool sizeMatches =
                expected == null || expected == realTotal;
            if (start > realTotal || !sizeMatches) {
              // Сохранённый остаток относится к другому потоку (например,
              // webm вместо m4a) — начинаем файл заново.
              needRestart = true;
              break;
            }
          }
          if (serverTotal != null && serverTotal != realTotal) {
            // Размер сменился прямо во время загрузки: части уже могут быть
            // от разных файлов.
            needRestart = true;
            break;
          }
          serverTotal = realTotal;
          total = realTotal;

          if (chunk.bytes.isEmpty) {
            throw StreamDownloadException(
              'Сервер оборвал передачу: получено $written из $realTotal байт. '
              'Повторите — докачка продолжится с этого места.',
            );
          }
          if (chunk.rangeEnd != null &&
              chunk.rangeStart != null &&
              chunk.rangeStart! + chunk.bytes.length - 1 != chunk.rangeEnd) {
            // Тело не совпадает с заявленным диапазоном: в файле была бы
            // дыра или лишние байты, а размер при этом сошёлся бы.
            throw StreamDownloadException(
              'Сервер прислал ${chunk.bytes.length} байт вместо диапазона '
              '${chunk.rangeStart!}-${chunk.rangeEnd}. Повторите загрузку.',
            );
          }
          if (from + chunk.bytes.length > realTotal) {
            // Байт больше, чем сервер назвал в total, — ответ противоречив.
            needRestart = true;
            break;
          }

          sink.add(chunk.bytes);
          written += chunk.bytes.length;
          report();

          // Короткая часть при известном total — не конец файла: сервер мог
          // отдать меньше запрошенного. Продолжаем, пока не наберём total.
          if (written >= realTotal) break;
        }

        await sink.flush();
        await sink.close();
      } on Object {
        // Сохраняем то, что успело дойти, — отсюда продолжится докачка.
        await _closeQuietly(sink);
        rethrow;
      }

      if (needRestart) {
        restart = true;
        expected = null;
        serverTotal = null;
        continue;
      }

      if (written == 0) {
        throw StreamDownloadException(
          'Сервер не отдал ни одного байта трека. Проверьте обход блокировок.',
        );
      }
      if (serverTotal != null && written < serverTotal) {
        throw StreamDownloadException(
          'Загрузка оборвалась: получено $written из $serverTotal байт. '
          'Повторите — докачка продолжится с этого места.',
        );
      }
      onBytes?.call(written, written);
      onProgress?.call(1);
      return DownloadResult(bytes: written, total: serverTotal);
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
  Future<_Chunk> _fetch(
    Uri url,
    int start,
    int end, {
    DownloadCancelToken? cancel,
  }) async {
    cancel?.throwIfCancelled();

    final HttpClientRequest request;
    try {
      request = await _withCancel(_client.getUrl(url), cancel)
          .timeout(chunkTimeout);
    } on TimeoutException {
      throw StreamDownloadException(
        'Сервер не принял соединение за ${chunkTimeout.inSeconds} с. '
        'Проверьте сеть или обход блокировок.',
      );
    }
    request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    // Без явного диапазона медиасервер отвечает 403.
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');

    final HttpClientResponse response;
    try {
      response =
          await _withCancel(request.close(), cancel).timeout(chunkTimeout);
    } on TimeoutException {
      request.abort();
      throw StreamDownloadException(
        'Сервер не ответил за ${chunkTimeout.inSeconds} с. '
        'Повторите загрузку — докачка продолжится с этого места.',
      );
    } on Object {
      request.abort();
      rethrow;
    }

    if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
      // Запросили за концом файла: сервер сообщает настоящий размер в
      // `Content-Range: bytes */N`, если он вообще его сообщает.
      final int? total = _unsatisfiedTotal(response.headers);
      await _drain(response);
      return _Chunk(
        const <int>[],
        total: total,
        unsatisfiable: true,
      );
    }

    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      await _drain(response);
      throw StreamDownloadException(_explain(response.statusCode, start));
    }

    final _ContentRange? range = _parseContentRange(response.headers);
    final bool wholeFile = response.statusCode == HttpStatus.ok;

    final List<int> bytes;
    try {
      bytes = await _readBody(response, cancel);
    } on TimeoutException {
      throw StreamDownloadException(
        'Сервер перестал присылать данные (больше ${chunkTimeout.inSeconds} с '
        'без ответа). Повторите загрузку — докачка продолжится.',
      );
    }

    if (wholeFile) {
      return _Chunk(
        bytes,
        total: range?.total ?? response.contentLength,
        wholeFile: true,
      );
    }
    return _Chunk(
      bytes,
      total: range?.total,
      rangeStart: range?.start,
      rangeEnd: range?.end,
    );
  }

  /// Оборачивает сетевой шаг так, чтобы отмена срабатывала сразу, не дожидаясь
  /// таймаута: зависшие `getUrl`/`close` иначе не отменить.
  Future<T> _withCancel<T>(Future<T> step, DownloadCancelToken? cancel) {
    if (cancel == null) return step;
    if (cancel.isCancelled) {
      return Future<T>.error(const DownloadCancelledException());
    }
    return Future.any<T>(<Future<T>>[
      step,
      cancel.whenCancelled
          .then<T>((_) => throw const DownloadCancelledException()),
    ]);
  }

  /// Читает тело ответа, не давая зависшему потоку держать задачу вечно.
  ///
  /// `timeout` на потоке срабатывает на паузу между кусками; отмена рвёт
  /// подписку сразу, не дожидаясь таймаута.
  Future<List<int>> _readBody(
    HttpClientResponse response,
    DownloadCancelToken? cancel,
  ) {
    final BytesBuilder builder = BytesBuilder(copy: false);
    final Completer<void> done = Completer<void>();
    late final StreamSubscription<List<int>> subscription;

    subscription = response.timeout(chunkTimeout).listen(
      (List<int> part) {
        if (cancel?.isCancelled ?? false) {
          subscription.cancel();
          if (!done.isCompleted) {
            done.completeError(const DownloadCancelledException());
          }
          return;
        }
        builder.add(part);
      },
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );

    if (cancel != null) {
      // Слушатель живёт, пока идёт чтение; после завершения он уже ничего
      // не сделает — `done` закрыт.
      unawaited(cancel.whenCancelled.then((_) {
        subscription.cancel();
        if (!done.isCompleted) {
          done.completeError(const DownloadCancelledException());
        }
      }));
    }

    return done.future.then((_) => builder.takeBytes());
  }

  Future<void> _drain(HttpClientResponse response) async {
    try {
      await response.drain<void>().timeout(chunkTimeout);
    } on Object {
      // Тело ошибки не нужно: важнее исходный статус.
    }
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

  /// Разбирает `Content-Range: bytes 0-1023/4096`.
  ///
  /// Для `bytes 0-1023/*` размер неизвестен — [total] будет `null`, и это
  /// не даст считать файл проверенным.
  _ContentRange? _parseContentRange(HttpHeaders headers) {
    final String? value = headers.value(HttpHeaders.contentRangeHeader);
    if (value == null) return null;
    final RegExpMatch? match = _contentRangePattern.firstMatch(value);
    if (match == null) return null;
    final int start = int.parse(match.group(1)!);
    final int end = int.parse(match.group(2)!);
    final String rawTotal = match.group(3)!;
    final int? total = rawTotal == '*' ? null : int.tryParse(rawTotal);
    return _ContentRange(start: start, end: end, total: total);
  }

  /// Размер из ответа `416`: `Content-Range: bytes */4096`.
  ///
  /// Только заголовок: `Content-Length` у 416 описывает тело ошибки, а не
  /// размер файла, и доверять ему нельзя.
  int? _unsatisfiedTotal(HttpHeaders headers) {
    final String? value = headers.value(HttpHeaders.contentRangeHeader);
    if (value == null) return null;
    final RegExpMatch? match = _unsatisfiedRangePattern.firstMatch(value);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  void dispose() => _client.close(force: true);

  static final RegExp _contentRangePattern =
      RegExp(r'bytes\s+(\d+)-(\d+)/(\d+|\*)');
  static final RegExp _unsatisfiedRangePattern =
      RegExp(r'bytes\s+\*/(\d+)');
}

/// Разобранный `Content-Range` ответа.
class _ContentRange {
  const _ContentRange({
    required this.start,
    required this.end,
    required this.total,
  });

  final int start;
  final int end;
  final int? total;
}

/// Одна скачанная часть.
class _Chunk {
  const _Chunk(
    this.bytes, {
    this.total,
    this.rangeStart,
    this.rangeEnd,
    this.wholeFile = false,
    this.unsatisfiable = false,
  });

  final List<int> bytes;

  /// Полный размер файла, как его назвал сервер; `null` — не сообщил.
  final int? total;

  /// Начало диапазона из `Content-Range`; `null` — заголовка нет.
  final int? rangeStart;

  /// Конец диапазона из `Content-Range`; по нему тело сверяется с заголовком.
  final int? rangeEnd;

  /// Сервер ответил `200` и отдал файл целиком, проигнорировав `Range`.
  final bool wholeFile;

  /// Сервер ответил `416`: запрошенный диапазон за концом файла.
  final bool unsatisfiable;
}
