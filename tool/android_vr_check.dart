// Проверка клиента ANDROID_VR: он не требует ни входа, ни PO-токена.
//
// Запуск: dart run tool/android_vr_check.dart [videoId]
//
// Если ссылки от этого клиента отдают файл целиком (а не первый мегабайт),
// звук заработает без входа и без прокси.
import 'dart:io';

import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

const String _uaVr = 'com.google.android.apps.youtube.vr.oculus/1.61.48 '
    '(Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; '
    'Cronet/132.0.6808.3)';

/// Профиль Android VR: взят из каталога клиентов Metrolist.
YoutubeApiClient _androidVr(String version, String userAgent) {
  return YoutubeApiClient(
    <String, dynamic>{
      'context': <String, dynamic>{
        'client': <String, dynamic>{
          'clientName': 'ANDROID_VR',
          'clientVersion': version,
          'osName': 'Android',
          'osVersion': '12',
          'deviceMake': 'Oculus',
          'deviceModel': 'Quest 3',
          'androidSdkVersion': 32,
          'userAgent': userAgent,
          'hl': 'en',
          'gl': 'US',
          'utcOffsetMinutes': 0,
        },
      },
    },
    'https://music.youtube.com/youtubei/v1/player?prettyPrint=false',
    headers: <String, String>{
      // Числовой идентификатор клиента YouTube ждёт именно здесь.
      'X-Youtube-Client-Name': '28',
      'X-Youtube-Client-Version': version,
      'User-Agent': userAgent,
    },
  );
}

Future<void> main(List<String> args) async {
  final String videoId = args.isNotEmpty ? args.first : '9RfVp-GhKfs';
  await BypassManager.instance.apply(const AntiDpiConfig());

  final List<(String, YoutubeApiClient)> candidates = <(String, YoutubeApiClient)>[
    ('Android VR 1.61.48', _androidVr('1.61.48', _uaVr)),
    (
      'Android VR 1.65.10',
      _androidVr(
        '1.65.10',
        'com.google.android.apps.youtube.vr.oculus/1.65.10 '
            '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
      ),
    ),
  ];

  final YoutubeExplode yt = YoutubeExplode();
  for (final (String label, YoutubeApiClient client) in candidates) {
    stdout.writeln('\n=== $label ===');
    try {
      final StreamManifest manifest = await yt.videos.streamsClient
          .getManifest(videoId, ytClients: <YoutubeApiClient>[client])
          .timeout(const Duration(seconds: 30));

      final List<AudioOnlyStreamInfo> audio = manifest.audioOnly.toList()
        ..sort((AudioOnlyStreamInfo a, AudioOnlyStreamInfo b) =>
            b.bitrate.kiloBitsPerSecond.compareTo(a.bitrate.kiloBitsPerSecond));
      if (audio.isEmpty) {
        stdout.writeln('  аудиодорожек нет');
        continue;
      }

      final Uri url = audio.first.url;
      stdout.writeln('  дорожек: ${audio.length}, лучшая '
          '${audio.first.bitrate.kiloBitsPerSecond.round()} kbps '
          '${audio.first.audioCodec}');
      stdout.writeln('  клиент в ссылке: c=${url.queryParameters['c']}');
      stdout.writeln('  размер файла: ${url.queryParameters['clen']}');

      final bool first = await _range(url, 0, 1048575);
      final bool middle = await _range(url, 1048576, 2097151);
      final bool far = await _range(url, 3000000, 3100000);
      stdout.writeln('  диапазоны: начало ${first ? "ок" : "403"}, '
          'после 1 МБ ${middle ? "ок" : "403"}, '
          'дальний участок ${far ? "ок" : "403"}');

      if (middle && far) {
        stdout.writeln('  ИТОГ: клиент отдаёт файл целиком — звук заработает!');
        File('/tmp/opencode/vr_works.txt').writeAsStringSync(label);
      }
    } on Object catch (error) {
      stdout.writeln('  ошибка: ${error.toString().split('\n').first}');
    }
  }

  yt.close();
  await BypassManager.instance.dispose();
  exit(0);
}

Future<bool> _range(Uri url, int start, int end) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, _uaVr);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
    final HttpClientResponse response =
        await request.close().timeout(const Duration(seconds: 25));
    int got = 0;
    await for (final List<int> chunk in response) {
      got += chunk.length;
      if (got > (end - start + 1)) break;
    }
    return response.statusCode == 206 && got > 1000;
  } on Object {
    return false;
  } finally {
    client.close(force: true);
  }
}
