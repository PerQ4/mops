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

/// Страница альбома: обложка, метаданные и список треков.
class AlbumScreen extends ConsumerWidget {
  const AlbumScreen({super.key, required this.albumId});

  final String albumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<Album> album = ref.watch(albumProvider(albumId));

    return Scaffold(
      body: album.when(
        data: (Album data) => _AlbumBody(album: data),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace _) => Scaffold(
          appBar: AppBar(),
          body: ErrorState(
          message: describeError(error),
            onRetry: () => ref.invalidate(albumProvider(albumId)),
          ),
        ),
      ),
    );
  }
}

class _AlbumBody extends ConsumerWidget {
  const _AlbumBody({required this.album});

  final Album album;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? current = ref.watch(currentTrackProvider);
    final bool playing = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.isPlaying),
    );

    final String? meta = _metaLine();
    final bool isCurrentAlbum =
        current != null && album.tracks.any((Track t) => t.id == current.id);

    return CustomScrollView(
      slivers: <Widget>[
        SliverAppBar(
          pinned: true,
          expandedHeight: 64,
          title: Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        SliverToBoxAdapter(
          child: PageHeader(
            title: album.title,
            subtitle: meta,
            description: album.description,
            imageUrl: album.thumbnails.sized(600),
            fallbackIcon: Icons.album_outlined,
            actions: <Widget>[
              FilledButton.icon(
                onPressed: album.tracks.isEmpty
                    ? null
                    : () => ref
                        .read(playerControllerProvider.notifier)
                        .playQueue(album.tracks),
                icon: Icon(
                  isCurrentAlbum && playing ? Icons.pause : Icons.play_arrow,
                ),
                label: Text(isCurrentAlbum && playing ? 'Пауза' : 'Слушать'),
              ),
              OutlinedButton.icon(
                onPressed: album.tracks.isEmpty
                    ? null
                    : () => ref
                        .read(playerControllerProvider.notifier)
                        .playQueue(album.tracks, shuffle: true),
                icon: const Icon(Icons.shuffle),
                label: const Text('Вперемешку'),
              ),
            ],
          ),
        ),
        if (album.tracks.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.music_off_outlined,
              title: 'Треков нет',
              subtitle: 'YouTube Music не вернул список треков для этого альбома.',
            ),
          )
        else
          SliverList.builder(
            itemCount: album.tracks.length,
            itemBuilder: (BuildContext context, int index) {
              final Track track = album.tracks[index];
              final bool isCurrent = current?.id == track.id;
              return TrackTile(
                track: track,
                leadingNumber: index + 1,
                isCurrent: isCurrent,
                isPlaying: isCurrent && playing,
                showDuration: true,
                subtitleOverride: track.artistLine,
                onTap: () => ref
                    .read(playerControllerProvider.notifier)
                    .playTrack(track, context: album.tracks),
              );
            },
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  String? _metaLine() {
    final List<String> parts = <String>[];
    if (album.artists.isNotEmpty) parts.add(album.artistLine);
    if (album.year != null) parts.add(album.year!);
    if (album.trackCount != null) parts.add(trackCountLabel(album.trackCount));
    if (album.duration != null) {
      parts.add('${album.duration!.inMinutes} мин');
    }
    return parts.isEmpty ? null : parts.join(' • ');
  }
}
