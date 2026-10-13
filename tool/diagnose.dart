// Пошаговая диагностика доступа к YouTube Music.
//
// Запуск: dart run tool/diagnose.dart [videoId]
//
// Отвечает на вопрос «где именно обрывается», проверяя каждое звено
// по отдельности: DNS, доступ к API напрямую и с подменой, доступность
// медиахоста, получение ссылки на поток и скачивание первых байтов.
import 'dart:io';

import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:mops/core/net/fronting.dart';
import 'package:mops/core/net/local_proxy.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

const String kHost = 'music.youtube.com';
const String kMediaHost = 'redirector.googlevideo.com';

Future<void> main(List<String> args) async {
  final String videoId = args.isNotEmpty ? args.first : '9RfVp-GhKfs';

  _title('1. DNS: есть ли IPv4-адрес');
  await _checkDns(kHost);
  await _checkDns('www.google.com');
  await _checkDns('youtube.com');

  _title('2. Доступ к API YouTube Music');
  final bool direct =
      await ConnectivityCheck.dataReachable(fronting: false);
  _line('напрямую', direct);
  final bool fronted =
      await ConnectivityCheck.dataReachable(fronting: true);
  _line('с подменой хоста', fronted);

  _title('3. Доступность медиахоста (звук)');
  final bool media = await ConnectivityCheck.mediaReachable();
  _line('$kMediaHost напрямую', media);

  _title('4. Локальный прокси');
  final LocalProxy? proxy = await LocalProxyDetector.find();
  _line('найден', proxy != null, extra: proxy?.toString());

  // Дальше проверяем два режима по очереди.
  await _checkStreams(videoId, fronting: fronted, label: 'с подменой хоста');
  await _checkStreams(videoId, fronting: false, label: 'напрямую');

  await BypassManager.instance.dispose();
  exit(0);
}

Future<void> _checkStreams(
  String videoId, {
  required bool fronting,
  required String label,
}) async {
  _title('5. Получение ссылки на поток: $label');

  await BypassManager.instance.apply(
    AntiDpiConfig(fronting: FrontingConfig(enabled: fronting)),
  );
  stdout.writeln('   обход: ${BypassManager.instance.isActive}');

  final YoutubeExplode yt = YoutubeExplode();
  Uri? url;
  try {
    final StreamManifest manifest = await yt.videos.streamsClient
        .getManifest(videoId)
        .timeout(const Duration(seconds: 30));
    final List<AudioOnlyStreamInfo> audio = manifest.audioOnly.toList()
      ..sort((AudioOnlyStreamInfo a, AudioOnlyStreamInfo b) =>
          b.bitrate.kiloBitsPerSecond.compareTo(a.bitrate.kiloBitsPerSecond));
    _line('дорожек найдено: ${audio.length}', audio.isNotEmpty);
    if (audio.isNotEmpty) {
      url = audio.first.url;
      stdout.writeln('   лучшая: ${audio.first.bitrate.kiloBitsPerSecond.round()} '
          'kbps ${audio.first.audioCodec}');
    }
  } on Object catch (error) {
    // Здесь чаще всего и обрывается: библиотека не смогла получить данные.
    _line('ошибка: ${error.runtimeType}', false);
    stdout.writeln('   ${error.toString().split('\n').first}');
  } finally {
    yt.close();
  }

  if (url != null) {
    await _checkDownload(url);
  }
  await BypassManager.instance.dispose();
}

Future<void> _checkDownload(Uri url) async {
  stdout.writeln('   скачивание первых байтов…');
  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    final HttpClientRequest request = await client.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
    final HttpClientResponse response =
        await request.close().timeout(const Duration(seconds: 15));
    int received = 0;
    await for (final List<int> chunk in response) {
      received += chunk.length;
      if (received > 300_000) break;
    }
    _line('HTTP ${response.statusCode}, получено $received байт',
        response.statusCode == 200 && received > 1000);
  } on Object catch (error) {
    _line('${error.runtimeType}: ${error.toString().split('\n').first}', false);
  } finally {
    client?.close(force: true);
  }
}

Future<void> _checkDns(String host) async {
  try {
    final List<InternetAddress> v4 =
        await InternetAddress.lookup(host, type: InternetAddressType.IPv4);
    final List<InternetAddress> v6 =
        await InternetAddress.lookup(host, type: InternetAddressType.IPv6);
    stdout.writeln('   ${host.padRight(32)} '
        'IPv4: ${v4.isEmpty ? "нет" : v4.first.address}  '
        'IPv6: ${v6.isEmpty ? "нет" : "есть"}');
  } on Object {
    stdout.writeln('   ${host.padRight(32)} не разрешается');
  }
}

void _title(String text) {
  stdout.writeln('\n=== $text ===');
}

void _line(String label, bool ok, {String? extra}) {
  stdout.writeln('   ${ok ? "✓" : "✗"} $label'
      '${extra == null ? "" : " — $extra"}');
}
