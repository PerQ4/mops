import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/models/models.dart';
import '../../data/sources/catalog_source.dart';
import '../../state/auth_controller.dart';
import '../../state/catalog_providers.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/async_views.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/media_card.dart';
import '../../widgets/section_list.dart';
import '../../widgets/track_tile.dart';
import '../common/navigation.dart';

/// Поиск по YouTube Music.
///
/// Пока запрос не введён, показываются вкладки «Обзор» (настроения и жанры) и
/// «Подсказки» (тренды и содержимое своей библиотеки). Как только запрос есть —
/// выдача с фильтрами, как и раньше.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  Timer? _debounce;

  /// Запрос, который реально отправляем в сеть (после задержки).
  String _query = '';
  SearchFilter _filter = SearchFilter.all;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    // Перерисовываем сразу — чтобы кнопка «очистить» появлялась без задержки.
    setState(() {});
    // А запрос отправляем с задержкой, чтобы не бить по сети на каждую букву.
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() => _query = value.trim());
    });
  }

  void _submit(String value) {
    _debounce?.cancel();
    setState(() => _query = value.trim());
    _focus.unfocus();
  }

  void _clear() {
    _controller.clear();
    _debounce?.cancel();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          focusNode: _focus,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: _submit,
          decoration: InputDecoration(
            hintText: 'Треки, альбомы, исполнители…',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Очистить',
                    icon: const Icon(Icons.close),
                    onPressed: _clear,
                  ),
            filled: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 4),
          ),
        ),
      ),
      body: _query.isEmpty
          ? _DiscoverTabs(onPick: _pickSuggestion)
          : Column(
              children: <Widget>[
                _FilterBar(
                  selected: _filter,
                  onSelected: (SearchFilter filter) =>
                      setState(() => _filter = filter),
                ),
                Expanded(child: _body()),
              ],
            ),
    );
  }

  Widget _body() {
    final SearchQuery key = SearchQuery(_query, _filter);
    final AsyncValue<List<BrowseSection>> results =
        ref.watch(searchResultsProvider(key));

    return results.when(
      data: (List<BrowseSection> sections) {
        if (sections.isEmpty) {
          return const EmptyState(
            icon: Icons.search_off,
            title: 'Ничего не найдено',
            subtitle: 'Попробуйте другой запрос или снимите фильтр.',
          );
        }
        return SectionListView(sections: sections);
      },
      loading: () => const SectionSkeleton(rows: 3),
      error: (Object error, StackTrace _) => ErrorState(
        message: describeError(error),
        onRetry: () => ref.invalidate(searchResultsProvider(key)),
      ),
    );
  }

  void _pickSuggestion(String value) {
    _controller.text = value;
    _submit(value);
  }
}

