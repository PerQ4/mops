import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/layout.dart';
import '../data/models/models.dart';
import '../features/common/navigation.dart';
import '../state/catalog_providers.dart';
import '../state/player_controller.dart';
import 'artwork.dart';
import 'horizontal_list.dart';
import 'media_card.dart';
import 'track_menu.dart';
import 'track_tile.dart';

/// Запускает элемент карусели — нажатие на обложку.
///
/// Трек играет сразу; альбом, плейлист и исполнитель — целиком, для чего их
/// треки подтягиваются по сети. Открытие страницы — это [openBrowseItem],
/// его вызывает нажатие на подпись под обложкой.
Future<void> playBrowseItem(
  BuildContext context,
  WidgetRef ref,
  BrowseItem item, {
  List<Track>? playContext,
}) async {
  final PlayerController controller =
      ref.read(playerControllerProvider.notifier);

  switch (item) {
    case TrackItem(:final Track track):
      controller.playTrack(track, context: playContext);

    case AlbumItem(:final Album album):
      final Album full = await ref.read(albumProvider(album.id).future);
      if (full.tracks.isNotEmpty) controller.playQueue(full.tracks);

    case PlaylistItem(:final Playlist playlist):
      // Видеоклипы YouTube Music приходят как `musicTwoRowItemRenderer`
      // со ссылкой `watchEndpoint`. Разбор пока относит их к плейлистам и
      // теряет videoId — получается плейлист с пустым id, поэтому достаём
      // идентификатор из адреса обложки и играем как трек.
      final String? videoId = playlist.id.isEmpty
          ? videoIdFromThumbnails(playlist.thumbnails)
          : null;
      if (videoId != null) {
        controller.playTrack(
          Track(
            id: videoId,
            title: playlist.title,
            thumbnails: playlist.thumbnails,
          ),
        );
      } else if (playlist.id.isNotEmpty) {
        final Playlist full =
            await ref.read(playlistProvider(playlist.id).future);
        if (full.tracks.isNotEmpty) controller.playQueue(full.tracks);
      }

    case ArtistItem(:final Artist artist):
      final Artist full = await ref.read(artistProvider(artist.id).future);
      // У исполнителя играем верхние треки — как кнопка на его странице.
      if (full.topTracks.isNotEmpty) controller.playQueue(full.topTracks);
  }
}

/// Открывает страницу элемента — нажатие на подпись под обложкой.
void openBrowseItem(
  BuildContext context,
  WidgetRef ref,
  BrowseItem item,
) {
  switch (item) {
    case TrackItem(:final Track track):
      // Нажатие на подпись карточки трека ведёт на страницу альбома (сингл —
      // та же страница альбома). Раньше подпись запускала трек: альбом и
      // исполнитель были доступны только из меню «…».
      final AlbumRef? album = track.album;
      if (album != null && album.isNavigable) {
        AppRoutes.album(context, album.id!);
      } else {
        // Альбома нет — тогда, как и раньше, запускаем трек.
        ref.read(playerControllerProvider.notifier).playTrack(track);
      }
    case AlbumItem(:final Album album):
      AppRoutes.album(context, album.id);
    case ArtistItem(:final Artist artist):
      AppRoutes.artist(context, artist.id);
    case PlaylistItem(:final Playlist playlist):
      // Пустой id при живом videoId — это видеоклип, страницы у него нет.
      if (playlist.id.isNotEmpty &&
          videoIdFromThumbnails(playlist.thumbnails) == null) {
        AppRoutes.playlist(context, playlist.id);
      }
  }
}

/// Все треки внутри одной секции — контекст воспроизведения.
List<Track> tracksOf(BrowseSection section) => section.items
    .whereType<TrackItem>()
    .map((TrackItem item) => item.track)
    .toList();

/// Список секций главной и подобных страниц.
///
/// Форма взята у ArchiveTune: секция с треками показывается **обычным
/// списком**, а не каруселью карточек — так треки читаются и не «дёргаются».
/// Карусель остаётся только для альбомов, исполнителей и плейлистов, где
/// важна обложка.
class SectionListView extends ConsumerWidget {
  const SectionListView({
    super.key,
    required this.sections,
    this.padding = const EdgeInsets.only(bottom: 24),
    this.header,
    this.footer,
    this.emptyPlaceholder,
    this.trackPreviewLimit = 5,
  });

  final List<BrowseSection> sections;
  final EdgeInsets padding;
  final Widget? header;

