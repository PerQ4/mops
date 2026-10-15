import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/horizontal_list.dart';
import '../../widgets/async_views.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/section_list.dart';
import '../../widgets/track_tile.dart';
import '../common/navigation.dart';
import 'library_spotlight_tile.dart';

/// Личная коллекция: чипы-фильтры и содержимое выбранного раздела.
///
/// Форма из ArchiveTune: сверху ряд капсул-фильтров, ниже — содержимое. Вместо
/// `TabBar`, как было раньше, потому что на широком экране капсулы читаются
/// лучше и не растягиваются на всю ширину.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  LibraryFilter _filter = LibraryFilter.all;

  @override
  Widget build(BuildContext context) {
    final AuthState auth = ref.watch(authControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Коллекция'),
        actions: <Widget>[
          IconButton(
            tooltip: auth.isSignedIn ? 'Аккаунт' : 'Войти',
            icon: Icon(
              auth.isSignedIn
                  ? Icons.account_circle_outlined
                  : Icons.login_outlined,
            ),
            onPressed: () => AppRoutes.account(context),
          ),
          // На широком экране настройки живут в боковой навигации.
          if (context.isCompactLayout)
            IconButton(
              tooltip: 'Настройки',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => AppRoutes.settings(context),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: auth.isSignedIn
          ? Column(
              children: <Widget>[
                _FilterChips(
                  selected: _filter,
                  onSelected: (LibraryFilter filter) =>
                      setState(() => _filter = filter),
                ),
                Expanded(child: _body()),
              ],
            )
          : _SignInPrompt(),
    );
  }

  Widget _body() {
    return switch (_filter) {
      LibraryFilter.all => const _LibraryOverview(),
      LibraryFilter.liked => const _SongsTab(),
      LibraryFilter.playlists => const _PlaylistsGrid(),
      LibraryFilter.songs => const _LibrarySongsTab(),
      LibraryFilter.artists => const _ArtistsGrid(),
      LibraryFilter.albums => const _AlbumsGrid(),
      LibraryFilter.subscriptions => const _SubscriptionsGrid(),
    };
  }
}

/// Разделы библиотеки — они же чипы-фильтры.
///
/// «Подписки» оставлены отдельным чипом: без него раздел потерялся бы, хотя
/// в списке из задания его нет.
///
/// «Мне нравится» — отдельный чип, хотя раньше лайкнутые треки прятались под
/// «Треками»: YouTube Music различает их (лайкнутая музыка и сохранённые
/// треки), и без своего раздела лайкнутый плейлист было не найти.
enum LibraryFilter {
  all('Библиотека', Icons.library_music_outlined),
  liked('Мне нравится', Icons.favorite_outline),
  playlists('Плейлисты', Icons.queue_music),
  songs('Треки', Icons.music_note_outlined),
  artists('Исполнители', Icons.person_outline),
  albums('Альбомы', Icons.album_outlined),
  subscriptions('Подписки', Icons.subscriptions_outlined);

  const LibraryFilter(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Ряд капсул-фильтров.
///
/// В ArchiveTune это `LazyRow` с отступом 24 по краям, шагом 12 между чипами и
/// вертикальным отступом 8 (LibraryScreen.kt:332-341). Высота чипа — 40
/// (иконка 20 + отступ 10×2), поэтому ряд занимает 56.
class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.selected, required this.onSelected});

  final LibraryFilter selected;
  final ValueChanged<LibraryFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    return HorizontalList(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      showScrollbar: false,
      separator: 12,
      itemCount: LibraryFilter.values.length,
      itemBuilder: (BuildContext context, int index) {
        final LibraryFilter filter = LibraryFilter.values[index];
        return _FilterCapsule(
          filter: filter,
          selected: filter == selected,
          onTap: () => onSelected(filter),
        );
      },
    );
  }
}

/// Капсула-фильтр в стиле `ExpressiveTabChip` (LibraryScreen.kt:540-617):
/// выбранная — заливка `primary` с текстом `onPrimary`, невыбранная —
/// `surfaceContainerHighest` α0.5 (роль `surfaceVariant` устарела во Flutter)
/// с текстом `onSurfaceVariant`. Выбранная слегка увеличена (1.05), при нажатии
/// сжимается (0.92).
class _FilterCapsule extends StatefulWidget {
  const _FilterCapsule({
    required this.filter,
    required this.selected,
    required this.onTap,
  });

  final LibraryFilter filter;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_FilterCapsule> createState() => _FilterCapsuleState();
}

