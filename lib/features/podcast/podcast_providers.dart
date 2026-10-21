import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/audio_engine.dart';
import '../../state/auth_controller.dart';
import '../../state/catalog_providers.dart';
import '../../state/player_controller.dart';
import 'podcast_models.dart';
import 'podcast_store.dart';

/// Обзор подкастов YouTube Music (`FEmusic_podcasts`).
final FutureProvider<List<PodcastSection>> podcastSectionsProvider =
    FutureProvider<List<PodcastSection>>((Ref ref) async {
  return ref.watch(catalogSourceProvider).podcastSections();
});

/// Страница шоу. Ключ — [PodcastShow.key] (звуковой id плейлиста или browse-id).
final podcastShowProvider =
    FutureProvider.family<PodcastShow, String>((Ref ref, String showId) async {
  return ref.watch(catalogSourceProvider).podcastShow(showId);
});

/// Шоу, на которые оформлена подписка.
///
/// Раздел живёт в каталоге (`FEmusic_library_non_music_audio_list`), а не в
/// `LibrarySource`: тот файл по условиям задачи не меняется. Без входа список
/// пуст — как у остальных разделов библиотеки.
final FutureProvider<List<PodcastShow>> podcastSubscriptionsProvider =
    FutureProvider<List<PodcastShow>>((Ref ref) async {
  final bool signedIn = ref.watch(
    authControllerProvider.select((AuthState s) => s.isSignedIn),
  );
  if (!signedIn) return const <PodcastShow>[];
  return ref.watch(catalogSourceProvider).libraryPodcasts();
});

/// Хранилище истории — одно на приложение: держит файл и очередь записи.
final Provider<PodcastStore> podcastStoreProvider =
    Provider<PodcastStore>((Ref ref) => PodcastStore());

/// Локальное состояние подкастов: незаконченные эпизоды и недавние.
@immutable
class PodcastLocalState {
  const PodcastLocalState({
    this.progress = const <String, PodcastEntry>{},
    this.recent = const <PodcastEntry>[],
  });

  /// Незаконченные эпизоды: id эпизода → запись с позицией.
  final Map<String, PodcastEntry> progress;

  /// Недавно игравшие эпизоды, свежие первыми.
  final List<PodcastEntry> recent;

  /// Самый свежий незаконченный эпизод шоу — для кнопки «Продолжить».
  PodcastEntry? progressForShow(String showId) {
    PodcastEntry? best;
    for (final PodcastEntry entry in progress.values) {
      if (entry.showId != showId) continue;
      if (best == null || entry.at > best.at) best = entry;
    }
    return best;
  }

  bool get isEmpty => progress.isEmpty && recent.isEmpty;
}

/// Ведёт локальный прогресс подкастов по состоянию плеера.
///
/// Провайдер намеренно без `autoDispose`: экран шоу можно закрыть, а эпизод
/// продолжит играть, и прогресс должен записываться дальше. Подписка на
/// плеер живёт всё время приложения — но создаётся при первом открытии
/// подкастов, поэтому обычные треки её не касаются.
class PodcastLocal extends Notifier<PodcastLocalState> {
  /// Снимки шоу и эпизодов, полученные из интерфейса. По ним плеер понимает,
  /// что текущий трек — эпизод подкаста, и что именно записывать в историю.
  final Map<String, PodcastEntry> _known = <String, PodcastEntry>{};

  /// Когда последний раз писали прогресс: чаще раза в 5 секунд незачем.
  DateTime? _lastWriteAt;

  /// Последний статус воспроизведения — пауза и завершение пишутся сразу,
  /// не дожидаясь окна троттлинга.
  PlaybackStatus? _lastStatus;

  @override
  PodcastLocalState build() {
    // `ref.listen`, а не подписка на поток движка: позиция приходит вместе с
    // состоянием плеера, и здесь же видно смену трека.
    ref.listen<PlayerUiState>(playerControllerProvider,
        (PlayerUiState? previous, PlayerUiState next) {
      _onPlayer(previous, next);
    });

    unawaited(_load());
    return const PodcastLocalState();
  }

