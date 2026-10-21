import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/local/playlist_tags.dart';
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
import '../playlist/playlist_screen.dart';
import '../podcast/podcast_library_section.dart';
import 'library_empty_state.dart';
import 'library_spotlight_tile.dart';
import 'local_files_section.dart';

/// Личная коллекция: чипы-фильтры и содержимое выбранного раздела.
///
/// Форма из ArchiveTune: сверху капсулы-фильтры, ниже — содержимое. Вместо
/// `TabBar`, как было раньше, потому что капсулы читаются лучше и не
/// растягиваются на всю ширину. Капсулы переносятся по строкам: все разделы
/// видны сразу, без горизонтальной прокрутки.
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
      body: auth.isSignedIn ||
              _filter == LibraryFilter.localFiles ||
              // Обзор подкастов в YouTube Music публичный: гость тоже может
              // открыть шоу и послушать выпуск. Подписки появятся после входа.
              _filter == LibraryFilter.podcasts
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
          : Column(
              children: <Widget>[
                // Чипы видны и без входа: «Локальные файлы» — единственный
                // раздел коллекции, который работает без аккаунта. Прятать
                // весь ряд значило бы сделать локальную музыку недоступной.
                _FilterChips(
                  selected: _filter,
                  onSelected: (LibraryFilter filter) =>
                      setState(() => _filter = filter),
                ),
                Expanded(child: _SignInPrompt()),
              ],
            ),
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
      LibraryFilter.podcasts => const PodcastLibrarySection(),
      LibraryFilter.localFiles => const LocalFilesSection(),
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
///
/// Значки — как в `LibraryScreen.kt:358-367`: у корневого раздела
/// `graphic_eq`, у остальных — залитые `music_note`, `person`, `album`,
/// `queue_music`. У «Подписок» и «Мне нравится» в оригинале отдельных чипов
/// нет, поэтому значки подобраны в том же залитом стиле.
enum LibraryFilter {
  all('Библиотека', Icons.graphic_eq),
  liked('Мне нравится', Icons.favorite),
  playlists('Плейлисты', Icons.queue_music),
  songs('Треки', Icons.music_note),
  artists('Исполнители', Icons.person),
  albums('Альбомы', Icons.album),
  subscriptions('Подписки', Icons.subscriptions),
  podcasts('Подкасты', Icons.podcasts),
  localFiles('Локальные файлы', Icons.folder_outlined);

  const LibraryFilter(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Ряд капсул-фильтров, который переносится по строкам.
///
/// В ArchiveTune это `LazyRow` с горизонтальной прокруткой
/// (LibraryScreen.kt:332-341). На десктопе у ряда не было полосы прокрутки, и
/// на узком окне половина разделов просто пряталась за краем. `Wrap` держит
/// весь набор на виду: число строк меняется, состав — нет.
class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.selected, required this.onSelected});

  final LibraryFilter selected;
  final ValueChanged<LibraryFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // На узком окне значки отнимают у подписей больше места, чем дают
        // подсказки: без них тот же набор укладывается в меньшее число строк.
        final bool showIcons = constraints.maxWidth >= AppLayout.compactMax;
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final LibraryFilter filter in LibraryFilter.values)
                _FilterCapsule(
                  filter: filter,
                  selected: filter == selected,
                  showIcon: showIcons,
                  onTap: () => onSelected(filter),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Капсула-фильтр в стиле `ExpressiveTabChip` (LibraryScreen.kt:540-617):
/// выбранная — заливка `primary` с текстом `onPrimary`, невыбранная —
/// `surfaceContainerHighest` α0.5 (роль `surfaceVariant` устарела во Flutter)
/// с текстом `onSurfaceVariant`.
class _FilterCapsule extends StatelessWidget {
  const _FilterCapsule({
    required this.filter,
    required this.selected,
    required this.onTap,
    this.showIcon = true,
  });

  final LibraryFilter filter;
  final bool selected;
  final VoidCallback onTap;

  /// Значок можно скрыть: на узком окне подпись важнее картинки.
  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color background = selected
        ? scheme.primary
        : scheme.surfaceContainerHighest.withValues(alpha: 0.5);
    final Color foreground = selected
        ? scheme.onPrimary
        : scheme.onSurfaceVariant;

    return Material(
      color: background,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: showIcon ? 12 : 14,
            vertical: 8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (showIcon) ...<Widget>[
                Icon(filter.icon, size: 18, color: foreground),
                const SizedBox(width: 6),
              ],
              Text(
                filter.label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
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
    final AsyncValue<List<Playlist>> playlists = ref.watch(
      likedPlaylistsProvider,
    );
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

    final bool nothingYet =
        playlistItems.isEmpty &&
        artistItems.isEmpty &&
        subItems.isEmpty &&
        songItems.isEmpty;
    final bool anyLoading =
        playlists.isLoading ||
        artists.isLoading ||
        subs.isLoading ||
        songs.isLoading;
    final Object? error =
        playlists.error ?? artists.error ?? subs.error ?? songs.error;

    if (anyLoading && nothingYet) {
      return const _LibraryGridSkeleton();
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
        subtitle:
            'Сохраняйте треки и плейлисты в YouTube Music — они появятся '
            'здесь.',
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final SliverGridDelegate delegate = _libraryGridDelegate(
          constraints.maxWidth,
        );
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
            ..._gridSection(
              context,
              title: 'Плейлисты',
              items: playlistItems,
              delegate: delegate,
            ),
            ..._gridSection(
              context,
              title: 'Исполнители',
              items: artistItems,
              delegate: delegate,
            ),
            ..._gridSection(
              context,
              title: 'Подписки',
              items: subItems,
              delegate: delegate,
            ),
            const SliverToBoxAdapter(
              child: SizedBox(height: AppLayout.floatingDockClearance),
            ),
          ],
        );
      },
    );
  }
}

