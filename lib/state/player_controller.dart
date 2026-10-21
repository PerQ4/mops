import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/audio/audio_engine.dart';
import '../core/audio/media_kit_engine.dart';
import '../core/playback/listening_tracker.dart';
import '../core/playback/playback_failure.dart';
import '../core/scrobbling/scrobbler.dart';
import '../data/local/listening_stats.dart';
import '../data/local/local_media.dart';
import '../data/local/queue_snapshot.dart';
import '../data/models/models.dart';
import '../data/sources/sponsorblock.dart';
import '../data/sources/stream_downloader.dart';
import '../data/sources/stream_resolver.dart';
// Хранилище подкастов, а не `podcastLocalProvider`: тот сам слушает плеер, и
// взаимная зависимость провайдеров была бы циклом. Само хранилище о плеере не
// знает и слушает только диск.
import '../features/podcast/podcast_models.dart';
import '../features/podcast/podcast_providers.dart';
import '../features/podcast/podcast_store.dart';
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

/// Насколько позиция должна отъехать назад, чтобы это была перемотка, а не
/// округление на тике. Меньший откат не считается возвратом «к началу».
const Duration _kSponsorRewindWindow = Duration(seconds: 1);

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

  /// Идёт получение звука, а не его скачивание: фоновая загрузка трека на
  /// диск не должна подменять кнопку паузы значком загрузки.
  bool get isLoading => resolving || playback.isLoading;

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

  /// --------------------------- статистика прослушиваний (задача 8.1)
  ///
  /// Счётчик один на статистику и на скробблинг: считается только реально
  /// проигранное время, перемотки в зачёт не идут, повтор начинается заново.
  /// Само правило живёт в `core/playback/listening_tracker.dart`.
  final ListeningTracker _listen = ListeningTracker();

  /// Текущее проигрывание уже попало в журнал статистики.
  bool _listenRecorded = false;

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

  /// Позиция на прошлом тике — по ней видно возврат назад.
  Duration _sponsorPosition = Duration.zero;

  /// Номер загрузки текущего трека.
  ///
  /// Растёт на каждой загрузке: работа, начатая для прошлого трека, по этому
  /// номеру понимает, что её результат уже не нужен.
  int _loadGeneration = 0;

  /// Отложенная запись громкости: ползунок двигают чаще, чем нужно писать диск.
  double? _pendingVolume;
  Timer? _volumeSaveTimer;

  /// Известные эпизоды подкастов (id треков) и когда список читали в прошлый раз.
  final Set<String> _podcastEpisodes = <String>{};
  DateTime? _podcastPolledAt;

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

      // Прослушанное считаем здесь и один раз: журнал статистики и скробблинг
      // получают одно и то же время из общего счётчика.
      final bool acceptedEnd = playback.status == PlaybackStatus.completed &&
          !_seeking &&
          !_handlingEnd &&
          !playback.hasError;
      final ListeningTick tick = _advanceListening(
        playback,
        completed: acceptedEnd,
      );

      _scrobblePlayback(playback, tick);
      if (tick == ListeningTick.started) _listenRecorded = false;
      _countListening(playback);

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

    // Скачивание текущего трека показывается в островке теми же полями:
    // `downloadProgress` — настоящий прогресс по байтам из контроллера
    // загрузок. Слушаем его здесь, а не в интерфейсе, чтобы подпись жила в
    // одном состоянии плеера независимо от открытого экрана.
    ref.listen<DownloadsState>(downloadsControllerProvider,
        (DownloadsState? _, DownloadsState downloads) {
      final Track? track = state.current;
      final DownloadTask? task =
          track == null ? null : downloads.taskFor(track.id);
      if (task == null || task.failed) {
        if (state.downloading || state.downloadProgress != 0) {
          state = state.copyWith(downloading: false, downloadProgress: 0);
        }
        return;
      }
      state = state.copyWith(
        downloading: true,
        downloadProgress: task.progress,
      );
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

    // Выключили предзагрузку — обрываем и уже начатую проверку ссылки:
    // настройка должна действовать сразу, а не со следующего трека.
    ref.listen<bool>(
      settingsControllerProvider.select((s) => s.preloadNextTrack),
      (bool? _, bool enabled) {
        if (enabled) return;
        _preloadGeneration++;
        _preloadClient?.close(force: true);
        _preloadClient = null;
      },
    );

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
      // Предзагрузка держит собственный HTTP-клиент: закрываем его, чтобы
      // после удаления контроллера не осталось открытых соединений.
      _preloadGeneration++;
      _preloadClient?.close(force: true);
      _preloadClient = null;
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

  /// Добавляет несколько треков одним изменением состояния.
  ///
  /// Отдельный метод, а не цикл по [enqueue]: каждый вызов сериализует всю
  /// очередь, и на альбоме из 500 треков это 500 сериализаций растущего
  /// списка. Здесь сериализация одна.
  void enqueueAll(Iterable<Track> tracks) {
    final List<Track> added = tracks.toList(growable: false);
    if (added.isEmpty) return;
    state = state.copyWith(queue: <Track>[...state.queue, ...added]);
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

    final int generation = await _loadCurrent(autoplay: playback.isPlaying);
    // Пока резолвили поток, пользователь мог переключить трек — тогда
    // возвращать позицию уже некуда.
    if (state.current?.id != replacement.id) return;

    if (playback.position > Duration.zero) {
      await seek(playback.position, generation: generation);
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
      await pause();
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
    _flushVolume();
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

  /// Перематывает текущий трек.
  ///
  /// [generation] — номер загрузки, для которой перемотка задумана. Пока шла
  /// подготовка (резолв, загрузка источника), трек мог смениться, и перемотка
  /// улетела бы в новый — поэтому устаревшая перемотка не выполняется.
  Future<void> seek(Duration position, {int? generation}) async {
    final Duration target = position < Duration.zero ? Duration.zero : position;

    // Восстановленный трек ещё не загружен в движок: перематывать нечего.
    // Позицию запоминаем — её применит `_resumeRestored` сразу после старта.
    if (_restorePending) {
      _restorePosition = target;
      state = state.copyWith(
        playback: state.playback.copyWith(position: target),
      );
      return;
    }

    final int token = generation ?? _loadGeneration;
    if (token != _loadGeneration) return;

    // Перемотка поднимает флаг до самого её окончания: ложный EOS,
    // пришедший в это окно, не должен переключать очередь.
    _seeking = true;
    try {
      await _engine.seek(target);
    } on Object catch (error) {
      // Сбой перемотки не останавливает воспроизведение.
      debugPrint('Перемотка не удалась: $error');
    } finally {
      // Флаг снимаем только для своего поколения: у нового трека может идти
      // своя перемотка, и её флаг трогать нельзя.
      if (token == _loadGeneration) _seeking = false;
    }
  }

  /// Перемотка по доле длительности — тем же путём, что и обычная: иначе она
  /// обходила бы и восстановление очереди, и защиту от смены трека.
  Future<void> seekFraction(double fraction) {
    final Duration duration = state.playback.duration;
    if (duration <= Duration.zero) return Future<void>.value();
    return seek(duration * fraction.clamp(0.0, 1.0));
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

    // Набор пропущенного относится к проигрыванию от начала, а не к треку:
    // после повтора или перемотки назад вставки снова впереди, и пропускать
    // их надо заново — иначе второй раз они прозвучат.
    final bool rewound =
        playback.position + _kSponsorRewindWindow < _sponsorPosition;
    _sponsorPosition = playback.position;
    if (rewound) _sponsorSkipped.clear();

    // У локального файла нет видео на YouTube, а значит и разметки
    // SponsorBlock: запрос с путём в качестве id был бы бессмысленным.
    if (isLocalTrackId(track.id)) {
      _clearSponsorState();
      return;
    }

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
      final int generation = _loadGeneration;
      unawaited(
        seek(segment.end, generation: generation).whenComplete(() {
          // Трек мог смениться, пока шла перемотка: чужой флаг не снимаем.
          if (generation == _loadGeneration) _sponsorSeeking = false;
        }),
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
    _sponsorPosition = Duration.zero;
    if (_sponsorTrackId == null && _sponsorSegments.isEmpty) return;
    _sponsorTrackId = null;
    _sponsorCategories = const <SponsorBlockCategory>{};
    _sponsorSegments = const <SponsorSegment>[];
    _sponsorSkipped.clear();
  }

  /// Меняет громкость и откладывает запись в настройки.
  ///
  /// Ползунок двигают десятки раз в секунду, а запись настроек — это перезапись
  /// всего JSON. Пишем последнее значение не чаще раза в секунду; перед паузой
  /// и сменой трека — сразу ([_flushVolume]).
  Future<void> setVolume(double volume) async {
    await _engine.setVolume(volume);
    _pendingVolume = volume;
    _volumeSaveTimer ??= Timer(const Duration(seconds: 1), _flushVolume);
  }

  /// Записывает отложенную громкость немедленно.
  void _flushVolume() {
    _volumeSaveTimer?.cancel();
    _volumeSaveTimer = null;
    final double? volume = _pendingVolume;
    _pendingVolume = null;
    if (volume == null) return;
    unawaited(
      ref.read(settingsControllerProvider.notifier).setLastVolume(volume),
    );
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
    _flushVolume();
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
    // Заодно фиксируем отложенную громкость: снимок и так пишется на смене
    // трека, паузе и раз в пять секунд.
    _flushVolume();

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
    final int generation = await _loadCurrent();
    if (target > Duration.zero && state.current != null) {
      await seek(target, generation: generation);
    }
  }

  /// Номер актуальной предзагрузки.
  ///
  /// Любая новая загрузка трека, выключение настройки или удаление
  /// контроллера увеличивает счётчик: всё, что резолвилось для прошлого
  /// трека, после проверки номера молча прекращается. Так предзагрузка не
  /// может «догнать» уже играющий трек и потратить трафик на неактуальный.
  int _preloadGeneration = 0;

  /// Отдельный HTTP-клиент для проверки ссылки.
  ///
  /// Не общий клиент резолвера: предзагрузка не должна влиять на его пул
  /// соединений, а закрывается она вместе с контроллером.
  HttpClient? _preloadClient;

  // -------------------------------------------------------------- private

  /// Загружает текущий трек.
  ///
  /// Возвращает номер поколения этой загрузки: по нему перемотка, начатая
  /// после `await`, понимает, что трек за это время не сменился.
  Future<int> _loadCurrent({bool autoplay = true}) async {
    // Любая настоящая загрузка снимает «восстановленный» режим: дальше
    // позицию ведёт движок, а не снимок.
    _restorePending = false;
    _restorePosition = Duration.zero;

    // Перемотки и прочие действия, начатые для прошлого трека, по этому
    // номеру поймут, что их результат уже не к месту.
    final int generation = ++_loadGeneration;
    _seeking = false;
    _sponsorSeeking = false;
    _sponsorPosition = Duration.zero;

    // Громкость, не дописанную до настроек, фиксируем на границе трека.
    _flushVolume();

    final Track? track = state.current;
    if (track == null) return generation;

    // Всё, что предзагружалось для прошлого трека, больше не нужно.
    _preloadGeneration++;

    // Трек мог начать скачиваться раньше: подпись прогресса должна быть
    // сразу, не дожидаясь следующей порции байт.
    final DownloadTask? download =
        ref.read(downloadsControllerProvider).taskFor(track.id);
    state = state.copyWith(
      resolving: true,
      clearError: true,
      downloading: download != null && !download.failed,
      downloadProgress: download?.progress ?? 0,
    );

    // Новый трек: прошлый останавливаем сразу, не дожидаясь загрузки.
    await _engine.stop();

    try {
      final String? localPath = localPathFromId(track.id);
      final ResolvedStream resolved;
      if (localPath != null) {
        // Локальный файл не резолвится через сеть: путь из идентификатора и
        // есть источник. Проверяем только, что файл ещё на месте, — его могли
        // удалить или переименовать после сканирования.
        if (!await File(localPath).exists()) {
          throw PlaybackFailureException(
            'Файл не найден: $localPath',
            PlaybackFailure.unavailable,
          );
        }
        resolved = ResolvedStream(
          url: Uri.file(localPath),
          // Срок жизни у файла не истекает; поле обязательно в модели.
          expiresAt: DateTime.now().add(const Duration(days: 3650)),
          localPath: localPath,
          container: _localContainer(localPath),
        );
      } else {
        final quality = ref.read(settingsControllerProvider).audioQuality;
        resolved = await ref
            .read(streamResolverProvider)
            .resolve(track.id, quality: quality);
      }

      // Пока получали ссылку, пользователь мог переключить трек — тогда
      // загрузку надо отменить, иначе заиграет «не тот».
      if (state.current?.id != track.id) return generation;

      state = state.copyWith(
        streamNote: localPath != null
            ? 'ФАЙЛ'
            : (resolved.isLocal ? 'ОФЛАЙН' : _noteFor(resolved)),
      );

      // Ссылку отдаём плееру напрямую. media_kit (libmpv) запрашивает поток
      // обычным GET, который медиасервер принимает (проверено
      // tool/plain_get_check.dart: обычный GET — 200, перемотка диапазоном —
      // 206). Прежний GStreamer слал открытый диапазон `Range: bytes=0-` и
      // получал 403 «Forbidden», из-за чего файл приходилось качать целиком.
      //
      // Скачанный трек — путь к файлу, и движок должен открыть его как файл,
      // а не как сетевой адрес: иначе `file:`-адрес ушёл бы в HTTP-клиент.
      await _engine.load(
        resolved.localPath ?? resolved.url.toString(),
        autoplay: autoplay,
        isLocal: resolved.isLocal,
      );
      state = state.copyWith(
        resolving: false,
        // Успешная загрузка снимает прежнюю отметку: трек мог быть помечен
        // недоступным при временном сбое, и держать её после звука нельзя.
        unavailableIds: <String>{...state.unavailableIds}..remove(track.id),
      );

      // Следующий трек готовим только после того, как текущий зазвучал:
      // иначе предзагрузка конкурировала бы с ним за канал на старте.
      if (autoplay) unawaited(_preloadNext());
      return generation;
    } on PlaybackFailureException catch (error) {
      // Причина известна точно — искать в тексте ничего не нужно.
      state = state.copyWith(
        resolving: false,
        downloading: false,
        error: error.message,
        unavailableIds: error.reason == PlaybackFailure.unavailable
            ? <String>{...state.unavailableIds, track.id}
            : state.unavailableIds,
      );
    } on StreamResolutionException catch (error) {
      // Резолвер отличает «недоступно» (удалено, скрыто, регион) от сетевого
      // сбоя. Только первый случай даёт смысл искать замену — во втором
      // достаточно повторить попытку.
      final bool unavailable =
          failureOfResolution(error) == PlaybackFailure.unavailable;
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
    } on Object catch (error) {
      // `on Object`, а не `on Exception`: ошибка (например, `ArgumentError`)
      // тоже не должна оставлять интерфейс со спиннером навсегда.
      state = state.copyWith(
        resolving: false,
        downloading: false,
        error: 'Ошибка воспроизведения: $error',
      );
    } finally {
      // Любой выход из загрузки гасит признаки ожидания: даже если вылетело
      // то, что мы не предусмотрели, «крутилка» не должна остаться навсегда.
      if (state.current?.id == track.id &&
          (state.resolving || state.downloading)) {
        state = state.copyWith(resolving: false, downloading: false);
      }
      // Движок обнулил позицию при остановке прошлого трека — снимок хранит
      // новый трек с началом, а не позицию предыдущего.
      _persistSnapshot();
    }
    return generation;
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

  /// Расширение локального файла заглавными — для подписи контейнера.
  String? _localContainer(String path) {
    final int dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return null;
    final String extension = path.substring(dot + 1).toUpperCase();
    return extension.isEmpty ? null : extension;
  }

  /// Заранее резолвит следующий трек и проверяет ссылку одним байтом.
  ///
  /// Полноценно качать следующий трек нельзя: libmpv играет ссылку напрямую,
  /// а прогретый через посредника поток он всё равно не использует — трафик
  /// ушёл бы впустую. Что действительно ускоряет переход: резолвер получает
  /// ссылку заранее (при переключении она берётся из его кэша), а короткий
  /// запрос `Range: bytes=0-0` открывает DNS/TLS/соединение к медиасерверу.
  ///
  /// Предзагрузка не запускается при перемешивании (следующий трек случаен),
  /// на повторе одного трека, для локальных файлов и для уже скачанных
  /// треков: в этих случаях либо нечего предугадывать, либо качать нечего.
  Future<void> _preloadNext() async {
    final int generation = ++_preloadGeneration;
    if (!ref.read(settingsControllerProvider).preloadNextTrack) return;

    final PlayerUiState current = state;
    if (current.shuffle || current.repeat == PlayerRepeatMode.one) return;
    final Track? playing = current.current;
    // Идёт скачивание текущего трека — сеть занята им, предзагрузка подождёт
    // до следующего запуска (он же и начнёт её заново).
    if (playing == null || current.downloading) return;
    if (isLocalTrackId(playing.id)) return;

    final Track? next = _nextForPreload(current);
    if (next == null || isLocalTrackId(next.id)) return;

    final int fromIndex = current.index;
    final String playingId = playing.id;
    try {
      final quality = ref.read(settingsControllerProvider).audioQuality;
      final ResolvedStream resolved = await ref
          .read(streamResolverProvider)
          .resolve(next.id, quality: quality);

      if (!_preloadStillRelevant(generation, fromIndex, playingId)) return;
      // Скачанный трек (2.1) уже лежит файлом: сеть ему не нужна.
      if (resolved.isLocal) return;

      // Пауза после старта: одно короткое соединение не должно отбирать
      // полосу у трека, который ещё наполняет буфер.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!_preloadStillRelevant(generation, fromIndex, playingId)) return;
      if (!_bufferIsHealthy()) return;

      await _probeStream(resolved);
    } on Object catch (error) {
      // Предзагрузка не критична: трек просто начнётся как обычно.
      debugPrint('[Предзагрузка] ${next.id}: $error');
    }
  }

  /// Какой трек действительно заиграет следующим, по правилам [_advance].
  Track? _nextForPreload(PlayerUiState current) {
    if (current.index + 1 < current.queue.length) {
      return current.queue[current.index + 1];
    }
    if (current.repeat == PlayerRepeatMode.all && current.queue.isNotEmpty) {
      return current.queue.first;
    }
    // Конец очереди без повтора: следующий трек придёт из «радио», его id
    // ещё неизвестен.
    return null;
  }

  /// Предзагрузка всё ещё относится к играющему треку.
  bool _preloadStillRelevant(int generation, int index, String playingId) {
    return generation == _preloadGeneration &&
        state.index == index &&
        state.current?.id == playingId &&
        !state.shuffle &&
        ref.read(settingsControllerProvider).preloadNextTrack;
  }

  /// У текущего трека достаточно запаса, чтобы отдать сети лишний запрос.
  ///
  /// Если движок сообщает буфер и впереди меньше четырёх секунд, сеть и так
  /// еле успевает — предзагрузка откладывается. Нулевой буфер считаем
  /// неизвестным: не все движки его отдают, и запрещать предзагрузку из-за
  /// этого было бы неправильно.
  bool _bufferIsHealthy() {
    final Duration buffered = state.playback.buffered;
    if (buffered <= Duration.zero) return true;
    return buffered - state.playback.position >= const Duration(seconds: 4);
  }

  /// Открывает соединение и читает ровно первый кусок ответа.
  ///
  /// Ответ обрывается сразу после первого пакета: если сервер проигнорирует
  /// `Range` и начнёт отдавать файл целиком, весь трек всё равно не скачается.
  Future<void> _probeStream(ResolvedStream resolved) async {
    final HttpClient client = _preloadClient ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    final HttpClientRequest request = await client
        .getUrl(resolved.url)
        .timeout(const Duration(seconds: 8));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
    final String? userAgent = resolved.userAgent;
    if (userAgent != null && userAgent.isNotEmpty) {
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    }

    final HttpClientResponse response =
        await request.close().timeout(const Duration(seconds: 8));
    await _discardResponse(response);
  }

  /// Забирает тело ответа, не вытягивая его целиком.
  ///
  /// Маленькое тело (обычный ответ на `bytes=0-0` — один байт) дочитывается
  /// до конца: соединение остаётся в пуле клиента, и следующий запрос по этой
  /// же ссылке уже не тратит время на TCP/TLS. Большое или неизвестное тело
  /// обрывается после первого куска.
  Future<void> _discardResponse(HttpClientResponse response) async {
    final int length = response.contentLength;
    if (length >= 0 && length <= 64 * 1024) {
      await response.drain<void>().timeout(const Duration(seconds: 5));
      return;
    }

    final Completer<void> firstChunk = Completer<void>();
    late final StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      (List<int> _) {
        if (!firstChunk.isCompleted) firstChunk.complete();
      },
      onError: (Object error) {
        if (!firstChunk.isCompleted) firstChunk.completeError(error);
      },
      onDone: () {
        if (!firstChunk.isCompleted) firstChunk.complete();
      },
      cancelOnError: true,
    );
    try {
      await firstChunk.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    } finally {
      await subscription.cancel();
    }
  }

  /// Продвигает общий счётчик прослушанного и сообщает, что на тике
  /// произошло: по этому событию скрёббер и статистика начинают заново.
  ListeningTick _advanceListening(
    PlaybackState playback, {
    required bool completed,
  }) {
    final Track? track = state.current;
    if (track == null) {
      _listen.reset();
      return ListeningTick.none;
    }
    return _listen.advance(
      trackId: track.id,
      position: playback.position,
      total: _totalFor(track, playback),
      isPlaying: playback.isPlaying,
      completed: completed,
    );
  }

  /// Длительность: движок знает точную, модель — запасную.
  Duration _totalFor(Track track, PlaybackState playback) =>
      playback.duration > Duration.zero ? playback.duration : track.duration;

  /// Эпизод ли это подкаста.
  ///
  /// Список известных эпизодов ведёт модуль подкастов: другого признака у
  /// `Track` нет, а играть эпизод и песню можно одним и тем же путём. Берём его
  /// из хранилища подкастов: `podcastLocalProvider` сам слушает плеер, и
  /// взаимная зависимость провайдеров была бы циклом.
  bool _isPodcastEpisode(String trackId) {
    if (_podcastEpisodes.contains(trackId)) return true;
    _pollPodcastEpisodes();
    return false;
  }

  /// Перечитывает список эпизодов не чаще раза в пять секунд.
  ///
  /// Свежий эпизод попадает в хранилище только после пары секунд звука, поэтому
  /// одного чтения на старте трека мало: до порога скробблинга (минуты) список
  /// успевает обновиться, и прослушивание подкаста не уйдёт в профиль.
  void _pollPodcastEpisodes() {
    final DateTime now = DateTime.now();
    final DateTime? last = _podcastPolledAt;
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _podcastPolledAt = now;
    unawaited(_loadPodcastEpisodes());
  }

  Future<void> _loadPodcastEpisodes() async {
    try {
      final PodcastStoredData data =
          await ref.read(podcastStoreProvider).read();
      if (!ref.mounted) return;
      for (final PodcastEntry entry in <PodcastEntry>[
        ...data.progress,
        ...data.recent,
      ]) {
        _podcastEpisodes.add(entry.episodeId);
      }
    } on Object catch (error) {
      // Без списка эпизодов подкаст может уйти в профиль — но падать из-за
      // этого воспроизведение не должно.
      debugPrint('[Скробблинг] список подкастов не прочитан: $error');
    }
  }

  /// Передаёт сервису скробблинга, что сейчас играет и сколько уже сыграно.
  ///
  /// Сетевые ошибки сюда не доходят: сервис гасит их в лог сам, и
  /// воспроизведение от статистики не зависит.
  void _scrobblePlayback(PlaybackState playback, ListeningTick tick) {
    final Track? track = state.current;
    if (track == null) {
      _scrobbler.reset();
      return;
    }
    _scrobbler.onPlayback(
      track,
      total: _totalFor(track, playback),
      listened: _listen.listened,
      tick: tick,
      isPlaying: playback.isPlaying,
      isPodcast: _isPodcastEpisode(track.id),
    );
  }

  /// Зачитывает трек в журнал, когда набралось достаточно.
  ///
  /// Порог — четыре минуты или половина трека, что меньше: короткий трек
  /// засчитывается после половины, длинный — после четырёх минут (правило в
  /// `core/playback/listening_tracker.dart`, общее со скробблером). В журнал
  /// попадает только реально проигранное время.
  void _countListening(PlaybackState playback) {
    final Track? track = state.current;
    if (track == null) {
      _listenRecorded = false;
      return;
    }
    if (_listenRecorded) return;

    final Duration total = _totalFor(track, playback);
    if (!shouldCreditListen(total: total, listened: _listen.listened)) return;

    // Запись могли выключить уже после начала трека — тогда журнал не трогаем.
    final settings = ref.read(settingsControllerProvider);
    if (!settings.listeningStatsEnabled) return;

    _listenRecorded = true;
    final Duration listened = _listen.listened;
    final int millis = total > Duration.zero && listened > total
        ? total.inMilliseconds
        : listened.inMilliseconds;
    unawaited(
      ref.read(listeningStatsProvider.notifier).add(
            ListenEvent(
              trackId: track.id,
              title: track.title,
              artists: <String>[
                for (final ArtistRef artist in track.artists) artist.name,
              ],
              album: track.album?.name,
              at: DateTime.now(),
              seconds: max(1, (millis / 1000).round()),
            ),
          ),
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
    final PlayerUiState snapshot = state;
    final Track? seed =
        snapshot.current ?? (snapshot.queue.isEmpty ? null : snapshot.queue.last);
    if (seed == null) return;
    // Локального трека нет на YouTube: «радио по треку» для него невозможно,
    // а запрос с путём вместо videoId только тратил бы сеть.
    if (isLocalTrackId(seed.id)) {
      state = state.copyWith(
        playback: state.playback.copyWith(status: PlaybackStatus.paused),
      );
      return;
    }

    final int index = snapshot.index;
    try {
      final List<Track> radio =
          await ref.read(catalogSourceProvider).autoplayQueue(seed.id);
      if (!ref.mounted) return;

      // Пока шёл запрос, трек или очередь могли смениться. Радио относилось к
      // прежнему месту, и вставлять его в новую очередь нельзя: треки встали
      // бы не туда, а переход — не на тот трек.
      if (state.current?.id != seed.id || state.index != index) return;
      // Очередь успели дополнить вручную — следующий трек уже есть, и радио
      // больше не нужно.
      if (state.index + 1 < state.queue.length) return;

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

      // Уходим на первый добавленный трек: он стоит сразу за сыгравшим.
      final int target = state.queue.length;
      final List<Track> queue = <Track>[...state.queue, ...fresh];
      _pushHistory(state.index);
      state = state.copyWith(queue: queue, index: target);
      await _loadCurrent();
    } on Object catch (error) {
      if (!ref.mounted) return;
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
