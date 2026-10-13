import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/catalog_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/async_views.dart';
import '../../widgets/media_card.dart';
import '../../widgets/section_list.dart';
import '../../widgets/track_tile.dart';
import '../common/navigation.dart';

/// Страница исполнителя: популярные треки, альбомы, синглы, похожие.
class ArtistScreen extends ConsumerWidget {
  const ArtistScreen({super.key, required this.artistId});

  final String artistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<Artist> artist = ref.watch(artistProvider(artistId));

    return Scaffold(
      body: artist.when(
        data: (Artist data) => _ArtistBody(artist: data),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace _) => Scaffold(
          appBar: AppBar(),
          body: ErrorView(
            error: error,
            onRetry: () => ref.invalidate(artistProvider(artistId)),
          ),
        ),
      ),
    );
  }
}

class _ArtistBody extends ConsumerWidget {
  const _ArtistBody({required this.artist});

  final Artist artist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? current = ref.watch(currentTrackProvider);
    final bool playing = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.isPlaying),
    );

    return ListView(
      padding: EdgeInsets.zero,
      children: <Widget>[
        SafeArea(
          bottom: false,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 4, top: 4),
              child: BackButton(onPressed: () => Navigator.maybePop(context)),
            ),
          ),
        ),
        PageHeader(
          title: artist.name,
          subtitle: artist.subscribers,
          description: artist.description,
          imageUrl: artist.thumbnails.sized(600),
          circular: true,
          fallbackIcon: Icons.person_outline,
          actions: <Widget>[
            FilledButton.icon(
              onPressed: artist.topTracks.isEmpty
                  ? null
                  : () => ref
                      .read(playerControllerProvider.notifier)
                      .playQueue(artist.topTracks, shuffle: true),
              icon: const Icon(Icons.shuffle),
              label: const Text('Слушать'),
            ),
          ],
        ),
        if (artist.topTracks.isNotEmpty) ...<Widget>[
          const _SectionTitle('Популярные треки'),
          for (int i = 0; i < artist.topTracks.length && i < 10; i++)
            TrackTile(
              track: artist.topTracks[i],
              leadingIndex: i + 1,
              isCurrent: current?.id == artist.topTracks[i].id,
              isPlaying: current?.id == artist.topTracks[i].id && playing,
              subtitleOverride: artist.topTracks[i].artistLine,
              onTap: () => ref
                  .read(playerControllerProvider.notifier)
                  .playTrack(
                    artist.topTracks[i],
                    context: artist.topTracks,
                  ),
            ),
          const SizedBox(height: 12),
        ],
        if (artist.albums.isNotEmpty)
          _CardRow(title: 'Альбомы', albums: artist.albums),
        if (artist.singles.isNotEmpty)
          _CardRow(title: 'Синглы и мини-альбомы', albums: artist.singles),
        if (artist.related.isNotEmpty)
          _ArtistRow(title: 'Похожие исполнители', artists: artist.related),
        const SizedBox(height: 32),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .titleLarge
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Горизонтальная лента альбомов.
class _CardRow extends StatelessWidget {
  const _CardRow({required this.title, required this.albums});

  final String title;
  final List<Album> albums;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionTitle(title),
        SizedBox(
          height: 232,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: albums.length,
            separatorBuilder: (BuildContext context, int _) =>
                const SizedBox(width: 8),
            itemBuilder: (BuildContext context, int index) {
              final Album album = albums[index];
              return BrowseItemCard(
                item: AlbumItem(album),
                width: 160,
                onTap: (BrowseItem _) => AppRoutes.album(context, album.id),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

/// Горизонтальная лента исполнителей.
class _ArtistRow extends StatelessWidget {
  const _ArtistRow({required this.title, required this.artists});

  final String title;
  final List<Artist> artists;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionTitle(title),
        SizedBox(
          height: 226,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: artists.length,
            separatorBuilder: (BuildContext context, int _) =>
                const SizedBox(width: 8),
            itemBuilder: (BuildContext context, int index) {
              final Artist artist = artists[index];
              return BrowseItemCard(
                item: ArtistItem(artist),
                width: 160,
                onTap: (BrowseItem _) => AppRoutes.artist(context, artist.id),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
