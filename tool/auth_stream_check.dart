// Проверяет, поднимает ли вход в аккаунт ограничение выдачи потока.
//
// Запуск: dart run tool/auth_stream_check.dart [videoId]
//
// Берёт сохранённую сессию приложения и пробует получить поток с входом и без.
import 'dart:convert';
import 'dart:io';

import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

const String _uaVr = 'com.google.android.apps.youtube.vr.oculus/1.65.10 '
    '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';

const String _sessionPath =
    '/home/perqa/.local/share/com.mops.mops/session.json';

/// HTTP-клиент библиотеки с добавленными заголовками авторизации.
class _AuthHttpClient extends YoutubeHttpClient {
  _AuthHttpClient(this._extra);

  final Map<String, String> _extra;

  @override
  Map<String, String> get headers => <String, String>{
        ...super.headers,
        ..._extra,
      };
}

Future<void> main(List<String> args) async {
  final String videoId = args.isNotEmpty ? args.first : '9RfVp-GhKfs';
  await BypassManager.instance.apply(const AntiDpiConfig());

  final String cookieString = (jsonDecode(
    File(_sessionPath).readAsStringSync(),
  ) as Map<String, dynamic>)['cookieString'] as String;

  final CookieAuth auth = CookieAuth(cookieString);
  stdout.writeln('сессия: cookie ${cookieString.length} символов, '
      'подпись ${auth.isUsable ? "есть" : "НЕТ"}');

  // 1. Свой клиент: Android VR, с входом и без.
  for (final bool useAuth in <bool>[true, false]) {
    stdout.writeln('\n=== Android VR, '
        '${useAuth ? "с входом" : "без входа"} ===');
    await _check(
      videoId,
      auth: useAuth ? auth : const AnonymousAuth(),
      authenticated: useAuth,
    );
  }

  // 2. Клиент библиотеки по умолчанию, с входом.
  stdout.writeln('\n=== клиент библиотеки, с входом ===');
  final YoutubeExplode yt = YoutubeExplode(
    httpClient: _AuthHttpClient(auth.headers),
  );
  try {
    final StreamManifest manifest =
        await yt.videos.streamsClient.getManifest(videoId);
    final List<AudioOnlyStreamInfo> audio = manifest.audioOnly.toList()
      ..sort((AudioOnlyStreamInfo a, AudioOnlyStreamInfo b) =>
          b.bitrate.kiloBitsPerSecond.compareTo(a.bitrate.kiloBitsPerSecond));
    stdout.writeln('  дорожек: ${audio.length}, '
        'c=${audio.first.url.queryParameters['c']}');
    await _ranges(audio.first.url);
  } on Object catch (error) {
    stdout.writeln('  ошибка: ${error.toString().split('\n').first}');
  }
  yt.close();

  await BypassManager.instance.dispose();
  exit(0);
}

Future<void> _check(
  String videoId, {
  required AuthProvider auth,
  required bool authenticated,
}) async {
  final InnerTubeClient client = InnerTubeClient(
    auth: auth,
    locale: 'en',
    region: 'US',
  );
  try {
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
            'userAgent': _uaVr,
            'hl': 'en',
            'gl': 'US',
          },
        },
        'videoId': videoId,
        'contentCheckOk': true,
        'racyCheckOk': true,
      },
      extraHeaders: <String, String>{
        'X-Youtube-Client-Name': '28',
        'X-Youtube-Client-Version': '1.65.10',
        'User-Agent': _uaVr,
      },
      authenticated: authenticated,
    );

    final dynamic status = response['playabilityStatus'];
    stdout.writeln('  статус: ${status is Map ? status['status'] : '?'}');
    final dynamic sd = response['streamingData'];
    final List<Map<String, dynamic>> audio = <dynamic>[
      ...(sd is Map ? (sd['adaptiveFormats'] as List<dynamic>? ?? <dynamic>[]) : <dynamic>[]),
    ]
        .whereType<Map<String, dynamic>>()
        .where((Map<String, dynamic> f) =>
            '${f['mimeType']}'.startsWith('audio') && f['url'] != null)
        .toList();
    if (audio.isEmpty) {
      stdout.writeln('  прямых аудиоссылок нет');
      return;
    }
    audio.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        ((b['bitrate'] as num?) ?? 0).compareTo((a['bitrate'] as num?) ?? 0));
    final Uri url = Uri.parse(audio.first['url'] as String);
    stdout.writeln('  дорожек: ${audio.length}, c=${url.queryParameters['c']}');
    await _ranges(url);
  } on Object catch (error) {
    stdout.writeln('  ошибка: ${error.toString().split('\n').first}');
  } finally {
    client.dispose();
  }
}

Future<void> _ranges(Uri url) async {
  final int first = await _range(url, 0, 1048575);
  final int second = await _range(url, 1048576, 2097151);
  stdout.writeln('  кусок 0 (0–1 МБ):   ${first > 0 ? "ок, $first байт" : "403"}');
  stdout.writeln('  кусок 1 (1–2 МБ):   ${second > 0 ? "ок, $second байт" : "403"}');
}

Future<int> _range(Uri url, int start, int end) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, _uaVr);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
    final HttpClientResponse response =
        await request.close().timeout(const Duration(seconds: 25));
    if (response.statusCode != 206) return 0;
    int got = 0;
    await for (final List<int> part in response) {
      got += part.length;
    }
    return got;
  } on Object {
    return 0;
  } finally {
    client.close(force: true);
  }
}
