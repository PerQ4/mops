import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/audio/audio_engine.dart';
import '../data/models/models.dart';
import '../data/sources/stream_downloader.dart';
import '../data/sources/stream_resolver.dart';
import 'catalog_providers.dart';
import 'providers.dart';

/// Режим повтора.
enum PlayerRepeatMode {
  off('Не повторять'),
  all('Повторять очередь'),
  one('Повторять трек');

  const PlayerRepeatMode(this.label);

  final String label;

  PlayerRepeatMode get next => switch (this) {
        PlayerRepeatMode.off => PlayerRepeatMode.all,
        PlayerRepeatMode.all => PlayerRepeatMode.one,
        PlayerRepeatMode.one => PlayerRepeatMode.off,
      };
}

/// Полное состояние плеера, которое видит интерфейс.
@immutable
class PlayerUiState {
  const PlayerUiState({
    this.queue = const <Track>[],
    this.index = -1,
    this.shuffle = false,
    this.repeat = PlayerRepeatMode.off,
    this.playback = PlaybackState.initial,
    this.resolving = false,
    this.error,
    this.autoPlayRadio = true,
    this.downloading = false,
    this.downloadProgress = 0,
    this.streamNote,
  });

  final List<Track> queue;

  /// Индекс текущего трека в [queue]; -1 — ничего не выбрано.
  final int index;
  final bool shuffle;
  final PlayerRepeatMode repeat;
  final PlaybackState playback;

  /// Идёт получение ссылки на поток (между нажатием и звуком).
  final bool resolving;
  final String? error;
  final bool autoPlayRadio;

  /// Идёт загрузка потока на диск (режим обхода блокировок).
  final bool downloading;

  /// Прогресс загрузки от 0 до 1.
  final double downloadProgress;

  /// Подпись качества потока: контейнер и битрейт, например `WEBM 147`.
  final String? streamNote;

  Track? get current =>
      (index >= 0 && index < queue.length) ? queue[index] : null;

  bool get hasTrack => current != null;
  bool get isPlaying => playback.isPlaying;
  bool get isLoading => resolving || downloading || playback.isLoading;

  /// Треки, которые пойдут следующими (для панели очереди).
  List<Track> get upNext {
    if (index < 0 || queue.isEmpty) return queue;
    return queue.sublist((index + 1).clamp(0, queue.length));
  }

  /// Уже проигранные треки.
  List<Track> get played => index <= 0 ? const <Track>[] : queue.sublist(0, index);

  PlayerUiState copyWith({
    List<Track>? queue,
    int? index,
    bool? shuffle,
    PlayerRepeatMode? repeat,
    PlaybackState? playback,
    bool? resolving,
    String? error,
    bool clearError = false,
    bool? autoPlayRadio,
    bool? downloading,
    double? downloadProgress,
    String? streamNote,
  }) {
    return PlayerUiState(
      queue: queue ?? this.queue,
      index: index ?? this.index,
      shuffle: shuffle ?? this.shuffle,
      repeat: repeat ?? this.repeat,
      playback: playback ?? this.playback,
      resolving: resolving ?? this.resolving,
      error: clearError ? null : (error ?? this.error),
      autoPlayRadio: autoPlayRadio ?? this.autoPlayRadio,
      downloading: downloading ?? this.downloading,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      streamNote: streamNote ?? this.streamNote,
    );
  }
}

/// Управляет очередью и воспроизведением.
///
/// Ответственность: что играет, что дальше, повтор/перемешивание, а также
/// получение ссылки на поток и передача её в [AudioEngine]. Тексты песен
/// и метаданные сюда не входят — за них отвечают отдельные провайдеры.
class PlayerController extends Notifier<PlayerUiState> {
  /// Движок берём через `ref` при каждом обращении: провайдер не меняется,
  /// но так не нужен `late final`, который ломается при пересоздании нотификатора.
  AudioEngine get _engine => ref.read(audioEngineProvider);

  StreamSubscription<PlaybackState>? _engineSub;
  final Random _random = Random();

  /// История проигранных индексов — нужна для «назад» при перемешивании.
  final List<int> _history = <int>[];

