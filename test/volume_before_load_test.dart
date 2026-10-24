// Громкость до первого трека.
//
// Симптом: до запуска воспроизведения ползунок не двигался, а сохранённая
// громкость не доходила до движка. Причина — контроллер выбрасывал состояние
// движка со статусом `idle`, пока ждал восстановленную очередь, а само значение
// громкости нигде, кроме настроек, не хранилось.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mops/core/audio/audio_engine.dart';
import 'package:mops/data/local/app_settings.dart';
import 'package:mops/data/local/downloads.dart';
import 'package:mops/data/local/listening_stats.dart';
import 'package:mops/data/local/queue_snapshot.dart';
import 'package:mops/data/models/models.dart';
import 'package:mops/data/sources/stream_resolver.dart';
import 'package:mops/state/player_controller.dart';
import 'package:mops/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Движок, который помнит громкость: по ней видно, что значение дошло до
/// открытия потока, а не только до состояния интерфейса.
class _VolumeEngine implements AudioEngine {
  final StreamController<PlaybackState> _states =
      StreamController<PlaybackState>.broadcast();
  final ValueNotifier<String?> _effectIssue = ValueNotifier<String?>(null);

  PlaybackState _state = PlaybackState.initial;

  /// Все запрошенные громкости по порядку.
  final List<double> volumes = <double>[];

  /// Сколько было выставлено к моменту `load` — то, с чем трек зазвучит.
  double? volumeAtLoad;

  final List<String> loaded = <String>[];

  @override
  Stream<PlaybackState> get stateStream => _states.stream;

  @override
  PlaybackState get state => _state;

  void emit(PlaybackState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  @override
  Future<void> load(
    String source, {
    bool autoplay = true,
    bool isLocal = false,
  }) async {
    loaded.add(source);
    volumeAtLoad = volumes.isEmpty ? null : volumes.last;
    _state = PlaybackState(
      status: PlaybackStatus.loading,
      volume: volumeAtLoad ?? 1.0,
    );
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {
    _state = PlaybackState.initial;
  }

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
  }

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  bool get supportsPitch => false;

  @override
  Future<void> setPitch(double pitch) async {}

  @override
  List<AudioOutputDevice> get audioDevices => const <AudioOutputDevice>[];

  @override
  Stream<List<AudioOutputDevice>> get audioDevicesStream =>
      const Stream<List<AudioOutputDevice>>.empty();

  @override
  Future<void> setAudioDevice(String name) async {}

  @override
  Future<void> setEqualizer(List<double> bands) async {}

  @override
  Future<void> setSkipSilence(bool enabled) async {}

  @override
  Future<void> setAudioNormalization(bool enabled) async {}

  @override
  ValueListenable<String?> get audioEffectIssue => _effectIssue;

  @override
  Future<void> dispose() async {
    _effectIssue.dispose();
    await _states.close();
  }
}

class _FakeResolver implements StreamResolver {
  @override
  bool get isAvailable => true;

  @override
  Future<ResolvedStream> resolve(
    String videoId, {
    required AudioQuality quality,
    String? preferContainer,
  }) async =>
      ResolvedStream(
        url: Uri.parse('https://media.test/$videoId'),
        bitrateKbps: 128,
        container: 'm4a',
        mimeType: 'audio/mp4',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      );

  @override
  void dispose() {}
}

class _MemoryListeningStore extends ListeningStatsStore {
  final List<ListenEvent> events = <ListenEvent>[];

  @override
  Future<List<ListenEvent>> readAll() async =>
      List<ListenEvent>.unmodifiable(events);

  @override
  Future<void> writeAll(List<ListenEvent> next) async {
    events
      ..clear()
      ..addAll(next);
  }

