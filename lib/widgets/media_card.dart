import 'package:flutter/material.dart';

import '../core/utils/format.dart';
import '../data/models/models.dart';
import 'artwork.dart';

/// Карточка карусели: обложка, заголовок, подпись.
///
/// Для исполнителей используется круглая обложка ([circular]) — так принято
/// в Material-музыкальных интерфейсах и это же делает YouTube Music.
class MediaCard extends StatelessWidget {
  const MediaCard({
    super.key,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.imageUrl,
    this.width = 160,
    this.circular = false,
    this.icon,
    this.heroTag,
    this.badge,
  });

  final String title;
  final String? subtitle;
  final String? imageUrl;
  final double width;
  final bool circular;
  final IconData? icon;
  final Object? heroTag;
  final Widget? badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Stack(
                children: <Widget>[
                  Artwork(
                    url: imageUrl,
                    size: width,
                    icon: icon,
                    heroTag: heroTag,
                    radius: BorderRadius.circular(circular ? width / 2 : 16),
                  ),
                  if (badge != null)
                    Positioned(right: 8, bottom: 8, child: badge!),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Карточка из [BrowseItem] — сама понимает, что за сущность внутри.
class BrowseItemCard extends StatelessWidget {
  const BrowseItemCard({
    super.key,
    required this.item,
    required this.onTap,
    this.width = 160,
    this.isCurrent = false,
  });

  final BrowseItem item;
  final double width;
  final bool isCurrent;

  /// Что делать при нажатии: у трека — играть, у остальных — открыть.
  final void Function(BrowseItem item) onTap;

  @override
  Widget build(BuildContext context) {
    final (String? subtitle, bool circular, IconData icon) = switch (item) {
      TrackItem(:final Track track) => (cleanArtistName(track.artistLine), false, Icons.music_note),
      AlbumItem(:final Album album) => (
          album.year ?? album.artistLine,
          false,
          Icons.album_outlined,
        ),
      ArtistItem() => ('Исполнитель', true, Icons.person_outline),
      PlaylistItem(:final Playlist playlist) => (
          playlist.author,
          false,
          Icons.queue_music,
        ),
    };

    return MediaCard(
      title: item.title,
      subtitle: subtitle,
      imageUrl: item.thumbnails.sized((width * 2).round()),
      width: width,
      circular: circular,
      icon: icon,
      onTap: () => onTap(item),
    );
  }
}