  @override
  PlayerUiState build() {
    // Отписка от предыдущего движка (если нотификатор пересоздали).
    _engineSub?.cancel();

    _engineSub = _engine.stateStream.listen((PlaybackState playback) {
      state = state.copyWith(playback: playback);
      if (playback.status == PlaybackStatus.error && playback.error != null) {
        state = state.copyWith(error: playback.error);
      }
      if (playback.status == PlaybackStatus.completed) {
        // Не await: обработчик не должен блокировать поток событий.
        unawaited(_handleTrackEnded());
      }
    });

    // Восстанавливаем громкость и скорость из прошлой сессии.
    final settings = ref.read(settingsControllerProvider);
    unawaited(_engine.setVolume(settings.lastVolume));
    unawaited(_engine.setSpeed(settings.lastSpeed));

    ref.onDispose(() {
      _engineSub?.cancel();
      _engineSub = null;
    });

    return const PlayerUiState();
  }

  // ------------------------------------------------------------- запуск

  /// Заменяет очередь и начинает воспроизведение.
  Future<void> playQueue(
    List<Track> tracks, {
    int startIndex = 0,
    bool? shuffle,
  }) async {
    if (tracks.isEmpty) return;
    final int safeIndex = startIndex.clamp(0, tracks.length - 1);

    _history.clear();
    state = state.copyWith(
      queue: List<Track>.of(tracks),
      index: safeIndex,
      shuffle: shuffle ?? state.shuffle,
      clearError: true,
    );
    await _loadCurrent();
  }

  /// Включает один трек. Если передан контекст — он становится очередью.
  Future<void> playTrack(Track track, {List<Track>? context}) async {
    final List<Track> list = (context == null || context.isEmpty)
        ? <Track>[track]
        : List<Track>.of(context);

    int index = list.indexWhere((Track t) => t.id == track.id);
    if (index < 0) {
      // Трека нет в переданном контексте (например, это «радио»).
      list.insert(0, track);
      index = 0;
    }
    await playQueue(list, startIndex: index);
  }

  /// Добавляет трек в конец очереди.
  void enqueue(Track track) {
    final List<Track> queue = <Track>[...state.queue, track];
    state = state.copyWith(queue: queue);
  }

  /// Ставит трек сразу после текущего.
  void playNext(Track track) {
    if (!state.hasTrack) {
      unawaited(playTrack(track));
      return;
    }
    final List<Track> queue = <Track>[...state.queue];
    queue.insert(state.index + 1, track);
    state = state.copyWith(queue: queue);
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= state.queue.length) return;
    final List<Track> queue = <Track>[...state.queue]..removeAt(index);

