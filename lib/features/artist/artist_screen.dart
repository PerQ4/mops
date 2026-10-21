import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/local/blocked_artists.dart';
import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/catalog_providers.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/horizontal_list.dart';
import '../../widgets/async_views.dart';
import '../../widgets/media_card.dart';
import '../../widgets/track_tile.dart';
import '../album/media_hero.dart';
import '../common/navigation.dart';
import '../../widgets/empty_state.dart';
import 'artist_hero.dart';

/// Кнопка подписки на канал.
///
/// Подписка была только в слое данных и отдельной вкладкой в библиотеке —
/// подписаться из приложения было нельзя. Иконка показывает состояние
/// (колокольчик/активный колокольчик), нажатие меняет его сразу, а при ошибке
/// состояние откатывается и показывается сообщение.
class _SubscribeButton extends ConsumerWidget {
  const _SubscribeButton({required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );
    final bool subscribed = ref.watch(
      subscribedIdsProvider.select((Set<String> ids) => ids.contains(channelId)),
    );

    return HeroCircleButton(
      icon: subscribed ? Icons.notifications_active : Icons.notifications_none,
      tooltip: subscribed ? 'Отписаться' : 'Подписаться',
      size: 52,
      // Без входа подписываться некуда — как и лайк в меню трека.
      onPressed: !signedIn
          ? null
          : () async {
              try {
                await ref
                    .read(subscribedIdsProvider.notifier)
                    .toggle(channelId);
              } on Object catch (error) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(describeError(error))),
                  );
                }
              }
            },
    );
  }
}

/// Кнопка блокировки исполнителя.
///
/// Блокировка — локальная (в YouTube Music её нет), поэтому кнопка живёт на
/// странице исполнителя и в меню трека. Состояние берём из общего
/// [blockedArtistsProvider]: одно и то же на обоих входах.
class _BlockArtistButton extends ConsumerWidget {
  const _BlockArtistButton({required this.artistId, required this.artistName});

  final String artistId;
  final String artistName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool blocked = ref.watch(
      blockedArtistsProvider.select(
        (List<BlockedArtist> list) =>
            list.any((BlockedArtist item) => item.id == artistId),
      ),
    );

    return HeroCircleButton(
      icon: blocked ? Icons.person_add_alt_1_outlined : Icons.person_off_outlined,
      tooltip: blocked ? 'Разблокировать' : 'Заблокировать исполнителя',
      size: 52,
      onPressed: () => _toggleArtistBlock(
        context,
        ref,
        artistId: artistId,
        artistName: artistName,
        blocked: blocked,
      ),
    );
  }
}

/// Плашка на странице заблокированного исполнителя.
///
/// Страницу мы не прячем (см. `CatalogSource.artist`): именно отсюда
/// блокировку можно снять, и без плашки было бы непонятно, почему у
/// исполнителя «пропали» треки в остальном приложении.
class _BlockedBanner extends StatelessWidget {
  const _BlockedBanner({required this.onUnblock});

  final VoidCallback onUnblock;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.person_off_outlined, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Исполнитель заблокирован — его треки скрыты на главной, '
                'в поиске и плейлистах.',
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
            TextButton(
              onPressed: onUnblock,
              style: TextButton.styleFrom(
                foregroundColor: scheme.onErrorContainer,
              ),
              child: const Text('Разблокировать'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Меняет блокировку и сообщает результат.
///
/// Ошибку показываем, а не глотаем: пользователь нажал кнопку и должен
/// понимать, применилось ли решение.
Future<void> _toggleArtistBlock(
  BuildContext context,
  WidgetRef ref, {
  required String artistId,
  required String artistName,
  required bool blocked,
}) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  try {
    if (blocked) {
      await ref.read(blockedArtistsProvider.notifier).unblock(artistId);
    } else {
      await ref
          .read(blockedArtistsProvider.notifier)
          .block(id: artistId, name: artistName);
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          blocked
              ? 'Блокировка снята: $artistName'
              : 'Исполнитель заблокирован: $artistName',
        ),
      ),
    );
  } on Object {
    messenger.showSnackBar(
      const SnackBar(content: Text('Не удалось изменить блокировку.')),
    );
  }
}

/// Страница исполнителя: популярные треки, альбомы, синглы, похожие.
///
/// Форма — из `ArtistScreen.kt`: полноширинная обложка с градиентом и
/// прижатым к низу текстом, отдельный блок описания, затем секции в порядке
/// «популярные треки → альбомы → синглы → похожие». Горизонтальные ленты
/// собраны общим виджетом [HorizontalList], карточки — [BrowseItemCard].
class ArtistScreen extends ConsumerWidget {
  const ArtistScreen({super.key, required this.artistId});

