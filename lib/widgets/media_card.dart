import 'package:flutter/material.dart';

import '../core/theme/layout.dart';
import '../data/models/models.dart';
import 'artwork.dart';

/// videoId, спрятанный в адресе обложки (`i.ytimg.com/vi/<id>/…`).
///
/// Нужен как обходной путь: видеоклипы YouTube Music приходят как
/// `musicTwoRowItemRenderer` со ссылкой `watchEndpoint`, а разбор пока
/// относит их к плейлистам и теряет идентификатор. Обложка — единственное
/// место, где он сохранился, поэтому по ней и восстанавливаем.
final RegExp _videoIdInUrl = RegExp(r'/vi/([A-Za-z0-9_-]{11})/');

String? videoIdFromThumbnails(List<Thumbnail> thumbnails) {
  for (final Thumbnail thumb in thumbnails) {
    final RegExpMatch? match = _videoIdInUrl.firstMatch(thumb.url);
    if (match != null) return match.group(1);
  }
  return null;
}

/// Элемент, который на самом деле играется (трек или восстановленный клип).
bool isPlayableItem(BrowseItem item) => switch (item) {
      TrackItem() => true,
      PlaylistItem(:final Playlist playlist) => playlist.id.isEmpty &&
          videoIdFromThumbnails(playlist.thumbnails) != null,
      _ => false,
    };

/// Карточка карусели: обложка, заголовок, подпись.
///
/// Размеры фиксированы константами, поэтому карточки не меняют высоту от
/// текста и карусель не «дёргается» при прокрутке. Форма — из спецификации
/// ArchiveTune: обложка с радиусом 8, заголовок `bodyLarge` bold в одну
/// строку, подпись `bodyMedium` до двух строк.
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
    this.showPlay = false,
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

  /// Показывать на обложке кнопку play — для карточек, которые играют.
  final bool showPlay;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double art = artworkSize ?? width;

    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppLayout.radiusM),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Stack(
              children: <Widget>[
                Artwork(
                  url: imageUrl,
                  size: art,
                  icon: icon,
                  heroTag: heroTag,
                  radius: BorderRadius.circular(
                    circular ? art / 2 : AppLayout.gridThumbnailRadius,
                  ),
                ),
                if (showPlay)
                  // Кнопка play по центру обложки — как `OverlayPlayButton`
                  // в `SongGridItem`.
                  Positioned.fill(
                    child: Center(child: _PlayBadge(onTap: onTap)),
                  ),
              ],
            ),
            // Зазор до заголовка — 6, как `Spacer(height = 6.dp)` в `GridItem`.
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium?.copyWith(color: scheme.secondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Кнопка play на обложке: круг 36, фон `black` α0.6, значок 20.
///
/// Числа — из `OverlayPlayButton` (Items.kt): `size(36.dp)`, чёрный фон с
/// альфой `ActiveBoxAlpha` = 0.6, значок `size(20.dp)` цвета `Color.White`.
/// Нужна, чтобы карточку-трек было видно как «играющую», а не как ссылку
/// на страницу: нажатие в любом месте всё равно запускает воспроизведение.
class _PlayBadge extends StatelessWidget {
  const _PlayBadge({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.6),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: const SizedBox(
          width: 36,
          height: 36,
          child: Icon(Icons.play_arrow_rounded, size: 20, color: Colors.white),
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

    // Круглый аватар не должен быть шире карточки — иначе обрезка по краям.
    final double? avatarSize = circular
        ? (width < AppLayout.artistAvatar ? width : AppLayout.artistAvatar)
        : null;

    return MediaCard(
      title: item.title,
      subtitle: subtitle,
      imageUrl: item.thumbnails.sized((width * 2).round()),
      width: width,
      circular: circular,
      artworkSize: avatarSize,
      icon: icon,
      // Кнопка play — у всего, что реально играется: треки и восстановленные
      // видеоклипы. Альбом/плейлист/исполнитель открывают свою страницу.
      showPlay: isPlayableItem(item),
      onTap: () => onTap(item),
    );
  }
}
