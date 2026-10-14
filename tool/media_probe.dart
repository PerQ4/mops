// Проверка выдачи потока: получить свежую ссылку и проверить куски.
//
// Запуск:
//   dart run tool/media_probe.dart get    — получить ссылку, сохранить, проверить
//   dart run tool/media_probe.dart test   — взять сохранённую ссылку и проверить
//
// Нужно, чтобы сравнить выдачу с системным обходом и без него.
import 'dart:io';

import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';

const String _ua = 'com.google.android.apps.youtube.vr.oculus/1.65.10 '
    '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';

const String _file = '/tmp/opencode/media_url.txt';

Future<void> main(List<String> args) async {
  final String mode = args.isNotEmpty ? args.first : 'get';
  // В режиме test обход не поднимаем: как раз проверяем выдачу без него,
  // а bootstrap обхода сам ходит в сеть и без zapret не пройдёт.
  if (mode != 'test') {
    await BypassManager.instance.apply(const AntiDpiConfig());
  }

  String raw;
  if (mode == 'test') {
    raw = File(_file).readAsStringSync().trim();
    stdout.writeln('ссылка из файла (${raw.length} символов)');
  } else {
    final InnerTubeClient client = InnerTubeClient(locale: 'en', region: 'US');
    final Map<String, dynamic> response = await client.post(
      'player',
      body: <String, dynamic>{
        'context': <String, dynamic>{
          'client': <String, dynamic>{
            'clientName': 'ANDROID_VR',
            'clientVersion': '1.65.10',
            'osName': 'Android',
            'osVersion': '12L',
            'deviceMake': 'Oculus',
            'deviceModel': 'Quest 3',
            'androidSdkVersion': 32,
            'userAgent': _ua,
            'hl': 'en',
            'gl': 'US',
          },
        },
        'videoId': '9RfVp-GhKfs',
        'contentCheckOk': true,
        'racyCheckOk': true,
      },
      extraHeaders: <String, String>{
        'X-Youtube-Client-Name': '28',
        'X-Youtube-Client-Version': '1.65.10',
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
    audio.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        ((b['bitrate'] as num?) ?? 0).compareTo((a['bitrate'] as num?) ?? 0));
    raw = audio.first['url'] as String;
    File(_file).writeAsStringSync(raw);
    client.dispose();
    stdout.writeln('ссылка получена и сохранена');
  }

  final Uri url = Uri.parse(raw);
  final String host = url.host;
  stdout.writeln('хост: $host');

  final int first = await _range(url, 0, 1048575);
  final int second = await _range(url, 1048576, 2097151);
  stdout.writeln('  кусок 0 (0–1 МБ): ${first > 0 ? "ок, $first байт" : "нет"}');
  stdout.writeln('  кусок 1 (1–2 МБ): ${second > 0 ? "ок, $second байт" : "403"}');

  await BypassManager.instance.dispose();
  exit(0);
}

Future<int> _range(Uri url, int start, int end) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, _ua);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
    final HttpClientResponse response =
        await request.close().timeout(const Duration(seconds: 25));
    if (response.statusCode != 206) return 0;
    int got = 0;
    await for (final List<int> part in response) {
      got += part.length;
    }
    return got;
  } on Object catch (error) {
    stdout.writeln('    ошибка: ${error.toString().split('\n').first}');
    return 0;
  } finally {
    client.close(force: true);
  }
}
