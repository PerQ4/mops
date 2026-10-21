import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/audio/audio_engine.dart';
import '../core/audio/media_kit_engine.dart';
import '../core/scrobbling/scrobbler.dart';
import '../data/local/queue_snapshot.dart';
import '../data/models/models.dart';
import '../data/sources/sponsorblock.dart';
import '../data/sources/stream_downloader.dart';
import '../data/sources/stream_proxy.dart';
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

/// Значение таймера сна «остановить после текущего трека».
///
/// Отдельная константа, а не литерал `-1` в интерфейсе: одно и то же значение
/// читают и контроллер (в `_handleTrackEnded`), и меню выбора.
const int kSleepTimerAfterTrack = -1;

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
    this.audioDevices = const <AudioOutputDevice>[],
    this.audioDeviceName = 'auto',
    this.sleepTimer = 0,
    this.unavailableIds = const <String>{},
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

  /// Доступные устройства вывода звука.
  final List<AudioOutputDevice> audioDevices;

  /// Выбранное устройство вывода (`auto` — системное).
  final String audioDeviceName;

  /// Таймер сна: `0` — выключен, [kSleepTimerAfterTrack] — остановить после
  /// текущего трека, `> 0` — сколько минут осталось до остановки.
  ///
  /// Хранится именно остаток, а не выбранное число минут: интерфейсу нужно
  /// показывать, сколько ещё играть. Отсчёт идёт от дедлайна в контроллере,
  /// поэтому подпись не «уезжает» из-за задержек тика.
  final int sleepTimer;

  /// Треки, для которых YouTube не отдал поток именно из-за недоступности
  /// (удалён, скрыт, ограничен по региону). Обычные сетевые ошибки сюда не
  /// попадают: для них замена не нужна, достаточно повторить попытку.
  final Set<String> unavailableIds;

  Track? get current =>
      (index >= 0 && index < queue.length) ? queue[index] : null;

  bool get hasTrack => current != null;
  bool get isPlaying => playback.isPlaying;
  bool get isLoading => resolving || downloading || playback.isLoading;

  /// Таймер сна включён (в любом из режимов).
  bool get sleepTimerActive => sleepTimer != 0;

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
    List<AudioOutputDevice>? audioDevices,
    String? audioDeviceName,
    int? sleepTimer,
    Set<String>? unavailableIds,
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
      audioDevices: audioDevices ?? this.audioDevices,
      audioDeviceName: audioDeviceName ?? this.audioDeviceName,
      sleepTimer: sleepTimer ?? this.sleepTimer,
      unavailableIds: unavailableIds ?? this.unavailableIds,
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

  /// Скробблинг: Last.fm и ListenBrainz живут за одним хуком — правило
  /// «когда отправлять» для площадок общее (см. `core/scrobbling`).
  ScrobblerController get _scrobbler =>
      ref.read(scrobblingProvider.notifier);

  StreamSubscription<PlaybackState>? _engineSub;
  StreamSubscription<List<AudioOutputDevice>>? _devicesSub;

  /// Пропажа устройства вывода: только [MediaKitEngine] умеет её заметить.
  StreamSubscription<AudioOutputDevice>? _deviceLossSub;
  final Random _random = Random();

  /// История проигранных индексов — нужна для «назад» при перемешивании.
  final List<int> _history = <int>[];

  /// Идёт перемотка. Пока она не закончилась, завершение трека может прийти
  /// ложно (GStreamer шлёт EOS на flush-перемотке потока) — его игнорируем,
  /// иначе очередь перескочит на следующий.
  bool _seeking = false;

  /// Уже обрабатываем конец трека. Завершение может прийти дважды, и без
  /// этого флага очередь перескочила бы через трек.
  bool _handlingEnd = false;

  /// Тик подписи таймера сна (раз в минуту).
  Timer? _sleepTimer;

  /// Одноразовый «выстрел» таймера сна — ровно в дедлайн.
  Timer? _sleepStop;

  /// Момент, когда таймер сна должен остановить звук.
  ///
  /// Отсчёт идёт от него, а не «минус минута за тик»: тик может опоздать
  /// (сборка кадра, простой процесса), и накопленная ошибка растянула бы
  /// таймер.
  DateTime? _sleepDeadline;

  /// Очередь восстановлена из снимка, но трек ещё не загружен в движок.
  ///
  /// Пока это так, «idle» от движка (например, от установки громкости) не
  /// должен затирать сохранённую позицию, которую показывает интерфейс.
  bool _restorePending = false;

  /// Позиция, с которой нужно продолжить восстановленный трек.
  Duration _restorePosition = Duration.zero;

  /// Периодическая запись снимка очереди.
  Timer? _snapshotTimer;

  /// Последний записанный снимок — чтобы не писать на диск одно и то же.
  String? _lastSnapshot;

  /// Вставки текущего трека по данным SponsorBlock.
  List<SponsorSegment> _sponsorSegments = const <SponsorSegment>[];

  /// Трек, для которого получены [_sponsorSegments].
  String? _sponsorTrackId;

  /// Категории, с которыми запрошены текущие сегменты.
  ///
  /// Храним отдельно от настроек: если пользователь включит новую категорию,
  /// набор разойдётся, и сегменты нужно перезапросить — иначе новая метка
  /// просто не придёт.
  Set<SponsorBlockCategory> _sponsorCategories =
      const <SponsorBlockCategory>{};

  /// Отметки, которые уже пропущены в этом проигрывании трека.
  ///
  /// Именно по UUID, а не по позиции: движок после перемотки ещё несколько
  /// тиков присылает прежнюю позицию, и без этого списка мы бы перематывали
  /// один и тот же отрезок по кругу.
  final Set<String> _sponsorSkipped = <String>{};

  /// Идёт перемотка через вставку: следующие тики не должны запускать ещё
  /// одну, пока движок не догнал новую позицию.
  bool _sponsorSeeking = false;

  @override
  PlayerUiState build() {
    // Отписка от предыдущего движка (если нотификатор пересоздали).
    _engineSub?.cancel();
    // Таймер сна — состояние сессии: при пересоздании нотификатора он не
    // должен остаться висеть от прошлого.
    _cancelSleepTimer();

    _engineSub = _engine.stateStream.listen((PlaybackState playback) {
      // Пока восстановленный трек не запущен, в движке ничего нет: его «idle»
      // затирал бы сохранённую позицию, которую показывает интерфейс.
      if (_restorePending && playback.status == PlaybackStatus.idle) {
        return;
      }
      state = state.copyWith(playback: playback);
      if (playback.status == PlaybackStatus.error && playback.error != null) {
        state = state.copyWith(error: playback.error);
      }

      // Пропуск вставок — здесь же, на тиках движка: это единственный момент,
      // когда известна настоящая позиция. Ошибки сети клиент глотает сам,
      // поэтому вызов не может помешать воспроизведению.
      _syncSponsorBlock(playback);

      // Скробблинг: «сейчас играет» и накопление прослушанного. Идёт до
      // обработки конца трека: там очередь перескочит на следующий, а закрыть
      // статистику нужно по сыгравшему треку.
      final bool acceptedEnd = playback.status == PlaybackStatus.completed &&
          !_seeking &&
          !_handlingEnd &&
          !playback.hasError;
      _scrobblePlayback(playback, completed: acceptedEnd);

      // На ошибке и во время перемотки вперёд не идём: «конец трека» здесь
      // ложный, а настоящее завершение придёт без этих условий.
      if (acceptedEnd) {
        // Не await: обработчик не должен блокировать поток событий.
        _handlingEnd = true;
        unawaited(
          _handleTrackEnded()
              .catchError((Object error) =>
                  debugPrint('Ошибка обработки конца трека: $error'))
              .whenComplete(() => _handlingEnd = false),
        );
      }
    });

    // Восстанавливаем громкость и скорость из прошлой сессии.
    final settings = ref.read(settingsControllerProvider);
    unawaited(_engine.setVolume(settings.lastVolume));
    unawaited(_engine.setSpeed(settings.lastSpeed));

    // Смена настроек SponsorBlock подхватывается сразу, не дожидаясь тика:
    // включённая категория должна подтянуть свои метки даже на паузе, а
    // выключенная — сразу перестать пропускаться. Остальные настройки
    // (громкость, тема) сюда не относятся, поэтому сравниваем только поля
    // блокировки.
    ref.listen(settingsControllerProvider, (previous, next) {
      final bool sameBlockSettings = previous != null &&
          previous.sponsorBlockEnabled == next.sponsorBlockEnabled &&
          setEquals(
            previous.sponsorBlockCategories.toSet(),
            next.sponsorBlockCategories.toSet(),
          );
      if (sameBlockSettings) return;
      _syncSponsorBlock(state.playback);
    });

    // Очередь прошлой сессии читаем до возврата состояния: она должна быть на
    // экране с первого кадра, а не появиться через мгновение. Восстанавливаем
    // без автозапуска — звук пойдёт только после нажатия «играть».
    final QueueSnapshot? snapshot = settings.restoreQueue
        ? QueueSnapshot.decode(
            ref.read(sharedPreferencesProvider).getString(kQueueSnapshotKey),
          )
        : null;
    if (snapshot != null) {
      _restorePending = true;
      _restorePosition = snapshot.position;
    }

    // Устройства вывода: список приходит от движка и меняется на лету.
    // В `build()` состояние читать нельзя — начальный список отдаём через
    // возвращаемое значение, а дальше обновляем из потока.
    _devicesSub?.cancel();
    _devicesSub = _engine.audioDevicesStream.listen(
      (List<AudioOutputDevice> devices) {
        state = state.copyWith(audioDevices: devices);
      },
    );

    // Пропажа устройства вывода. Поток есть только у движка, который умеет её
    // отличать от смены устройства пользователем; у прочих здесь ничего нет.
    _deviceLossSub?.cancel();
    _deviceLossSub = null;
    final AudioEngine engine = _engine;
    if (engine is MediaKitEngine) {
      _deviceLossSub = engine.lostAudioDeviceStream.listen(_onAudioDeviceLost);
    }

    // Позицию сохраняем по таймеру, а не на каждое её обновление: движок шлёт
    // её несколько раз в секунду, и столько же записей на диск было бы лишним.
    _snapshotTimer?.cancel();
    _snapshotTimer = Timer.periodic(
      const Duration(seconds: 5),
      (Timer _) => _persistSnapshot(),
    );

    ref.onDispose(() {
      _engineSub?.cancel();
      _engineSub = null;
      _devicesSub?.cancel();
      _devicesSub = null;
      _deviceLossSub?.cancel();
      _deviceLossSub = null;
      _snapshotTimer?.cancel();
      _snapshotTimer = null;
      _cancelSleepTimer();
    });

    return PlayerUiState(
      queue: snapshot?.tracks ?? const <Track>[],
      index: snapshot?.index ?? -1,
      playback: _restoredPlayback(snapshot),
      audioDevices: _engine.audioDevices,
    );
  }

  /// Состояние воспроизведения восстановленной очереди: трек выбран, но не
  /// загружен — показываем сохранённую позицию и длительность, статус «пауза».
  PlaybackState _restoredPlayback(QueueSnapshot? snapshot) {
    final Track? track = snapshot?.current;
    if (track == null) return PlaybackState.initial;
    return PlaybackState(
      status: PlaybackStatus.paused,
      position: snapshot!.position,
      duration: track.duration,
    );
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

  /// Запускает «радио» от трека: сам трек встаёт первым, дальше — похожие
  /// рекомендации YouTube.
  ///
  /// В отличие от [_extendWithRadio], который дописывает конец очереди, здесь
  /// очередь заменяется целиком: это осознанный выбор пользователя, а не
  /// автоматическое продление.
  Future<void> startRadio(Track seed) async {
    try {
      final List<Track> radio =
          await ref.read(catalogSourceProvider).autoplayQueue(seed.id);
      // Seed первым, его же из рекомендаций убираем: `autoplayQueue` уже
      // отсеивает сам трек, но контракт чужих списков лучше не предполагать.
      final List<Track> queue = <Track>[
        seed,
        ...radio.where((Track t) => t.id != seed.id).take(25),
      ];

      // Seed уже звучит: `playQueue` перезагрузил бы его с нуля и оборвал
      // музыку. Меняем только очередь — трек и позиция остаются на месте.
      if (state.current?.id == seed.id) {
        _history.clear();
        state = state.copyWith(
          queue: List<Track>.of(queue),
          index: 0,
          clearError: true,
        );
        _persistSnapshot();
        return;
      }

      await playQueue(queue);
    } on Exception catch (error) {
      state = state.copyWith(error: 'Не удалось загрузить рекомендации: $error');
    }
  }

  /// Добавляет трек в конец очереди.
  void enqueue(Track track) {
    final List<Track> queue = <Track>[...state.queue, track];
    state = state.copyWith(queue: queue);
    _persistSnapshot();
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
    _persistSnapshot();
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= state.queue.length) return;
    final List<Track> queue = <Track>[...state.queue]..removeAt(index);

    // Убрали играющий трек: на его место встаёт следующий, и играть должен
    // именно он. Без перезагрузки состояние показывало бы новый трек, а звучал
    // бы прежний — как раз этот случай и случался.
    final bool removedCurrent = index == state.index;

    int newIndex = state.index;
    if (index < state.index) {
      newIndex = state.index - 1;
    } else if (removedCurrent) {
      // Убрали последний оставшийся трек: clamp по пустому списку бросил бы
      // ArgumentError (диапазон 0..-1), поэтому индекс сбрасываем сами —
      // ниже он всё равно станет -1.
      newIndex = queue.isEmpty ? -1 : state.index.clamp(0, queue.length - 1);
    }
    state = state.copyWith(queue: queue, index: queue.isEmpty ? -1 : newIndex);
    _persistSnapshot();

    if (queue.isEmpty) {
      // Очереди нет — таймеру нечего останавливать: без снятия он «выстрелил»
      // бы позже по пустому плееру.
      clearSleepTimer();
      _releaseStreams();
      unawaited(_engine.stop());
      return;
    }
    if (removedCurrent) unawaited(_loadCurrent());
  }

  /// Подменяет трек во всех позициях очереди.
  ///
  /// Позиция воспроизведения и состояние «играет/пауза» не меняются. Если
  /// заменяется играющий трек, сначала загружается новый поток, затем
  /// возвращаются прежняя позиция и пауза: иначе подмена начинала бы песню
  /// с начала и включала звук там, где он был выключен.
  Future<void> replaceTrack(Track oldTrack, Track replacement) async {
    if (oldTrack.id == replacement.id) return;
    if (!state.queue.any((Track t) => t.id == oldTrack.id)) return;

    final bool wasCurrent = state.current?.id == oldTrack.id;
    final PlaybackState playback = state.playback;

    final List<Track> queue = <Track>[
      for (final Track track in state.queue)
        if (track.id == oldTrack.id)
          Track(
            id: replacement.id,
            title: replacement.title,
            artists: replacement.artists,
            album: replacement.album,
            duration: replacement.duration,
            thumbnails: replacement.thumbnails,
            isExplicit: replacement.isExplicit,
            // Контекст плейлиста в очереди сохраняем: по нему боковая панель
            // понимает, какой плейлист сейчас звучит. Запись `setVideoId`
            // относится к старому видео и новой записи уже не подходит.
            playlistId: track.playlistId,
            isVideo: replacement.isVideo,
          )
        else
          track,
    ];
    state = state.copyWith(queue: queue);

    if (!wasCurrent) {
      _persistSnapshot();
      return;
    }

    await _loadCurrent(autoplay: playback.isPlaying);
    // Пока резолвили поток, пользователь мог переключить трек — тогда
    // возвращать позицию уже некуда.
    if (state.current?.id != replacement.id) return;

    if (playback.position > Duration.zero) {
      await seek(playback.position);
    }
    _persistSnapshot();
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
    _persistSnapshot();
  }

  Future<void> clearQueue() async {
    _history.clear();
    // Очередь обнуляется целиком — вместе с ней снимаем и таймер сна.
    clearSleepTimer();
    // И снимок: при следующем запуске восстанавливать нечего.
    _clearSnapshot();
    state = const PlayerUiState();
    _releaseStreams();
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
      // Пауза — удобный момент зафиксировать позицию: дальше она не меняется.
      _persistSnapshot();
    } else {
      await play();
    }
  }

  Future<void> play() {
    // Восстановленный трек в движке ещё не загружен — сначала загружаем его,
    // и только потом возвращаем сохранённую позицию.
    if (_restorePending && state.hasTrack) return _resumeRestored();
    return _engine.play();
  }

  Future<void> pause() async {
    await _engine.pause();
    _persistSnapshot();
  }

  Future<void> next() => _advance(manual: true);

  Future<void> previous() async {
    // Восстановленный трек в движке ещё не загружен: перематывать нечего —
    // «назад» начинает его с начала.
    if (_restorePending && state.hasTrack) {
      await _resumeRestored(position: Duration.zero);
      return;
    }

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

  Future<void> seek(Duration position) async {
    // Перемотка поднимает флаг до самого её окончания: ложный EOS,
    // пришедший в это окно, не должен переключать очередь.
    _seeking = true;
    try {
      await _engine.seek(position);
    } on Object catch (error) {
      // Сбой перемотки не останавливает воспроизведение.
      debugPrint('Перемотка не удалась: $error');
    } finally {
      _seeking = false;
    }
  }

  Future<void> seekFraction(double fraction) {
    final Duration duration = state.playback.duration;
    if (duration <= Duration.zero) return Future<void>.value();
    return _engine.seek(duration * fraction.clamp(0.0, 1.0));
  }

  // ------------------------------------------------------------ SponsorBlock

  /// Держит сегменты в соответствии с треком и настройками и пропускает
  /// вставку, если позиция внутри неё.
  ///
  /// Проверка категории идёт по текущим настройкам, а не по тем, с которыми
  /// сегменты запрашивались: выключенная категория должна перестать
  /// пропускаться сразу, даже если её сегменты уже лежат в памяти.
  void _syncSponsorBlock(PlaybackState playback) {
    final Track? track = state.current;
    if (track == null) return;

    final settings = ref.read(settingsControllerProvider);
    final Set<SponsorBlockCategory> categories =
        settings.sponsorBlockEnabled
            ? settings.sponsorBlockCategories.toSet()
            : const <SponsorBlockCategory>{};

    // Настройка выключена или не выбрано ни одной категории.
    if (categories.isEmpty) {
      _clearSponsorState();
      return;
    }

    if (_sponsorTrackId != track.id ||
        !_sameSponsorCategories(categories)) {
      _sponsorTrackId = track.id;
      _sponsorCategories = categories;
      _sponsorSegments = const <SponsorSegment>[];
      _sponsorSkipped.clear();
      unawaited(_fetchSponsorSegments(track.id, categories));
    }

    // Пропускаем только во время звука: на паузе перемотка была бы
    // неожиданной, а на завершении трека — уже бессмысленной.
    if (!playback.isPlaying || _sponsorSeeking) return;

    final Duration position = playback.position;
    for (final SponsorSegment segment in _sponsorSegments) {
      if (!categories.contains(segment.category)) continue;
      if (_sponsorSkipped.contains(segment.uuid)) continue;
      if (position < segment.start || position >= segment.end) continue;

      // Отметку ставим ДО перемотки: пока движок не догнал новую позицию,
      // он присылает старую, и без отметки мы бы перематывали повторно.
      _sponsorSkipped.add(segment.uuid);
      _sponsorSeeking = true;
      unawaited(
        seek(segment.end).whenComplete(() => _sponsorSeeking = false),
      );
      break;
    }
  }

  Future<void> _fetchSponsorSegments(
    String videoId,
    Set<SponsorBlockCategory> categories,
  ) async {
    final List<SponsorSegment> segments = await ref
        .read(sponsorBlockClientProvider)
        .segments(videoId, categories: categories);

    // Пока шёл запрос, трек или категории могли смениться — результат
    // устарел и к текущему воспроизведению не относится.
    if (!ref.mounted || _sponsorTrackId != videoId) return;
    if (!_sameSponsorCategories(categories)) return;
    _sponsorSegments = segments;
  }

  bool _sameSponsorCategories(Set<SponsorBlockCategory> categories) =>
      categories.length == _sponsorCategories.length &&
      _sponsorCategories.containsAll(categories);

  void _clearSponsorState() {
    if (_sponsorTrackId == null && _sponsorSegments.isEmpty) return;
    _sponsorTrackId = null;
    _sponsorCategories = const <SponsorBlockCategory>{};
    _sponsorSegments = const <SponsorSegment>[];
    _sponsorSkipped.clear();
  }

  Future<void> setVolume(double volume) async {
    await _engine.setVolume(volume);
    await ref.read(settingsControllerProvider.notifier).setLastVolume(volume);
  }

  Future<void> setSpeed(double speed) async {
    await _engine.setSpeed(speed);
    await ref.read(settingsControllerProvider.notifier).setLastSpeed(speed);
  }

  /// Меняет высоту тона относительно темпа (1.0 — без сдвига).
  ///
  /// В настройках для питча поля нет: сдвинутая высота — свойство конкретного
  /// прослушивания, а не привычка, поэтому между запусками она не сохраняется
  /// и сбрасывается при загрузке нового трека (это делает движок).
  Future<void> setPitch(double pitch) => _engine.setPitch(pitch);

  /// Выбирает устройство вывода звука (`auto` — системное).
  Future<void> setAudioDevice(String name) async {
    state = state.copyWith(audioDeviceName: name);
    await _engine.setAudioDevice(name);
  }

  /// Устройство, в которое шёл звук, исчезло (выдернули наушники, отвалился
  /// Bluetooth).
  ///
  /// Возвращать выбор к «Системному» нужно в любом случае: прежнего устройства
  /// больше нет, и отметка в списке указывала бы в пустоту. Пауза же — по
  /// настройке: иначе трек продолжался бы в тишину.
  void _onAudioDeviceLost(AudioOutputDevice device) {
    // Возвращать выбор к «Системному» нужно и в движке, а не только в
    // состоянии: иначе mpv остался бы на исчезнувшем устройстве, и звук после
    // снятия с паузы мог не вернуться.
    if (state.audioDeviceName != 'auto') {
      unawaited(
        setAudioDevice('auto').catchError((Object error) {
          // Устройство могли отключить в момент закрытия окна: сбой здесь
          // не должен превращаться в необработанную ошибку.
          debugPrint('Не удалось вернуть системное устройство: $error');
        }),
      );
    }
    if (!state.playback.isPlaying) return;
    if (!ref.read(settingsControllerProvider).pauseOnDeviceMute) return;
    debugPrint('Устройство вывода пропало (${device.description}) — пауза');
    unawaited(pause());
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

  // ---------------------------------------------------------- таймер сна

  /// Включает таймер сна.
  ///
  /// [minutes] — через сколько минут остановить звук; [kSleepTimerAfterTrack]
  /// (`-1`) — остановить после текущего трека. Ноль и меньше выключают таймер:
  /// так вызывающий код может передать «ничего не выбрано» без отдельной
  /// ветки.
  void startSleepTimer(int minutes) {
    _cancelSleepTimer();
    if (minutes == kSleepTimerAfterTrack) {
      // Отсчёт не нужен: остановку сделает `_handleTrackEnded`.
      state = state.copyWith(sleepTimer: kSleepTimerAfterTrack);
      return;
    }
    if (minutes <= 0) {
      // «Ничего не выбрано» — просто выключаем: вызывающему коду не нужна
      // отдельная ветка на этот случай.
      clearSleepTimer();
      return;
    }

    _sleepDeadline = DateTime.now().add(Duration(minutes: minutes));
    state = state.copyWith(sleepTimer: minutes);
    // Подпись обновляем раз в минуту, а звук гасит отдельный одноразовый
    // таймер: периодический тик может прийти за миллисекунду до дедлайна, и
    // тогда пауза сдвинулась бы на целую минуту вперёд.
    _sleepTimer = Timer.periodic(
      const Duration(minutes: 1),
      (Timer _) => _tickSleepTimer(),
    );
    _sleepStop = Timer(Duration(minutes: minutes), _stopForSleep);
  }

  /// Снимает таймер сна — и отсчёт, и состояние.
  void clearSleepTimer() {
    _cancelSleepTimer();
    if (state.sleepTimerActive) state = state.copyWith(sleepTimer: 0);
  }

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepStop?.cancel();
    _sleepStop = null;
    _sleepDeadline = null;
  }

  /// Обновляет остаток минут в подписи.
  void _tickSleepTimer() {
    final DateTime? deadline = _sleepDeadline;
    if (deadline == null) return;

    final int minutes =
        (deadline.difference(DateTime.now()).inSeconds / 60).ceil();
    if (minutes != state.sleepTimer) {
      state = state.copyWith(sleepTimer: minutes);
    }
  }

  /// Гасит звук по таймеру сна.
  void _stopForSleep() {
    // Снимаем отсчёт до паузы: пока идёт асинхронная остановка, интерфейс не
    // должен показывать всё ещё активный таймер.
    clearSleepTimer();
    // Трек остаётся в очереди и на своей позиции — утром можно продолжить
    // с того же места.
    unawaited(_engine.pause());
    // Пауза — удобный момент зафиксировать позицию: дальше она не изменится.
    _persistSnapshot();
  }

  // ------------------------------------------------------- снимок очереди

  /// Записывает компактный снимок очереди в `shared_preferences`.
  ///
  /// Вызывается на изменениях очереди и по таймеру. Одинаковый снимок не
  /// пишем повторно: на паузе позиция не меняется, и лишние записи на диск
  /// были бы бесполезны.
  void _persistSnapshot() {
    final PlayerUiState current = state;
    if (current.queue.isEmpty) {
      // Пустую очередь в снимке хранить нечего — она ничего не восстановит.
      if (_lastSnapshot != null) _clearSnapshot();
      return;
    }

    final String encoded = QueueSnapshot(
      tracks: current.queue,
      index: current.index,
      position: current.playback.position,
    ).encode();
    if (encoded == _lastSnapshot) return;
    _lastSnapshot = encoded;

    final SharedPreferences prefs = ref.read(sharedPreferencesProvider);
    unawaited(prefs.setString(kQueueSnapshotKey, encoded));
  }

  /// Убирает снимок: очередь обнулена, восстанавливать нечего.
  void _clearSnapshot() {
    _lastSnapshot = null;
    final SharedPreferences prefs = ref.read(sharedPreferencesProvider);
    unawaited(prefs.remove(kQueueSnapshotKey));
  }

  /// Запускает восстановленный трек с сохранённой позиции.
  ///
  /// Обычный путь воспроизведения начинается с нуля, а здесь позицию нужно
  /// вернуть: трек был не загружен, движок про неё не знает. [position]
  /// позволяет начать и не с сохранённого места — так делает «назад».
  Future<void> _resumeRestored({Duration? position}) async {
    final Duration target = position ?? _restorePosition;
    await _loadCurrent();
    if (target > Duration.zero && state.current != null) {
      await seek(target);
    }
  }

  /// Включена ли предзагрузка следующего трека через посредника.
  ///
  /// Сейчас выключена: ссылку играет libmpv напрямую, посредник не нужен.
  /// Оставлена как выключатель, чтобы код предзагрузки не пришлось удалять:
  /// он понадобится, если мы вернёмся к gapless через локальный поток.
  static const bool _preloadEnabled = false;

  /// Локальный адрес текущего потока — чтобы освободить прошлый.
  Uri? _localStream;

  /// Локальный адрес предзагруженного следующего трека.
  Uri? _warmedStream;

  /// Освобождает оба опубликованных потока (текущий и прогретый).
  void _releaseStreams() {
    final Uri? current = _localStream;
    final Uri? warmed = _warmedStream;
    _localStream = null;
    _warmedStream = null;
    final StreamProxy proxy = ref.read(streamProxyProvider);
    if (current != null) proxy.release(current);
    if (warmed != null && warmed != current) proxy.release(warmed);
  }

  // -------------------------------------------------------------- private

  Future<void> _loadCurrent({bool autoplay = true}) async {
    // Любая настоящая загрузка снимает «восстановленный» режим: дальше
    // позицию ведёт движок, а не снимок.
    _restorePending = false;
    _restorePosition = Duration.zero;

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

      // Ссылку отдаём плееру напрямую. media_kit (libmpv) запрашивает поток
      // обычным GET, который медиасервер принимает (проверено
      // tool/plain_get_check.dart: обычный GET — 200, перемотка диапазоном —
      // 206). Прежний GStreamer слал открытый диапазон `Range: bytes=0-` и
      // получал 403 «Forbidden», из-за чего файл приходилось качать целиком.
      await _engine.load(resolved.url.toString(), autoplay: autoplay);
      state = state.copyWith(
        resolving: false,
        downloading: false,
        // Успешная загрузка снимает прежнюю отметку: трек мог быть помечен
        // недоступным при временном сбое, и держать её после звука нельзя.
        unavailableIds: <String>{...state.unavailableIds}..remove(track.id),
      );

      // Предзагрузку следующего трека через посредника не используем: она была
      // нужна только GStreamer. Код оставлен под флагом — пригодится, если
      // понадобится бесшовный переход (gapless).
      if (_preloadEnabled) unawaited(_warmNext());
      return;
    } on StreamResolutionException catch (error) {
      // Резолвер отличает «недоступно» (удалено, скрыто, регион) от сетевого
      // сбоя. Только первый случай даёт смысл искать замену — во втором
      // достаточно повторить попытку.
      final bool unavailable = error.message.contains('недоступно');
      state = state.copyWith(
        resolving: false,
        downloading: false,
        error: error.message,
        unavailableIds: unavailable
            ? <String>{...state.unavailableIds, track.id}
            : state.unavailableIds,
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
    } finally {
      // Движок обнулил позицию при остановке прошлого трека — снимок хранит
      // новый трек с началом, а не позицию предыдущего.
      _persistSnapshot();
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

  /// Заранее качает следующий трек через посредника.
  ///
  /// Вызывается после запуска текущего. Ссылку резолвим сразу: у резолвера
  /// кэш, поэтому при переключении `serve` вернёт уже прогретый поток —
  /// и следующий трек начнётся без паузы.
  Future<void> _warmNext() async {
    // При перемешивании следующий трек случаен — предугадать нельзя.
    if (state.shuffle) return;
    final int nextIndex = state.index + 1;
    if (nextIndex < 0 || nextIndex >= state.queue.length) return;

    final Track next = state.queue[nextIndex];
    final int fromIndex = state.index;
    try {
      final quality = ref.read(settingsControllerProvider).audioQuality;
      final ResolvedStream resolved = await ref
          .read(streamResolverProvider)
          .resolve(next.id, quality: quality);

      // Пока резолвили, очередь могла уйти вперёд — тогда прогрев не нужен.
      if (state.index != fromIndex) return;

      final Uri warmed = await ref.read(streamProxyProvider).warm(
            resolved.url,
            userAgent: resolved.userAgent,
            mimeType: resolved.mimeType,
          );
      if (state.index != fromIndex) return;

      final Uri? old = _warmedStream;
      _warmedStream = warmed;
      // Прошлый прогретый поток больше не актуален.
      if (old != null && old != warmed && old != _localStream) {
        ref.read(streamProxyProvider).release(old);
      }
    } on Object {
      // Предзагрузка не критична: трек просто начнётся как обычно.
    }
  }

  /// Передаёт сервису скробблинга, что сейчас играет и сколько уже сыграно.
  ///
  /// Сетевые ошибки сюда не доходят: сервис гасит их в лог сам, и
  /// воспроизведение от статистики не зависит.
  void _scrobblePlayback(PlaybackState playback, {required bool completed}) {
    final Track? track = state.current;
    if (track == null) {
      _scrobbler.reset();
      return;
    }
    _scrobbler.onPlayback(
      track,
      position: playback.position,
      duration: playback.duration,
      isPlaying: playback.isPlaying,
      completed: completed,
    );
  }

  Future<void> _handleTrackEnded() async {
    // «После трека» проверяем раньше повтора: таймер сна важнее — иначе на
    // повторе одного трека он не сработал бы никогда.
    if (state.sleepTimer == kSleepTimerAfterTrack) {
      // Снимаем до паузы: иначе таймер остался бы висеть и остановил бы ещё
      // и следующий трек.
      clearSleepTimer();
      await _engine.pause();
      return;
    }
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
