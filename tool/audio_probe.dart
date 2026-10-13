// Проверка скачивания аудиопотока при включённом обходе.
//
// Запуск: dart run tool/audio_probe.dart [videoId]
//
// Проверяет, что ссылку на поток удаётся получить и что сами байты
// действительно скачиваются через приложение (GStreamer сюда не входит:
// при обходе звук качает приложение и проигрывает из кэша).
import 'dart:io';

import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:mops/core/net/fronting.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> main(List<String> args) async {
  final String videoId = args.isNotEmpty ? args.first : '9RfVp-GhKfs';

  await BypassManager.instance.apply(
    const AntiDpiConfig(fronting: FrontingConfig(enabled: true)),
  );
  stdout.writeln('Обход включён: ${BypassManager.instance.isActive}\n');

  final YoutubeExplode yt = YoutubeExplode();
  try {
    stdout.writeln('=== Получение потоков для $videoId ===');
    final StreamManifest manifest =
        await yt.videos.streamsClient.getManifest(videoId);
    final List<AudioOnlyStreamInfo> audio = manifest.audioOnly.toList()
      ..sort((AudioOnlyStreamInfo a, AudioOnlyStreamInfo b) =>
          b.bitrate.kiloBitsPerSecond.compareTo(a.bitrate.kiloBitsPerSecond));

    stdout.writeln('  аудиодорожек: ${audio.length}');
    for (final AudioOnlyStreamInfo stream in audio.take(4)) {
      stdout.writeln('    • ${stream.container.name} '
          '${stream.bitrate.kiloBitsPerSecond.round()} kbps '
          '${stream.audioCodec}');
    }
    if (audio.isEmpty) {
      stdout.writeln('  НЕТ АУДИОДОРОЖЕК');
      exitCode = 1;
      return;
    }

    final AudioOnlyStreamInfo best = audio.first;
    stdout.writeln('\n=== Скачивание ${best.bitrate.kiloBitsPerSecond.round()} kbps ===');

    final HttpClient client = HttpClient();
    final HttpClientRequest request = await client.getUrl(best.url);
    request.headers.set(HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0)');
    final HttpClientResponse response = await request.close();
    stdout.writeln('  HTTP ${response.statusCode}, '
        'заявлено ${response.contentLength} байт');

    int received = 0;
    final Stopwatch watch = Stopwatch()..start();
    await for (final List<int> chunk in response) {
      received += chunk.length;
      // Достаточно первых мегабайтов: проверяем сам факт передачи данных.
      if (received > 1_500_000) break;
    }
    watch.stop();

    final double kbps = received / 1024 / (watch.elapsedMilliseconds / 1000);
    stdout.writeln('  получено $received байт за '
        '${watch.elapsedMilliseconds} мс (${kbps.toStringAsFixed(0)} КБ/с)');
    stdout.writeln(received > 100_000
        ? '\nИТОГ: аудио скачивается, воспроизведение возможно.'
        : '\nИТОГ: данных слишком мало — что-то не так.');
    if (received <= 100_000) exitCode = 1;
    client.close(force: true);
  } on Object catch (error, stack) {
    stdout.writeln('\nОШИБКА: $error');
    stdout.writeln(stack.toString().split('\n').take(4).join('\n'));
    exitCode = 1;
  } finally {
    yt.close();
    await BypassManager.instance.dispose();
  }
  exit(exitCode);
}
