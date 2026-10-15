import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/models/models.dart';
import '../../state/catalog_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/async_views.dart';
import '../../widgets/media_card.dart';
import '../../widgets/track_tile.dart';
import '../album/media_hero.dart';
import '../common/navigation.dart';
import '../../widgets/empty_state.dart';

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
        loading: () => const MediaDetailSkeleton(rows: 5),
        error: (Object error, StackTrace _) => Scaffold(
          appBar: AppBar(),
          body: ErrorState(
          message: describeError(error),
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

    final List<Track> top = artist.topTracks;
    final bool isCurrentArtist =
        current != null && top.any((Track t) => t.id == current.id);
    final bool hasTracks = top.isNotEmpty;

    return CustomScrollView(
      slivers: <Widget>[
        SliverAppBar(
          pinned: true,
          expandedHeight: AppLayout.appBarHeight,
          title: Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        SliverToBoxAdapter(
          child: MediaHero(
            title: artist.name,
            // Подписчики — это «аудитория» из ArchiveTune (ArtistScreen.kt:465-479):
            // строка метаданных `labelMedium` α0.62, а не подпись.
            meta: artist.subscribers,
            description: artist.description,
            imageUrl: artist.thumbnails.sized(600),
            fallbackIcon: Icons.person_outline,
            // Порядок действий как в ArchiveTune: перемешать, слушать, добавить.
            actions: <Widget>[
              HeroCircleButton(
                icon: Icons.shuffle,
                tooltip: 'Перемешать',
                size: 52,
                onPressed: hasTracks
                    ? () => ref
                        .read(playerControllerProvider.notifier)
                        .playQueue(top, shuffle: true)
                    : null,
              ),
              HeroPlayButton(
                label: isCurrentArtist && playing ? 'Пауза' : 'Слушать',
                icon: isCurrentArtist && playing
                    ? Icons.pause
                    : Icons.play_arrow,
                onPressed: !hasTracks
                    ? null
                    : () {
                        final PlayerController controller =
                            ref.read(playerControllerProvider.notifier);
                        if (isCurrentArtist && playing) {
                          controller.togglePlayPause();
                        } else {
                          controller.playQueue(top);
                        }
                      },
              ),
              HeroCircleButton(
                icon: Icons.playlist_add,
                tooltip: 'В очередь',
                size: 52,
                onPressed: hasTracks ? () => _enqueueAll(ref, top) : null,
              ),
            ],
          ),
        ),
        if (top.isNotEmpty) ...<Widget>[
          const SliverToBoxAdapter(child: _SectionTitle('Популярные треки')),
          SliverList.builder(
            itemCount: top.length > 10 ? 10 : top.length,
            itemBuilder: (BuildContext context, int index) {
              final Track track = top[index];
              final bool isCurrent = current?.id == track.id;
              return TrackTile(
                track: track,
                leadingNumber: index + 1,
                isCurrent: isCurrent,
                isPlaying: isCurrent && playing,
                subtitleOverride: track.artistLine,
                onTap: () => ref
                    .read(playerControllerProvider.notifier)
                    .playTrack(track, context: top),
              );
            },
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
        ],
        if (artist.albums.isNotEmpty)
          SliverToBoxAdapter(
            child: _CardRow(title: 'Альбомы', albums: artist.albums),
          ),
        if (artist.singles.isNotEmpty)
          SliverToBoxAdapter(
            child: _CardRow(title: 'Синглы и мини-альбомы', albums: artist.singles),
          ),
        if (artist.related.isNotEmpty)
          SliverToBoxAdapter(
            child: _ArtistRow(title: 'Похожие исполнители', artists: artist.related),
          ),
        const SliverToBoxAdapter(
          // Отступ снизу под плавающий островок плеера.
          child: SizedBox(height: AppLayout.floatingDockClearance),
        ),
      ],
    );
  }

  /// Кладёт популярные треки в конец очереди.
  void _enqueueAll(WidgetRef ref, List<Track> tracks) {
    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);
    for (final Track track in tracks) {
      controller.enqueue(track);
    }
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    // Заголовок секции в стиле `NavigationTitle`: отступы 12/12 и цвет
    // `primary` (NavigationTitle.kt:43-76).
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.primary,
            ),
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
          height: AppLayout.cardHeight + 8,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            // Отступ ленты — 12, как у заголовка секции (ArtistScreen.kt:759-761).
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: albums.length,
            separatorBuilder: (BuildContext context, int _) =>
                const SizedBox(width: 12),
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
          // У круглых аватаров обложка меньше карточки, поэтому высота иная.
          height: AppLayout.artistAvatar + 90,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            // Отступ ленты — 12, как у заголовка секции.
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: artists.length,
            separatorBuilder: (BuildContext context, int _) =>
                const SizedBox(width: 12),
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
