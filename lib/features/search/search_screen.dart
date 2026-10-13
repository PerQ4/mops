import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../data/sources/catalog_source.dart';
import '../../state/catalog_providers.dart';
import '../../widgets/async_views.dart';
import '../../widgets/section_list.dart';
import '../../widgets/empty_state.dart';

/// Поиск по YouTube Music: подсказки, фильтры и результаты.
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
    // Задержка, чтобы не бить по сети на каждую букву.
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
      body: Column(
        children: <Widget>[
          if (_query.isNotEmpty) _FilterBar(
            selected: _filter,
            onSelected: (SearchFilter filter) => setState(() => _filter = filter),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_query.isEmpty) return _Suggestions(onPick: _pickSuggestion);

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
        return SectionListView(
          sections: sections,
        );
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

/// Подсказки, пока запрос не введён.
class _Suggestions extends ConsumerWidget {
  const _Suggestions({required this.onPick});

  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Показываем недавно популярные направления — без учёта аккаунта.
    const List<(String, IconData)> quick = <(String, IconData)>[
      ('Новинки музыки', Icons.new_releases_outlined),
      ('Чарты', Icons.trending_up),
      ('Спокойная музыка', Icons.self_improvement_outlined),
      ('Для тренировки', Icons.fitness_center),
      ('Русский рэп', Icons.mic_external_on_outlined),
      ('Классика', Icons.piano_outlined),
    ];

    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            'Популярные запросы',
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        for (final (String label, IconData icon) in quick)
          ListTile(
            leading: Icon(icon, color: scheme.onSurfaceVariant),
            title: Text(label),
            onTap: () => onPick(label),
          ),
      ],
    );
  }
}

/// Результаты поиска в виде обычного списка треков.
///
/// Используется страницами, которым нужен именно список, а не карусели.
List<Track> tracksFromSections(List<BrowseSection> sections) => sections
    .expand((BrowseSection section) => tracksOf(section))
    .toList();
