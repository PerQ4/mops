import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../data/sources/catalog_source.dart';
import '../../state/catalog_providers.dart';
import '../../widgets/async_views.dart';
import '../../widgets/section_list.dart';

/// Раздел «Обзор»: новые релизы, чарты, настроения и жанры.
///
/// Вместо одной длинной страницы — вкладки, как в YouTube Music.
class ExploreScreen extends ConsumerStatefulWidget {
  const ExploreScreen({super.key});

  @override
  ConsumerState<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends ConsumerState<ExploreScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: ExploreSection.values.length,
    vsync: this,
  );

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Обзор'),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: <Widget>[
            for (final ExploreSection section in ExploreSection.values)
              Tab(text: section.label),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: <Widget>[
          for (final ExploreSection section in ExploreSection.values)
            _ExploreTab(browseId: section.browseId),
        ],
      ),
    );
  }
}

class _ExploreTab extends ConsumerWidget {
  const _ExploreTab({required this.browseId});

  final String browseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<BrowseSection>> sections =
        ref.watch(browseSectionProvider(browseId));

    return sections.when(
      data: (List<BrowseSection> data) {
        if (data.isEmpty) {
          return const EmptyView(
            icon: Icons.category_outlined,
            title: 'Раздел пуст',
            subtitle: 'YouTube Music не вернул содержимое для этого раздела.',
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(browseSectionProvider(browseId));
            await ref.read(browseSectionProvider(browseId).future);
          },
          child: SectionListView(sections: data),
        );
      },
      loading: () => const SectionSkeleton(),
      error: (Object error, StackTrace _) => ErrorView(
        error: error,
        onRetry: () => ref.invalidate(browseSectionProvider(browseId)),
      ),
    );
  }
}