class _FilterCapsuleState extends State<_FilterCapsule> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color background = widget.selected
        ? scheme.primary
        : scheme.surfaceContainerHighest.withValues(alpha: 0.5);
    final Color foreground =
        widget.selected ? scheme.onPrimary : scheme.onSurfaceVariant;
    final double scale = _pressed ? 0.92 : (widget.selected ? 1.05 : 1.0);

    return AnimatedScale(
      scale: scale,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      child: Material(
        color: background,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          onHighlightChanged: (bool value) => setState(() => _pressed = value),
          child: Padding(
            // Отступы капсулы: 18 по горизонтали, 10 по вертикали.
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(widget.filter.icon, size: 20, color: foreground),
                const SizedBox(width: 8),
                Text(
                  widget.filter.label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        color: foreground,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Сводный раздел «Библиотека»: плейлисты, исполнители и подписки подряд.
class _LibraryOverview extends ConsumerWidget {
  const _LibraryOverview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Playlist>> playlists = ref.watch(likedPlaylistsProvider);
    final AsyncValue<List<Artist>> artists = ref.watch(libraryArtistsProvider);
    final AsyncValue<List<Artist>> subs = ref.watch(subscriptionsProvider);
    final AsyncValue<List<Track>> songs = ref.watch(likedSongsProvider);

    final List<BrowseItem> playlistItems =
        (playlists.value ?? const <Playlist>[])
            .map<BrowseItem>(PlaylistItem.new)
            .toList();
    final List<BrowseItem> artistItems = (artists.value ?? const <Artist>[])
        .map<BrowseItem>(ArtistItem.new)
        .toList();
    final List<BrowseItem> subItems = (subs.value ?? const <Artist>[])
        .map<BrowseItem>(ArtistItem.new)
        .toList();
    final List<Track> songItems = songs.value ?? const <Track>[];

    final bool nothingYet = playlistItems.isEmpty &&
        artistItems.isEmpty &&
        subItems.isEmpty &&
        songItems.isEmpty;
    final bool anyLoading =
        playlists.isLoading || artists.isLoading || subs.isLoading || songs.isLoading;
    final Object? error =
        playlists.error ?? artists.error ?? subs.error ?? songs.error;

    if (anyLoading && nothingYet) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null && nothingYet) {
      return ErrorState(
        message: describeError(error),
        onRetry: () {
          ref.invalidate(likedPlaylistsProvider);
          ref.invalidate(libraryArtistsProvider);
          ref.invalidate(subscriptionsProvider);
          ref.invalidate(likedSongsProvider);
        },
      );
    }
    if (nothingYet) {
      return const EmptyState(
        icon: Icons.library_music_outlined,
        title: 'Коллекция пуста',
        subtitle: 'Сохраняйте треки и плейлисты в YouTube Music — они появятся '
            'здесь.',
      );
    }

    return CustomScrollView(
      slivers: <Widget>[
        if (songItems.isNotEmpty) ...<Widget>[
          const SliverToBoxAdapter(child: _GridHeader('Мне нравится')),
          SliverList.builder(
            itemCount: songItems.length > 5 ? 5 : songItems.length,
            itemBuilder: (BuildContext context, int index) {
              final Track track = songItems[index];
              return TrackTile(
                track: track,
                onTap: () => ref
                    .read(playerControllerProvider.notifier)
                    .playTrack(track, context: songItems),
              );
            },
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
        ],
        ..._gridSection(context, title: 'Плейлисты', items: playlistItems),
        ..._gridSection(context, title: 'Исполнители', items: artistItems),
        ..._gridSection(context, title: 'Подписки', items: subItems),
        const SliverToBoxAdapter(
          child: SizedBox(height: AppLayout.floatingDockClearance),
        ),
      ],
    );
  }
}

class _PlaylistsGrid extends ConsumerWidget {
  const _PlaylistsGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Playlist>> playlists =
        ref.watch(likedPlaylistsProvider);

    return playlists.when(
      data: (List<Playlist> data) => _TileGrid(
        items: data.map<BrowseItem>(PlaylistItem.new).toList(),
        emptyIcon: Icons.queue_music,
        emptyTitle: 'Плейлистов нет',
        emptySubtitle: 'Создайте плейлист в YouTube Music — он появится здесь.',
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace _) => ErrorState(
        message: describeError(error),
        onRetry: () => ref.invalidate(likedPlaylistsProvider),
      ),
    );
  }
}

class _ArtistsGrid extends ConsumerWidget {
  const _ArtistsGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Artist>> artists = ref.watch(libraryArtistsProvider);

    return artists.when(
      data: (List<Artist> data) => _TileGrid(
        items: data.map<BrowseItem>(ArtistItem.new).toList(),
        emptyIcon: Icons.person_outline,
        emptyTitle: 'Исполнителей нет',
        emptySubtitle: 'Подпишитесь на исполнителей в YouTube Music.',
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace _) => ErrorState(
        message: describeError(error),
        onRetry: () => ref.invalidate(libraryArtistsProvider),
      ),
    );
  }
}

class _SubscriptionsGrid extends ConsumerWidget {
  const _SubscriptionsGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Artist>> subs = ref.watch(subscriptionsProvider);

    return subs.when(
      data: (List<Artist> data) => _TileGrid(
        items: data.map<BrowseItem>(ArtistItem.new).toList(),
        emptyIcon: Icons.person_outline,
        emptyTitle: 'Подписок нет',
        emptySubtitle: 'Подпишитесь на исполнителей в YouTube Music.',
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace _) => ErrorState(
        message: describeError(error),
        onRetry: () => ref.invalidate(subscriptionsProvider),
      ),
    );
  }
}

