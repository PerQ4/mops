import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../core/utils/format.dart';
import '../../data/models/models.dart';
import '../../data/sources/library_source.dart';
import '../../state/catalog_providers.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/async_views.dart';
import '../../widgets/track_tile.dart';
import '../../widgets/empty_state.dart';
import '../album/media_hero.dart';


/// Страница плейлиста.
class PlaylistScreen extends ConsumerWidget {
  const PlaylistScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // «Понравившаяся музыка» в библиотеке открывается с id `VLLM` (а из
    // очереди — с `LM`). Общий `playlistProvider` запрашивает раздел без
    // авторизации, и гостю YouTube отдаёт пустой плейлист, поэтому для
    // «Мне нравится» берём отдельный авторизованный источник.
    final bool liked = LibrarySource.isLikedPlaylist(playlistId);
    final AsyncValue<Playlist> playlist = liked
        ? ref.watch(likedSongsPlaylistProvider)
        : ref.watch(playlistProvider(playlistId));

    return Scaffold(
      body: playlist.when(
        data: (Playlist data) => _PlaylistBody(playlist: data),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace _) => Scaffold(
          appBar: AppBar(),
          body: ErrorState(
            message: describeError(error),
            onRetry: () => ref.invalidate(
              liked ? likedSongsPlaylistProvider : playlistProvider(playlistId),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaylistBody extends ConsumerWidget {
  const _PlaylistBody({required this.playlist});

  final Playlist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? current = ref.watch(currentTrackProvider);
    final bool playing = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.isPlaying),
    );

    final bool isCurrentPlaylist =
        current != null && playlist.tracks.any((Track t) => t.id == current.id);
    final bool hasTracks = playlist.tracks.isNotEmpty;

    return CustomScrollView(
      slivers: <Widget>[
        SliverAppBar(
          pinned: true,
          expandedHeight: AppLayout.appBarHeight,
          title: Text(
            playlist.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        SliverToBoxAdapter(
          child: MediaHero(
            title: playlist.title,
            subtitle: playlist.author,
            meta: _metaLine(),
            description: playlist.description,
            imageUrl: playlist.thumbnails.sized(600),
            fallbackIcon: Icons.queue_music,
            actions: <Widget>[
              HeroPlayButton(
                label: isCurrentPlaylist && playing ? 'Пауза' : 'Слушать',
                icon: isCurrentPlaylist && playing
                    ? Icons.pause
                    : Icons.play_arrow,
                onPressed: !hasTracks
                    ? null
                    : () {
                        final PlayerController controller =
                            ref.read(playerControllerProvider.notifier);
                        // Иконка «пауза» должна действительно ставить на
                        // паузу, а не перезапускать плейлист с начала.
                        if (isCurrentPlaylist && playing) {
                          controller.togglePlayPause();
                        } else {
                          controller.playQueue(playlist.tracks);
                        }
                      },
              ),
              HeroCircleButton(
                icon: Icons.shuffle,
                tooltip: 'Перемешать',
                size: 52,
                onPressed: hasTracks
                    ? () => ref
                        .read(playerControllerProvider.notifier)
                        .playQueue(playlist.tracks, shuffle: true)
                    : null,
              ),
              HeroCircleButton(
                icon: Icons.playlist_add,
                tooltip: 'В очередь',
                size: 52,
                onPressed: hasTracks ? () => _enqueueAll(ref) : null,
              ),
            ],
          ),
        ),
        if (playlist.tracks.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.music_off_outlined,
              title: 'Плейлист пуст',
              subtitle: 'В нём пока нет доступных треков.',
            ),
          )
        else
          SliverList.builder(
            itemCount: playlist.tracks.length,
            itemBuilder: (BuildContext context, int index) {
              final Track track = playlist.tracks[index];
              final bool isCurrent = current?.id == track.id;
              return TrackTile(
                track: track,
                isCurrent: isCurrent,
                isPlaying: isCurrent && playing,
                onTap: () => ref
                    .read(playerControllerProvider.notifier)
                    .playTrack(track, context: playlist.tracks),
              );
            },
          ),
        const SliverToBoxAdapter(
          // Отступ снизу под плавающий островок плеера.
          child: SizedBox(height: AppLayout.floatingDockClearance),
        ),
      ],
    );
  }

  /// «N треков • длительность» — формат метаданных из спецификации.
  /// Автор вынесен в подпись героя.
  String? _metaLine() {
    final List<String> parts = <String>[];
    if (playlist.trackCount != null) {
      parts.add(trackCountLabel(playlist.trackCount));
    }
    if (playlist.duration != null) {
      final String total = formatTotalDuration(playlist.duration!);
      if (total.isNotEmpty) parts.add(total);
    }
    return parts.isEmpty ? null : parts.join(' • ');
  }

  /// Кладёт весь плейлист в конец очереди.
  void _enqueueAll(WidgetRef ref) {
    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);
    for (final Track track in playlist.tracks) {
      controller.enqueue(track);
    }
  }
}