class _PlaylistsGrid extends ConsumerStatefulWidget {
  const _PlaylistsGrid();

  @override
  ConsumerState<_PlaylistsGrid> createState() => _PlaylistsGridState();
}

class _PlaylistsGridState extends ConsumerState<_PlaylistsGrid> {
  /// Выбранный тег-фильтр; `null` — показывать все плейлисты.
  String? _tag;

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Playlist>> playlists = ref.watch(
      likedPlaylistsProvider,
    );
    final Map<String, Set<String>> tags = ref.watch(playlistTagsProvider);
    final List<String> allTags = ref.watch(playlistTagsListProvider);

    return playlists.when(
      data: (List<Playlist> data) {
        // Снятый с последнего плейлиста тег исчезает из списка чипов — тогда
        // фильтр по нему пришлось бы сбрасывать только вручную, а показывать
        // было бы нечего. Считаем его снятым сразу.
        final String? selected =
            _tag != null && allTags.contains(_tag) ? _tag : null;
        final List<Playlist> visible = selected == null
            ? data
            : data
                .where(
                  (Playlist p) => tags[p.id]?.contains(selected) ?? false,
                )
                .toList();

        return Column(
          children: <Widget>[
            if (allTags.isNotEmpty)
              _TagFilterChips(
                tags: allTags,
                selected: selected,
                onSelected: (String? tag) => setState(() => _tag = tag),
              ),
            Expanded(
              child: _TileGrid(
                items: visible.map<BrowseItem>(PlaylistItem.new).toList(),
                emptyIcon: Icons.playlist_add,
                emptyTitle: selected == null
                    ? 'Плейлистов нет'
                    : 'С этим тегом плейлистов нет',
                onItemLongPress: (BrowseItem item) {
                  // У плитки библиотеки нет данных о владении плейлистом,
                  // поэтому правимость лист определит сам (всё, кроме «Мне
                  // нравится»), а чужой плейлист сервер честно отклонит.
                  if (item is PlaylistItem) {
                    showPlaylistActionsSheet(context, item.playlist);
                  }
                },
                itemOverlay: (BuildContext context, BrowseItem item) {
                  if (item is! PlaylistItem) return null;
                  return _TagButton(
                    playlist: item.playlist,
                    hasTags:
                        (tags[item.playlist.id] ?? const <String>{}).isNotEmpty,
                  );
                },
              ),
            ),
          ],
        );
      },
      loading: () => const _LibraryGridSkeleton(),
      error: (Object error, StackTrace _) => ErrorState(
        message: describeError(error),
        onRetry: () => ref.invalidate(likedPlaylistsProvider),
      ),
    );
  }
}

/// Ряд чипов-фильтров по тегам над сеткой плейлистов.
///
/// Первый чип — «Все»: без него снять фильтр можно было бы только выбором
/// другого тега, а вернуться к полному списку было бы нечем.
class _TagFilterChips extends StatelessWidget {
  const _TagFilterChips({
    required this.tags,
    required this.selected,
    required this.onSelected,
  });

