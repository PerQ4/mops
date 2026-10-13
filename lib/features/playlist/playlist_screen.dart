import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/format.dart';
import '../../data/models/models.dart';
import '../../state/catalog_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/async_views.dart';
import '../../widgets/section_list.dart';
import '../../widgets/track_tile.dart';
import '../../widgets/empty_state.dart';


/// Страница плейлиста.
class PlaylistScreen extends ConsumerWidget {
  const PlaylistScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<Playlist> playlist =
        ref.watch(playlistProvider(playlistId));

    return Scaffold(
      body: playlist.when(
        data: (Playlist data) => _PlaylistBody(playlist: data),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace _) => Scaffold(
          appBar: AppBar(),
          body: ErrorState(
          message: describeError(error),
            onRetry: () => ref.invalidate(playlistProvider(playlistId)),
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

    return CustomScrollView(
      slivers: <Widget>[
        SliverAppBar(
          pinned: true,
          expandedHeight: 64,
          title: Text(
            playlist.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        SliverToBoxAdapter(
          child: PageHeader(
            title: playlist.title,
            subtitle: _metaLine(),
            description: playlist.description,
            imageUrl: playlist.thumbnails.sized(600),
            fallbackIcon: Icons.queue_music,
            actions: <Widget>[
              FilledButton.icon(
                onPressed: playlist.tracks.isEmpty
                    ? null
                    : () => ref
                        .read(playerControllerProvider.notifier)
                        .playQueue(playlist.tracks),
                icon: Icon(
                  isCurrentPlaylist && playing
                      ? Icons.pause
                      : Icons.play_arrow,
                ),
                label: Text(
                  isCurrentPlaylist && playing ? 'Пауза' : 'Слушать',
                ),
              ),
              OutlinedButton.icon(
                onPressed: playlist.tracks.isEmpty
                    ? null
                    : () => ref
                        .read(playerControllerProvider.notifier)
                        .playQueue(playlist.tracks, shuffle: true),
                icon: const Icon(Icons.shuffle),
                label: const Text('Вперемешку'),
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
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  String? _metaLine() {
    final List<String> parts = <String>[];
    if (playlist.author != null && playlist.author!.isNotEmpty) {
      parts.add(playlist.author!);
    }
    if (playlist.trackCount != null) {
      parts.add(trackCountLabel(playlist.trackCount));
    }
    return parts.isEmpty ? null : parts.join(' • ');
  }
}