  final String artistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<Artist> artist = ref.watch(artistProvider(artistId));

    return Scaffold(
      body: artist.when(
        data: (Artist data) => _ArtistBody(artist: data),
        loading: () => const ArtistDetailSkeleton(rows: 5),
        error: (Object error, StackTrace _) => Scaffold(
          appBar: AppBar(),
          body: ErrorState(
            message: describeError(error),
            onRetry: () => ref.invalidate(artistProvider(artistId)),
          ),
        ),
      ),
    );
  }
}

class _ArtistBody extends ConsumerWidget {
  const _ArtistBody({required this.artist});

  final Artist artist;

  /// Сколько популярных треков показываем в списке.
  ///
  /// В ArchiveTune секция отдаёт все треки, которые вернул YouTube (обычно
  /// пять). У нас `topTracks` собирается по всем «песенным» секциям и может
  /// быть длинным, поэтому список ограничен — иначе страница наполовину
  /// состоит из одного списка.
  static const int _topTracksLimit = 10;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? current = ref.watch(currentTrackProvider);
    final bool playing = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.isPlaying),
    );
    final bool blocked = ref.watch(
      blockedArtistsProvider.select(
        (List<BlockedArtist> list) =>
            list.any((BlockedArtist item) => item.id == artist.id),
      ),
    );

    final List<Track> top = artist.topTracks;
    final bool isCurrentArtist =
        current != null && top.any((Track t) => t.id == current.id);
    final bool hasTracks = top.isNotEmpty;

    // Строка «аудитории» — подписчики. Отдельных «слушателей за месяц» в
    // наших данных нет, поэтому показываем то, что отдал YouTube
    // (`Artist.subscribers`, он же подзаголовок страницы).
    final String? audience = artist.subscribers;
    final String catalog = artistCatalogLine(artist);

    final bool isEmpty = !hasTracks &&
        artist.albums.isEmpty &&
        artist.singles.isEmpty &&
        artist.related.isEmpty;

    final String? description = artist.description?.trim();

    return CustomScrollView(
      slivers: <Widget>[
        SliverAppBar(
          pinned: true,
          expandedHeight: AppLayout.appBarHeight,
          title: Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        SliverToBoxAdapter(
          child: ArtistHero(
            name: artist.name,
            // Крупная обложка: `ArtistHeroArtworkSizePx` = 1200
            // (ArtistScreen.kt:1152).
            imageUrl: artist.thumbnails.sized(1200),
            audience: audience,
            catalog: catalog,
            // Порядок действий как в ArchiveTune: перемешать, слушать,
            // добавить (`ArtistScreen.kt:504-585`, `MediaDetailHero.kt:341-409`).
            actions: <Widget>[
              HeroCircleButton(
                icon: Icons.shuffle,
                tooltip: 'Перемешать',
                size: 52,
                onPressed: hasTracks
                    ? () => ref
                        .read(playerControllerProvider.notifier)
                        .playQueue(top, shuffle: true)
                    : null,
              ),
              HeroPlayButton(
                label: isCurrentArtist && playing ? 'Пауза' : 'Слушать',
                icon: isCurrentArtist && playing
                    ? Icons.pause
                    : Icons.play_arrow,
                onPressed: !hasTracks
                    ? null
                    : () {
                        final PlayerController controller =
                            ref.read(playerControllerProvider.notifier);
                        if (isCurrentArtist && playing) {
                          controller.togglePlayPause();
                        } else {
                          controller.playQueue(top);
                        }
                      },
              ),
              HeroCircleButton(
                icon: Icons.playlist_add,
                tooltip: 'В очередь',
                size: 52,
                onPressed: hasTracks ? () => _enqueueAll(ref, top) : null,
              ),
              // Подписка на канал — как кнопка «Подписаться» в YouTube Music.
              _SubscribeButton(channelId: artist.id),
              _BlockArtistButton(
                artistId: artist.id,
                artistName: artist.name,
              ),
            ],
          ),
        ),
        if (blocked)
          SliverToBoxAdapter(
            child: _BlockedBanner(
              onUnblock: () => _toggleArtistBlock(
                context,
                ref,
                artistId: artist.id,
                artistName: artist.name,
                blocked: true,
              ),
            ),
          ),
        // Описание — отдельным блоком под шапкой, а не внутри неё
        // (ArtistScreen.kt:590-617).
        if (description != null && description.isNotEmpty)
          SliverToBoxAdapter(child: ArtistDescription(text: description)),
        if (hasTracks) ...<Widget>[
          const SliverToBoxAdapter(child: _SectionTitle('Популярные треки')),
          SliverList.builder(
            itemCount: top.length > _topTracksLimit
                ? _topTracksLimit
                : top.length,
            itemBuilder: (BuildContext context, int index) {
              final Track track = top[index];
              final bool isCurrent = current?.id == track.id;
              // Обложка вместо номера и меню «…» справа — как `YouTubeListItem`
              // в секции популярных треков (ArtistScreen.kt:815-871).
              return TrackTile(
                track: track,
                isCurrent: isCurrent,
                isPlaying: isCurrent && playing,
                // Подпись — только исполнители и длительность, без альбома:
                // так её собирает `joinByBullet(artists, duration)`.
                subtitleOverride: track.artistLine,
                onTap: () => ref
                    .read(playerControllerProvider.notifier)
                    .playTrack(track, context: top),
              );
            },
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
        ],
        if (artist.albums.isNotEmpty)
          SliverToBoxAdapter(
            child: _CardRow(title: 'Альбомы', albums: artist.albums),
          ),
        if (artist.singles.isNotEmpty)
          SliverToBoxAdapter(
            child: _CardRow(title: 'Синглы и мини-альбомы', albums: artist.singles),
          ),
        if (artist.related.isNotEmpty)
          SliverToBoxAdapter(
            child: _ArtistRow(title: 'Похожие исполнители', artists: artist.related),
          ),
        if (isEmpty)
          const SliverToBoxAdapter(
            child: SizedBox(
              height: 320,
              child: EmptyState(
                icon: Icons.person_outline,
                title: 'Ничего не найдено',
                subtitle:
                    'YouTube Music не вернул треки и альбомы этого исполнителя.',
              ),
            ),
          ),
        const SliverToBoxAdapter(
          // Отступ снизу под плавающий островок плеера.
          child: SizedBox(height: AppLayout.floatingDockClearance),
        ),
      ],
    );
  }

  /// Кладёт популярные треки в конец очереди.
  void _enqueueAll(WidgetRef ref, List<Track> tracks) {
    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);
    for (final Track track in tracks) {
      controller.enqueue(track);
    }
  }
}

