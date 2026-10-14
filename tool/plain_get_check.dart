// Проверяет, принимает ли ссылка visionOS обычный GET без диапазона.
//
// Запуск: dart run tool/plain_get_check.dart
//
// Если да — посредник не нужен: ссылку можно отдать плееру напрямую, как это
// делают ArchiveTune и Metrolist (ExoPlayer/Media3).
import 'dart:io';

import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';

const String _ua = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15';

Future<void> main(List<String> args) async {
  final String videoId = args.isNotEmpty ? args.first : 'gDGF0SE0aVk';
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
  final Uri url = Uri.parse(audio.first['url'] as String);
  client.dispose();
  stdout.writeln('ссылка: c=${url.queryParameters['c']} '
      'clen=${url.queryParameters['clen']}');

  // 1. Обычный GET без диапазона — именно так просит ExoPlayer/GStreamer.
  stdout.writeln('\n== обычный GET (без Range) ==');
  await _get(url, null, _ua);
  stdout.writeln('== обычный GET без User-Agent ==');
  await _get(url, null, null);

  // 2. Диапазон — для перемотки.
  stdout.writeln('\n== Range: bytes=1048576-2097151 ==');
  await _get(url, 'bytes=1048576-2097151', _ua);

  await BypassManager.instance.dispose();
  exit(0);
}

Future<void> _get(Uri url, String? range, String? ua) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.getUrl(url);
    if (ua != null) request.headers.set(HttpHeaders.userAgentHeader, ua);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final HttpClientResponse response =
        await request.close().timeout(const Duration(seconds: 25));
    int got = 0;
    await for (final List<int> part in response) {
      got += part.length;
      if (got > 300 * 1024) break;
    }
    stdout.writeln('  статус ${response.statusCode}, получено $got байт');
  } on Object catch (error) {
    stdout.writeln('  ошибка: ${error.toString().split('\n').first}');
  } finally {
    client.close(force: true);
  }
}