  final List<String> tags;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return HorizontalList(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      showScrollbar: false,
      separator: 8,
      itemCount: tags.length + 1,
      itemBuilder: (BuildContext context, int index) {
        if (index == 0) {
          return _TagCapsule(
            label: 'Все',
            selected: selected == null,
            onTap: () => onSelected(null),
          );
        }
        final String tag = tags[index - 1];
        return _TagCapsule(
          label: tag,
          selected: tag == selected,
          onTap: () => onSelected(tag),
        );
      },
    );
  }
}

/// Капсула тега — та же форма, что у чипов разделов, но без значка: тегов
/// может быть много, и значок у каждого только мешал бы.
class _TagCapsule extends StatelessWidget {
  const _TagCapsule({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color background = selected
        ? scheme.secondaryContainer
        : scheme.surfaceContainerHighest.withValues(alpha: 0.5);
    final Color foreground = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;

    return Material(
      color: background,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: foreground,
            ),
          ),
        ),
      ),
    );
  }
}

/// Кнопка тегов в углу плитки плейлиста.
///
/// Залитая метка — у плейлиста есть теги, контурная — ещё нет: так видно, где
/// разметка уже сделана, не открывая диалог.
class _TagButton extends StatelessWidget {
  const _TagButton({required this.playlist, required this.hasTags});

  final Playlist playlist;
  final bool hasTags;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface.withValues(alpha: 0.9),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        tooltip: hasTags ? 'Теги плейлиста' : 'Назначить теги',
        iconSize: 18,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 34, height: 34),
        icon: Icon(hasTags ? Icons.label : Icons.label_outline),
        onPressed: () => showPlaylistTagsDialog(context, playlist),
      ),
    );
  }
}

/// Диалог назначения тегов плейлисту.
///
/// Показывает и уже назначенные теги, и все прочие: тег можно переиспользовать
/// одним нажатием, а не набирать заново. Теги локальные — в YouTube Music их
/// нет, поэтому диалог меняет только локальное хранилище.
Future<void> showPlaylistTagsDialog(
  BuildContext context,
  Playlist playlist,
) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _PlaylistTagsDialog(playlist: playlist),
  );
}

class _PlaylistTagsDialog extends ConsumerStatefulWidget {
  const _PlaylistTagsDialog({required this.playlist});

  final Playlist playlist;

  @override
  ConsumerState<_PlaylistTagsDialog> createState() =>
      _PlaylistTagsDialogState();
}

class _PlaylistTagsDialogState extends ConsumerState<_PlaylistTagsDialog> {
  final TextEditingController _field = TextEditingController();

  /// Выбранные теги. Заполняется из хранилища при первом кадре, дальше набор
  /// правит пользователь: подмешивать состояние провайдера нельзя — иначе
  /// каждое нажатие чипа «откатывалось» бы сохранённым значением.
  Set<String>? _selected;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, Set<String>> byPlaylist =
        ref.watch(playlistTagsProvider);
    final List<String> known = ref.watch(playlistTagsListProvider);
    final Set<String> selected =
        _selected ??= <String>{...?byPlaylist[widget.playlist.id]};

    final List<String> shown = <String>{...known, ...selected}.toList()..sort();

