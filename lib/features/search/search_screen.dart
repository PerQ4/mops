import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/models/models.dart';
import '../../data/sources/catalog_source.dart';
import '../../state/auth_controller.dart';
import '../../state/catalog_providers.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/horizontal_list.dart';
import '../../widgets/async_views.dart';
import '../../widgets/media_card.dart';
import '../../widgets/section_list.dart';
import '../../widgets/track_tile.dart';
import '../common/navigation.dart';
import 'search_states.dart';

/// Поиск по YouTube Music.
///
/// Пока запрос не введён, показываются «Подсказки» (тренды и содержимое своей
/// библиотеки): обзор из поиска убран — он живёт в одноимённом разделе, и
/// третий экземпляр тех же настроений и жанров здесь только дублировал его.
/// Как только запрос есть — выдача с фильтрами.
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
  void initState() {
    super.initState();
    // На десктопе открыть поиск и сразу печатать — обычное ожидание: клавиатура
    // не выезжает и фокус никому не мешает. На телефоне не трогаем — там фокус
    // вытащил бы экранную клавиатуру сразу при открытии вкладки.
    final bool touchFirst = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    if (!touchFirst) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

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
        // Поле — 56, панель — 72: по 8 сверху и снизу. При стандартной высоте
        // 56 поле прилипало к краям панели вплотную.
        toolbarHeight: 72,
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
            // Поле поиска — как `SearchBar` в ArchiveTune: высота 56 и
            // «капсульная» форма (радиус 28 из темы). Отступ 16 по горизонтали
            // и 16 по вертикали даёт ровно 56 при строке `bodyLarge` 24.
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
          ),
        ),
      ),
      body: _query.isEmpty
          ? _Suggestions(onPick: _pickSuggestion)
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
    final AsyncValue<List<BrowseSection>> results = ref.watch(
      searchResultsProvider(key),
    );

    return results.when(
      data: (List<BrowseSection> sections) {
        if (sections.isEmpty) {
          return const SearchStateMessage(message: 'Ничего не найдено');
        }
        return SectionListView(sections: sections);
      },
      loading: () => const SearchResultsSkeleton(),
      error: (Object error, StackTrace _) => SearchStateMessage(
        message: describeError(error),
        action: FilledButton(
          onPressed: () => ref.invalidate(searchResultsProvider(key)),
          child: const Text('Повторить'),
        ),
      ),
    );
  }

  void _pickSuggestion(String value) {
    _controller.text = value;
    _submit(value);
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
            leading: Icon(
              icon,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            title: Text(label),
            onTap: () => onPick(label),
          ),
        if (signedIn && artistList.isNotEmpty) ...<Widget>[
          const _SearchSectionTitle('Исполнители'),
          HorizontalList(
            height: AppLayout.artistAvatar + 90,
            // Отступ ленты — 12, как у заголовка секции.
            padding: const EdgeInsets.symmetric(horizontal: 12),
            separator: 12,
            itemCount: artistList.length,
            itemBuilder: (BuildContext context, int index) {
              final Artist artist = artistList[index];
              return BrowseItemCard(
                item: ArtistItem(artist),
                width: 160,
                onTap: (BrowseItem _) => AppRoutes.artist(context, artist.id),
              );
            },
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
    // Заголовок секции в стиле `NavigationTitle`: отступы 12/12 и цвет
    // `primary` (NavigationTitle.kt:43-76).
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

/// Полоса фильтров: «Всё», «Треки», «Альбомы»…
///
/// В ArchiveTune это `ChipsRow` (ui/component/ChipsRow.kt:44-88): прокрутка по
/// горизонтали, отступ 12 слева, шаг 8 между чипами, вертикальный отступ 8.
/// Чип — `FilterChip` со скруглением 16, фоном `surfaceContainer` и галочкой
/// при выборе (иконка 18).
class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.selected, required this.onSelected});

  final SearchFilter selected;
  final ValueChanged<SearchFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return HorizontalList(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      showScrollbar: false,
      separator: 8,
      itemCount: SearchFilter.values.length,
      itemBuilder: (BuildContext context, int index) {
        final SearchFilter filter = SearchFilter.values[index];
        final bool isSelected = filter == selected;
        return FilterChip(
          label: Text(filter.label),
          selected: isSelected,
          showCheckmark: false,
          avatar: Icon(
            isSelected ? Icons.check : _filterIcon(filter),
            size: 18,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          side: BorderSide.none,
          backgroundColor: scheme.surfaceContainer,
          selectedColor: scheme.secondaryContainer,
          onSelected: (bool _) => onSelected(filter),
        );
      },
    );
  }

  /// Иконки фильтров — как в `OnlineSearchResult.kt:323-330`: залитые
  /// `search`, `music_note`, `slow_motion_video`, `album`, `person`,
  /// `queue_music`.
  IconData _filterIcon(SearchFilter filter) => switch (filter) {
    SearchFilter.all => Icons.search,
    SearchFilter.songs => Icons.music_note,
    SearchFilter.videos => Icons.slow_motion_video,
    SearchFilter.albums => Icons.album,
    SearchFilter.artists => Icons.person,
    SearchFilter.playlists => Icons.queue_music,
  };
}

/// Результаты поиска в виде обычного списка треков.
///
/// Используется страницами, которым нужен именно список, а не карусели.
List<Track> tracksFromSections(List<BrowseSection> sections) =>
    sections.expand((BrowseSection section) => tracksOf(section)).toList();
