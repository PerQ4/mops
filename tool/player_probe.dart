// Точная проверка клиентов YouTube: какой отдаёт поток целиком.
//
// Запуск: dart run tool/player_probe.dart [videoId]
//
// Профили клиентов взяты из каталога Metrolist (innertubex). Для каждого
// печатается ответ YouTube и проверяется, отдаёт ли медиасервер файл дальше
// первого мегабайта.
import 'dart:io';

import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';

/// Профиль клиента YouTube.
class ClientProfile {
  const ClientProfile({
    required this.label,
    required this.name,
    required this.version,
    required this.numericId,
    required this.userAgent,
    this.extra = const <String, Object?>{},
  });

  final String label;
  final String name;
  final String version;
  final String numericId;
  final String userAgent;
  final Map<String, Object?> extra;
}

const String _webUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0';

final List<ClientProfile> profiles = <ClientProfile>[
  ClientProfile(
    label: 'Android VR 1.61.48',
    name: 'ANDROID_VR',
    version: '1.61.48',
    numericId: '28',
    userAgent: 'com.google.android.apps.youtube.vr.oculus/1.61.48 '
        '(Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; '
        'Cronet/132.0.6808.3)',
    extra: <String, Object?>{
      'osName': 'Android',
      'osVersion': '12',
      'deviceMake': 'Oculus',
      'deviceModel': 'Quest 3',
      'androidSdkVersion': 32,
    },
  ),
  ClientProfile(
    label: 'Android VR 1.65.10',
    name: 'ANDROID_VR',
    version: '1.65.10',
    numericId: '28',
    userAgent: 'com.google.android.apps.youtube.vr.oculus/1.65.10 '
        '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
    extra: <String, Object?>{
      'osName': 'Android',
      'osVersion': '12L',
      'deviceMake': 'Oculus',
      'deviceModel': 'Quest 3',
      'androidSdkVersion': 32,
    },
  ),
  ClientProfile(
    label: 'TVHTML5 Simply Embedded',
    name: 'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
    version: '2.0',
    numericId: '85',
    userAgent: _webUa,
  ),
  ClientProfile(
    label: 'iOS 20.10.4',
    name: 'IOS',
    version: '20.10.4',
    numericId: '5',
    userAgent: 'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 '
        'like Mac OS X;)',
    extra: <String, Object?>{
      'deviceMake': 'Apple',
      'deviceModel': 'iPhone16,2',
      'osName': 'IOS',
      'osVersion': '18.3.2.22B83',
    },
  ),
  ClientProfile(
    label: 'WEB_REMIX',
    name: 'WEB_REMIX',
    version: '1.20260707.12.00',
    numericId: '67',
    userAgent: _webUa,
  ),
];

Future<void> main(List<String> args) async {
  final String videoId = args.isNotEmpty ? args.first : '9RfVp-GhKfs';
  await BypassManager.instance.apply(const AntiDpiConfig());
  final InnerTubeClient client = InnerTubeClient(locale: 'en', region: 'US');

  for (final ClientProfile profile in profiles) {
    stdout.writeln('\n=== ${profile.label} ===');
    try {
      final Map<String, dynamic> response = await client.post(
        'player',
        body: <String, dynamic>{
          'context': <String, dynamic>{
            'client': <String, dynamic>{
              'clientName': profile.name,
              'clientVersion': profile.version,
              'hl': 'en',
              'gl': 'US',
              'utcOffsetMinutes': 0,
              'userAgent': profile.userAgent,
              ...profile.extra,
            },
          },
          'videoId': videoId,
          'contentCheckOk': true,
          'racyCheckOk': true,
        },
        extraHeaders: <String, String>{
          'X-YouTube-Client-Name': profile.numericId,
          'X-YouTube-Client-Version': profile.version,
          'User-Agent': profile.userAgent,
        },
      );

      final dynamic status = response['playabilityStatus'];
      final String state = status is Map ? '${status['status']}' : '?';
      final String reason = status is Map ? '${status['reason'] ?? ''}' : '';
      final dynamic streaming = response['streamingData'];
      final List<dynamic> formats = streaming is Map
          ? <dynamic>[
              ...(streaming['adaptiveFormats'] as List<dynamic>? ??
                  <dynamic>[]),
              ...(streaming['formats'] as List<dynamic>? ?? <dynamic>[]),
            ]
          : <dynamic>[];

      final List<Map<String, dynamic>> audio = formats
          .whereType<Map<String, dynamic>>()
          .where((Map<String, dynamic> f) =>
              '${f['mimeType']}'.startsWith('audio'))
          .toList();

      stdout.writeln('  статус: $state ${reason.isEmpty ? "" : "($reason)"}');
      stdout.writeln('  форматов: ${formats.length}, аудио: ${audio.length}');

      final List<Map<String, dynamic>> direct = audio
          .where((Map<String, dynamic> f) => f['url'] != null)
          .toList();
      if (direct.isEmpty) {
        stdout.writeln('  прямых ссылок нет'
            '${audio.isEmpty ? "" : " (нужна расшифровка подписи)"}');
        continue;
      }

      direct.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
          ((b['bitrate'] as num?) ?? 0).compareTo((a['bitrate'] as num?) ?? 0));
      final Uri url = Uri.parse(direct.first['url'] as String);
      stdout.writeln('  ссылка: c=${url.queryParameters['c']} '
          'clen=${url.queryParameters['clen']}');

      final bool first = await _range(url, 0, 1048575, profile.userAgent);
      final bool middle = await _range(url, 1048576, 2097151, profile.userAgent);
      final bool far = await _range(url, 3000000, 3100000, profile.userAgent);
      stdout.writeln('  диапазоны: начало ${first ? "ок" : "нет"}, '
          'после 1 МБ ${middle ? "ок" : "нет"}, '
          'дальний участок ${far ? "ок" : "нет"}');

      if (middle && far) {
        stdout.writeln('  ==> ЭТОТ КЛИЕНТ ОТДАЁТ ФАЙЛ ЦЕЛИКОМ');
        File('/tmp/opencode/working_client.txt')
            .writeAsStringSync('${profile.label}|${profile.name}|'
                '${profile.version}|${profile.numericId}');
      }
    } on Object catch (error) {
      stdout.writeln('  ошибка: ${error.toString().split('\n').first}');
    }
  }

  client.dispose();
  await BypassManager.instance.dispose();
  exit(0);
}

Future<bool> _range(Uri url, int start, int end, String userAgent) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, userAgent);
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