class _AlbumsGrid extends ConsumerWidget {
  const _AlbumsGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Album>> albums = ref.watch(_libraryAlbumsProvider);

    return albums.when(
      data: (List<Album> data) => _TileGrid(
        items: data.map<BrowseItem>(AlbumItem.new).toList(),
        emptyIcon: Icons.album_outlined,
        emptyTitle: 'Альбомов нет',
        emptySubtitle: 'Альбомы собираются из сохранённых треков.',
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace _) => ErrorState(
        message: describeError(error),
        onRetry: () => ref.invalidate(_libraryAlbumsProvider),
      ),
    );
  }
}

/// Альбомы, собранные из сохранённых треков.
///
/// Отдельного источника альбомов библиотеки нет, но данные о них уже есть в
/// треках (`album.id`, `album.name` и обложка). Группируем — так фильтр
/// «Альбомы» показывает реально сохранённое, без нового запроса и без выдумки.
final FutureProvider<List<Album>> _libraryAlbumsProvider =
    FutureProvider<List<Album>>((ref) async {
  final List<Track> tracks = await ref.watch(librarySongsProvider.future);

  final Map<String, List<Track>> grouped = <String, List<Track>>{};
  for (final Track track in tracks) {
    final String? id = track.album?.id;
    if (id == null || id.isEmpty) continue;
    grouped.putIfAbsent(id, () => <Track>[]).add(track);
  }

  return grouped.entries.map((MapEntry<String, List<Track>> entry) {
    final Track first = entry.value.first;
    return Album(
      id: entry.key,
      title: first.album?.name ?? first.title,
      artists: first.artists,
      thumbnails: first.thumbnails,
      tracks: entry.value,
      trackCount: entry.value.length,
    );
  }).toList();
});

class _SongsTab extends ConsumerWidget {
  const _SongsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Track>> songs = ref.watch(likedSongsProvider);

    return songs.when(
      data: (List<Track> data) {
        if (data.isEmpty) {
          return const EmptyState(
            icon: Icons.favorite_border,
            title: 'Лайков нет',
            subtitle: 'Отмечайте треки лайком — они соберутся здесь.',
          );
        }
        return TrackListView(
          tracks: data,
          header: _PlayAllHeader(tracks: data, title: 'Мне нравится'),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace _) => ErrorState(
        message: describeError(error),
        onRetry: () => ref.invalidate(likedSongsProvider),
      ),
    );
  }
}

/// Сохранённые треки — раздел «Треки» библиотеки YouTube Music.
///
/// Это не то же самое, что «Мне нравится»: сюда попадают треки, сохранённые
/// в библиотеку (`FEmusic_liked_videos`). Раньше «Треки» показывали лайкнутое
/// и дублировали «Мне нравится»; теперь у разделов разные источники.
class _LibrarySongsTab extends ConsumerWidget {
  const _LibrarySongsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Track>> songs = ref.watch(librarySongsProvider);

    return songs.when(
      data: (List<Track> data) {
        if (data.isEmpty) {
          return const EmptyState(
            icon: Icons.music_note_outlined,
            title: 'Сохранённых треков нет',
            subtitle: 'Добавляйте треки в библиотеку YouTube Music — они '
                'появятся здесь.',
          );
        }
        return TrackListView(
          tracks: data,
          header: _PlayAllHeader(tracks: data, title: 'Треки'),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace _) => ErrorState(
        message: describeError(error),
        onRetry: () => ref.invalidate(librarySongsProvider),
      ),
    );
  }
}

