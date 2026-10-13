import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/async_views.dart';
import '../../widgets/media_card.dart';
import '../../widgets/section_list.dart';
import '../common/navigation.dart';

/// Личная коллекция: плейлисты, лайки, исполнители и подписки.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AuthState auth = ref.watch(authControllerProvider);

    return DefaultTabController(
      length: 4,
      child: Scaffold(
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
            IconButton(
              tooltip: 'Настройки',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => AppRoutes.settings(context),
            ),
            const SizedBox(width: 4),
          ],
          bottom: auth.isSignedIn
              ? const TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: <Widget>[
                    Tab(text: 'Плейлисты'),
                    Tab(text: 'Треки'),
                    Tab(text: 'Исполнители'),
                    Tab(text: 'Подписки'),
                  ],
                )
              : null,
        ),
        body: auth.isSignedIn
            ? const TabBarView(
                children: <Widget>[
                  _PlaylistsTab(),
                  _SongsTab(),
                  _ArtistsTab(),
                  _SubscriptionsTab(),
                ],
              )
            : _SignInPrompt(),
      ),
    );
  }
}

/// Приглашение войти — вместо пустых вкладок.
class _SignInPrompt extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return EmptyView(
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

// --------------------------------------------------------------- вкладки

class _PlaylistsTab extends ConsumerWidget {
  const _PlaylistsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Playlist>> playlists =
        ref.watch(likedPlaylistsProvider);

    return playlists.when(
      data: (List<Playlist> data) {
        if (data.isEmpty) {
          return const EmptyView(
            icon: Icons.queue_music,
            title: 'Плейлистов нет',
            subtitle: 'Создайте плейлист в YouTube Music — он появится здесь.',
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220,
            childAspectRatio: 0.72,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: data.length,
          itemBuilder: (BuildContext context, int index) {
            final Playlist playlist = data[index];
            return BrowseItemCard(
              item: PlaylistItem(playlist),
              width: 200,
              onTap: (BrowseItem _) =>
                  AppRoutes.playlist(context, playlist.id),
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace _) => ErrorView(
        error: error,
        onRetry: () => ref.invalidate(likedPlaylistsProvider),
      ),
    );
  }
}

class _SongsTab extends ConsumerWidget {
  const _SongsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Track>> songs = ref.watch(likedSongsProvider);

    return songs.when(
      data: (List<Track> data) {
        if (data.isEmpty) {
          return const EmptyView(
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
      error: (Object error, StackTrace _) => ErrorView(
        error: error,
        onRetry: () => ref.invalidate(likedSongsProvider),
      ),
    );
  }
}

class _ArtistsTab extends ConsumerWidget {
  const _ArtistsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Artist>> artists = ref.watch(libraryArtistsProvider);

    return artists.when(
      data: (List<Artist> data) => _ArtistGrid(artists: data, emptyTitle: 'Исполнителей нет'),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace _) => ErrorView(
        error: error,
        onRetry: () => ref.invalidate(libraryArtistsProvider),
      ),
    );
  }
}

class _SubscriptionsTab extends ConsumerWidget {
  const _SubscriptionsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Artist>> subs = ref.watch(subscriptionsProvider);

    return subs.when(
      data: (List<Artist> data) => _ArtistGrid(artists: data, emptyTitle: 'Подписок нет'),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace _) => ErrorView(
        error: error,
        onRetry: () => ref.invalidate(subscriptionsProvider),
      ),
    );
  }
}

class _ArtistGrid extends StatelessWidget {
  const _ArtistGrid({required this.artists, required this.emptyTitle});

  final List<Artist> artists;
  final String emptyTitle;

  @override
  Widget build(BuildContext context) {
    if (artists.isEmpty) {
      return EmptyView(
        icon: Icons.person_outline,
        title: emptyTitle,
        subtitle: 'Подпишитесь на исполнителей в YouTube Music.',
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        childAspectRatio: 0.68,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: artists.length,
      itemBuilder: (BuildContext context, int index) {
        final Artist artist = artists[index];
        return BrowseItemCard(
          item: ArtistItem(artist),
          width: 180,
          onTap: (BrowseItem _) => AppRoutes.artist(context, artist.id),
        );
      },
    );
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
