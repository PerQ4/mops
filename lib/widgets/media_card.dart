import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/layout.dart';
import '../data/models/models.dart';
import 'artist_line.dart';
import 'artwork.dart';
import 'entity_menu.dart';
import 'track_menu.dart';

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
    this.onPlay,
    this.subtitleArtists,
    this.onSecondaryTap,
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

  /// Исполнители подписи: если заданы, подпись собирается из них и каждое
  /// имя ведёт на свою страницу, как в строке трека и в очереди.
  final List<ArtistRef>? subtitleArtists;

  /// Открыть страницу — нажатие на подпись под обложкой.
  final VoidCallback onTap;

  /// Запустить воспроизведение — нажатие на обложку.
  ///
  /// Если не задано, обложка ведёт себя как подпись: так карточки, у которых
  /// «запускать» нечего (например, исполнители в поиске), ничего не теряют.
  final VoidCallback? onPlay;

  /// Контекстное меню — правый клик по карточке.
  ///
  /// Сама карточка не знает, что за сущность показывает; действие задаёт
  /// [BrowseItemCard]. Нажатия и свайпы не затрагиваются: жест только
  /// вторичный. Позиция нужна для [showMenu]: меню открывается у курсора, а не
  /// шторкой снизу.
  final void Function(Offset globalPosition)? onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double art = artworkSize ?? width;
    final VoidCallback artworkTap = onPlay ?? onTap;

    // Две зоны нажатия вместо одной: обложка запускает, подпись открывает
    // страницу. Раньше нажатие в любом месте открывало страницу, и запустить
    // карточку из ленты было нельзя.
    final Widget card = SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          InkWell(
            onTap: artworkTap,
            borderRadius: BorderRadius.circular(
              circular ? art / 2 : AppLayout.gridThumbnailRadius,
            ),
            child: Stack(
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
                    child: Center(child: _PlayBadge(onTap: artworkTap)),
                  ),
              ],
            ),
          ),
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppLayout.radiusS),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // Зазор до заголовка — 6, как `Spacer(height = 6.dp)`
                // в `GridItem`.
                const SizedBox(height: 6),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (subtitleArtists != null || 
                    (subtitle != null && subtitle!.isNotEmpty)) ...<Widget>[
                  const SizedBox(height: 2),
                  if (subtitleArtists != null)
                    ArtistLine(
                      artists: subtitleArtists!,
                      maxLines: 2,
                      style: text.bodyMedium?.copyWith(color: scheme.secondary),
                    )
                  else
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
        ],
      ),
    );

    // Обёртка нужна только ради вторичного жеста: обычные нажатия она не
    // перехватывает и в арене распознавателей не участвует.
    if (onSecondaryTap == null) return card;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // `onSecondaryTapUp`, а не `onSecondaryTap`: нужна точка нажатия,
      // чтобы поставить меню у курсора.
      onSecondaryTapUp: (TapUpDetails details) =>
          onSecondaryTap!(details.globalPosition),
      child: card,
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
class BrowseItemCard extends ConsumerWidget {
  const BrowseItemCard({
    super.key,
    required this.item,
    required this.onTap,
    this.onPlay,
    this.width = AppLayout.cardWidth,
  });

  final BrowseItem item;
  final double width;

  /// Открыть страницу — нажатие на подпись.
  final void Function(BrowseItem item) onTap;

  /// Запустить — нажатие на обложку. Если не задано, обложка открывает
  /// страницу, как и подпись.
  final void Function(BrowseItem item)? onPlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Вместе с подписью достаём и исполнителей: у трека подпись собирается
    // из них, чтобы каждое имя вело на свою страницу.
    final (String? subtitle, bool circular, IconData icon, List<ArtistRef>?)
        info = switch (item) {
      TrackItem(:final Track track) => (
          track.artistLine,
          false,
          Icons.music_note,
          track.artists,
        ),
      AlbumItem(:final Album album) => (
          album.year ?? album.artistLine,
          false,
          Icons.album_outlined,
          null,
        ),
      ArtistItem() => (null, true, Icons.person_outline, null),
      PlaylistItem(:final Playlist playlist) => (
          playlist.author,
          false,
          Icons.queue_music,
          null,
        ),
    };
    final (String? subtitle, bool circular, IconData icon,
        List<ArtistRef>? subtitleArtists) = info;

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
      // видеоклипы.
      showPlay: isPlayableItem(item),
      // У трека в подписи — исполнители-ссылки, а не готовая строка.
      subtitleArtists: subtitleArtists,
      onTap: () => onTap(item),
      onPlay: onPlay == null ? null : () => onPlay!(item),
      // Меню по правой кнопке — у каждой сущности своё: у трека уже есть
      // готовая шторка с обложкой, у остальных действия живут кнопками в
      // шапках страниц, и карточка повторяет их у курсора.
      onSecondaryTap: _secondaryTap(context, ref),
    );
  }

  /// Обработчик правого клика для текущего элемента.
  ///
  /// Возвращает `null`, если показывать нечего: так карточка не перехватывает
  /// вторичный жест впустую.
  void Function(Offset globalPosition)? _secondaryTap(
    BuildContext context,
    WidgetRef ref,
  ) {
    switch (item) {
      case TrackItem(:final Track track):
        return (Offset _) => unawaited(showTrackMenu(context, track));
      case AlbumItem(:final Album album):
        return (Offset position) =>
            unawaited(showAlbumMenu(context, ref, album, position: position));
      case ArtistItem(:final Artist artist):
        return (Offset position) =>
            unawaited(showArtistMenu(context, ref, artist, position: position));
      case PlaylistItem(:final Playlist playlist):
        // Клип YouTube Music приходит плейлистом без id: страницы и очереди у
        // него нет, а играется он как трек (см. `playBrowseItem`). Для такого
        // элемента честнее меню трека, чем пустое меню плейлиста.
        final String? videoId = playlist.id.isEmpty
            ? videoIdFromThumbnails(playlist.thumbnails)
            : null;
        if (videoId != null) {
          return (Offset _) => unawaited(
                showTrackMenu(
                  context,
                  Track(
                    id: videoId,
                    title: playlist.title,
                    thumbnails: playlist.thumbnails,
                  ),
                ),
              );
        }
        if (playlist.id.isEmpty) return null;
        return (Offset position) => unawaited(
              showPlaylistMenu(context, ref, playlist, position: position),
            );
    }
  }
}
