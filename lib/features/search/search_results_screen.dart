import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/models/models.dart';
import '../../data/sources/catalog_source.dart';
import '../../state/catalog_providers.dart';
import '../../widgets/async_views.dart';
import '../../widgets/section_list.dart';
import 'search_states.dart';

/// Результаты поиска по уже заданному запросу.
///
/// Нужен для переходов вида «настроение → результаты»: обычный экран поиска
/// остаётся отдельным разделом, а здесь показывается только выдача. Данные и
/// разбор взяты те же, поэтому дублирования логики нет.
class SearchResultsScreen extends ConsumerWidget {
  const SearchResultsScreen({super.key, required this.query});

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<BrowseSection>> results = ref.watch(
      searchResultsProvider(SearchQuery(query, SearchFilter.all)),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(query, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: results.when(
        data: (List<BrowseSection> sections) {
          if (sections.isEmpty) {
            return const SearchStateMessage(message: 'Ничего не найдено');
          }
          return SectionListView(
            sections: sections,
            padding: const EdgeInsets.only(bottom: AppLayout.gutter),
          );
        },
        loading: () => const SearchResultsSkeleton(),
        error: (Object error, StackTrace _) => SearchStateMessage(
          message: describeError(error),
          action: FilledButton(
            onPressed: () => ref.invalidate(
              searchResultsProvider(SearchQuery(query, SearchFilter.all)),
            ),
            child: const Text('Повторить'),
          ),
        ),
      ),
    );
  }
}
