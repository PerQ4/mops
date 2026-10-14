import 'package:flutter/material.dart';

import '../../core/theme/layout.dart';
import '../../data/models/models.dart';
import '../../widgets/artwork.dart';

/// Плитка-подборка библиотеки.
///
/// Форма из ArchiveTune: фон `surfaceContainerLow`, крупное скругление 26,
/// обложка с малым радиусом и отступом 6. Отдельная от `BrowseItemCard`
/// реализация: у плитки библиотеки есть подложка, которой у карточек каруселей
/// нет.
class LibrarySpotlightTile extends StatelessWidget {
  const LibrarySpotlightTile({
    super.key,
    required this.item,
    required this.onTap,
  });

  final BrowseItem item;
  final VoidCallback onTap;

  /// Радиус плитки — 26, как у «spotlight»-карточек в спецификации.
  static const double radius = 26;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    final (String? subtitle, bool circular, IconData icon) = switch (item) {
      TrackItem(:final Track track) => (track.artistLine, false, Icons.music_note),
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

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(radius),
        // Мягкое «свечение» подложки. Цвет обложки не извлекаем: квантование
        // картинки на каждую плитку — слишком дорого для сетки.
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.20),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  height: AppLayout.gridThumbnailHeight,
                  width: double.infinity,
                  child: circular
                      ? Align(
                          alignment: Alignment.center,
                          child: SizedBox.square(
                            dimension: AppLayout.gridThumbnailHeight,
                            child: Artwork(
                              url: item.thumbnails.sized(
                                (AppLayout.gridThumbnailHeight * 2).round(),
                              ),
                              icon: icon,
                              radius: BorderRadius.circular(
                                AppLayout.gridThumbnailHeight / 2,
                              ),
                            ),
                          ),
                        )
                      : Artwork(
                          url: item.thumbnails.sized(
                            (AppLayout.gridThumbnailHeight * 2).round(),
                          ),
                          icon: icon,
                          radius: BorderRadius.circular(
                            AppLayout.gridThumbnailRadius,
                          ),
                        ),
                ),
                const SizedBox(height: 8),
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (subtitle != null && subtitle.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