/// Приглашение войти — вместо пустой коллекции.
class _SignInPrompt extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.library_music_outlined,
      title: 'Коллекция пуста',
      subtitle: 'Войдите в аккаунт YouTube Music, чтобы видеть свои плейлисты, '
          'лайки и подписки.',
      action: FilledButton.icon(
        onPressed: () => AppRoutes.account(context),
        icon: const Icon(Icons.login),
        label: const Text('Войти'),
      ),
    );
  }
}

/// Сетка плиток: общий шаблон для плейлистов, альбомов и исполнителей.
class _TileGrid extends StatelessWidget {
  const _TileGrid({
    required this.items,
    required this.emptyTitle,
    this.emptyIcon = Icons.inbox_outlined,
    this.emptySubtitle,
  });

  final List<BrowseItem> items;
  final IconData emptyIcon;
  final String emptyTitle;
  final String? emptySubtitle;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return EmptyState(
        icon: emptyIcon,
        title: emptyTitle,
        subtitle: emptySubtitle,
      );
    }

    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          // Отступ сетки — 24 по краям, как в ArchiveTune (LibraryPlaylistsScreen.kt:463-465).
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          sliver: SliverGrid(
            gridDelegate: _libraryGridDelegate,
            delegate: SliverChildBuilderDelegate(
              (BuildContext context, int index) => LibrarySpotlightTile(
                item: items[index],
                onTap: () => _openItem(context, items[index]),
              ),
              childCount: items.length,
            ),
          ),
        ),
        const SliverToBoxAdapter(
          child: SizedBox(height: AppLayout.floatingDockClearance),
        ),
      ],
    );
  }
}

/// Сетка библиотеки: колонок становится больше с ростом ширины окна.
///
/// `mainAxisExtent` задан явно: высота плитки не зависит от ширины колонки,
/// поэтому сетка не «дёргается».
const SliverGridDelegateWithMaxCrossAxisExtent _libraryGridDelegate =
    SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 200,
  mainAxisExtent: 200,
  crossAxisSpacing: 16,
  mainAxisSpacing: 16,
);

/// Секция сводного раздела: заголовок и сетка плиток.
List<Widget> _gridSection(
  BuildContext context, {
  required String title,
  required List<BrowseItem> items,
}) {
  if (items.isEmpty) return const <Widget>[];
  return <Widget>[
    SliverToBoxAdapter(child: _GridHeader(title)),
    SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      sliver: SliverGrid(
        gridDelegate: _libraryGridDelegate,
        delegate: SliverChildBuilderDelegate(
          (BuildContext context, int index) => LibrarySpotlightTile(
            item: items[index],
            onTap: () => _openItem(context, items[index]),
          ),
          childCount: items.length,
        ),
      ),
    ),
    const SliverToBoxAdapter(child: SizedBox(height: 24)),
  ];
}

class _GridHeader extends StatelessWidget {
  const _GridHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    // Заголовок секции сводной библиотеки — как в `LibraryMixScreen`
    // (LibraryMixScreen.kt:325-330): `titleMedium` полужирный, цвет
    // поверхности, отступы 24/8.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface,
            ),
      ),
    );
  }
}

/// Открывает элемент библиотеки.
void _openItem(BuildContext context, BrowseItem item) {
  switch (item) {
    case AlbumItem(:final Album album):
      AppRoutes.album(context, album.id);
    case ArtistItem(:final Artist artist):
      AppRoutes.artist(context, artist.id);
    case PlaylistItem(:final Playlist playlist):
      AppRoutes.playlist(context, playlist.id);
    case TrackItem():
      // В сетках библиотеки треков нет — отдельные треки живут во вкладке
      // «Треки», поэтому открывать здесь нечего.
      break;
  }
}

/// Шапка списка с кнопкой «слушать всё».
class _PlayAllHeader extends ConsumerWidget {
  const _PlayAllHeader({required this.tracks, required this.title});

  final List<Track> tracks;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
            ),
          ),
          // Кнопка «слушать всё» — как в ArchiveTune: заливка `primary`,
          // иконка 16, подпись `labelMedium` полужирная (LibrarySongsScreen.kt:382-411).
          FilledButton.icon(
            style: FilledButton.styleFrom(
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            onPressed: () => ref
                .read(playerControllerProvider.notifier)
                .playQueue(tracks, shuffle: true),
            icon: const Icon(Icons.shuffle, size: 16),
            label: const Text(
              'Слушать',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
