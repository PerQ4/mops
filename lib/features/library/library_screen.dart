import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
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
      LibraryFilter.playlists => const _PlaylistsGrid(),
      LibraryFilter.songs => const _SongsTab(),
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
enum LibraryFilter {
  all('Библиотека', Icons.library_music_outlined),
  playlists('Плейлисты', Icons.queue_music),
  songs('Треки', Icons.music_note_outlined),
  artists('Исполнители', Icons.person_outline),
  albums('Альбомы', Icons.album_outlined),
  subscriptions('Подписки', Icons.subscriptions_outlined);

  const LibraryFilter(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Ряд капсул-фильтров. Высота капсулы — 48, как в спецификации.
class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.selected, required this.onSelected});

  final LibraryFilter selected;
  final ValueChanged<LibraryFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // 48 (капсула) + 8×2 (отступы) = 64.
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: LibraryFilter.values.length,
        separatorBuilder: (BuildContext context, int _) =>
            const SizedBox(width: 8),
        itemBuilder: (BuildContext context, int index) {
          final LibraryFilter filter = LibraryFilter.values[index];
          return _FilterCapsule(
            filter: filter,
            selected: filter == selected,
            onTap: () => onSelected(filter),
          );
        },
      ),
    );
  }
}

class _FilterCapsule extends StatelessWidget {
  const _FilterCapsule({
    required this.filter,
    required this.selected,
    required this.onTap,
  });

  final LibraryFilter filter;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color foreground =
        selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;

    return Material(
      color: selected
          ? scheme.secondaryContainer.withValues(alpha: 0.94)
          : scheme.surfaceContainerHigh.withValues(alpha: 0.78),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(selected ? Icons.check : filter.icon, size: 18, color: foreground),
              const SizedBox(width: 8),
              Text(
                filter.label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: foreground,
                    ),
              ),
            ],
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
          padding: const EdgeInsets.fromLTRB(
            AppLayout.gutter,
            16,
            AppLayout.gutter,
            0,
          ),
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
  crossAxisSpacing: 12,
  mainAxisSpacing: 12,
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
      padding: const EdgeInsets.symmetric(horizontal: AppLayout.gutter),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppLayout.gutter,
        20,
        AppLayout.gutter,
        12,
      ),
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .titleLarge
            ?.copyWith(fontWeight: FontWeight.w600),
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
    final TextTheme text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: () => ref
                .read(playerControllerProvider.notifier)
                .playQueue(tracks, shuffle: true),
            icon: const Icon(Icons.shuffle),
            label: const Text('Слушать'),
          ),
        ],
      ),
    );
  }
}
