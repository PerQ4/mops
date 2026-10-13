import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';
import '../features/common/navigation.dart';
import '../state/player_controller.dart';
import 'artwork.dart';
import 'section_carousel.dart';
import 'track_tile.dart';

/// Обрабатывает нажатие на элемент карусели.
///
/// Треки запускаются, а альбомы, исполнители и плейлисты открываются —
/// ровно то поведение, к которому привыкли по YouTube Music.
void openBrowseItem(
  BuildContext context,
  WidgetRef ref,
  BrowseItem item, {
  List<Track>? playContext,
}) {
  switch (item) {
    case TrackItem(:final Track track):
      ref.read(playerControllerProvider.notifier).playTrack(
            track,
            context: playContext,
          );
    case AlbumItem(:final Album album):
      AppRoutes.album(context, album.id);
    case ArtistItem(:final Artist artist):
      AppRoutes.artist(context, artist.id);
    case PlaylistItem(:final Playlist playlist):
      AppRoutes.playlist(context, playlist.id);
  }
}

/// Все треки внутри одной секции — контекст воспроизведения.
List<Track> tracksOf(BrowseSection section) => section.items
    .whereType<TrackItem>()
    .map((TrackItem item) => item.track)
    .toList();

/// Вертикальный список каруселей.
class SectionListView extends ConsumerWidget {
  const SectionListView({
    super.key,
    required this.sections,
    this.padding = const EdgeInsets.symmetric(vertical: 8),
    this.header,
    this.cardWidth = 160,
    this.emptyPlaceholder,
  });

  final List<BrowseSection> sections;
  final EdgeInsets padding;
  final Widget? header;
  final double cardWidth;
  final Widget? emptyPlaceholder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (sections.isEmpty) {
      return emptyPlaceholder ?? const SizedBox.shrink();
    }

    return ListView.builder(
      padding: padding,
      itemCount: sections.length + (header != null ? 1 : 0),
      itemBuilder: (BuildContext context, int index) {
        if (header != null) {
          if (index == 0) return header!;
          index -= 1;
        }

        final BrowseSection section = sections[index];
        return SectionCarousel(
          section: section,
          cardWidth: cardWidth,
          onItemTap: (BrowseItem item) => openBrowseItem(
            context,
            ref,
            item,
            playContext: tracksOf(section),
          ),
        );
      },
    );
  }
}

/// Вертикальный список треков (используется на страницах альбома/плейлиста).
class TrackListView extends ConsumerWidget {
  const TrackListView({
    super.key,
    required this.tracks,
    this.padding = const EdgeInsets.symmetric(vertical: 8),
    this.header,
    this.context_,
    this.showIndex = false,
    this.shrinkWrap = false,
    this.physics,
  });

  final List<Track> tracks;
  final EdgeInsets padding;
  final Widget? header;

  /// Контекст воспроизведения; по умолчанию — сам список.
  final List<Track>? context_;
  final bool showIndex;
  final bool shrinkWrap;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerUiState player = ref.watch(playerControllerProvider);
    final String? currentId = player.current?.id;
    final List<Track> playContext = context_ ?? tracks;

    return ListView.builder(
      padding: padding,
      shrinkWrap: shrinkWrap,
      physics: physics,
      itemCount: tracks.length + (header != null ? 1 : 0),
      itemBuilder: (BuildContext context, int index) {
        if (header != null) {
          if (index == 0) return header!;
          index -= 1;
        }

        final Track track = tracks[index];
        final bool isCurrent = currentId == track.id;

        return TrackTile(
          track: track,
          leadingIndex: showIndex ? index + 1 : null,
          isCurrent: isCurrent,
          isPlaying: isCurrent && player.isPlaying,
          onTap: () => ref.read(playerControllerProvider.notifier).playTrack(
                track,
                context: playContext,
              ),
          onLongPress: () => _showTrackActions(context, ref, track),
        );
      },
    );
  }

  void _showTrackActions(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.play_arrow),
                title: const Text('Играть сейчас'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  ref.read(playerControllerProvider.notifier).playTrack(track);
                },
              ),
              ListTile(
                leading: const Icon(Icons.queue_play_next),
                title: const Text('Играть следующим'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  ref.read(playerControllerProvider.notifier).playNext(track);
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: const Text('В конец очереди'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  ref.read(playerControllerProvider.notifier).enqueue(track);
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Крупный заголовок страницы с обложкой — шапка альбома/плейлиста/артиста.
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.description,
    this.imageUrl,
    this.circular = false,
    this.actions = const <Widget>[],
    this.fallbackIcon,
  });

  final String title;
  final String? subtitle;
  final String? description;
  final String? imageUrl;
  final bool circular;
  final List<Widget> actions;
  final IconData? fallbackIcon;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool wide = MediaQuery.sizeOf(context).width >= 720;
    const double size = 200;

    final Widget artwork = Artwork(
      url: imageUrl,
      size: size,
      icon: fallbackIcon,
      radius: BorderRadius.circular(circular ? size / 2 : 20),
    );

    final Widget info = Column(
      crossAxisAlignment:
          wide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          title,
          textAlign: wide ? TextAlign.start : TextAlign.center,
          style: text.displaySmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            subtitle!,
            textAlign: wide ? TextAlign.start : TextAlign.center,
            style: text.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        if (description != null && description!.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            description!.trim(),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            textAlign: wide ? TextAlign.start : TextAlign.center,
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        if (actions.isNotEmpty) ...<Widget>[
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: wide ? WrapAlignment.start : WrapAlignment.center,
            children: actions,
          ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                artwork,
                const SizedBox(width: 24),
                Expanded(child: info),
              ],
            )
          : Column(
              children: <Widget>[
                artwork,
                const SizedBox(height: 20),
                info,
              ],
            ),
    );
  }
}
