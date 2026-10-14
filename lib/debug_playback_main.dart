// ВРЕМЕННАЯ точка входа для отладки воспроизведения (удаляется после разбора).
//
// Запуск без участия пользователя:
//   flutter build linux --release -t lib/debug_playback_main.dart --no-tree-shake-icons
//   GST_DEBUG=2 ./build/linux/x64/release/bundle/mops > /tmp/opencode/playback.log 2>&1
//
// Сценарий: получить поток, играть 20 с, перемотать на середину, ждать 20 с,
// нажать «играть», ждать ещё 20 с — печатая каждое событие движка.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'core/audio/audio_engine.dart';
import 'core/audio/audioplayers_engine.dart';
import 'core/innertube/innertube_client.dart';
import 'core/net/anti_dpi.dart';
import 'core/net/bypass.dart';
import 'data/local/app_settings.dart';
import 'data/sources/stream_proxy.dart';
import 'data/sources/stream_resolver.dart';

/// Трек для проверки — тот же, что в `tool/audio_range_check.dart`.
const String kVideoId = '9RfVp-GhKfs';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BypassManager.instance.apply(const AntiDpiConfig());

  final DateTime started = DateTime.now();
  String stamp() => '[${DateTime.now().difference(started).inMilliseconds} мс]';
  void log(String message) {
    // ignore: avoid_print
    print(message);
  }

  final InnerTubeClient tube = InnerTubeClient(locale: 'ru', region: 'RU');
  final YoutubeStreamResolver resolver = YoutubeStreamResolver(
    innerTube: tube,
    locale: 'ru',
    region: 'RU',
    clientChoice: StreamSource.auto,
  );
  final StreamProxy proxy = StreamProxy(verbose: true);
  final AudioEngine engine = AudioplayersEngine();

  engine.stateStream.listen((PlaybackState s) {
    log('${stamp()} СОСТОЯНИЕ ${s.status.name} '
        'поз=${s.position.inMilliseconds} мс '
        'длит=${s.duration.inMilliseconds} мс '
        'ошибка=${s.error ?? "-"}');
  });

  try {
    final ResolvedStream resolved =
        await resolver.resolve(kVideoId, quality: AudioQuality.high);
    final int clen =
        int.tryParse(resolved.url.queryParameters['clen'] ?? '') ?? 0;
    log('${stamp()} ССЫЛКА c=${resolved.url.queryParameters['c']} '
        'контейнер=${resolved.container} mime=${resolved.mimeType} '
        'clen=$clen');

    final Uri local = await proxy.serve(
      resolved.url,
      userAgent: resolved.userAgent,
      mimeType: resolved.mimeType,
    );
    log('${stamp()} ЛОКАЛЬНО $local');

    await engine.load(local.toString(), autoplay: true);
    await Future<void>.delayed(const Duration(seconds: 20));
    log('${stamp()} ПОСЛЕ 20 С: ${engine.state.status.name} '
        'поз=${engine.state.position.inMilliseconds} '
        'длит=${engine.state.duration.inMilliseconds}');

    final Duration target = engine.state.duration > Duration.zero
        ? engine.state.duration ~/ 2
        : const Duration(seconds: 60);
    log('${stamp()} ПЕРЕМОТКА на ${target.inMilliseconds} мс');
    await engine.seek(target);
    log('${stamp()} ПОСЛЕ SEEK: ${engine.state.status.name} '
        'поз=${engine.state.position.inMilliseconds} '
        'длит=${engine.state.duration.inMilliseconds}');

    await Future<void>.delayed(const Duration(seconds: 20));
    log('${stamp()} SEEK +20 С: ${engine.state.status.name} '
        'поз=${engine.state.position.inMilliseconds} '
        'длит=${engine.state.duration.inMilliseconds}');

    log('${stamp()} НАЖАТИЕ «ИГРАТЬ»');
    await engine.play();
    await Future<void>.delayed(const Duration(seconds: 20));
    log('${stamp()} PLAY +20 С: ${engine.state.status.name} '
        'поз=${engine.state.position.inMilliseconds} '
        'длит=${engine.state.duration.inMilliseconds}');
  } on Object catch (error) {
    log('${stamp()} ИСКЛЮЧЕНИЕ: $error');
  }

  await engine.dispose();
  await proxy.dispose();
  resolver.dispose();
  tube.dispose();
  await BypassManager.instance.dispose();
  log('${stamp()} ГОТОВО');
  exit(0);
}
