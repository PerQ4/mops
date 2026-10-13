// Качает поток по кускам, как это делает плеер приложения.
//
// Запуск: dart run tool/audio_range_check.dart [videoId]
//
// Плеер качает файл кусками по 1 МБ. Если сервер отдаёт только первый кусок,
// звука не будет; если отдаёт все — заработает.
import 'dart:io';

import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';

const String _ua = 'com.google.android.apps.youtube.vr.oculus/1.65.10 '
    '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';

const int _chunk = 1024 * 1024;

Future<void> main(List<String> args) async {
  final String videoId = args.isNotEmpty ? args.first : '9RfVp-GhKfs';
  await BypassManager.instance.apply(const AntiDpiConfig());
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
      'videoId': videoId,
      'contentCheckOk': true,
      'racyCheckOk': true,
    },
    extraHeaders: <String, String>{
      'X-YouTube-Client-Name': '28',
      'X-YouTube-Client-Version': '1.65.10',
    },
  );

  final dynamic sd = response['streamingData'];
  final List<dynamic> formats = <dynamic>[
    ...(sd['adaptiveFormats'] as List<dynamic>? ?? <dynamic>[]),
    ...(sd['formats'] as List<dynamic>? ?? <dynamic>[]),
  ];
  final List<Map<String, dynamic>> audio = formats
      .whereType<Map<String, dynamic>>()
      .where((Map<String, dynamic> f) => '${f['mimeType']}'.startsWith('audio'))
      .toList();
  audio.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
      ((b['bitrate'] as num?) ?? 0).compareTo((a['bitrate'] as num?) ?? 0));

  final Uri url = Uri.parse(audio.first['url'] as String);
  final int total = int.tryParse(url.queryParameters['clen'] ?? '') ?? 0;
  stdout.writeln('ссылка: c=${url.queryParameters['c']}, размер: $total байт');
  stdout.writeln('качаю кусками по ${_chunk ~/ 1024} КБ:\n');

  int downloaded = 0;
  int chunkIndex = 0;
  while (downloaded < total) {
    final int start = downloaded;
    final int end = (start + _chunk - 1).clamp(0, total - 1);
    final int got = await _range(url, start, end);
    if (got <= 0) {
      stdout.writeln('  кусок $chunkIndex '
          '(${start ~/ 1024}–${end ~/ 1024} КБ): НЕ ПОЛУЧЕН');
      break;
    }
    downloaded += got;
    stdout.writeln('  кусок $chunkIndex '
        '(${start ~/ 1024}–${end ~/ 1024} КБ): ок, всего '
        '${(downloaded / 1024 / 1024).toStringAsFixed(2)} МБ');
    chunkIndex++;
    if (chunkIndex > 40) break;
  }

  stdout.writeln();
  if (downloaded >= total) {
    stdout.writeln('ИТОГ: файл скачан целиком — звук заработает.');
  } else {
    stdout.writeln('ИТОГ: получено ${(downloaded / 1024).toStringAsFixed(0)} КБ '
        'из ${(total / 1024).toStringAsFixed(0)} КБ — дальше сервер не отдаёт.');
  }

  client.dispose();
  await BypassManager.instance.dispose();
  exit(0);
}

/// Возвращает число полученных байт или 0 при ошибке.
Future<int> _range(Uri url, int start, int end) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, _ua);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
    final HttpClientResponse response =
        await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != 206) {
      stdout.writeln('    статус ${response.statusCode}');
      return 0;
    }
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