  /// Нижний элемент списка — например, индикатор догрузки. В оригинале
  /// (`HomeScreen.kt:637-653`) он добавлен последним элементом ленты с
  /// отступом 32, а не плавает поверх содержимого.
  final Widget? footer;
  final Widget? emptyPlaceholder;

  /// Сколько треков показывать в секции до кнопки «Все».
  final int trackPreviewLimit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (sections.isEmpty) {
      return emptyPlaceholder ?? const SizedBox.shrink();
    }

    // Плоский список без подписей (результаты поиска) показываем без «шапок»,
    // чтобы не плодить лишние заголовки.
    final bool flat = sections.length == 1 && sections.first.title.isEmpty;

    return ContentWidth(
      child: ListView.builder(
      // Отступ снизу под плавающий островок: содержимое по-прежнему уходит
      // под него, но последние строки можно доскроллить выше.
      padding: padding.copyWith(
        bottom: padding.bottom + AppLayout.floatingDockClearance,
      ),
      itemCount: sections.length +
          (header != null ? 1 : 0) +
          (footer != null ? 1 : 0),
      itemBuilder: (BuildContext context, int index) {
        if (header != null) {
          if (index == 0) return header!;
          index -= 1;
        }
        // Нижний элемент идёт после всех секций.
        if (footer != null && index == sections.length) return footer!;

        final BrowseSection section = sections[index];
        return flat
            ? _TrackRows(section: section, showTitle: false)
            : _Section(section: section, trackPreviewLimit: trackPreviewLimit);
      },
      ),
    );
  }
}

/// Одна секция: либо список треков, либо карусель карточек.
class _Section extends ConsumerWidget {
  const _Section({required this.section, required this.trackPreviewLimit});

  final BrowseSection section;
  final int trackPreviewLimit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Track> tracks = tracksOf(section);
    final bool isTrackSection = tracks.isNotEmpty && tracks.length == section.items.length;

    final Widget body = isTrackSection
        ? _TrackRows(section: section, limit: trackPreviewLimit)
        : _CardCarousel(section: section);

    // Промежуток между секциями — 18 по спецификации. Отступ снизу, а не
    // сверху: так у последней секции не остаётся «висящей» пустоты сверху.
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: body,
    );
  }
}

/// Заголовок секции в стиле ArchiveTune — `HomeSectionHeader`.
///
/// Высота ≥64, отступ 16 по горизонтали и 8 по вертикали, строки в колонке
/// прижаты к центру. Название — `titleLarge` semibold цвета `onSurface`,
/// надпись-ярлык — `labelLarge` цвета `onSurfaceVariant`. Кнопка «Слушать все»
/// (`OutlinedButton`, ≥40 в высоту и ≥88 в ширину) показывается только там,
/// где есть продолжение.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.label, this.onShowAll});

  final String title;

  /// Вторая, мелкая строка над названием (`section.label` в оригинале).
  final String? label;
  final VoidCallback? onShowAll;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (label != null && label!.isNotEmpty)
                    Text(
                      label!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
            if (onShowAll != null) ...<Widget>[
              const SizedBox(width: 12),
              // В оригинале это `OutlinedButton` с `heightIn(min = 40.dp)` и
              // `widthIn(min = 88.dp)` и текстом `play_all` = «Прослушать все».
              OutlinedButton(
                onPressed: onShowAll,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(88, 40),
                ),
                child: const Text('Прослушать все'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Секция треков обычным списком.
class _TrackRows extends ConsumerWidget {
  const _TrackRows({
    required this.section,
    this.limit,
    this.showTitle = true,
  });

  final BrowseSection section;
  final int? limit;
  final bool showTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Track> tracks = tracksOf(section);
    if (tracks.isEmpty) return const SizedBox.shrink();

    final int shown = limit == null ? tracks.length : tracks.length.clamp(0, limit!);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (showTitle && section.title.isNotEmpty)
          _SectionTitle(
            title: section.title,
            label: section.subtitle,
            onShowAll: tracks.length > shown
                ? () => ref
                    .read(playerControllerProvider.notifier)
                    .playQueue(tracks, shuffle: true)
                : null,
          ),
        for (int i = 0; i < shown; i++)
          TrackTile(
            track: tracks[i],
            onTap: () => ref
                .read(playerControllerProvider.notifier)
                .playTrack(tracks[i], context: tracks),
          ),
      ],
    );
  }
}

/// Карусель карточек: альбомы, исполнители, плейлисты.
class _CardCarousel extends ConsumerWidget {
  const _CardCarousel({required this.section});

