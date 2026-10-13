import 'dart:async';

/// Состояние воспроизведения, не зависящее от конкретного бэкенда.
enum PlaybackStatus {
  /// Ничего не загружено.
  idle,

  /// Идёт загрузка/разбор потока.
  loading,

  /// Данные подгружаются, звук ещё не идёт.
  buffering,

  playing,
  paused,

  /// Трек доиграл до конца.
  completed,

  error,
}

/// Снимок состояния плеера.
class PlaybackState {
  const PlaybackState({
    this.status = PlaybackStatus.idle,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffered = Duration.zero,
    this.volume = 1.0,
    this.speed = 1.0,
    this.error,
  });

  final PlaybackStatus status;
  final Duration position;
  final Duration duration;
  final Duration buffered;
  final double volume;
  final double speed;
  final String? error;

  bool get isPlaying => status == PlaybackStatus.playing;
  bool get isLoading =>
      status == PlaybackStatus.loading || status == PlaybackStatus.buffering;
  bool get hasError => status == PlaybackStatus.error;

  /// Прогресс от 0 до 1 (безопасно при неизвестной длительности).
  double get progress {
    if (duration.inMilliseconds <= 0) return 0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  PlaybackState copyWith({
    PlaybackStatus? status,
    Duration? position,
    Duration? duration,
    Duration? buffered,
    double? volume,
    double? speed,
    String? error,
    bool clearError = false,
  }) {
    return PlaybackState(
      status: status ?? this.status,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      buffered: buffered ?? this.buffered,
      volume: volume ?? this.volume,
      speed: speed ?? this.speed,
      error: clearError ? null : (error ?? this.error),
    );
  }

  static const PlaybackState initial = PlaybackState();
}

/// Контракт аудиодвижка.
///
/// Реализации: [AudioplayersEngine] (по умолчанию, работает на всех платформах;
/// на Linux — через GStreamer). При желании сюда подставляется `media_kit`
/// или `just_audio` без изменений в UI.
abstract class AudioEngine {
  /// Поток изменений состояния. Должен поддерживать несколько подписчиков.
  Stream<PlaybackState> get stateStream;

  /// Последнее известное состояние.
  PlaybackState get state;

  /// Загружает поток по URL. `autoplay` — начать воспроизведение сразу.
  Future<void> load(String url, {bool autoplay = true});

  Future<void> play();
  Future<void> pause();
  Future<void> stop();

  /// Позиция для seek.
  Future<void> seek(Duration position);

  /// Громкость 0.0–1.0.
  Future<void> setVolume(double volume);

  /// Скорость воспроизведения (1.0 — обычная).
  Future<void> setSpeed(double speed);

  Future<void> dispose();
}

/// Исключение с понятным пользователю текстом.
class AudioEngineException implements Exception {
  AudioEngineException(this.message);

  final String message;

  @override
  String toString() => message;
}
