import 'package:flutter/material.dart';

import '../../core/theme/layout.dart';
import '../../data/models/models.dart';
import '../../widgets/artwork.dart';

/// Плитка-подборка библиотеки.
///
/// Форма из ArchiveTune: фон `surfaceContainerLow`, крупное скругление 32,
/// отступ 12, обложка со скруглением 26. Заголовок — `labelLarge` полужирный,
/// подпись — `bodySmall` приглушённая (PlaylistGridCard,
/// `LibraryPlaylistsScreen.kt:823-945`; `GridItem`,
/// `ui/component/Items.kt:312-346`).
class LibrarySpotlightTile extends StatelessWidget {
  const LibrarySpotlightTile({
    super.key,
    required this.item,
    required this.onTap,
  });

  final BrowseItem item;
  final VoidCallback onTap;

  /// Радиус плитки — 32, обложки — 26 (как у карточек-подборок в спецификации).
  static const double radius = 32;
  static const double thumbnailRadius = 26;

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
        // Тени нет: плитка отделяется от фона только тональным цветом.
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
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
                          radius: BorderRadius.circular(thumbnailRadius),
                        ),
                ),
                const SizedBox(height: 8),
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (subtitle != null && subtitle.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.6),
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
