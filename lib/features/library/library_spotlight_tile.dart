import 'package:flutter/material.dart';

import '../../core/theme/layout.dart';
import '../../data/models/models.dart';
import '../../widgets/artwork.dart';

/// Плитка-подборка библиотеки.
///
/// Форма из ArchiveTune: фон `surfaceContainerLow`, крупное скругление 32,
/// отступ 12, обложка со скруглением 26 и **квадратная** (`aspectRatio(1f)`,
/// `LibraryPlaylistsScreen.kt:863-868`). Заголовок — `labelLarge` полужирный,
/// подпись — `bodySmall` приглушённая (PlaylistGridCard,
/// `LibraryPlaylistsScreen.kt:933-944`).
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
                // Обложка квадратная: в `PlaylistGridCard` это
                // `Box(fillMaxWidth().aspectRatio(1f))` — так плитка совпадает
                // по форме с обложкой и не превращается в прямоугольник на
                // широкой ячейке.
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final double side = constraints.maxWidth;
                    if (circular) {
                      // Круглый аватар ограничен размером сетки — иначе на
                      // широком окне он раздувался бы вместе с ячейкой.
                      final double avatar = side < AppLayout.gridThumbnailHeight
                          ? side
                          : AppLayout.gridThumbnailHeight;
                      return SizedBox.square(
                        dimension: side,
                        child: Center(
                          child: SizedBox.square(
                            dimension: avatar,
                            child: Artwork(
                              url: item.thumbnails.sized((avatar * 2).round()),
                              icon: icon,
                              radius: BorderRadius.circular(avatar / 2),
                            ),
                          ),
                        ),
                      );
                    }
                    return AspectRatio(
                      aspectRatio: 1,
                      child: Artwork(
                        url: item.thumbnails.sized((side * 2).round()),
                        icon: icon,
                        radius: BorderRadius.circular(thumbnailRadius),
                      ),
                    );
                  },
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