/// Вкладки пустого поиска: «Обзор» и «Подсказки».
class _DiscoverTabs extends StatelessWidget {
  const _DiscoverTabs({required this.onPick});

  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: <Widget>[
          const TabBar(
            tabs: <Widget>[
              Tab(text: 'Обзор'),
              Tab(text: 'Подсказки'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: <Widget>[
                const _MoodsGrid(),
                _Suggestions(onPick: onPick),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Сетка «Настроения и жанры». Обзор по строкам-запросам к YouTube Music.
class _MoodsGrid extends StatelessWidget {
  const _MoodsGrid();

  /// Настроения и жанры. Отдельного источника у InnerTube нет — как и на
  /// главной, это подписи для поиска, а не выдуманные сущности.
  static const List<(String, IconData)> _moods = <(String, IconData)>[
    ('Хорошее настроение', Icons.sentiment_satisfied_outlined),
    ('Спокойное', Icons.self_improvement_outlined),
    ('Энергичное', Icons.bolt_outlined),
    ('Романтика', Icons.favorite_border),
    ('Для работы', Icons.work_outline),
    ('Для тренировки', Icons.fitness_center),
    ('Поп', Icons.music_note_outlined),
    ('Рок', Icons.electric_bolt),
    ('Хип-хоп', Icons.mic_external_on_outlined),
    ('Электроника', Icons.graphic_eq),
    ('Классика', Icons.piano_outlined),
    ('Джаз', Icons.music_video_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppLayout.gutter,
        16,
        AppLayout.gutter,
        AppLayout.floatingDockClearance,
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        // Ячейка не уже ~180, как в спецификации.
        maxCrossAxisExtent: 200,
        mainAxisExtent: 88,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: _moods.length,
      itemBuilder: (BuildContext context, int index) {
        final (String label, IconData icon) = _moods[index];
        return _MoodTile(
          label: label,
          icon: icon,
          onTap: () => AppRoutes.searchWithQuery(context, label),
        );
      },
    );
  }
}

class _MoodTile extends StatelessWidget {
  const _MoodTile({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: <Widget>[
              Icon(icon, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Подсказки: тренды и содержимое своей библиотеки.
class _Suggestions extends ConsumerWidget {
  const _Suggestions({required this.onPick});

  final ValueChanged<String> onPick;

  /// Популярные направления — показываем как «тренды».
  static const List<(String, IconData)> _trends = <(String, IconData)>[
    ('Новинки музыки', Icons.new_releases_outlined),
    ('Чарты', Icons.trending_up),
    ('Спокойная музыка', Icons.self_improvement_outlined),
    ('Для тренировки', Icons.fitness_center),
    ('Русский рэп', Icons.mic_external_on_outlined),
    ('Классика', Icons.piano_outlined),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );
    final AsyncValue<List<Artist>> artists = ref.watch(libraryArtistsProvider);
    final AsyncValue<List<Track>> songs = ref.watch(likedSongsProvider);

    final List<Artist> artistList = artists.value ?? const <Artist>[];
    final List<Track> songList = songs.value ?? const <Track>[];

    return ListView(
      padding: const EdgeInsets.only(
        top: 8,
        bottom: 8 + AppLayout.floatingDockClearance,
      ),
      children: <Widget>[
        const _SearchSectionTitle('Тренды'),
        for (final (String label, IconData icon) in _trends)
          ListTile(
            leading: Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
            title: Text(label),
            onTap: () => onPick(label),
          ),
        if (signedIn && artistList.isNotEmpty) ...<Widget>[
          const _SearchSectionTitle('Исполнители'),
          SizedBox(
            height: AppLayout.artistAvatar + 90,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppLayout.gutter),
              itemCount: artistList.length,
              separatorBuilder: (BuildContext context, int _) =>
                  const SizedBox(width: 12),
              itemBuilder: (BuildContext context, int index) {
                final Artist artist = artistList[index];
                return BrowseItemCard(
                  item: ArtistItem(artist),
                  width: 160,
                  onTap: (BrowseItem _) => AppRoutes.artist(context, artist.id),
                );
              },
            ),
          ),
        ],
        if (signedIn && songList.isNotEmpty) ...<Widget>[
          const _SearchSectionTitle('Треки'),
          for (final Track track in songList.take(5))
            TrackTile(
              track: track,
              onTap: () => ref
                  .read(playerControllerProvider.notifier)
                  .playTrack(track, context: songList),
            ),
        ],
      ],
    );
  }
}

class _SearchSectionTitle extends StatelessWidget {
  const _SearchSectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppLayout.gutter,
        20,
        AppLayout.gutter,
        8,
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

/// Полоса фильтров: «Всё», «Треки», «Альбомы»…
class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.selected, required this.onSelected});

  final SearchFilter selected;
  final ValueChanged<SearchFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: SearchFilter.values.length,
        separatorBuilder: (BuildContext context, int _) => const SizedBox(width: 8),
        itemBuilder: (BuildContext context, int index) {
          final SearchFilter filter = SearchFilter.values[index];
          return FilterChip(
            label: Text(filter.label),
            selected: filter == selected,
            showCheckmark: false,
            onSelected: (bool _) => onSelected(filter),
          );
        },
      ),
    );
  }
}

/// Результаты поиска в виде обычного списка треков.
///
/// Используется страницами, которым нужен именно список, а не карусели.
List<Track> tracksFromSections(List<BrowseSection> sections) => sections
    .expand((BrowseSection section) => tracksOf(section))
    .toList();
