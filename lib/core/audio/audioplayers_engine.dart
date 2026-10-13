import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import 'audio_engine.dart';

/// Реализация [AudioEngine] поверх `audioplayers`.
///
/// Почему `audioplayers`: это единственный бэкенд, который работает на всех
/// целевых платформах без установки дополнительных системных пакетов.
/// На Linux он использует GStreamer (opus, matroska и `souphttpsrc` для
/// HTTPS-стриминга), на Windows/macOS/Android/iOS — нативные плееры,
/// в вебе — HTML5 audio.
///
/// Если позже понадобится gapless и точный seek, этот класс заменяется на
/// реализацию поверх `media_kit` — интерфейс [AudioEngine] не меняется.
class AudioplayersEngine implements AudioEngine {
  AudioplayersEngine({AudioPlayer? player})
      : _player = player ?? AudioPlayer() {
    _attach();
  }

  final AudioPlayer _player;
  final StreamController<PlaybackState> _controller =
      StreamController<PlaybackState>.broadcast();

  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];

  PlaybackState _state = PlaybackState.initial;
  bool _disposed = false;

  @override
  Stream<PlaybackState> get stateStream => _controller.stream;

  @override
  PlaybackState get state => _state;

  void _attach() {
    _subs.addAll(<StreamSubscription<dynamic>>[
      _player.onPlayerStateChanged.listen(_onPlayerState),
      _player.onPositionChanged.listen((Duration position) {
        _emit(_state.copyWith(position: position));
      }),
      _player.onDurationChanged.listen((Duration duration) {
        _emit(_state.copyWith(duration: duration));
      }),
      _player.onPlayerComplete.listen((_) {
        _emit(_state.copyWith(
          status: PlaybackStatus.completed,
          position: _state.duration,
        ));
      }),
      _player.onLog.listen(_onLog),
    ]);
  }

  void _onPlayerState(PlayerState state) {
    final PlaybackStatus mapped = switch (state) {
      PlayerState.playing => PlaybackStatus.playing,
      PlayerState.paused => PlaybackStatus.paused,
      PlayerState.completed => PlaybackStatus.completed,
      PlayerState.stopped => PlaybackStatus.idle,
      PlayerState.disposed => PlaybackStatus.idle,
    };
    _emit(_state.copyWith(status: mapped, clearError: true));
  }

  void _onLog(String message) {
    // audioplayers пишет в лог и ошибки, и отладку. Понятный пользователю
    // текст формируем только для явных сбоев.
    final String lower = message.toLowerCase();
    if (lower.contains('error') || lower.contains('failed')) {
      _emit(_state.copyWith(
        status: PlaybackStatus.error,
        error: _humanizeError(message),
      ));
    }
  }

  String _humanizeError(String raw) {
    if (raw.contains('403')) {
      return 'YouTube отклонил ссылку на поток. Попробуйте запустить трек ещё раз.';
    }
    if (raw.contains('404')) {
      return 'Поток не найден. Возможно, трек удалён или недоступен в регионе.';
    }
    return 'Не удалось воспроизвести трек. Попробуйте другой или повторите позже.';
  }

  void _emit(PlaybackState next) {
    _state = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  @override
  Future<void> load(
    String source, {
    bool autoplay = true,
    bool isLocal = false,
  }) async {
    _emit(_state.copyWith(
      status: PlaybackStatus.loading,
      position: Duration.zero,
      duration: Duration.zero,
      clearError: true,
    ));

    try {
      if (isLocal) {
        await _player.setSourceDeviceFile(source);
      } else {
        await _player.setSourceUrl(source);
      }
      if (autoplay) {
        await _player.resume();
        // Часть платформ не отдаёт состояние сразу — выставляем сами.
        if (_state.status == PlaybackStatus.loading) {
          _emit(_state.copyWith(status: PlaybackStatus.playing));
        }
      }
    } on Exception catch (error) {
      _emit(_state.copyWith(
        status: PlaybackStatus.error,
        error: _humanizeError(error.toString()),
      ));
    }
  }

  @override
  Future<void> play() async {
    if (_state.status == PlaybackStatus.completed) {
      await _player.seek(Duration.zero);
    }
    await _player.resume();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    _emit(_state.copyWith(status: PlaybackStatus.idle, position: Duration.zero));
  }

  @override
  Future<void> seek(Duration position) async {
    final Duration clamped = position < Duration.zero ? Duration.zero : position;
    await _player.seek(clamped);
    _emit(_state.copyWith(position: clamped));
  }

  @override
  Future<void> setVolume(double volume) async {
    final double clamped = volume.clamp(0.0, 1.0);
    await _player.setVolume(clamped);
    _emit(_state.copyWith(volume: clamped));
  }

  @override
  Future<void> setSpeed(double speed) async {
    // audioplayers меняет темп без сохранения тона на части платформ,
    // поэтому ограничиваем разумным диапазоном.
    final double clamped = speed.clamp(0.5, 2.0);
    await _player.setPlaybackRate(clamped);
    _emit(_state.copyWith(speed: clamped));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final StreamSubscription<dynamic> sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await _controller.close();
    try {
      await _player.dispose();
    } on Exception catch (error) {
      debugPrint('Ошибка при освобождении плеера: $error');
    }
  }
}
