import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'audio_engine.dart';

/// Реализация [AudioEngine] поверх `media_kit` (на Linux — libmpv).
///
/// Почему не `audioplayers` (GStreamer), как было раньше. GStreamer запрашивает
/// поток с открытым диапазоном (`Range: bytes=0-`), а медиасервер YouTube
/// отвечает на такой запрос 403 «Forbidden» — поэтому ссылку нельзя было
/// отдать плееру напрямую и поток качался целиком. libmpv запрашивает файл
/// обычным GET: проверено `tool/plain_get_check.dart` — обычный GET отдаётся
/// (200), а перемотка идёт закрытыми/открытыми диапазонами (206). Так же
/// работает ExoPlayer в ArchiveTune и Metrolist.
///
/// Громкость media_kit измеряется в процентах (100.0 — обычная), а контракт
/// [AudioEngine] — от 0.0 до 1.0, поэтому на границе класса значение
/// переводится туда и обратно.
class MediaKitEngine implements AudioEngine {
  MediaKitEngine({Player? player}) : _player = player ?? Player() {
    _attach();
  }

  final Player _player;
  final StreamController<PlaybackState> _controller =
      StreamController<PlaybackState>.broadcast();
  final StreamController<List<AudioOutputDevice>> _devices =
      StreamController<List<AudioOutputDevice>>.broadcast();
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];

  PlaybackState _state = PlaybackState.initial;
  bool _disposed = false;

  /// Идёт открытие источника. Пока оно не закончилось, `playing = false` от
  /// плеера означает не паузу, а «ещё не началось»; иначе интерфейс мигал бы
  /// «пауза → играет» при каждом запуске трека.
  bool _opening = false;

  /// Идёт перемотка. libmpv на перемотке переоткрывает поток и на миг
  /// сообщает `playing = false`/`completed`. Принимать это за паузу или конец
  /// трека нельзя — очередь перескочила бы на следующий.
  bool _seeking = false;
  Timer? _seekSafetyTimer;

  /// Источник сейчас загружен в плеер.
  ///
  /// После [stop] libmpv выгружает медиа, и ни `play`, ни `seek` его уже не
  /// оживят — нужен повторный `open`. Поэтому запоминаем источник.
  String? _lastSource;
  bool _lastIsLocal = false;
  bool _sourceLoaded = false;

  @override
  Stream<PlaybackState> get stateStream => _controller.stream;

  @override
  PlaybackState get state => _state;

  void _attach() {
    // Уровень звука/спектр media_kit (libmpv) в Dart не отдаёт: `audio-params`
    // и `audio-bitrate` — это формат и битрейт потока, а не мгновенная
    // громкость, а визуализации у пакета нет. Поэтому «живую» волну интерфейс
    // строит сам (`_liveWaveLevel` в `player_controls.dart`), и слушать здесь
    // нечего.
    _subs.addAll(<StreamSubscription<dynamic>>[
      _player.stream.playing.listen(_onPlaying),
      _player.stream.completed.listen(_onCompleted),
      _player.stream.buffering.listen(_onBuffering),
      _player.stream.position.listen((Duration position) {
        _emit(_state.copyWith(position: position));
      }),
      _player.stream.duration.listen((Duration duration) {
        // Ноль — это «ещё не знаем», а не реальная длительность. Иначе
        // полоса прогресса на миг обнулялась бы на старте.
        if (duration > Duration.zero) {
          _emit(_state.copyWith(duration: duration));
        }
      }),
      _player.stream.buffer.listen((Duration buffered) {
        _emit(_state.copyWith(buffered: buffered));
      }),
      _player.stream.error.listen(_onError),
      _player.stream.log.listen(_onLog),
      _player.stream.audioDevices.listen(_onAudioDevices),
      // Сведения о потоке — для диалога «Детали потока» (кодек, битрейт,
      // частота, каналы). Контейнер media_kit не отдаёт, см. [PlaybackState].
      _player.stream.tracks.listen(_onTracks),
      _player.stream.audioParams.listen(_onAudioParams),
      _player.stream.audioBitrate.listen(_onAudioBitrate),
    ]);
  }

  /// Разбирает состав потока: кодек и параметры выбранной аудиодорожки.
  ///
  /// `stream.track` в media_kit обновляется только явным `setAudioTrack`, а мы
  /// дорожки не переключаем, поэтому текущую берём из `stream.tracks` — ту, что
  /// помечена `default` (именно её выбирает libmpv), иначе первую реальную.
  void _onTracks(Tracks tracks) {
    final AudioTrack? audio = _selectedAudioTrack(tracks);
    if (audio == null) return;
    _emit(_state.copyWith(
      audioCodec: audio.codec,
      // `demux-bitrate` есть не у всех потоков: если мгновенный `audio-bitrate`
      // уже пришёл, он точнее и не перекрывается.
      bitrate: _state.bitrate ?? audio.bitrate,
      // Частота источника важнее частоты вывода, поэтому дорожка перекрывает
      // значение из `audio-params` (см. [_onAudioParams]).
      sampleRate: audio.samplerate ?? _state.sampleRate,
      channels: audio.channelscount ?? _state.channels,
    ));
  }

  /// `audio-params` — параметры уже на выходе декодера. Их берём только как
  /// запасной источник: `track-list` даёт частоту и каналы самого потока.
  void _onAudioParams(AudioParams params) {
    _emit(_state.copyWith(
      sampleRate: _state.sampleRate ?? params.sampleRate,
      channels: _state.channels ?? params.channelCount,
    ));
  }

  void _onAudioBitrate(double? bitrate) {
    // `null` — у потока битрейт неизвестен; прежнее значение не трогаем.
    if (bitrate == null) return;
    _emit(_state.copyWith(bitrate: bitrate.round()));
  }

  /// Первая реальная аудиодорожка: `auto`/`no` — служебные записи mpv.
  AudioTrack? _selectedAudioTrack(Tracks tracks) {
    AudioTrack? first;
    for (final AudioTrack track in tracks.audio) {
      if (track.id == 'auto' || track.id == 'no') continue;
      first ??= track;
      if (track.isDefault == true) return track;
    }
    return first;
  }

  void _onAudioDevices(List<AudioDevice> devices) {
    if (_devices.isClosed) return;
    _devices.add(_mapDevices(devices));
  }

  List<AudioOutputDevice> _mapDevices(List<AudioDevice> devices) => devices
      .map((AudioDevice d) => AudioOutputDevice(
            name: d.name,
            description: d.description.isEmpty ? d.name : d.description,
          ))
      .toList(growable: false);

  @override
  List<AudioOutputDevice> get audioDevices =>
      _mapDevices(_player.state.audioDevices);

  @override
  Stream<List<AudioOutputDevice>> get audioDevicesStream => _devices.stream;

  @override
  Future<void> setAudioDevice(String name) async {
    final List<AudioDevice> list = _player.state.audioDevices;
    final AudioDevice device = list.firstWhere(
      (AudioDevice d) => d.name == name,
      orElse: () => AudioDevice(name, ''),
    );
    await _player.setAudioDevice(device);
  }

  void _onPlaying(bool playing) {
    if (playing) {
      _opening = false;
      _sourceLoaded = true;
      _emit(_state.copyWith(status: PlaybackStatus.playing, clearError: true));
      return;
    }

    // Открытие или перемотка ещё идут — «не играет» здесь не пауза.
    if (_opening || _seeking) return;

    // Завершённый трек и явные ошибки не переводим в паузу: иначе очередь
    // теряла бы признак «трек доиграл».
    if (_state.status == PlaybackStatus.completed ||
        _state.status == PlaybackStatus.idle ||
        _state.status == PlaybackStatus.error) {
      return;
    }

    _emit(_state.copyWith(status: PlaybackStatus.paused, clearError: true));
  }

  void _onCompleted(bool completed) {
    if (!completed) return;
    // Ложный EOS перемотки: поток переоткрывается, но трек не закончился.
    if (_seeking) return;
    if (_state.status == PlaybackStatus.completed) return;

    // libmpv освободил поток: чтобы «играть» снова, нужен `open`.
    _sourceLoaded = false;
    _emit(_state.copyWith(
      status: PlaybackStatus.completed,
      position: _state.duration,
      clearError: true,
    ));
  }

  void _onBuffering(bool buffering) {
    if (_disposed) return;

    if (buffering) {
      if (_state.status == PlaybackStatus.completed ||
          _state.status == PlaybackStatus.error ||
          _state.status == PlaybackStatus.idle) {
        return;
      }
      _emit(_state.copyWith(status: PlaybackStatus.buffering));
      return;
    }

    // Буферизация закончилась, а отдельного события «играет» может не быть —
    // возвращаем статус сами. Пока идёт открытие/перемотка, не вмешиваемся.
    if (_opening || _seeking) return;
    if (_state.status == PlaybackStatus.buffering) {
      _emit(_state.copyWith(
        status: _player.state.playing
            ? PlaybackStatus.playing
            : PlaybackStatus.paused,
      ));
    }
  }

  void _onError(String message) {
    if (_disposed) return;
    // Сбой перемотки — не сбой трека: звук продолжается, менять состояние
    // воспроизведения не нужно.
    if (_seeking) return;
    _opening = false;
    _sourceLoaded = false;
    _emit(_state.copyWith(
      status: PlaybackStatus.error,
      error: _humanizeError(message),
      clearMediaInfo: true,
    ));
  }

  void _onLog(PlayerLog log) {
    // Ошибки и предупреждения libmpv печатаем в журнал: по ним видно, что
    // именно не понравилось медиасерверу («Forbidden», «Internal data stream
    // error» и подобное). В `state` их не превращаем — часть сообщений
    // безобидна (например, о необязательном видео-потоке).
    if (log.level == 'error' || log.level == 'fatal' || log.level == 'warn') {
      debugPrint('[mpv/${log.prefix}] ${log.text}');
    }
  }

  String _humanizeError(String raw) {
    final String lower = raw.toLowerCase();
    if (lower.contains('403') || lower.contains('forbidden')) {
      return 'YouTube отклонил ссылку на поток. Попробуйте запустить трек ещё раз.';
    }
    if (lower.contains('404')) {
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
    _endSeek();
    _lastSource = source;
    _lastIsLocal = isLocal;
    _sourceLoaded = false;
    _opening = true;
    _emit(_state.copyWith(
      status: PlaybackStatus.loading,
      position: Duration.zero,
      duration: Duration.zero,
      buffered: Duration.zero,
      clearError: true,
      // Новый источник — прежние кодек и битрейт к нему не относятся.
      clearMediaInfo: true,
    ));

    try {
      await _player.open(_mediaFor(source, isLocal), play: autoplay);
      _sourceLoaded = true;
      if (autoplay) {
        // Часть событий приходит с задержкой — показываем старт сразу,
        // `_opening` снимается настоящим `playing = true` или ошибкой.
        if (_state.status == PlaybackStatus.loading) {
          _emit(_state.copyWith(status: PlaybackStatus.playing));
        }
      } else {
        _opening = false;
        _emit(_state.copyWith(status: PlaybackStatus.paused));
      }
    } on Object catch (error) {
      _opening = false;
      _sourceLoaded = false;
      _emit(_state.copyWith(
        status: PlaybackStatus.error,
        error: _humanizeError(error.toString()),
      ));
    }
  }

  @override
  Future<void> play() async {
    // Потока в плеере нет (трек доиграл или был `stop`) — поднимаем заново.
    if (!_sourceLoaded || _state.status == PlaybackStatus.completed) {
      final Duration target = _state.status == PlaybackStatus.completed
          ? Duration.zero
          : _state.position;
      await _restart(target);
      return;
    }
    await _player.play();
  }

  @override
  Future<void> pause() async {
    _opening = false;
    _endSeek();
    await _player.pause();
    _emit(_state.copyWith(status: PlaybackStatus.paused));
  }

  @override
  Future<void> stop() async {
    _opening = false;
    _endSeek();
    // libmpv выгружает медиа — запоминаем, что источник нужно открыть снова.
    _sourceLoaded = false;
    try {
      await _player.stop();
    } on Object catch (error) {
      debugPrint('Ошибка остановки плеера: $error');
    }
    _emit(_state.copyWith(
      status: PlaybackStatus.idle,
      position: Duration.zero,
      clearMediaInfo: true,
    ));
  }

  @override
  Future<void> seek(Duration position) async {
    final Duration clamped = position < Duration.zero ? Duration.zero : position;
    _beginSeek();

    // Позицию показываем сразу: перемотка сетевого потока занимает время,
    // а полоса не должна «отпрыгивать» назад.
    _emit(_state.copyWith(position: clamped));

    // Источника в плеере нет — перематывать нечего, поднимаем поток заново
    // сразу с выбранного места (в media_kit это `start` у [Media]).
    if (!_sourceLoaded) {
      await _restart(clamped, emitLoading: false);
      _endSeek();
      return;
    }

    try {
      await _player.seek(clamped);
    } on Object catch (error) {
      // Ошибку перемотки не показываем как сбой воспроизведения: звук
      // продолжается, плеер остаётся на прежнем месте.
      debugPrint('Перемотка не удалась: $error');
    } finally {
      _endSeek();
    }
  }

  /// Заново открывает последний источник — после `stop` или конца трека.
  ///
  /// `target` — откуда начать (ноль — с начала).
  Future<void> _restart(Duration target, {bool emitLoading = true}) async {
    final String? source = _lastSource;
    if (source == null) return;

    _opening = true;
    if (emitLoading) {
      _emit(_state.copyWith(status: PlaybackStatus.loading, clearError: true));
    }
    try {
      await _player.open(
        _mediaFor(source, _lastIsLocal, start: target),
        play: true,
      );
      _sourceLoaded = true;
      if (_state.status == PlaybackStatus.loading) {
        _emit(_state.copyWith(
          status: PlaybackStatus.playing,
          position: target,
          clearError: true,
        ));
      }
    } on Object catch (error) {
      _opening = false;
      _sourceLoaded = false;
      _emit(_state.copyWith(
        status: PlaybackStatus.error,
        error: _humanizeError(error.toString()),
      ));
    }
  }

  /// Собирает [Media] для сетевого адреса или локального файла.
  Media _mediaFor(String source, bool isLocal, {Duration? start}) {
    final String uri = isLocal ? Uri.file(source).toString() : source;
    return Media(uri, start: start);
  }

  /// Включает защиту от ложного EOS на время перемотки.
  void _beginSeek() {
    _seeking = true;
    _seekSafetyTimer?.cancel();
    // Страховка: если поток `completed` не придёт или перемотка «зависнет»,
    // снимаем флаг сами — иначе настоящий конец трека будет пропущен.
    _seekSafetyTimer = Timer(const Duration(seconds: 10), _endSeek);
  }

  void _endSeek() {
    _seeking = false;
    _seekSafetyTimer?.cancel();
    _seekSafetyTimer = null;
  }

  @override
  Future<void> setVolume(double volume) async {
    final double clamped = volume.clamp(0.0, 1.0);
    // media_kit принимает проценты: 100.0 — обычная громкость.
    await _player.setVolume(clamped * 100.0);
    _emit(_state.copyWith(volume: clamped));
  }

  @override
  Future<void> setSpeed(double speed) async {
    final double clamped = speed.clamp(0.5, 2.0);
    await _player.setRate(clamped);
    _emit(_state.copyWith(speed: clamped));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _seekSafetyTimer?.cancel();
    _seekSafetyTimer = null;
    for (final StreamSubscription<dynamic> sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await _controller.close();
    await _devices.close();
    try {
      await _player.dispose();
    } on Object catch (error) {
      debugPrint('Ошибка при освобождении плеера: $error');
    }
  }
}
