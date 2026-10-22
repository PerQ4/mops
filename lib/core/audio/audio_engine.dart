import 'dart:async';

import 'package:flutter/foundation.dart';

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
    this.pitch = 1.0,
    this.error,
    this.audioCodec,
    this.container,
    this.bitrate,
    this.sampleRate,
    this.channels,
  });

  final PlaybackStatus status;
  final Duration position;
  final Duration duration;
  final Duration buffered;
  final double volume;
  final double speed;

  /// Высота тона относительно темпа (1.0 — без сдвига).
  ///
  /// Темп сюда не входит: при изменении скорости высота остаётся натуральной,
  /// а этот множитель сдвигает её отдельно (см. [AudioEngine.setPitch]).
  final double pitch;

  final String? error;

  /// Кодек выбранной аудиодорожки (`opus`, `mp4a.40.2`, …).
  ///
  /// `null` — состав потока ещё не разобран. Это нормально на старте: libmpv
  /// сообщает дорожки чуть позже открытия.
  final String? audioCodec;

  /// Контейнер потока (`webm`, `mp4`, …).
  ///
  /// Всегда `null`: `media_kit` в Dart его не отдаёт — ни `PlayerState`, ни
  /// `Tracks` не содержат формата контейнера. Поле оставлено, чтобы диалог
  /// «Детали потока» показывал «нет данных» честно, а не выдуманное значение.
  final String? container;

  /// Битрейт аудиопотока в бит/с.
  final int? bitrate;

  /// Частота дискретизации, Гц.
  final int? sampleRate;

  /// Число каналов аудиопотока.
  final int? channels;

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
    double? pitch,
    String? error,
    bool clearError = false,
    String? audioCodec,
    String? container,
    int? bitrate,
    int? sampleRate,
    int? channels,
    // Сбросить сведения о потоке в «неизвестно» (смена источника, стоп).
    bool clearMediaInfo = false,
  }) {
    return PlaybackState(
      status: status ?? this.status,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      buffered: buffered ?? this.buffered,
      volume: volume ?? this.volume,
      speed: speed ?? this.speed,
      pitch: pitch ?? this.pitch,
      error: clearError ? null : (error ?? this.error),
      audioCodec: clearMediaInfo ? null : (audioCodec ?? this.audioCodec),
      container: clearMediaInfo ? null : (container ?? this.container),
      bitrate: clearMediaInfo ? null : (bitrate ?? this.bitrate),
      sampleRate: clearMediaInfo ? null : (sampleRate ?? this.sampleRate),
      channels: clearMediaInfo ? null : (channels ?? this.channels),
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
  ///
  /// Высота тона при этом не меняется: компенсацию берёт на себя движок
  /// (libmpv — через `scaletempo`).
  Future<void> setSpeed(double speed);

  /// Доступно ли независимое управление высотой тона.
  ///
  /// Питч — не универсальная возможность бэкенда: чтобы менять высоту отдельно
  /// от темпа, нужен фильтр и отключённая автокоррекция высоты. Там, где
  /// этого нет, интерфейс честно пишет «недоступно», а не делает вид, что
  /// сдвиг работает.
  bool get supportsPitch;

  /// Высота тона относительно темпа (1.0 — без сдвига).
  ///
  /// Темп не меняется: движок сам компенсирует вызванное сдвигом ускорение.
  Future<void> setPitch(double pitch);

  /// Доступные устройства вывода звука.
  List<AudioOutputDevice> get audioDevices;

  /// Поток изменений списка устройств (и выбранного).
  Stream<List<AudioOutputDevice>> get audioDevicesStream;

  /// Выбирает устройство вывода по имени (`auto` — системное).
  Future<void> setAudioDevice(String name);

  /// Эквалайзер: усиления полос в дБ, ровно [kEqualizerBandCount] значений
  /// (см. `audio_equalizer.dart`).
  ///
  /// Пустой список или все нули — эквалайзер выключен. Движок сам выбирает,
  /// каким фильтром mpv это выразить (`superequalizer`, иначе `equalizer`);
  /// неподдерживаемый фильтр звук не роняет, а попадает в [audioEffectIssue].
  Future<void> setEqualizer(List<double> bands);

  /// Убирать паузы в потоке (mpv `silenceremove`).
  Future<void> setSkipSilence(bool enabled);

  /// Выравнивать громкость между тихими и громкими местами (mpv `dynaudnorm`).
  Future<void> setAudioNormalization(bool enabled);

  /// Последняя беда с аудиофильтрами — словами mpv; `null` — всё принято.
  ///
  /// Отдельно от `PlaybackState.error` намеренно: отказ фильтра не должен
  /// выглядеть как сбой трека, но и молчать о нём нельзя — интерфейс обязан
  /// показать, что эффект не применился.
  ValueListenable<String?> get audioEffectIssue;

  Future<void> dispose();
}

/// Заголовки, которые плеер должен отправить вместе с потоком.
///
/// Почему отдельным хранилищем, а не полем [AudioEngine.load]. Движок получает
/// от контроллера только адрес источника. Поток, добытый веб-сессией
/// приложения, требует тех же `User-Agent` и `Cookie`, что были у страницы:
/// без них медиасервер отвечает отказом. Резолвер запоминает их здесь по
/// адресу, а движок забирает при открытии и отдаёт libmpv как
/// `http-header-fields`.
///
/// Хранилище небольшое и перезаписывается по адресу: ссылки живут часами,
/// а на один трек нужна одна запись.
class StreamRequestHeaders {
  StreamRequestHeaders._();

  /// Сколько адресов помнить. Записи старше вытесняются: держать десятки
  /// cookie-строк незачем, а ссылки на них всё равно истекают.
  static const int _limit = 16;

  static final Map<String, Map<String, String>> _byUrl =
      <String, Map<String, String>>{};

  /// Запоминает заголовки для адреса [url] ([headers] пустые — забыть).
  static void remember(Uri url, Map<String, String>? headers) {
    final String key = url.toString();
    _byUrl.remove(key);
    if (headers == null || headers.isEmpty) return;

    _byUrl[key] = Map<String, String>.unmodifiable(headers);
    while (_byUrl.length > _limit) {
      _byUrl.remove(_byUrl.keys.first);
    }
  }

  /// Заголовки, с которыми нужно открывать [source]; `null` — обычный поток.
  static Map<String, String>? forUrl(String source) => _byUrl[source];

  /// Очищает хранилище — только для тестов.
  @visibleForTesting
  static void clear() => _byUrl.clear();
}

/// Исключение с понятным пользователю текстом.
class AudioEngineException implements Exception {
  AudioEngineException(this.message);

  final String message;

  @override
  String toString() => message;
}
