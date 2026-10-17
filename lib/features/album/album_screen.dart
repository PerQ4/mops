import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../core/utils/format.dart';
import '../../data/models/models.dart';
import '../../state/catalog_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/async_views.dart';
import '../../widgets/track_tile.dart';
import 'media_hero.dart';

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
        loading: () => const MediaDetailSkeleton(),
        error: (Object error, StackTrace _) => Scaffold(
          appBar: AppBar(),
          body: MediaDetailStatePanel(
            icon: Icons.cloud_off_outlined,
            title: 'Не удалось загрузить',
            description: describeError(error),
            actionLabel: 'Повторить',
            onAction: () => ref.invalidate(albumProvider(albumId)),
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

    final bool isCurrentAlbum =
        current != null && album.tracks.any((Track t) => t.id == current.id);
    final bool hasTracks = album.tracks.isNotEmpty;

    return CustomScrollView(
      slivers: <Widget>[
        SliverAppBar(
          pinned: true,
          expandedHeight: AppLayout.appBarHeight,
          title: Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        // Альбом без треков показывается без «героя»: в оригинале ветка
        // `hasSongs == false` выводит только панель состояния, портрет альбома
        // тогда не нужен (AlbumScreen.kt:495-511).
        if (album.tracks.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: MediaDetailStatePanel(
              icon: Icons.album_outlined,
              title: 'Треков нет',
              description:
                  'YouTube Music не вернул список треков для этого альбома.',
            ),
          )
        else ...<Widget>[
          SliverToBoxAdapter(
            child: MediaHero(
              title: album.title,
              // Исполнители шапки (`BrowseParser.pageArtists`) — кликабельной
              // подписью, как ссылки в оригинале.
              artists: album.artists,
              meta: _metaLine(),
              description: album.description,
              imageUrl: album.thumbnails.sized(600),
              fallbackIcon: Icons.album_outlined,
              // Порядок действий как в ArchiveTune: перемешать, слушать,
              // добавить (MediaDetailHero.kt:341-409).
              actions: <Widget>[
                HeroCircleButton(
                  icon: Icons.shuffle,
                  tooltip: 'Перемешать',
                  size: 52,
                  onPressed: hasTracks
                      ? () => ref
                          .read(playerControllerProvider.notifier)
                          .playQueue(album.tracks, shuffle: true)
                      : null,
                ),
                HeroPlayButton(
                  label: isCurrentAlbum && playing ? 'Пауза' : 'Слушать',
                  icon: isCurrentAlbum && playing
                      ? Icons.pause
                      : Icons.play_arrow,
                  onPressed: !hasTracks
                      ? null
                      : () {
                          final PlayerController controller =
                              ref.read(playerControllerProvider.notifier);
                          // На паузе нажимаем «продолжить», иначе запускаем
                          // альбом заново — так иконка не расходится с делом.
                          if (isCurrentAlbum && playing) {
                            controller.togglePlayPause();
                          } else {
                            controller.playQueue(album.tracks);
                          }
                        },
                ),
                HeroCircleButton(
                  icon: Icons.playlist_add,
                  tooltip: 'В очередь',
                  size: 52,
                  onPressed: hasTracks ? () => _enqueueAll(ref) : null,
                ),
                // Сохранение в библиотеку: ключ состояния — browse-id
                // страницы, а мутации нужен звуковой id плейлиста альбома.
                HeroSaveButton(
                  stateId: album.id,
                  playlistId: album.audioPlaylistId,
                ),
              ],
            ),
          ),
          // Заголовок списка треков — `NavigationTitle` из ArchiveTune
          // (AlbumScreen.kt:403-407, NavigationTitle.kt:43-76).
          const SliverToBoxAdapter(child: _SectionTitle('Треки')),
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
                // Подпись собирается кликабельной (исполнители — ссылки),
                // поэтому `subtitleOverride` (простой текст) не передаём.
                onTap: () => ref
                    .read(playerControllerProvider.notifier)
                    .playTrack(track, context: album.tracks),
              );
            },
          ),
        ],
        const SliverToBoxAdapter(
          // Отступ снизу: последние строки не уходят под плавающий островок.
          child: SizedBox(height: AppLayout.floatingDockClearance),
        ),
      ],
    );
  }

  /// «год • N треков • длительность» — формат метаданных из спецификации.
  /// Исполнитель вынесен в подпись героя, поэтому здесь его нет.
  String? _metaLine() {
    final List<String> parts = <String>[];
    if (album.year != null) parts.add(album.year!);
    if (album.trackCount != null) parts.add(trackCountLabel(album.trackCount));
    if (album.duration != null) {
      final String total = formatTotalDuration(album.duration!);
      if (total.isNotEmpty) parts.add(total);
    }
    return parts.isEmpty ? null : parts.join(mediaDetailMetadataSeparator);
  }

  /// Кладёт весь альбом в конец очереди.
  ///
  /// Собираем по одному треку: у контроллера нет пакетного добавления, а
  /// заводить его — значит трогать чужой слой состояния.
  void _enqueueAll(WidgetRef ref) {
    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);
    for (final Track track in album.tracks) {
      controller.enqueue(track);
    }
  }
}

/// Заголовок секции в стиле `NavigationTitle` из ArchiveTune: отступы 12/12,
/// `titleLarge` полужирный цветом `primary` (NavigationTitle.kt:43-76).
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
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