    return AlertDialog(
      title: Text(
        widget.playlist.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (shown.isEmpty)
              Text(
                'Тегов пока нет — добавьте первый.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final String tag in shown)
                    FilterChip(
                      label: Text(tag),
                      selected: selected.contains(tag),
                      onSelected: (bool value) => setState(() {
                        if (value) {
                          selected.add(tag);
                        } else {
                          selected.remove(tag);
                        }
                      }),
                    ),
                ],
              ),
            const SizedBox(height: 16),
            TextField(
              controller: _field,
              decoration: const InputDecoration(
                labelText: 'Новый тег',
                isDense: true,
              ),
              onSubmitted: _addTag,
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }

  /// Добавляет набранный тег в набор. Пустой ввод молча игнорируется — это не
  /// ошибка, а незаконченный ввод.
  void _addTag(String raw) {
    final String? tag = normalizePlaylistTag(raw);
    if (tag == null) return;
    setState(() {
      _selected = <String>{...?_selected, tag};
      _field.clear();
    });
  }

  Future<void> _save() async {
    await ref
        .read(playlistTagsProvider.notifier)
        .setTags(widget.playlist.id, _selected ?? const <String>{});
    if (!mounted) return;
    Navigator.pop(context);
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
        emptyIcon: Icons.person,
        emptyTitle: 'Исполнителей нет',
      ),
      loading: () => const _LibraryGridSkeleton(),
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
        emptyIcon: Icons.person,
        emptyTitle: 'Подписок нет',
      ),
      loading: () => const _LibraryGridSkeleton(),
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
        emptyIcon: Icons.album,
        emptyTitle: 'Альбомов нет',
      ),
      loading: () => const _LibraryGridSkeleton(),
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
          return const _LibraryEmptyPane(
            icon: Icons.favorite,
            title: 'Лайков нет',
          );
        }
        return TrackListView(
          tracks: data,
          header: _PlayAllHeader(tracks: data, title: 'Мне нравится'),
        );
      },
      loading: () => const _LibraryListSkeleton(),
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
          return const _LibraryEmptyPane(
            icon: Icons.music_note,
            title: 'Сохранённых треков нет',
          );
        }
        return TrackListView(
          tracks: data,
          header: _PlayAllHeader(tracks: data, title: 'Треки'),
        );
      },
      loading: () => const _LibraryListSkeleton(),
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
      subtitle:
          'Войдите в аккаунт YouTube Music, чтобы видеть свои плейлисты, '
          'лайки и подписки.',
      action: FilledButton.icon(
        onPressed: () => AppRoutes.account(context),
        icon: const Icon(Icons.login),
        label: const Text('Войти'),
      ),
    );
  }
}

/// Пустая вкладка библиотеки: карточка `LibraryEmptyState` с боковыми
/// отступами 24 — как пустой список в ArchiveTune, где карточка встроена
/// прямо в прокручиваемое содержимое раздела.
class _LibraryEmptyPane extends StatelessWidget {
  const _LibraryEmptyPane({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        24,
        16,
        24,
        AppLayout.floatingDockClearance,
      ),
      children: <Widget>[LibraryEmptyState(title: title, icon: icon)],
    );
  }
}

/// Скелетон сетки библиотеки: карточки-заглушки того же размера, что и
/// настоящие плитки, поэтому при загрузке сетка не «прыгает».
///
/// Форма плитки — `GridItemPlaceHolder` (shimmer/GridItemPlaceholder.kt):
/// отступ 12, квадратная обложка, затем подписи. Сетка — общий делегат
/// [_libraryGridDelegate], чтобы заглушка совпадала с содержимым.
/// Цвет — как у остальных скелетонов приложения: `surfaceContainerHighest`,
/// без анимации «шиммера» (media_hero.dart:270-274).
class _LibraryGridSkeleton extends StatelessWidget {
  const _LibraryGridSkeleton();

