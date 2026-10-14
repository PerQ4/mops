// Проверяет получение ссылки через библиотеку с разными клиентами.
//
// Запуск: dart run tool/manifest_probe.dart [videoId]
//
// Приложение получает поток через youtube_explode_dart, и важно понять,
// какие настройки дают рабочий манифест.
import 'dart:io';

import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

const String _uaVr = 'com.google.android.apps.youtube.vr.oculus/1.65.10 '
    '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';

YoutubeApiClient _androidVr() => YoutubeApiClient(
      <String, dynamic>{
        'context': <String, dynamic>{
          'client': <String, dynamic>{
            'clientName': 'ANDROID_VR',
            'clientVersion': '1.65.10',
            'osName': 'Android',
            'osVersion': '12L',
            'deviceMake': 'Oculus',
            'deviceModel': 'Quest 3',
            'androidSdkVersion': 32,
            'userAgent': _uaVr,
            'hl': 'en',
            'gl': 'US',
          },
        },
      },
      'https://music.youtube.com/youtubei/v1/player?prettyPrint=false',
      headers: <String, String>{
        'X-Youtube-Client-Name': '28',
        'X-Youtube-Client-Version': '1.65.10',
        'User-Agent': _uaVr,
      },
    );

Future<void> main(List<String> args) async {
  final String videoId = args.isNotEmpty ? args.first : '9RfVp-GhKfs';
  await BypassManager.instance.apply(const AntiDpiConfig());
  final YoutubeExplode yt = YoutubeExplode();

  Future<void> attempt(
    String label, {
    List<YoutubeApiClient>? clients,
    bool? requireWatchPage,
  }) async {
    stdout.writeln('\n=== $label ===');
    try {
      final StreamManifest manifest = await yt.videos.streamsClient
          .getManifest(
            videoId,
            ytClients: clients,
            requireWatchPage: requireWatchPage ?? true,
          )
          .timeout(const Duration(seconds: 30));
      final List<AudioOnlyStreamInfo> audio = manifest.audioOnly.toList()
        ..sort((AudioOnlyStreamInfo a, AudioOnlyStreamInfo b) =>
            b.bitrate.kiloBitsPerSecond.compareTo(a.bitrate.kiloBitsPerSecond));
      stdout.writeln('  аудиодорожек: ${audio.length}');
      if (audio.isNotEmpty) {
        stdout.writeln('  лучшая: '
            '${audio.first.bitrate.kiloBitsPerSecond.round()} kbps '
            '${audio.first.audioCodec}');
        stdout.writeln('  ссылка: c=${audio.first.url.queryParameters['c']}');
      }
    } on Object catch (error) {
      stdout.writeln('  ошибка: ${error.toString().split('\n').first}');
    }
  }

  await attempt('клиент библиотеки по умолчанию',
      clients: null, requireWatchPage: false);
  await attempt('Android VR, без страницы просмотра',
      clients: <YoutubeApiClient>[_androidVr()], requireWatchPage: false);
  await attempt('Android VR, со страницей просмотра',
      clients: <YoutubeApiClient>[_androidVr()], requireWatchPage: true);

  yt.close();
  await BypassManager.instance.dispose();
  exit(0);
}
