// Проверка локального посредника: обычный GET и запрос диапазона.
//
// Запуск: dart run tool/proxy_check.dart [videoId]
// Без аргумента берётся короткий трек; для проверки длинной выдачи
// (обрыв через минуту) подставьте идентификатор подольше.
import 'dart:io';

import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:mops/data/sources/stream_proxy.dart';

const String _ua = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15';

Future<void> main(List<String> args) async {
  final String videoId = args.isNotEmpty ? args.first : 'dQw4w9WgXcQ';
  await BypassManager.instance.apply(const AntiDpiConfig());
  final InnerTubeClient client = InnerTubeClient(locale: 'en', region: 'US');

  final Map<String, dynamic> response = await client.post(
    'player',
    body: <String, dynamic>{
      'context': <String, dynamic>{
        'client': <String, dynamic>{
          'clientName': 'VISIONOS',
          'clientVersion': '1.02',
          'osName': 'visionOS',
          'osVersion': '26.5.23O471',
          'deviceMake': 'Apple',
          'deviceModel': 'RealityDevice17,1',
          'hl': 'en',
          'gl': 'US',
        },
      },
      'videoId': videoId,
      'contentCheckOk': true,
      'racyCheckOk': true,
    },
    extraHeaders: <String, String>{
      'X-Youtube-Client-Name': '101',
      'X-YouTube-Client-Version': '1.02',
      'User-Agent': _ua,
    },
  );

  final dynamic sd = response['streamingData'];
  final List<Map<String, dynamic>> audio = <dynamic>[
    ...(sd['adaptiveFormats'] as List<dynamic>? ?? <dynamic>[]),
  ]
      .whereType<Map<String, dynamic>>()
      .where((Map<String, dynamic> f) =>
          '${f['mimeType']}'.startsWith('audio') && f['url'] != null)
      .toList();
  // Берём самый качественный поток — как при настройке «Максимум»
  // (по умолчанию). Так кусок в 1 МБ соответствует меньшему времени
  // и проверка длинной выдачи ближе к реальному плееру.
  audio.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
      ((b['bitrate'] as num?) ?? 0).compareTo((a['bitrate'] as num?) ?? 0));
  final Uri source = Uri.parse(audio.first['url'] as String);
  final String formatMime = '${audio.first['mimeType']}'.split(';').first;
  client.dispose();
  stdout.writeln('источник: ${source.host}, размер ${source.queryParameters['clen']}, '
      'формат $formatMime');

  final StreamProxy proxy = StreamProxy(verbose: true);
  final Uri local = await proxy.serve(
    source,
    userAgent: _ua,
    mimeType: formatMime,
  );
  stdout.writeln('локальный адрес: $local\n');

  // Режим «serve»: держим посредника открытым, чтобы проверить GStreamer.
  if (Platform.environment['PROXY_SERVE'] == '1') {
    stdout.writeln('LOCAL_URL=$local');
    await Future<void>.delayed(const Duration(minutes: 5));
    return;
  }

  // 1. Обычный GET — именно так запрашивает GStreamer.
  stdout.writeln('== обычный GET (как GStreamer) ==');
  await _get(local, null, 'первые 200 КБ');

  // 2. Запрос диапазона — так плеер перематывает.
  stdout.writeln('\n== Range: bytes=1000000-1099999 ==');
  await _get(local, 'bytes=1000000-1099999', 'участок в середине');
  stdout.writeln('\n== Range за концом файла ==');
  await _get(local, 'bytes=3000000-3099999', 'за концом');

  // 3. HEAD.
  stdout.writeln('\n== HEAD ==');
  final HttpClient head = HttpClient();
  final HttpClientRequest hr = await head.headUrl(local);
  final HttpClientResponse hres = await hr.close();
  stdout.writeln('  статус ${hres.statusCode}, '
      'content-length ${hres.headers.value('content-length')}, '
      'accept-ranges ${hres.headers.value('accept-ranges')}');
  head.close(force: true);

  await proxy.dispose();
  await BypassManager.instance.dispose();
  exit(0);
}

Future<void> _get(Uri url, String? range, String label) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.getUrl(url);
    if (range != null) {
      request.headers.set(HttpHeaders.rangeHeader, range);
    }
    final HttpClientResponse response =
        await request.close().timeout(const Duration(seconds: 30));
    int got = 0;
    await for (final List<int> part in response) {
      got += part.length;
      if (got > 200 * 1024) break; // хватит, чтобы убедиться
    }
    stdout.writeln('  $label: статус ${response.statusCode}, получено $got байт, '
        'content-range ${response.headers.value('content-range')}');
  } on Object catch (error) {
    stdout.writeln('  $label: ошибка ${error.toString().split('\n').first}');
  } finally {
    client.close(force: true);
  }
}
