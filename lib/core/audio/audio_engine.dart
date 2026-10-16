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

/// Устройство вывода звука, не зависящее от бэкенда.
class AudioOutputDevice {
  const AudioOutputDevice({required this.name, required this.description});

  /// Внутреннее имя устройства (`auto` — выбор системы).
  final String name;

  /// Человекочитаемое описание.
  final String description;

  bool get isAuto => name == 'auto';

  @override
  bool operator ==(Object other) =>
      other is AudioOutputDevice && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// Контракт аудиодвижка.
///
/// Реализация по умолчанию — [MediaKitEngine] (`media_kit`/libmpv). Он
/// запрашивает поток обычным GET, поэтому ссылку можно отдавать прямо из
/// резолвера, без скачивания и локального посредника. Интерфейс от бэкенда
/// не зависит: подставить `audioplayers` или `just_audio` можно без правок UI.
///
/// Уровень громкости и спектр контракт намеренно не отдаёт: у
/// `media_kit`/libmpv в Dart такого API нет. `Player.stream.audioParams`
/// (`AudioParams`) содержит только формат, частоту дискретизации и каналы, а
/// `audio-bitrate` — постоянный для потока битрейт, а не мгновенную громкость;
/// готовой «визуализации» у пакета тоже нет. Поэтому «живая» волна на полосе
/// перемотки строится из реально известных значений (позиция и громкость) —
/// см. `_liveWaveLevel` в `features/player/player_controls.dart`.
abstract class AudioEngine {
  /// Поток изменений состояния. Должен поддерживать несколько подписчиков.
  Stream<PlaybackState> get stateStream;

  /// Последнее известное состояние.
  PlaybackState get state;

  /// Загружает поток по URL. `autoplay` — начать воспроизведение сразу.
  ///
  /// [isLocal] — [source] это путь к файлу на диске, а не сетевой адрес.
  /// Нужно, когда поток сначала скачивается через приложение (например, при
  /// обходе блокировок), а затем отдаётся движку как локальный файл.
  Future<void> load(String source, {bool autoplay = true, bool isLocal = false});

  Future<void> play();
  Future<void> pause();
  Future<void> stop();

  /// Позиция для seek.
  Future<void> seek(Duration position);

  /// Громкость 0.0–1.0.
  Future<void> setVolume(double volume);

  /// Скорость воспроизведения (1.0 — обычная).
  Future<void> setSpeed(double speed);

  /// Доступные устройства вывода звука.
  List<AudioOutputDevice> get audioDevices;

  /// Поток изменений списка устройств (и выбранного).
  Stream<List<AudioOutputDevice>> get audioDevicesStream;

  /// Выбирает устройство вывода по имени (`auto` — системное).
  Future<void> setAudioDevice(String name);

  Future<void> dispose();
}

/// Исключение с понятным пользователю текстом.
class AudioEngineException implements Exception {
  AudioEngineException(this.message);

  final String message;

  @override
  String toString() => message;
}
