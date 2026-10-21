import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/player_controller.dart';
import 'podcast_models.dart';
import 'podcast_providers.dart';

/// Запуск эпизодов подкаста.
///
/// Отдельно от экранов, потому что эпизод запускают из двух мест — страницы
/// шоу и блока «Недавно игравшие» в коллекции, — и оба должны одинаково
/// регистрировать снимок шоу (без него трекер прогресса не отличит эпизод от
/// обычного трека) и возвращать сохранённую позицию.
abstract final class PodcastPlayback {
  /// Играет шоу с выпуска [startIndex]. Перемешивание — без возврата позиции:
  /// при случайном порядке «продолжить» теряет смысл.
  static Future<void> playShow(
    WidgetRef ref,
    PodcastShow show, {
    int startIndex = 0,
    bool shuffle = false,
  }) async {
    final List<PodcastEpisode> episodes = show.episodes;
    if (episodes.isEmpty) return;

    for (final PodcastEpisode episode in episodes) {
      ref.read(podcastLocalProvider.notifier).noteEpisode(show, episode);
    }

    if (shuffle) {
      await ref.read(playerControllerProvider.notifier).playQueue(
            _tracks(episodes),
            startIndex: startIndex,
            shuffle: true,
          );
      return;
    }
    await _start(ref, episodes, startIndex);
  }

  /// Играет один выпуск. [context] — остальные выпуски шоу: они становятся
  /// очередью, чтобы после эпизода играл следующий.
  static Future<void> playEpisode(
    WidgetRef ref,
    PodcastShow show,
    PodcastEpisode episode, {
    List<PodcastEpisode>? context,
  }) async {
    final List<PodcastEpisode> episodes = (context == null || context.isEmpty)
        ? <PodcastEpisode>[episode]
        : List<PodcastEpisode>.of(context);
    for (final PodcastEpisode item in episodes) {
      ref.read(podcastLocalProvider.notifier).noteEpisode(show, item);
    }

    int index = episodes.indexWhere(
      (PodcastEpisode item) => item.id == episode.id,
    );
    if (index < 0) {
      episodes.insert(0, episode);
      index = 0;
    }
    await _start(ref, episodes, index);
  }

  /// Возобновляет выпуск из локальной истории.
  ///
  /// Снимок шоу и трека уже лежит в записи, поэтому сеть для запуска не
  /// нужна — эпизод заиграет, даже если шоу пропало из каталога.
  static Future<void> resumeEntry(WidgetRef ref, PodcastEntry entry) async {
    final PodcastShow show = PodcastShow(
      browseId: entry.showId,
      playlistId: entry.showPlaylistId,
      title: entry.showTitle,
      thumbnails: entry.showArtwork == null
          ? const <Thumbnail>[]
          : <Thumbnail>[Thumbnail(url: entry.showArtwork!)],
    );
    ref.read(podcastLocalProvider.notifier).noteEpisode(show, entry.episode);
    await _start(ref, <PodcastEpisode>[entry.episode], 0);
  }

  static List<Track> _tracks(List<PodcastEpisode> episodes) =>
      episodes.map((PodcastEpisode episode) => episode.track).toList(
            growable: false,
          );

  /// Запускает очередь и перематывает на сохранённую позицию.
  ///
  /// `playQueue` ждёт загрузки потока, поэтому перемотка сразу после него
  /// попадает в уже готовый трек. Проверка текущего id нужна на случай, если
  /// пользователь успел переключить выпуск, пока шёл резолв.
  static Future<void> _start(
    WidgetRef ref,
    List<PodcastEpisode> episodes,
    int index,
  ) async {
    if (episodes.isEmpty) return;
    final int safeIndex = index.clamp(0, episodes.length - 1);
    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);
    // Экран могли закрыть, пока шёл резолв. Обращение к `ref` после `await`
    // у уже размонтированного виджета бросает, поэтому живость запоминаем
    // заранее по контексту и перемотку без экрана не применяем.
    final BuildContext context = ref.context;
    await controller.playQueue(_tracks(episodes), startIndex: safeIndex);
    if (!context.mounted) return;

    final String episodeId = episodes[safeIndex].id;
    if (ref.read(playerControllerProvider).current?.id != episodeId) return;

    final Duration position =
        ref.read(podcastLocalProvider).progress[episodeId]?.position ??
            Duration.zero;
    // Первые секунды не восстанавливаем: это не «продолжить», а начало.
    if (position <= const Duration(seconds: 2)) return;
    await controller.seek(position);
  }
}
