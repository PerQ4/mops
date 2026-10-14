// ВРЕМЕННАЯ точка входа для отладки воспроизведения (удаляется после разбора).
//
// Сценарий без участия пользователя: играем очередь из двух треков, смотрим
// каждое изменение состояния контроллера, на 40-й секунде перематываем, на
// 70-й — ставим на паузу и снова запускаем. Так видно и обрыв, и перемотку.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/net/anti_dpi.dart';
import 'core/net/bypass.dart';
import 'data/models/models.dart';
import 'data/sources/stream_proxy.dart';
import 'state/player_controller.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BypassManager.instance.apply(const AntiDpiConfig());

  final DateTime started = DateTime.now();
  void log(String message) {
    final int ms = DateTime.now().difference(started).inMilliseconds;
    // ignore: avoid_print
    print('[$ms мс] $message');
  }

  final SharedPreferences prefs = await SharedPreferences.getInstance();

  final StreamProxy proxy = StreamProxy(verbose: true);
  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      streamProxyProvider.overrideWithValue(proxy),
    ],
  );

  final PlayerController controller =
      container.read(playerControllerProvider.notifier);

  container.listen<PlayerUiState>(
    playerControllerProvider,
    (PlayerUiState? previous, PlayerUiState next) {
      log('СОСТОЯНИЕ индекс=${next.index} '
          'статус=${next.playback.status.name} '
          'поз=${next.playback.position.inMilliseconds} '
          'длит=${next.playback.duration.inMilliseconds} '
          'resolving=${next.resolving} '
          'ошибка=${next.error ?? "-"}');
    },
    fireImmediately: true,
  );

  final List<Track> queue = <Track>[
    const Track(id: '9RfVp-GhKfs', title: 'Трек 1'),
    const Track(id: 'dQw4w9WgXcQ', title: 'Трек 2'),
  ];

  log('СТАРТ очереди');
  await controller.playQueue(queue);

  // Периодический снимок состояния — чтобы видеть, что происходит, даже если
  // событий нет.
  Timer.periodic(const Duration(seconds: 5), (Timer _) {
    final PlayerUiState s = container.read(playerControllerProvider);
    log('СНИМОК индекс=${s.index} статус=${s.playback.status.name} '
        'поз=${s.playback.position.inMilliseconds} '
        'длит=${s.playback.duration.inMilliseconds} ошибка=${s.error ?? "-"}');
  });

  await Future<void>.delayed(const Duration(seconds: 40));
  log('ПЕРЕМОТКА на 30 с');
  await controller.seek(const Duration(seconds: 30));

  await Future<void>.delayed(const Duration(seconds: 25));
  log('ПАУЗА');
  await controller.togglePlayPause();
  await Future<void>.delayed(const Duration(seconds: 3));
  log('ИГРАТЬ (после паузы)');
  await controller.togglePlayPause();

  await Future<void>.delayed(const Duration(seconds: 60));
  log('КОНЕЦ СЦЕНАРИЯ');

  container.dispose();
  await proxy.dispose();
  await BypassManager.instance.dispose();
  log('ГОТОВО');
  exit(0);
}