    int newIndex = state.index;
    if (index < state.index) {
      newIndex = state.index - 1;
    } else if (index == state.index) {
      newIndex = state.index.clamp(0, queue.length - 1);
    }
    state = state.copyWith(queue: queue, index: queue.isEmpty ? -1 : newIndex);
    if (queue.isEmpty) unawaited(_engine.stop());
  }

  /// Переставляет элемент очереди.
  ///
  /// [newIndex] — итоговая позиция: элемент [oldIndex] уже мысленно удалён
  /// (такова семантика `onReorderItem`).
  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= state.queue.length) return;

    final List<Track> queue = <Track>[...state.queue];
    final Track moved = queue.removeAt(oldIndex);
    final int target = newIndex.clamp(0, queue.length);
    queue.insert(target, moved);

    int currentIndex = state.index;
    if (oldIndex == state.index) {
      currentIndex = target;
    } else if (oldIndex < state.index && target >= state.index) {
      currentIndex = state.index - 1;
    } else if (oldIndex > state.index && target <= state.index) {
      currentIndex = state.index + 1;
    }
    state = state.copyWith(queue: queue, index: currentIndex);
  }

  Future<void> clearQueue() async {
    _history.clear();
    state = const PlayerUiState();
    await _engine.stop();
  }

  /// Переход к конкретному элементу очереди.
  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    _pushHistory(state.index);
    state = state.copyWith(index: index, clearError: true);
    await _loadCurrent();
  }

  // ----------------------------------------------------------- управление

  Future<void> togglePlayPause() async {
    if (!state.hasTrack) return;
    if (state.isPlaying) {
      await _engine.pause();
    } else {
      await _engine.play();
    }
  }

  Future<void> play() => _engine.play();

  Future<void> pause() => _engine.pause();

  Future<void> next() => _advance(manual: true);

  Future<void> previous() async {
    // Как в большинстве плееров: если трек проигран больше 3 секунд —
    // «назад» перематывает в начало, а не переключает трек.
    if (state.playback.position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }

    if (_history.isNotEmpty) {
      final int index = _history.removeLast();
      state = state.copyWith(index: index, clearError: true);
      await _loadCurrent();
      return;
    }

    if (state.shuffle && state.queue.length > 1) {
      await jumpTo(_randomIndex());
      return;
    }

    final int target = state.index - 1;
    if (target >= 0) {
      state = state.copyWith(index: target, clearError: true);
      await _loadCurrent();
    } else {
      await seek(Duration.zero);
    }
  }

  Future<void> seek(Duration position) => _engine.seek(position);

  Future<void> seekFraction(double fraction) {
    final Duration duration = state.playback.duration;
    if (duration <= Duration.zero) return Future<void>.value();
    return _engine.seek(duration * fraction.clamp(0.0, 1.0));
  }

  Future<void> setVolume(double volume) async {
    await _engine.setVolume(volume);
    await ref.read(settingsControllerProvider.notifier).setLastVolume(volume);
  }

  Future<void> setSpeed(double speed) async {
    await _engine.setSpeed(speed);
    await ref.read(settingsControllerProvider.notifier).setLastSpeed(speed);
  }

  void toggleShuffle() {
    state = state.copyWith(shuffle: !state.shuffle);
    if (state.shuffle) _history.clear();
  }

  void cycleRepeat() {
    state = state.copyWith(repeat: state.repeat.next);
  }

  void setAutoPlayRadio(bool value) {
    state = state.copyWith(autoPlayRadio: value);
  }

  /// Локальный адрес текущего потока — чтобы освободить прошлый.
  Uri? _localStream;

  // -------------------------------------------------------------- private

  Future<void> _loadCurrent() async {
    final Track? track = state.current;
    if (track == null) return;

    state = state.copyWith(resolving: true, clearError: true);

    // Новый трек: прошлый останавливаем сразу, не дожидаясь загрузки.
    await _engine.stop();

    try {
      final quality = ref.read(settingsControllerProvider).audioQuality;
      final ResolvedStream resolved = await ref
          .read(streamResolverProvider)
          .resolve(track.id, quality: quality);

      // Пока получали ссылку, пользователь мог переключить трек — тогда
      // загрузку надо отменить, иначе заиграет «не тот».
      if (state.current?.id != track.id) return;

      state = state.copyWith(streamNote: _noteFor(resolved));

      // Играем потоком через локального посредника: GStreamer подключается к
      // нему, а данные у YouTube качает приложение запросами с диапазоном
      // (обычный GET медиасервер отклоняет). Так трек начинает играть сразу,
      // без полной загрузки, а прошлый трек звучит до последнего момента.
      final Uri local = await ref.read(streamProxyProvider).serve(
            resolved.url,
            userAgent: resolved.userAgent,
            mimeType: resolved.mimeType,
          );
      if (state.current?.id != track.id) {
        ref.read(streamProxyProvider).release(local);
        return;
      }

      // Прошлый поток больше не нужен.
      final Uri? previous = _localStream;
      _localStream = local;
      if (previous != null) {
        ref.read(streamProxyProvider).release(previous);
      }

      await _engine.load(local.toString(), autoplay: true);
      state = state.copyWith(resolving: false);
      return;
    } on StreamResolutionException catch (error) {
      state = state.copyWith(
        resolving: false,
        downloading: false,
        error: error.message,
      );
    } on StreamDownloadException catch (error) {
      state = state.copyWith(
        resolving: false,
        downloading: false,
        error: error.message,
      );
    } on Exception catch (error) {
      state = state.copyWith(
        resolving: false,
        downloading: false,
        error: 'Ошибка воспроизведения: $error',
      );
    }
  }

  /// Подпись качества: контейнер и битрейт потока.
  String? _noteFor(ResolvedStream stream) {
    final String? container = stream.container;
    final int? kbps = stream.bitrateKbps;
    if (container == null && kbps == null) return null;
    final String name = (container ?? '').toUpperCase();
    return <String>[
      if (name.isNotEmpty) name,
      if (kbps != null) '$kbps',
    ].join(' ');
  }

  Future<void> _handleTrackEnded() async {
    if (state.repeat == PlayerRepeatMode.one) {
      await _engine.seek(Duration.zero);
      await _engine.play();
      return;
    }
    await _advance(manual: false);
  }

  /// Переход вперёд.
  ///
  /// [manual] — нажатие кнопки; при автоматическом переходе в конце очереди
  /// включается «радио по треку», если это разрешено настройками.
  Future<void> _advance({required bool manual}) async {
    if (state.queue.isEmpty) return;

    if (state.shuffle && state.queue.length > 1) {
      _pushHistory(state.index);
      state = state.copyWith(index: _randomIndex(), clearError: true);
      await _loadCurrent();
      return;
    }

    final int target = state.index + 1;
    if (target < state.queue.length) {
      _pushHistory(state.index);
      state = state.copyWith(index: target, clearError: true);
      await _loadCurrent();
      return;
    }

    // Конец очереди.
    if (state.repeat == PlayerRepeatMode.all) {
      _pushHistory(state.index);
      state = state.copyWith(index: 0, clearError: true);
      await _loadCurrent();
      return;
    }

    if (manual) return; // пользователь сам решает, что дальше

    if (state.autoPlayRadio) {
      await _extendWithRadio();
      return;
    }

    state = state.copyWith(
      playback: state.playback.copyWith(status: PlaybackStatus.paused),
    );
  }

  /// Дополняет очередь рекомендациями YouTube («радио по треку»).
  Future<void> _extendWithRadio() async {
    final Track? seed =
        state.current ?? (state.queue.isEmpty ? null : state.queue.last);
    if (seed == null) return;

    try {
      final List<Track> radio =
          await ref.read(catalogSourceProvider).autoplayQueue(seed.id);
      final Set<String> known =
          state.queue.map((Track t) => t.id).toSet();
      final List<Track> fresh = radio
          .where((Track t) => !known.contains(t.id))
          .take(25)
          .toList();

      if (fresh.isEmpty) {
        state = state.copyWith(
          playback: state.playback.copyWith(status: PlaybackStatus.paused),
        );
        return;
      }

      final List<Track> queue = <Track>[...state.queue, ...fresh];
      _pushHistory(state.index);
      state = state.copyWith(queue: queue, index: state.index + 1);
      await _loadCurrent();
    } on Exception catch (error) {
      state = state.copyWith(error: 'Не удалось загрузить рекомендации: $error');
    }
  }

  void _pushHistory(int index) {
    if (index < 0) return;
    _history.add(index);
    // История не должна расти бесконечно.
    if (_history.length > 200) _history.removeAt(0);
  }

  int _randomIndex() {
    if (state.queue.length <= 1) return 0;
    int candidate = state.index;
    // Ищем другой трек; ограничиваем попытки, чтобы не зациклиться.
    for (int i = 0; i < 20 && candidate == state.index; i++) {
      candidate = _random.nextInt(state.queue.length);
    }
    if (candidate == state.index) {
      candidate = (state.index + 1) % state.queue.length;
    }
    return candidate;
  }
}

final NotifierProvider<PlayerController, PlayerUiState> playerControllerProvider =
    NotifierProvider<PlayerController, PlayerUiState>(PlayerController.new);

/// Текущий трек — отдельный провайдер, чтобы интерфейс не перестраивался
/// на каждое изменение позиции воспроизведения.
final Provider<Track?> currentTrackProvider = Provider<Track?>((ref) {
  return ref.watch(
    playerControllerProvider.select((PlayerUiState s) => s.current),
  );
});