  @override
  Future<void> clear() async => events.clear();
}

const Track _kTrack = Track(
  id: '0s-yNUdAC8A',
  title: 'Громкий трек',
  duration: Duration(seconds: 10),
);

Future<ProviderContainer> _container({
  required AudioEngine engine,
  double lastVolume = 1.0,
  bool withSnapshot = false,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    if (withSnapshot)
      kQueueSnapshotKey: const QueueSnapshot(
        tracks: <Track>[_kTrack],
        index: 0,
        position: Duration(seconds: 3),
      ).encode(),
  });
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final Directory downloadsDir =
      Directory.systemTemp.createTempSync('mops-volume-downloads-');
  addTearDown(() {
    if (downloadsDir.existsSync()) downloadsDir.deleteSync(recursive: true);
  });

  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      initialSettingsProvider.overrideWithValue(
        AppSettings(
          playback: PlaybackSettings(
            lastVolume: lastVolume,
            preloadNextTrack: false,
          ),
        ),
      ),
      initialSessionProvider.overrideWithValue(null),
      audioEngineProvider.overrideWithValue(engine),
      streamResolverProvider.overrideWithValue(_FakeResolver()),
      listeningStatsStoreProvider.overrideWithValue(_MemoryListeningStore()),
      downloadsStoreProvider
          .overrideWithValue(DownloadsStore(directory: downloadsDir)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('setVolume(0.3) до загрузки: ползунок двигается, значение доходит до load',
      () async {
    final _VolumeEngine engine = _VolumeEngine();
    final ProviderContainer container = await _container(engine: engine);
    final PlayerController controller =
        container.read(playerControllerProvider.notifier);

    await controller.setVolume(0.3);

    // Интерфейс не ждёт подтверждения движка.
    expect(container.read(playerControllerProvider).playback.volume, 0.3);
    expect(engine.volumes.last, 0.3,
        reason: 'значение сразу передано движку');

    await controller.playTrack(_kTrack);

    expect(engine.loaded, hasLength(1));
    expect(engine.volumeAtLoad, 0.3,
        reason: 'трек открывается уже с выбранной громкостью');
    expect(engine.volumes.last, 0.3,
        reason: 'после открытия потока громкость передана повторно');
    expect(container.read(playerControllerProvider).playback.volume, 0.3);
  });

  test('быстрые повторные вызовы: побеждает последнее значение', () async {
    final _VolumeEngine engine = _VolumeEngine();
    final ProviderContainer container = await _container(engine: engine);
    final PlayerController controller =
        container.read(playerControllerProvider.notifier);

    // Ползунок можно тащить быстрее, чем движок успевает подтвердить запись.
    await Future.wait<void>(<Future<void>>[
      controller.setVolume(0.2),
      controller.setVolume(0.7),
    ]);

    expect(container.read(playerControllerProvider).playback.volume, 0.7);
    expect(engine.volumes.last, 0.7,
        reason: 'на движке не должно остаться предпоследнее значение');

    await controller.playTrack(_kTrack);
    expect(engine.volumeAtLoad, 0.7);
  });

  test('восстановленная очередь: громкость из настроек видна сразу', () async {
    final _VolumeEngine engine = _VolumeEngine();
    final ProviderContainer container = await _container(
      engine: engine,
      lastVolume: 0.5,
      withSnapshot: true,
    );

    PlayerUiState player = container.read(playerControllerProvider);
    expect(player.current?.id, _kTrack.id);
    expect(player.playback.volume, 0.5,
        reason: 'восстановленный трек не должен обнулять громкость');

    // «Пустой» движок до первого трека присылает idle — он не должен стирать
    // ни громкость, ни восстановленную позицию.
    engine.emit(const PlaybackState(
      status: PlaybackStatus.idle,
      volume: 0.5,
    ));
    await Future<void>.delayed(Duration.zero);

    player = container.read(playerControllerProvider);
    expect(player.playback.status, PlaybackStatus.paused);
    expect(player.playback.position, const Duration(seconds: 3));
    expect(player.playback.volume, 0.5);

    // И повторная установка громкости тоже видна без трека.
    await container.read(playerControllerProvider.notifier).setVolume(0.2);
    expect(container.read(playerControllerProvider).playback.volume, 0.2);
    expect(engine.volumes.last, 0.2);
  });
}
