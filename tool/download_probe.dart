// Проверка скачивания настоящего трека.
//
// Запуск: dart run tool/download_probe.dart [videoId]
//
// Берёт ссылку на поток так же, как приложение, и качает файл тем же
// кодом (RangeDownloader). Если файл скачался — звук заработает.
import 'dart:io';

import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:mops/core/net/fronting.dart';
import 'package:mops/data/sources/range_downloader.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> main(List<String> args) async {
  final String videoId = args.isNotEmpty ? args.first : '9RfVp-GhKfs';

  await BypassManager.instance.apply(const AntiDpiConfig());
  stdout.writeln('обход включён: ${BypassManager.instance.isActive}');

  final YoutubeExplode yt = YoutubeExplode();
  late final Uri url;
  late final int bitrateKbps;
  try {
    final StreamManifest manifest = await yt.videos.streamsClient
        .getManifest(videoId)
        .timeout(const Duration(seconds: 30));
    final List<AudioOnlyStreamInfo> audio = manifest.audioOnly.toList()
      ..sort((AudioOnlyStreamInfo a, AudioOnlyStreamInfo b) =>
          b.bitrate.kiloBitsPerSecond.compareTo(a.bitrate.kiloBitsPerSecond));
    if (audio.isEmpty) {
      stdout.writeln('аудиодорожек нет');
      exitCode = 1;
      return;
    }
    url = audio.first.url;
    bitrateKbps = audio.first.bitrate.kiloBitsPerSecond.round();
    stdout.writeln('нашлась дорожка: $bitrateKbps kbps '
        '${audio.first.audioCodec}');
    stdout.writeln('медиахост: ${url.host}');
    stdout.writeln('подмена применяется к нему: '
        '${const FrontingConfig().shouldFront(url.host)}');
  } on Object catch (error) {
    stdout.writeln('не удалось получить ссылку: $error');
    yt.close();
    await BypassManager.instance.dispose();
    exitCode = 1;
    return;
  }
  yt.close();

  final Directory dir = Directory('/tmp/opencode/download_probe');
  if (dir.existsSync()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  final File target = File('${dir.path}/$videoId.audio');

  stdout.writeln('\nскачиваю…');
  final Stopwatch watch = Stopwatch()..start();
  double lastReported = -1;
  try {
    final RangeDownloader downloader = RangeDownloader();
    final int bytes = await downloader.downloadTo(
      url,
      target,
      onProgress: (double progress) {
        final int percent = (progress * 100).round();
        if (percent != lastReported && percent % 20 == 0) {
          lastReported = percent.toDouble();
          stdout.writeln('   $percent%');
        }
      },
    );
    watch.stop();
    downloader.dispose();

    final double seconds = watch.elapsedMilliseconds / 1000;
    stdout.writeln('\n✓ скачано $bytes байт за ${seconds.toStringAsFixed(1)} с '
        '(${(bytes / 1024 / seconds).toStringAsFixed(0)} КБ/с)');
    stdout.writeln('  файл: ${target.path}');
    stdout.writeln('  ожидаемый битрейт $bitrateKbps kbps');

    final int secondsOfAudio = bytes * 8 ~/ (bitrateKbps * 1000);
    stdout.writeln('  этого хватит примерно на $secondsOfAudio с звука');
    stdout.writeln('\nИТОГ: звук скачивается, воспроизведение возможно.');
  } on Object catch (error) {
    stdout.writeln('\n✗ ${error.toString().split('\n').first}');
    exitCode = 1;
  } finally {
    await BypassManager.instance.dispose();
  }

  exit(exitCode);
}
