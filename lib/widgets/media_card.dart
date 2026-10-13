import 'package:flutter/material.dart';

import '../core/theme/layout.dart';
import '../data/models/models.dart';
import 'artwork.dart';

/// Карточка карусели: обложка, заголовок, подпись.
///
/// Размеры фиксированы константами, поэтому карточки не меняют высоту от
/// текста и карусель не «дёргается» при прокрутке.
class MediaCard extends StatelessWidget {
  const MediaCard({
    super.key,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.imageUrl,
    this.width = AppLayout.cardWidth,
    this.circular = false,
    this.artworkSize,
    this.icon,
    this.heroTag,
  });

  final String title;
  final String? subtitle;
  final String? imageUrl;
  final double width;
  final bool circular;

  /// Размер обложки. Для круглых аватаров меньше ширины карточки, чтобы
  /// подписи помещались без обрезки.
  final double? artworkSize;
  final IconData? icon;
  final Object? heroTag;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppLayout.radiusM),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Artwork(
              url: imageUrl,
              size: artworkSize ?? width,
              icon: icon,
              heroTag: heroTag,
              radius: BorderRadius.circular(
                circular
                    ? (artworkSize ?? width) / 2
                    : AppLayout.cardArtworkRadius,
              ),
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
    );
  }
}

/// Карточка из [BrowseItem] — сама понимает, что за сущность внутри.
class BrowseItemCard extends StatelessWidget {
  const BrowseItemCard({
    super.key,
    required this.item,
    required this.onTap,
    this.width = AppLayout.cardWidth,
  });

  final BrowseItem item;
  final double width;
  final void Function(BrowseItem item) onTap;

  @override
  Widget build(BuildContext context) {
    final (String? subtitle, bool circular, IconData icon) = switch (item) {
      TrackItem(:final Track track) => (
          track.artistLine,
          false,
          Icons.music_note,
        ),
      AlbumItem(:final Album album) => (
          album.year ?? album.artistLine,
          false,
          Icons.album_outlined,
        ),
      ArtistItem() => (null, true, Icons.person_outline),
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
      artworkSize: circular ? AppLayout.artistAvatar : null,
      icon: icon,
      onTap: () => onTap(item),
    );
  }
}
