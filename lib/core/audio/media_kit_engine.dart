import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'audio_engine.dart';
import 'audio_equalizer.dart';
import 'mpv_filter_probe.dart';

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
  MediaKitEngine({Player? player})
      : _player = player ??
            // `pitch: true` включает в libmpv независимый сдвиг высоты тона:
            // media_kit ставит фильтр `scaletempo` и отключает автокоррекцию
            // высоты, а темп и питч раскладывает между `speed` и `af`. Без
            // этого `setPitch` бросает ArgumentError.
            Player(configuration: const PlayerConfiguration(pitch: true)) {
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

  /// Выбранный темп.
  ///
  /// Храним сами: `speed`/`af` — глобальные свойства libmpv, и после `open`
  /// нового потока их нужно задать заново, иначе темп «потеряется» при
  /// переходе к следующему треку.
  double _speed = 1.0;

  /// Выбранная высота тона.
  ///
  /// Питч относится к конкретному прослушиванию, а не к сессии: при загрузке
  /// нового трека он возвращается к 1.0 (см. [load]). Повторное открытие того
  /// же потока (`stop`, конец трека) питч сохраняет.
  double _pitch = 1.0;

  /// Полосы эквалайзера (дБ). Пусто — эквалайзер выключен.
  ///
  /// Храним сами: `af` — глобальное свойство libmpv, и media_kit (темп и питч)
  /// переписывает его целиком, поэтому цепочку приходится собирать заново после
  /// каждого вмешательства, а не надеяться, что она уцелеет.
  List<double> _equalizerBands = const <double>[];

  /// Убирать паузы из потока.
  bool _skipSilence = false;

  /// Выравнивать громкость между тихими и громкими местами.
  bool _normalization = false;

  /// Отказы фильтров — словами mpv. `null` — все запрошенные эффекты приняты.
  final ValueNotifier<String?> _effectIssue = ValueNotifier<String?>(null);

  /// Пересборки `af` идут по очереди: параллельные чтение и запись одного
  /// свойства дали бы гонку — цепочка собиралась бы из устаревшего состояния.
  Future<void>? _chainQueue;

  @override
  ValueListenable<String?> get audioEffectIssue => _effectIssue;

  @override
  Stream<PlaybackState> get stateStream => _controller.stream;

  @override
  PlaybackState get state => _state;

  /// Плеер libmpv; `null` — у платформы нет свойств mpv.
  NativePlayer? get _native {
    final PlatformPlayer? platform = _player.platform;
    return platform is NativePlayer ? platform : null;
  }

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
    // Отказ аудиофильтра (сборка без него или неверный параметр) — тоже не
    // сбой трека: движок проверяет фильтры заранее, и обрывать звук из-за
    // цепочки эффектов нельзя. Причина при этом не теряется — она попадает в
    // [audioEffectIssue].
    if (MpvFilterProbe.looksLikeFilterError(message)) {
      debugPrint('[mpv/af] отказ фильтра: $message');
      return;
    }
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

    // Новый трек: высота тона возвращается к натуральной. Запоминаем, был ли
    // сдвиг, чтобы снять его в libmpv, а не только в состоянии.
    final bool pitchWasShifted = _pitch != 1.0;
    _pitch = 1.0;

    _emit(_state.copyWith(
      status: PlaybackStatus.loading,
      position: Duration.zero,
      duration: Duration.zero,
      buffered: Duration.zero,
      pitch: 1.0,
      clearError: true,
      // Новый источник — прежние кодек и битрейт к нему не относятся.
      clearMediaInfo: true,
    ));

    try {
      await _player.open(_mediaFor(source, isLocal), play: autoplay);
      _sourceLoaded = true;
      await _applyTempoPitch(resetPitch: pitchWasShifted);
      // Эффекты ставим после темпа/питча: media_kit задаёт своё `af` целиком и
      // затёр бы их. Не ждём: проверка фильтров на пробном плеере занимает
      // мгновения, но задерживать старт звука ею незачем.
      unawaited(_rebuildAudioChain());
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
      await _applyTempoPitch();
      unawaited(_rebuildAudioChain());
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
    _speed = clamped;
    await _player.setRate(clamped);
    // `setRate` переписывает `af` целиком (scaletempo) — возвращаем эффекты.
    await _rebuildAudioChain();
    _emit(_state.copyWith(speed: clamped));
  }

  @override
  bool get supportsPitch => true;

  @override
  Future<void> setPitch(double pitch) async {
    final double clamped = pitch.clamp(0.5, 2.0);
    _pitch = clamped;
    await _player.setPitch(clamped);
    await _rebuildAudioChain();
    _emit(_state.copyWith(pitch: clamped));
  }

  /// Возвращает выбранные темп и высоту тона после открытия потока.
  ///
  /// `speed` и `af` — глобальные свойства libmpv: новое `open` может их
  /// сбросить, а прошлый сдвиг высоты — остаться. Поэтому значения задаются
  /// заново: темп не теряется между треками, а сброшенный питч не «прилипает»
  /// с предыдущего.
  Future<void> _applyTempoPitch({bool resetPitch = false}) async {
    try {
      // Питч задаём первым: он же выставляет `speed`. Затем темп пересчитывает
      // `af` уже с учётом питча — media_kit делит scale на pitch.
      if (resetPitch || _pitch != 1.0) {
        await _player.setPitch(_pitch);
      }
      if (_speed != 1.0) {
        await _player.setRate(_speed);
      }
    } on Object catch (error) {
      debugPrint('Не удалось применить темп/питч: $error');
    }
  }

  // ------------------------------------------------------------------ эффекты

  /// Метка фильтров, которыми владеет движок.
  ///
  /// По ней свои фильтры отличаются от чужих (`scaletempo` от media_kit,
  /// `astats` визуализатора с меткой `mopsvis`), чтобы пересборка не снесла
  /// чужое.
  static const String _eqLabel = 'mopseq';
  static const String _skipLabel = 'mopsskip';
  static const String _normLabel = 'mopsnorm';

  /// Центры 18 фиксированных полос фильтра `superequalizer` (FFmpeg). Полоса
  /// ниже 65 Гц у него отсутствует, поэтому 10 «стандартных» полос в точности
  /// он не выражает — значения берём интерполяцией по его сетке.
  static const List<double> _superEqualizerFrequencies = <double>[
    65, 92, 131, 185, 262, 370, 523, 740, 1047, 1480, 2093, 2960,
    4186, 5920, 8372, 11840, 16744, 20000,
  ];

  /// Параметры фильтра `silenceremove`: срезать тишину в начале и в середине.
  ///
  /// `stop_periods=-1` — не останавливаться на первой паузе, а чистить поток
  /// дальше; порог −50 дБ и полусекундная тишина — чтобы не резать тихие, но
  /// содержательные места.
  static const String _skipSilenceParams =
      'start_periods=1:start_duration=0.1:start_threshold=-50dB:'
      'stop_periods=-1:stop_duration=0.5:stop_threshold=-50dB';

  @override
  Future<void> setEqualizer(List<double> bands) async {
    if (listEquals(_equalizerBands, bands)) return;
    _equalizerBands = List<double>.of(bands);
    await _rebuildAudioChain();
  }

  @override
  Future<void> setSkipSilence(bool enabled) async {
    if (_skipSilence == enabled) return;
    _skipSilence = enabled;
    await _rebuildAudioChain();
  }

  @override
  Future<void> setAudioNormalization(bool enabled) async {
    if (_normalization == enabled) return;
    _normalization = enabled;
    await _rebuildAudioChain();
  }

  /// Пересобирает цепочку `af` целиком и ставит её одним значением.
  ///
  /// Ставить фильтры по частям нельзя: при отказе mpv оставляет всю прежнюю
  /// цепочку, и тогда непонятно, что применилось. Чужое (scaletempo, astats)
  /// сохраняется, свои прошлые фильтры снимаются по метке, затем дописываются
  /// текущие. Пересборки сериализованы — см. [\_chainQueue].
  Future<void> _rebuildAudioChain() {
    final Future<void> run = (_chainQueue ?? Future<void>.value())
        .then((_) => _applyAudioChain());
    // Хвост очереди не должен «падать»: иначе следующая пересборка не пойдёт.
    _chainQueue = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _applyAudioChain() async {
    final NativePlayer? native = _native;
    if (native == null) {
      _setEffectIssue(null);
      return;
    }
    // Пока поток не открыт, ставить цепочку некуда: её подхватит ближайший
    // `open`/`_restart`, который сам вызовет пересборку.
    if (!_sourceLoaded) return;

    try {
      final List<String> segments = _splitChain(await native.getProperty('af'))
        ..removeWhere(_isOwnedFilter);

      final List<String> own = <String>[];
      final List<String> issues = <String>[];
      await _appendEqualizer(own);
      if (_skipSilence) {
        if (await MpvFilterProbe.supports(
          'silenceremove',
          _skipSilenceParams,
        )) {
          own.add('@$_skipLabel:silenceremove=$_skipSilenceParams');
        } else {
          issues.add(_filterIssue('silenceremove'));
        }
      }
      if (_normalization) {
        if (await MpvFilterProbe.supports('dynaudnorm', '')) {
          own.add('@$_normLabel:dynaudnorm');
        } else {
          issues.add(_filterIssue('dynaudnorm'));
        }
      }
      segments.addAll(own);

      await native.setProperty('af', segments.join(','));
      // Проверяем приём: при отказе mpv оставляет прежнюю цепочку. Молчать об
      // этом нельзя, но и рвать звук из-за фильтра — тоже.
      final String applied = await native.getProperty('af');
      final bool eqRequested =
          _equalizerBands.length == kEqualizerBandCount &&
              !equalizerIsFlat(_equalizerBands);
      if (eqRequested && !applied.contains('@$_eqLabel')) {
        issues.add(_filterIssue('superequalizer'));
      }
      if (_skipSilence && !applied.contains('@$_skipLabel')) {
        issues.add(_filterIssue('silenceremove'));
      }
      if (_normalization && !applied.contains('@$_normLabel')) {
        issues.add(_filterIssue('dynaudnorm'));
      }
      _setEffectIssue(issues.isEmpty ? null : issues.toSet().join('; '));
    } on Object catch (error) {
      _setEffectIssue('не удалось применить аудиофильтры: $error');
    }
  }

  /// Дописывает в [own] фильтр эквалайзера, если он настроен и есть в сборке.
  Future<void> _appendEqualizer(List<String> own) async {
    final List<double> bands = _equalizerBands;
    if (bands.length != kEqualizerBandCount || equalizerIsFlat(bands)) return;

    // Основной вариант — `superequalizer` (18 полос, кадровая обработка).
    if (await MpvFilterProbe.supports('superequalizer', '1b=0')) {
      final List<double> gains = _sampleSuperEqualizer(bands);
      final String params = <String>[
        for (int i = 0; i < gains.length; i++)
          '${i + 1}b=${gains[i].toStringAsFixed(2)}',
      ].join(':');
      own.add('@$_eqLabel:superequalizer=$params');
      return;
    }
    // Запасной — `equalizer`: одна параметрическая полоса на фильтр. Полосы
    // метим отдельными метками: одно имя на несколько фильтров mpv не даёт.
    if (await MpvFilterProbe.supports('equalizer', 'f=1000:t=q:w=1:g=0')) {
      for (int i = 0; i < kEqualizerBandCount; i++) {
        own.add(
          '@$_eqLabel${i + 1}:equalizer='
          'f=${kEqualizerBandFrequencies[i].round()}:t=q:w=1:'
          'g=${bands[i].toStringAsFixed(2)}',
        );
      }
    }
  }

  /// Раскладывает 10-полосную кривую по 18 фиксированным полосам
  /// `superequalizer`: значение в полосе фильтра — линейная интерполяция между
  /// соседними полосами эквалайзера в логарифмической шкале частот.
  static List<double> _sampleSuperEqualizer(List<double> bands) => <double>[
        for (final double frequency in _superEqualizerFrequencies)
          _gainAt(bands, frequency),
      ];

  static double _gainAt(List<double> bands, double frequency) {
    const List<double> freqs = kEqualizerBandFrequencies;
    if (frequency <= freqs.first) return bands.first;
    if (frequency >= freqs.last) return bands.last;
    final double logFrequency = math.log(frequency);
    for (int i = 1; i < freqs.length; i++) {
      if (frequency <= freqs[i]) {
        final double low = math.log(freqs[i - 1]);
        final double high = math.log(freqs[i]);
        final double t = (logFrequency - low) / (high - low);
        return bands[i - 1] + (bands[i] - bands[i - 1]) * t;
      }
    }
    return bands.last;
  }

  /// Разбирает цепочку `af` на отдельные фильтры. Запятая внутри параметров не
  /// встречается ни у наших фильтров, ни у `scaletempo` media_kit, поэтому
  /// верхнеуровневое деление безопасно.
  static List<String> _splitChain(String raw) => raw
      .split(',')
      .map((String segment) => segment.trim())
      .where((String segment) => segment.isNotEmpty)
      .toList();

  /// Наш ли это фильтр (ставили его мы сами). Чужое — не трогаем.
  static bool _isOwnedFilter(String segment) {
    final String text = segment.trim();
    return text.startsWith('@$_eqLabel') ||
        text.startsWith('@$_skipLabel') ||
        text.startsWith('@$_normLabel');
  }

  /// Причина отказа фильтра словами mpv — для честного сообщения в интерфейсе.
  static String _filterIssue(String name) {
    final String? reason = MpvFilterProbe.rejection(name);
    return reason == null
        ? 'в сборке libmpv нет фильтра $name'
        : 'фильтр $name недоступен: $reason';
  }

  void _setEffectIssue(String? issue) {
    if (_effectIssue.value == issue) return;
    _effectIssue.value = issue;
    if (issue != null) debugPrint('Аудиоэффекты: $issue');
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
    _effectIssue.dispose();
    try {
      await _player.dispose();
    } on Object catch (error) {
      debugPrint('Ошибка при освобождении плеера: $error');
    }
  }
}