  /// Сколько плиток-заглушек показать — примерно столько помещается на
  /// первом экране desktop-раскладки.
  static const int tiles = 8;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(
            24,
            16,
            24,
            AppLayout.floatingDockClearance,
          ),
          gridDelegate: _libraryGridDelegate(constraints.maxWidth),
          itemCount: tiles,
          itemBuilder: (BuildContext context, int index) => Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(32),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                AspectRatio(
                  aspectRatio: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const _SkeletonBar(widthFactor: 0.7, height: 16),
                const SizedBox(height: 2),
                const _SkeletonBar(widthFactor: 0.45, height: 12),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Скелетон списка треков библиотеки — форма `ListItemPlaceHolder`
/// (shimmer/ListItemPlaceholder.kt): строка 72, обложка 56 радиус 10 и две
/// строки-заглушки.
class _LibraryListSkeleton extends StatelessWidget {
  const _LibraryListSkeleton();

  /// Сколько строк-заглушек показать.
  static const int rows = 8;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        8,
        8,
        8,
        AppLayout.floatingDockClearance,
      ),
      itemCount: rows,
      itemBuilder: (BuildContext context, int index) => SizedBox(
        height: AppLayout.trackRowHeight,
        child: Row(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(8),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(
                    AppLayout.thumbnailRadius,
                  ),
                ),
                child: const SizedBox(
                  width: AppLayout.trackArtwork,
                  height: AppLayout.trackArtwork,
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const <Widget>[
                    _SkeletonBar(widthFactor: 0.6, height: 16),
                    SizedBox(height: 8),
                    _SkeletonBar(widthFactor: 0.35, height: 12),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Одна полоса-заглушка скелетона.
class _SkeletonBar extends StatelessWidget {
  const _SkeletonBar({required this.widthFactor, required this.height});

  final double widthFactor;
  final double height;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
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
    this.onItemLongPress,
    this.itemOverlay,
  });

  final List<BrowseItem> items;
  final IconData emptyIcon;
  final String emptyTitle;

  /// Действие долгого нажатия на плитку (если у раздела оно есть).
  final ValueChanged<BrowseItem>? onItemLongPress;

  /// Значок в углу плитки (если у раздела он есть). Возвращает `null`, когда
  /// элементу накладывать нечего, — тогда плитка остаётся без наложения.
  final Widget? Function(BuildContext context, BrowseItem item)? itemOverlay;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      // Пустая коллекция — карточка `LibraryEmptyState`, как в ArchiveTune
      // (`LibraryPlaylistsScreen.kt:468-479`), а не заглушка на всю страницу.
      return _LibraryEmptyPane(icon: emptyIcon, title: emptyTitle);
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return CustomScrollView(
          slivers: <Widget>[
            SliverPadding(
              // Отступ сетки — 24 по краям, как в ArchiveTune
              // (LibraryPlaylistsScreen.kt:463-465).
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              sliver: SliverGrid(
                gridDelegate: _libraryGridDelegate(constraints.maxWidth),
                delegate: SliverChildBuilderDelegate(
                  (BuildContext context, int index) {
                    final Widget tile = LibrarySpotlightTile(
                      item: items[index],
                      onTap: () => _openItem(context, items[index]),
                    );
                    final Widget? overlay =
                        itemOverlay?.call(context, items[index]);
                    return GestureDetector(
                      onLongPress: onItemLongPress == null
                          ? null
                          : () => onItemLongPress!(items[index]),
                      child: overlay == null
                          ? tile
                          : Stack(
                              children: <Widget>[
                                tile,
                                Positioned(top: 8, right: 8, child: overlay),
                              ],
                            ),
                    );
                  },
                  childCount: items.length,
                ),
              ),
            ),
            const SliverToBoxAdapter(
              child: SizedBox(height: AppLayout.floatingDockClearance),
            ),
          ],
        );
      },
    );
  }
}

/// Сетка библиотеки: колонок становится больше с ростом ширины окна.
///
/// Высота ячейки вычисляется из её ширины, а не задана константой: обложка
/// внутри плитки квадратная (`aspectRatio(1f)` в `PlaylistGridCard`,
/// `LibraryPlaylistsScreen.kt:863-868`). Фиксированный `mainAxisExtent`
/// обрезал бы обложку на широкой ячейке или оставлял пустоту на узкой.
/// Значение зависит только от ширины окна, поэтому при прокрутке сетка не
/// «дёргается».
const double _libraryGridSpacing = 16;
const double _libraryGridPadding = 24;
const double _libraryMinTileWidth = 200;

/// Высота «хвоста» плитки: отступы 12 сверху и снизу, зазор 8, заголовок
/// `labelLarge` (строка 20) и подпись `bodySmall` (16) с зазором 2, плюс
/// небольшой запас (2) — округление метрик строки в Flutter может дать
/// доли пикселя, и без запаса сетка показала бы полосу переполнения.
const double _libraryTileChrome = 12 + 8 + 20 + 2 + 16 + 12 + 2;

SliverGridDelegate _libraryGridDelegate(double availableWidth) {
  final double gridWidth = availableWidth - _libraryGridPadding * 2;
  final int columns = gridWidth <= 0
      ? 1
      : math.max(
          1,
          (gridWidth / (_libraryMinTileWidth + _libraryGridSpacing)).ceil(),
        );
  final double tileWidth = gridWidth <= 0
      ? _libraryMinTileWidth
      : (gridWidth - _libraryGridSpacing * (columns - 1)) / columns;
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    crossAxisSpacing: _libraryGridSpacing,
    mainAxisSpacing: _libraryGridSpacing,
    mainAxisExtent: tileWidth + _libraryTileChrome,
  );
}

/// Секция сводного раздела: заголовок и сетка плиток.
List<Widget> _gridSection(
  BuildContext context, {
  required String title,
  required List<BrowseItem> items,
  required SliverGridDelegate delegate,
}) {
  if (items.isEmpty) return const <Widget>[];
  return <Widget>[
    SliverToBoxAdapter(child: _GridHeader(title)),
    SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      sliver: SliverGrid(
        gridDelegate: delegate,
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
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
