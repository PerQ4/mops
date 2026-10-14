// Проверка посредника без сети: повтор куска при сбое и предзагрузка.
//
// Запуск: dart run tool/proxy_retry_check.dart
//
// Поднимается поддельный медиасервер, который один раз отвечает 403 на
// серединный кусок и принимает только закрытые диапазоны. Посредник должен:
//   1) повторить запрос и всё же отдать файл целиком;
//   2) по `warm` скачать начало заранее и отдать его из памяти.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mops/data/sources/stream_proxy.dart';

/// Тело «трека»: 3 МБ плюс хвост, чтобы последний кусок был неполным.
final Uint8List _body = Uint8List.fromList(
  List<int>.generate(3 * 1024 * 1024 + 777, (int i) => i % 251),
);

/// Куски, на которые сервер ответит 403 ровно один раз.
final Set<int> _failOnce = <int>{};

/// Сколько раз запрашивали кусок с данным смещением.
final Map<int, int> _requests = <int, int>{};

Future<void> main() async {
  final HttpServer upstream =
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  upstream.listen(_serveUpstream);

  bool ok = true;

  // 1. Один кусок падает с 403 — файл всё равно должен скачаться целиком.
  _failOnce.add(2 * 1024 * 1024);
  final StreamProxy proxy = StreamProxy(verbose: true);
  final Uri source = Uri.parse(
    'http://127.0.0.1:${upstream.port}/track?clen=${_body.length}',
  );
  final Uri local = await proxy.serve(source);
  final int got = await _download(local);
  stdout.writeln('\nслучай 1: получено $got из ${_body.length} байт');
  if (got != _body.length) {
    stdout.writeln('  ОШИБКА: файл не скачался целиком после сбоя куска');
    ok = false;
  } else if ((_requests[2 * 1024 * 1024] ?? 0) < 2) {
    stdout.writeln('  ОШИБКА: повтор запроса не выполнялся');
    ok = false;
  } else {
    stdout.writeln('  ок: сбой куска повторён, поток не оборвался');
  }
  await proxy.dispose();

  // 2. Предзагрузка: `warm` качает начало, а запрос плеера берёт его из памяти.
  _requests.clear();
  _failOnce.clear();
  final StreamProxy warmProxy = StreamProxy(
    verbose: true,
    warmBytes: 2 * 1024 * 1024,
  );
  final Uri warmSource = Uri.parse(
    'http://127.0.0.1:${upstream.port}/warm?clen=${_body.length}',
  );
  final Uri warmed = await warmProxy.warm(warmSource);
  // Ждём, пока фоновая докачка заберёт первые два куска.
  final bool prefetched = await _waitFor(
    () => (_requests[0] ?? 0) >= 1 && (_requests[1 * 1024 * 1024] ?? 0) >= 1,
  );
  final int before =
      (_requests[0] ?? 0) + (_requests[1 * 1024 * 1024] ?? 0);
  final int gotWarm = await _download(warmed);
  final int after = (_requests[0] ?? 0) + (_requests[1 * 1024 * 1024] ?? 0);
  stdout.writeln('\nслучай 2: прогрето=$prefetched, получено '
      '$gotWarm из ${_body.length} байт');
  if (!prefetched) {
    stdout.writeln('  ОШИБКА: прогрев не начался');
    ok = false;
  } else if (gotWarm != _body.length) {
    stdout.writeln('  ОШИБКА: прогретый поток отдан не целиком');
    ok = false;
  } else if (after != before) {
    stdout.writeln('  ОШИБКА: первые куски качались повторно, кэш не использован');
    ok = false;
  } else {
    stdout.writeln('  ок: начало отдано из памяти, повторных запросов нет');
  }
  await warmProxy.dispose();

  await upstream.close(force: true);
  stdout.writeln(ok ? '\nИТОГ: посредник работает как надо' : '\nИТОГ: есть сбои');
  exit(ok ? 0 : 1);
}

/// Отвечает как медиасервер: только закрытые диапазоны, разовый 403.
Future<void> _serveUpstream(HttpRequest request) async {
  final String? range = request.headers.value(HttpHeaders.rangeHeader);
  if (range == null) {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers.contentLength = _body.length;
    request.response.add(_body);
    await request.response.close();
    return;
  }

  final RegExpMatch match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
  final int start = int.parse(match.group(1)!);
  final String endRaw = match.group(2)!;
  final int end = endRaw.isEmpty ? _body.length - 1 : int.parse(endRaw);

  _requests[start] = (_requests[start] ?? 0) + 1;

  if (_failOnce.remove(start)) {
    request.response.statusCode = HttpStatus.forbidden;
    await request.response.close();
    return;
  }

  final int stop = math.min(end + 1, _body.length);
  final List<int> slice = _body.sublist(start, stop);
  request.response.statusCode = HttpStatus.partialContent;
  request.response.headers.set(
    HttpHeaders.contentRangeHeader,
    'bytes $start-${start + slice.length - 1}/${_body.length}',
  );
  request.response.headers.contentLength = slice.length;
  request.response.add(slice);
  await request.response.close();
}

/// Скачивает локальный адрес целиком и проверяет содержимое.
Future<int> _download(Uri local) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.getUrl(local);
    final HttpClientResponse response = await request.close();
    final Uint8List bytes = await _collect(response);
    if (bytes.length == _body.length && !_sameBytes(bytes, _body)) {
      stdout.writeln('  ОШИБКА: содержимое потока искажено');
    }
    return bytes.length;
  } finally {
    client.close(force: true);
  }
}

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final BytesBuilder builder = BytesBuilder(copy: false);
  await for (final List<int> part in stream) {
    builder.add(part);
  }
  return builder.takeBytes();
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<bool> _waitFor(bool Function() condition) async {
  for (int i = 0; i < 60; i++) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return condition();
}