  Future<void> _load() async {
    PodcastStoredData data;
    try {
      data = await ref.read(podcastStoreProvider).read();
    } on Object catch (error) {
      debugPrint('[Podcast] история недоступна: $error');
      return;
    }
    if (!ref.mounted) return;

    // Записи этой сессии важнее прочитанных с диска: они появились позже.
    final Map<String, PodcastEntry> progress = <String, PodcastEntry>{
      for (final PodcastEntry entry in data.progress) entry.episodeId: entry,
      ...state.progress,
    };
    final Map<String, PodcastEntry> recent = <String, PodcastEntry>{
      for (final PodcastEntry entry in data.recent) entry.episodeId: entry,
      for (final PodcastEntry entry in state.recent) entry.episodeId: entry,
    };
    final List<PodcastEntry> ordered = recent.values.toList()
      ..sort((PodcastEntry a, PodcastEntry b) => b.at.compareTo(a.at));

    state = PodcastLocalState(
      progress: progress,
      recent: ordered.take(PodcastStore.maxRecent).toList(growable: false),
    );
  }

  /// Регистрирует эпизод перед запуском: без снимка шоу плеер не отличит
  /// эпизод от обычного трека.
  void noteEpisode(PodcastShow show, PodcastEpisode episode) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    _known[episode.id] = PodcastEntry(
      showId: show.key,
      showTitle: show.title,
      showPlaylistId: show.playlistId,
      showArtwork: show.artwork,
      episode: episode,
      duration: episode.track.duration,
      at: now,
    );
  }

  /// Докуда дослушан эпизод. `Duration.zero` — прогресса нет.
  Duration resumePosition(String episodeId) =>
      state.progress[episodeId]?.position ?? Duration.zero;

  PodcastEntry? progressForShow(String showId) =>
      state.progressForShow(showId);

  /// Забывает прогресс эпизода (история остаётся).
  void forget(String episodeId) {
    if (!state.progress.containsKey(episodeId)) return;
    final Map<String, PodcastEntry> progress =
        Map<String, PodcastEntry>.of(state.progress)..remove(episodeId);
    state = PodcastLocalState(progress: progress, recent: state.recent);
    unawaited(_save());
  }

  /// Полная очистка истории и прогресса.
  void clearHistory() {
    state = const PodcastLocalState();
    unawaited(ref.read(podcastStoreProvider).clear());
  }

  void _onPlayer(PlayerUiState? previous, PlayerUiState next) {
    final String? previousId = previous?.current?.id;
    final String? id = next.current?.id;

    // Трек сменился — дописываем позицию ушедшего эпизода, иначе последние
    // секунды перед переключением терялись бы.
    if (previousId != null && previousId != id) {
      _writeProgress(previousId, previous!.playback, force: true);
    }

    if (id == null || id.isEmpty) return;
    final PodcastEntry? entry = _entryFor(id);
    if (entry == null) return;

    final PlaybackStatus status = next.playback.status;
    final bool statusChanged = status != _lastStatus;
    _lastStatus = status;

    _writeProgress(
      id,
      next.playback,
      force: statusChanged &&
          (status == PlaybackStatus.paused ||
              status == PlaybackStatus.completed),
    );
  }

  /// Текущая запись эпизода: свежие метаданные из снимка плюс сохранённая
  /// позиция. Если снимка в этой сессии нет, берём запись из истории — так
  /// прогресс продолжается и у эпизода, восстановленного из очереди.
  PodcastEntry? _entryFor(String episodeId) {
    PodcastEntry? saved = state.progress[episodeId];
    if (saved == null) {
      for (final PodcastEntry entry in state.recent) {
        if (entry.episodeId == episodeId) {
          saved = entry;
          break;
        }
      }
    }

    final PodcastEntry? known = _known[episodeId];
    if (known == null) return saved;
    if (saved == null) return known;

    return PodcastEntry(
      showId: known.showId,
      showTitle: known.showTitle,
      showPlaylistId: known.showPlaylistId,
      showArtwork: known.showArtwork,
      episode: known.episode,
      position: saved.position,
      duration: saved.duration,
      at: saved.at,
    );
  }

  /// Записывает позицию, если прошло достаточно времени или это пауза/конец.
  ///
  /// Позиции в первые секунды не пишем: при возобновлении с середины плеер
  /// успевает прислать нулевую позицию до перемотки, и сохранённый прогресс
  /// обнулился бы.
  void _writeProgress(
    String episodeId,
    PlaybackState playback, {
    required bool force,
  }) {
    final PodcastEntry? entry = _entryFor(episodeId);
    if (entry == null) return;

    final Duration duration = playback.duration > Duration.zero
        ? playback.duration
        : entry.duration;
    final bool completed = playback.status == PlaybackStatus.completed ||
        (duration > Duration.zero &&
            duration - playback.position <= const Duration(seconds: 15));
    final Duration position = completed ? duration : playback.position;

    if (position <= const Duration(seconds: 2) && !completed) return;

    final DateTime now = DateTime.now();
    final DateTime? last = _lastWriteAt;
    if (!force &&
        last != null &&
        now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _lastWriteAt = now;
    final int at = now.millisecondsSinceEpoch;

    final Map<String, PodcastEntry> progress =
        Map<String, PodcastEntry>.of(state.progress);
    if (completed) {
      progress.remove(episodeId);
    } else {
      progress[episodeId] = entry.copyWith(
        position: position,
        duration: duration,
        at: at,
      );
    }

    final List<PodcastEntry> recent = state.recent
        .where((PodcastEntry item) => item.episodeId != episodeId)
        .toList();
    recent.insert(
      0,
      entry.copyWith(position: position, duration: duration, at: at),
    );
    if (recent.length > PodcastStore.maxRecent) {
      recent.removeRange(PodcastStore.maxRecent, recent.length);
    }

    state = PodcastLocalState(progress: progress, recent: recent);
    unawaited(_save());
  }

  Future<void> _save() {
    return ref.read(podcastStoreProvider).writeAll(
          PodcastStoredData(
            progress: state.progress.values.toList(growable: false),
            recent: state.recent,
          ),
        );
  }
}