  final BrowseSection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Обложка карточки — 128 по сетке спецификации. Круглым аватарам тоже
    // хватает 128: карточка шире не нужна, подписи у них в одну строку.
    const double cardWidth = AppLayout.gridThumbnailHeight;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (section.title.isNotEmpty)
          _SectionTitle(title: section.title, label: section.subtitle),
        HorizontalList(
          // Высота зафиксирована константой — карусель не «прыгает». Разбор
          // высоты `GridItem` (Items.kt:274-310): внешний отступ 12 + обложка
          // 128 + зазор 6 + заголовок `bodyLarge` (24) + зазор 2 + подпись
          // `bodyMedium` в две строки (40) + внешний отступ 12 = 224, то есть
          // `cardWidth + 96`.
          height: cardWidth + 96,
          // Отступ края 12 и зазор 24 — это внешний `padding(12.dp)` у
          // каждого `GridItem` в оригинале (12 слева + 12 справа между
          // карточками). Заголовок секции при этом стоит на 16.
          padding: const EdgeInsets.symmetric(horizontal: 12),
          separator: 24,
          itemCount: section.items.length,
          itemBuilder: (BuildContext context, int index) {
            final BrowseItem item = section.items[index];
            final Widget card = BrowseItemCard(
              item: item,
              width: cardWidth,
              // У исполнителя обложка открывает его страницу, а не играет:
              // в ArchiveTune карточка исполнителя — это ссылка, а не запуск.
              onPlay: item is ArtistItem
                  ? null
                  : (BrowseItem value) => playBrowseItem(
                        context,
                        ref,
                        value,
                        playContext: tracksOf(section),
                      ),
              onTap: (BrowseItem value) => openBrowseItem(context, ref, value),
            );
            // У карточек треков долгое нажатие открывает то же меню, что и
            // строка списка: иначе из карусели меню не вызвать вовсе.
            if (item is TrackItem) {
              return GestureDetector(
                onLongPress: () => showTrackMenu(context, item.track),
                child: card,
              );
            }
            return card;
          },
        ),
      ],
    );
  }
}

/// Список треков одной страницы (альбом, плейлист, лайки).
class TrackListView extends ConsumerWidget {
  const TrackListView({
    super.key,
    required this.tracks,
    this.padding = const EdgeInsets.only(bottom: 24),
    this.header,
    this.playContext,
    this.showNumbers = false,
  });

  final List<Track> tracks;
  final EdgeInsets padding;
  final Widget? header;
  final List<Track>? playContext;
  final bool showNumbers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Следим только за тем, что влияет на вид строки. Позиция
    // воспроизведения меняется несколько раз в секунду — если смотреть и на
    // неё, весь список перестраивался бы на каждом тике.
    final (String? currentId, bool isPlaying) = ref.watch(
      playerControllerProvider.select(
        (PlayerUiState s) => (s.current?.id, s.isPlaying),
      ),
    );
    final List<Track> queue = playContext ?? tracks;

    return ContentWidth(
      child: ListView.builder(
      // Отступ снизу под плавающий островок.
      padding: padding.copyWith(
        bottom: padding.bottom + AppLayout.floatingDockClearance,
      ),
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
          leadingNumber: showNumbers ? index + 1 : null,
          isCurrent: isCurrent,
          isPlaying: isCurrent && isPlaying,
          onTap: () => ref
              .read(playerControllerProvider.notifier)
              .playTrack(track, context: queue),
        );
      },
      ),
    );
  }
}

/// Шапка страницы альбома, плейлиста или исполнителя.
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
    final double width = context.layoutWidth;
    final bool wide = AppLayout.isExpanded(width);
    const double size = AppLayout.headerArtwork;

    final Widget artwork = Artwork(
      url: imageUrl,
      size: size,
      icon: fallbackIcon,
      radius: BorderRadius.circular(circular ? size / 2 : AppLayout.radiusL),
    );

    final Widget info = Column(
      crossAxisAlignment:
          wide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          title,
          textAlign: wide ? TextAlign.start : TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: text.displaySmall?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -1,
          ),
        ),
        if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            subtitle!,
            textAlign: wide ? TextAlign.start : TextAlign.center,
            style: text.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        if (description != null && description!.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            description!.trim(),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: wide ? TextAlign.start : TextAlign.center,
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        if (actions.isNotEmpty) ...<Widget>[
          const SizedBox(height: 18),
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
      padding: const EdgeInsets.fromLTRB(
        AppLayout.gutter,
        8,
        AppLayout.gutter,
        8,
      ),
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
                const SizedBox(height: 18),
                info,
              ],
            ),
    );
  }
}