/// Заголовок секции в стиле `NavigationTitle` из ArchiveTune.
///
/// `titleLarge`, полужирный, цвет `primary`, отступы 12/12
/// (`NavigationTitle.kt:43-76`).
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

/// Размер обложки в горизонтальной ленте — `GridThumbnailHeight` из
/// `Dimensions.kt:39` (128), как у `GridItem` (`Items.kt:285`).
const double _gridArtworkSize = AppLayout.gridThumbnailHeight;

/// Высота ленты альбомов: обложка 128 плюс две строки подписи (заголовок и
/// год/исполнители) — с запасом, чтобы длинная подпись не обрезалась.
const double _cardRowHeight = _gridArtworkSize + 72;

/// Высота ленты исполнителей: у круглого аватара подписи нет, поэтому ниже.
const double _artistRowHeight = _gridArtworkSize + 48;

/// Горизонтальная лента альбомов или синглов.
///
/// Параметры ленты — из `ArtistScreen.kt:877-879`: отступ по краям 12,
/// зазор между элементами 4. Ширина карточки — `GridThumbnailHeight` (128),
/// как у `GridItem` в `Items.kt:285`.
class _CardRow extends StatelessWidget {
  const _CardRow({required this.title, required this.albums});

  final String title;
  final List<Album> albums;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionTitle(title),
        HorizontalList(
          height: _cardRowHeight,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          separator: 4,
          itemCount: albums.length,
          itemBuilder: (BuildContext context, int index) {
            final Album album = albums[index];
            return BrowseItemCard(
              item: AlbumItem(album),
              width: _gridArtworkSize,
              onTap: (BrowseItem _) => AppRoutes.album(context, album.id),
            );
          },
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

/// Горизонтальная лента исполнителей.
class _ArtistRow extends StatelessWidget {
  const _ArtistRow({required this.title, required this.artists});

  final String title;
  final List<Artist> artists;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionTitle(title),
        HorizontalList(
          height: _artistRowHeight,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          separator: 4,
          itemCount: artists.length,
          itemBuilder: (BuildContext context, int index) {
            final Artist artist = artists[index];
            return BrowseItemCard(
              item: ArtistItem(artist),
              width: _gridArtworkSize,
              onTap: (BrowseItem _) => AppRoutes.artist(context, artist.id),
            );
          },
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
