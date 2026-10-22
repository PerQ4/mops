import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'audio_engine.dart';
import 'audio_equalizer.dart';
import 'mpv_audio_chain.dart';
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
    // Цепочку `af` движок не держит сам: он её совладелец вместе с монитором
    // уровня. Владелец один на плеер — см. [MpvAudioChain].
    _chain = MpvAudioChain.forPlayer(_player);
    _attach();
  }

  final Player _player;

  /// Очередь записей `af`, общая с монитором уровня.
  late final MpvAudioChain? _chain;
  final StreamController<PlaybackState> _controller =
      StreamController<PlaybackState>.broadcast();
  final StreamController<List<AudioOutputDevice>> _devices =
      StreamController<List<AudioOutputDevice>>.broadcast();

  /// Пропажи устройства, в которое шёл звук. Отдельный поток, а не часть
  /// [stateStream]: пауза по настройке — решение контроллера, а не движка.
  final StreamController<AudioOutputDevice> _deviceLoss =
      StreamController<AudioOutputDevice>.broadcast();
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

  /// Устройство, которое mpv реально использует (`audio-out-detected-device`).
  ///
  /// При выборе «Системное» (`auto`) сам `audio-device` остаётся `auto`, и по
  /// списку устройств не видно, в какое из них идёт звук. Это свойство отдаёт
  /// физическое устройство, поэтому пропажу наушников видно и в режиме «авто».
  String? _detectedDevice;

  /// Последний полученный список устройств — нужен, чтобы отличить пропажу
  /// от смены устройства пользователем.
  List<AudioOutputDevice> _lastDevices = const <AudioOutputDevice>[];

  /// О пропаже уже сообщили: не повторяем, пока устройство не вернётся.
  bool _deviceLossReported = false;

  /// Имена устройств, которые когда-либо были в списке mpv.
  ///
  /// `audio-out-detected-device` и `audio-device-list` могут называть одно и
  /// то же устройство по-разному (у драйвера свой формат). Сравнивать имеет
  /// смысл только с тем, что список действительно показывал: иначе первое же
  /// переключение выглядело бы как пропажа, и музыка встала бы на паузу.
  final Set<String> _knownDeviceNames = <String>{};

  /// Устройство, которое было активно до последней смены обнаруженного.
  ///
  /// mpv может сообщить о новом устройстве раньше, чем обновит список, — тогда
  /// пропажу подтверждаем по следующему списку, а не спешим с паузой.
  String? _pendingDeviceLoss;
  Timer? _pendingDeviceLossTimer;

  /// Громкость до смены устройства и таймер её проверки.
  ///
  /// Системный микшер при переключении устройства иногда оставляет ноль.
  /// Запоминаем прежнюю громкость до переключения и через мгновение сверяем:
  /// если звук обнулился сам, возвращаем его.
  double? _volumeBeforeDeviceChange;
  Timer? _volumeRecoveryTimer;

  /// Очередь пересборок своей доли в `af`.
  ///
  /// Параллельные пересборки читали бы состояние эффектов вразнобой и ставили
  /// цепочку из устаревшего набора. Сами записи в `af` сериализует
  /// [MpvAudioChain] — туда же обращается монитор уровня.
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
    // «Системное» устройство: узнаём, какое физическое выбрано на самом деле.
    unawaited(_observeDetectedDevice());
  }

  /// Слушает свойство mpv «обнаруженное устройство вывода».
  ///
  /// Свойство есть не у каждого аудиодрайвера (на Windows — у `wasapi`);
  /// неизвестное свойство mpv просто игнорирует, и тогда остаётся сверка
  /// выбранного устройства со списком (см. [_checkDeviceLoss]).
  Future<void> _observeDetectedDevice() async {
    final NativePlayer? native = _native;
    if (native == null) return;
    try {
      await native.observeProperty('audio-out-detected-device', (String value) async {
        final String name = value.trim();
        if (name.isEmpty || name == _detectedDevice) return;
        final String previous = _detectedDevice ?? '';
        _detectedDevice = name;
        _watchVolumeAfterDeviceChange();
        // Прежнее устройство могло исчезнуть: mpv просто перешёл на следующее.
        // Список к этому моменту бывает ещё старым, поэтому не спешим — ждём
        // подтверждения от [_onAudioDevices], если оно вообще нужно.
        if (previous.isNotEmpty &&
            previous != 'auto' &&
            _knownDeviceNames.contains(previous)) {
          _pendingDeviceLoss = previous;
          if (!_lastDevices.any((AudioOutputDevice d) => d.name == previous)) {
            _pendingDeviceLoss = null;
            _reportDeviceLoss(previous);
          } else {
            // Список ещё старый. Даём ему обновиться; пользовательская смена
            // устройства список не трогает, поэтому по таймеру просто снимаем
            // ожидание — паузы не будет.
            _pendingDeviceLossTimer?.cancel();
            _pendingDeviceLossTimer = Timer(
              const Duration(seconds: 2),
              () => _pendingDeviceLoss = null,
            );
          }
        }
        _checkDeviceLoss(_lastDevices);
      });
    } on Object catch (error) {
      // Драйвер без такого свойства — не повод что-то менять в звуке.
      debugPrint('Устройство вывода не отслеживается: $error');
    }
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
    final List<AudioOutputDevice> mapped = _mapDevices(devices);
    _lastDevices = mapped;
    for (final AudioOutputDevice device in mapped) {
      _knownDeviceNames.add(device.name);
    }
    _confirmPendingDeviceLoss(mapped);
    _checkDeviceLoss(mapped);
    if (_devices.isClosed) return;
    _devices.add(mapped);
  }

  /// Подтверждает пропажу по свежему списку устройств.
  ///
  /// Пока список пуст, судить не о чем. Если прежнее устройство в списке
  /// осталось — это была смена по выбору пользователя, а не пропажа.
  void _confirmPendingDeviceLoss(List<AudioOutputDevice> devices) {
    final String? pending = _pendingDeviceLoss;
    if (pending == null || devices.isEmpty) return;
    _pendingDeviceLossTimer?.cancel();
    _pendingDeviceLossTimer = null;
    _pendingDeviceLoss = null;
    if (devices.any((AudioOutputDevice d) => d.name == pending)) return;
    _reportDeviceLoss(pending);
  }

  /// Проверяет, не исчезло ли устройство, в которое идёт звук.
  ///
  /// Активное устройство — выбранное пользователем, а при «Системном» — то,
  /// что mpv реально обнаружил. Пустой список — это ещё не перечисленные
  /// устройства, а не пропажа: иначе пауза срабатывала бы при старте.
  void _checkDeviceLoss(List<AudioOutputDevice> devices) {
    if (devices.isEmpty) return;
    final String selected = _player.state.audioDevice.name;
    final String active = selected == 'auto' || selected.isEmpty
        ? (_detectedDevice ?? '')
        : selected;
    if (active.isEmpty || active == 'auto') return;
    if (devices.any((AudioOutputDevice d) => d.name == active)) {
      _deviceLossReported = false;
      return;
    }
    // Если такого имени список никогда не показывал, это разный формат имён,
    // а не пропажа: молчим, чтобы не поставить паузу на ровном месте.
    if (!_knownDeviceNames.contains(active)) return;
    _reportDeviceLoss(active);
  }

  /// Сообщает о пропаже устройства один раз, пока оно не вернётся.
  void _reportDeviceLoss(String name) {
    if (_deviceLossReported) return;
    _deviceLossReported = true;
    if (!_deviceLoss.isClosed) {
      _deviceLoss.add(AudioOutputDevice(name: name, description: name));
    }
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

  /// Пропало устройство, в которое шёл звук.
  ///
  /// Намеренно не часть [AudioEngine]: движок не решает, ставить ли паузу, —
  /// это настройка приложения. Контроллер подписывается на поток, если движок
  /// умеет отличать пропажу (см. `player_controller.dart`).
  Stream<AudioOutputDevice> get lostAudioDeviceStream => _deviceLoss.stream;

  @override
  Future<void> setAudioDevice(String name) async {
    final List<AudioDevice> list = _player.state.audioDevices;
    final AudioDevice device = list.firstWhere(
      (AudioDevice d) => d.name == name,
      orElse: () => AudioDevice(name, ''),
    );
    _watchVolumeAfterDeviceChange();
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
      await _openInChain(
        () => _player.open(_mediaFor(source, isLocal), play: autoplay),
        resetPitch: pitchWasShifted,
      );
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
      // Пользователь нажал «играть» — именно это и восстанавливаем.
      await _restart(target, autoplay: true);
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
  /// `target` — откуда начать (ноль — с начала). [autoplay] — играть ли сразу;
  /// по умолчанию сохраняется то, что было: после ошибки или паузы перезапуск
  /// не должен включать звук без команды пользователя.
  Future<void> _restart(
    Duration target, {
    bool emitLoading = true,
    bool? autoplay,
  }) async {
    final String? source = _lastSource;
    if (source == null) return;
    final bool shouldPlay = autoplay ??
        (_state.status == PlaybackStatus.playing ||
            _state.status == PlaybackStatus.buffering);

    _opening = true;
    if (emitLoading) {
      _emit(_state.copyWith(status: PlaybackStatus.loading, clearError: true));
    }
    try {
      await _openInChain(
        () => _player.open(
          _mediaFor(source, _lastIsLocal, start: target),
          play: shouldPlay,
        ),
      );
      unawaited(_rebuildAudioChain());
      if (!shouldPlay) {
        // Открыли на паузе: настоящего `playing = true` не будет, снимаем
        // флаг открытия сами.
        _opening = false;
        _emit(_state.copyWith(
          status: PlaybackStatus.paused,
          position: target,
          clearError: true,
        ));
        return;
      }
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

  /// Открывает поток в очереди `af` и сразу восстанавливает темп/питч.
  ///
  /// `open` сбрасывает `af` — media_kit ставит туда только свой `scaletempo`.
  /// Если открывать вне очереди, запись движка или монитора могла бы попасть в
  /// зазор и потеряться. Здесь открытие и повторная сборка идут одной задачей
  /// владельца цепочки.
  Future<void> _openInChain(
    Future<void> Function() open, {
    bool resetPitch = false,
  }) async {
    final MpvAudioChain? chain = _chain;
    if (chain == null) {
      await open();
      _sourceLoaded = true;
      await _applyTempoPitch(resetPitch: resetPitch);
      return;
    }
    await chain.exclusive(() async {
      await open();
      _sourceLoaded = true;
      await _applyTempoPitch(resetPitch: resetPitch);
    });
  }

  /// Собирает [Media] для сетевого адреса или локального файла.
  ///
  /// Заголовки получают только сетевые источники: `Media.httpHeaders` заставляет
  /// media_kit выставить libmpv `http-header-fields`, а файлу это ни к чему и
  /// добавило бы лишний хук на каждое открытие.
  Media _mediaFor(String source, bool isLocal, {Duration? start}) {
    final String uri = isLocal ? Uri.file(source).toString() : source;
    final Map<String, String>? headers =
        isLocal ? null : StreamRequestHeaders.forUrl(uri);
    if (headers == null || headers.isEmpty) {
      return Media(uri, start: start);
    }
    return Media(uri, start: start, httpHeaders: headers);
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

  /// Запоминает громкость перед сменой устройства и проверяет её после.
  ///
  /// Системный микшер иногда оставляет на новом устройстве ноль. Проверяем не
  /// сразу, а через мгновение: драйвер выставляет громкость не мгновенно, и
  /// слишком ранняя проверка увидела бы ещё прежнее значение.
  void _watchVolumeAfterDeviceChange() {
    final double target = _state.volume;
    // Ноль выставил пользователь — «восстанавливать» его обратно нельзя.
    if (target <= 0.01) return;
    _volumeBeforeDeviceChange = target;
    _volumeRecoveryTimer?.cancel();
    _volumeRecoveryTimer = Timer(
      const Duration(milliseconds: 700),
      () => unawaited(_restoreVolumeAfterDeviceChange()),
    );
  }

  Future<void> _restoreVolumeAfterDeviceChange() async {
    final double? target = _volumeBeforeDeviceChange;
    _volumeBeforeDeviceChange = null;
    if (target == null || _disposed) return;
    // Пользователь успел выставить другую громкость — его выбор важнее.
    if ((_state.volume - target).abs() > 0.01) return;
    // `volume` у media_kit — проценты: ноль означает «звука нет».
    if (_player.state.volume > 0.5) return;
    await _player.setVolume(target * 100.0);
    _emit(_state.copyWith(volume: target));
    debugPrint('Громкость восстановлена после смены устройства вывода');
  }

  @override
  Future<void> setSpeed(double speed) async {
    final double clamped = speed.clamp(0.5, 2.0);
    _speed = clamped;
    // `setRate` переписывает `af` целиком (scaletempo), поэтому идёт в очередь
    // владельца цепочки: иначе запись монитора или пересборка эффектов между
    // чтением и записью потерялась бы.
    final MpvAudioChain? chain = _chain;
    if (chain != null) {
      await chain.exclusive(() => _player.setRate(clamped));
    } else {
      await _player.setRate(clamped);
    }
    await _rebuildAudioChain();
    _emit(_state.copyWith(speed: clamped));
  }

  @override
  bool get supportsPitch => true;

  @override
  Future<void> setPitch(double pitch) async {
    final double clamped = pitch.clamp(0.5, 2.0);
    _pitch = clamped;
    final MpvAudioChain? chain = _chain;
    if (chain != null) {
      await chain.exclusive(() => _player.setPitch(clamped));
    } else {
      await _player.setPitch(clamped);
    }
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

  /// Имя доли движка в общей цепочке `af`.
  static const String _partId = 'engine';

  /// Метка фильтров, которыми владеет движок.
  ///
  /// По ней свои фильтры отличаются от чужих (`scaletempo` от media_kit,
  /// `astats` визуализатора с меткой `mopsvis`), чтобы пересборка не снесла
  /// чужое.
  static const String _eqLabel = 'mopseq';
  static const String _gainLabel = 'mopsgain';
  static const String _skipLabel = 'mopsskip';
  static const String _normLabel = 'mopsnorm';

  /// Центры 18 фиксированных полос фильтра `superequalizer` (FFmpeg). Полоса
  /// ниже 65 Гц у него отсутствует, поэтому 10 «стандартных» полос в точности
  /// он не выражает — значения берём интерполяцией по его сетке.
  static const List<double> _superEqualizerFrequencies = <double>[
    65, 92, 131, 185, 262, 370, 523, 740, 1047, 1480, 2093, 2960,
    4186, 5920, 8372, 11840, 16744, 20000,
  ];

  /// Допустимый диапазон усиления полос `superequalizer`. Параметры `Nb` у
  /// него — линейный коэффициент, а не децибелы: 1 — полоса без изменения,
  /// 0 — полоса вырезана, а верхняя граница в нашей сборке — 20 (mpv пишет
  /// «out of range [0 - 20]»). Отсюда и потолок ограничения.
  static const double _superEqualizerMinGain = 0;
  static const double _superEqualizerMaxGain = 20;

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
  /// цепочку, и тогда непонятно, что применилось. Чужое (scaletempo, astats
  /// визуализатора) сохраняется, свои прошлые фильтры снимаются, затем
  /// дописываются текущие. Саму запись делает [MpvAudioChain] — он же владелец
  /// `af` для монитора уровня.
  Future<void> _rebuildAudioChain() {
    final Future<void> run = (_chainQueue ?? Future<void>.value())
        .then((_) => _applyAudioChain());
    // Хвост очереди не должен «падать»: иначе следующая пересборка не пойдёт.
    _chainQueue = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _applyAudioChain() async {
    final MpvAudioChain? chain = _chain;
    if (chain == null) {
      _setEffectIssue(null);
      return;
    }

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

    // Долю обновляем всегда, а применяем только при открытом потоке: до `open`
    // ставить цепочку некуда, её подхватит ближайшее открытие.
    final String? applied = await chain.setPart(
      _partId,
      MpvAudioChain.enginePriority,
      own,
      apply: _sourceLoaded,
    );
    if (!_sourceLoaded) {
      _setEffectIssue(issues.isEmpty ? null : issues.toSet().join('; '));
      return;
    }

    // Проверяем приём: при отказе mpv оставляет прежнюю цепочку. Молчать об
    // этом нельзя, но и рвать звук из-за фильтра — тоже.
    if (applied == null) {
      _setEffectIssue('не удалось применить аудиофильтры');
      return;
    }
    final bool eqRequested =
        _equalizerBands.length == kEqualizerBandCount &&
            !equalizerIsFlat(_equalizerBands);
    if (eqRequested && !MpvAudioChain.containsLabel(applied, _eqLabel)) {
      issues.add(_filterIssue('superequalizer'));
    }
    if (_skipSilence && !MpvAudioChain.containsLabel(applied, _skipLabel)) {
      issues.add(_filterIssue('silenceremove'));
    }
    if (_normalization && !MpvAudioChain.containsLabel(applied, _normLabel)) {
      issues.add(_filterIssue('dynaudnorm'));
    }
    _setEffectIssue(issues.isEmpty ? null : issues.toSet().join('; '));
  }

  /// Дописывает в [own] фильтр эквалайзера, если он настроен и есть в сборке.
  Future<void> _appendEqualizer(List<String> own) async {
    final List<double> bands = _equalizerBands;
    if (bands.length != kEqualizerBandCount || equalizerIsFlat(bands)) return;

    // Кривая остаётся в дБ до самой сборки строки: интерполяция между полосами
    // в децибелах совпадает с тем, что видит человек на графике, а линейное
    // усиление считается один раз — для фильтра.
    final List<double> gains = _sampleSuperEqualizer(bands);
    // Проверку `volume` заводим сразу: она идёт параллельно проверке
    // эквалайзера, и первый подъём кривой не ждёт две паузы подряд.
    final Future<bool> volumeSupported =
        MpvFilterProbe.supports('volume', 'volume=-1.00dB');

    // Основной вариант — `superequalizer` (18 полос, кадровая обработка),
    // запасной — `equalizer`: одна параметрическая полоса на фильтр.
    final bool hasSuper =
        await MpvFilterProbe.supports('superequalizer', '1b=1');
    final bool hasFallback = !hasSuper &&
        await MpvFilterProbe.supports('equalizer', 'f=1000:t=q:w=1:g=0');
    if (!hasSuper && !hasFallback) return;

    if (hasSuper) {
      final String params = <String>[
        for (int i = 0; i < gains.length; i++)
          '${i + 1}b=${_superEqualizerGain(gains[i]).toStringAsFixed(2)}',
      ].join(':');
      own.add('@$_eqLabel:superequalizer=$params');
    } else {
      // У `equalizer` параметр `g` действительно в децибелах, поэтому
      // конвертация не нужна. Полосы метим отдельными метками: одно имя на
      // несколько фильтров mpv не даёт.
      for (int i = 0; i < kEqualizerBandCount; i++) {
        own.add(
          '@$_eqLabel${i + 1}:equalizer='
          'f=${kEqualizerBandFrequencies[i].round()}:t=q:w=1:'
          'g=${bands[i].toStringAsFixed(2)}',
        );
      }
    }

    // Запас по громкости: полосы складываются, и подъём кривой уводит пики за
    // ноль. Опускаем весь тракт на самый большой подъём — пресет звучит тише,
    // но не режет верх. Плоскую кривую сюда не пускает проверка выше.
    final double peakDb = gains.reduce(math.max);
    if (peakDb > 0 && await volumeSupported) {
      final String attenuation = (-peakDb).toStringAsFixed(2);
      own.add('@$_gainLabel:volume=volume=${attenuation}dB');
    }
  }

  /// Переводит децибелы в линейное усиление полосы `superequalizer`.
  static double _superEqualizerGain(double db) =>
      math.pow(10, db / 20).toDouble().clamp(
            _superEqualizerMinGain,
            _superEqualizerMaxGain,
          ).toDouble();

  /// Раскладывает 10-полосную кривую по 18 фиксированным полосам
  /// `superequalizer`: значение в полосе фильтра — линейная интерполяция между
  /// соседними полосами эквалайзера в логарифмической шкале частот. Результат
  /// в дБ — в линейное усиление его переводит [_superEqualizerGain].
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
    _volumeRecoveryTimer?.cancel();
    _volumeRecoveryTimer = null;
    _pendingDeviceLossTimer?.cancel();
    _pendingDeviceLossTimer = null;
    for (final StreamSubscription<dynamic> sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await _controller.close();
    await _devices.close();
    await _deviceLoss.close();
    _effectIssue.dispose();
    try {
      await _player.dispose();
    } on Object catch (error) {
      debugPrint('Ошибка при освобождении плеера: $error');
    }
  }
}