final NotifierProvider<PodcastLocal, PodcastLocalState> podcastLocalProvider =
    NotifierProvider<PodcastLocal, PodcastLocalState>(PodcastLocal.new);

/// Подписки на шоу: одно состояние на всё приложение.
///
/// Оптимистичные правки поверх серверного списка — как у сохранённых
/// плейлистов (`SavedIdsController`): кнопка реагирует сразу, а после ответа
/// сервера список перечитывается.
class PodcastSubscriptionsController extends Notifier<Set<String>> {
  /// Локальные правки, ещё не подтверждённые сервером: `ключ шоу → подписка`.
  final Map<String, bool> _overrides = <String, bool>{};

  /// Последний серверный список — чтобы повторная загрузка не гасила уже
  /// показанную подписку.
  Set<String> _lastServer = <String>{};

  @override
  Set<String> build() {
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );
    if (!signedIn) {
      _overrides.clear();
      _lastServer = <String>{};
      return <String>{};
    }

    final List<PodcastShow>? shows =
        ref.watch(podcastSubscriptionsProvider).value;
    if (shows != null) {
      _lastServer = shows.map((PodcastShow show) => show.key).toSet();
    }

    _overrides.removeWhere(
      (String key, bool subscribed) =>
          _lastServer.contains(key) == subscribed,
    );

    final Set<String> keys = <String>{..._lastServer};
    _overrides.forEach((String key, bool subscribed) {
      if (subscribed) {
        keys.add(key);
      } else {
        keys.remove(key);
      }
    });
    return keys;
  }

  /// Подписывает или отписывает. [PodcastShow.playlistId] обязателен: сервер
  /// принимает только звуковой id, browse-id страницы он не понимает.
  Future<void> toggle(PodcastShow show) async {
    final String? playlistId = show.playlistId;
    if (playlistId == null || playlistId.isEmpty) {
      throw StateError('YouTube не вернул id плейлиста этого шоу');
    }

    final String key = show.key;
    final Set<String> before = state;
    final bool subscribed = !before.contains(key);

    _overrides[key] = subscribed;
    state = subscribed
        ? <String>{...before, key}
        : <String>{...before}..remove(key);

    try {
      await ref
          .read(librarySourceProvider)
          .setSaved(playlistId: playlistId, saved: subscribed);
      ref.invalidate(podcastSubscriptionsProvider);
    } on Object {
      _overrides.remove(key);
      state = before;
      rethrow;
    }
  }
}

final NotifierProvider<PodcastSubscriptionsController, Set<String>>
    podcastSubscriptionsControllerProvider =
    NotifierProvider<PodcastSubscriptionsController, Set<String>>(
  PodcastSubscriptionsController.new,
);
