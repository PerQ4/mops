import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/catalog_providers.dart';
import '../../widgets/async_views.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/section_list.dart';
import '../common/navigation.dart';

/// Главная страница.
///
/// Форма взята у ArchiveTune: строка настроений, затем секции. Треки идут
/// списком, альбомы и исполнители — каруселью. Заголовок страницы не
/// дублирует приветствие: имя пользователя показывается только когда он вошёл.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<BrowseSection>> sections =
        ref.watch(homeSectionsProvider);

    return Scaffold(
      appBar: AppBar(
        // Логотип вместо слова «Главная»: раздел и так виден в навигации.
        automaticallyImplyLeading: false,
        title: Row(
          children: <Widget>[
            Icon(
              Icons.graphic_eq,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 10),
            const Text('mOps'),
          ],
        ),
        actions: const <Widget>[_HomeActions()],
      ),
      body: sections.when(
        data: (List<BrowseSection> data) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(homeSectionsProvider);
            await ref.read(homeSectionsProvider.future);
          },
          child: SectionListView(
            sections: data,
            header: const _MoodRow(),
            emptyPlaceholder: const EmptyState(
              icon: Icons.explore_off_outlined,
              title: 'Подборки недоступны',
              subtitle: 'YouTube Music не вернул ни одной секции. '
                  'Попробуйте обновить или сменить регион в настройках.',
            ),
          ),
        ),
        loading: () => const SectionSkeleton(),
        error: (Object error, StackTrace _) => ErrorState(
          message: describeError(error),
          onRetry: () => ref.invalidate(homeSectionsProvider),
        ),
      ),
    );
  }
}

/// Кнопки в шапке: «нравится», новые релизы, настройки.
///
/// Настройки показываются только в узкой раскладке — на широкой они живут
/// в боковой навигации, и дублировать их не нужно.
class _HomeActions extends ConsumerWidget {
  const _HomeActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool compact = context.isCompactLayout;
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );

    return Row(
      children: <Widget>[
        IconButton.filledTonal(
          tooltip: signedIn ? 'Аккаунт' : 'Войти',
          icon: Icon(
            signedIn ? Icons.account_circle : Icons.login_outlined,
            size: 20,
          ),
          onPressed: () => AppRoutes.account(context),
        ),
        if (compact) ...<Widget>[
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: 'Настройки',
            icon: const Icon(Icons.settings_outlined, size: 20),
            onPressed: () => AppRoutes.settings(context),
          ),
        ],
        const SizedBox(width: 8),
      ],
    );
  }
}

/// Строка настроений — быстрые фильтры поиска.
class _MoodRow extends StatelessWidget {
  const _MoodRow();

  /// Подписи соответствуют тому, что реально ищется в YouTube Music.
  static const List<(String, IconData)> _moods = <(String, IconData)>[
    ('Хорошее настроение', Icons.sentiment_satisfied_outlined),
    ('Спокойное', Icons.self_improvement_outlined),
    ('Энергичное', Icons.bolt_outlined),
    ('Для работы', Icons.work_outline),
    ('Романтика', Icons.favorite_border),
    ('Новинки', Icons.new_releases_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: AppLayout.gutter,
          vertical: 4,
        ),
        itemCount: _moods.length,
        separatorBuilder: (BuildContext context, int _) =>
            const SizedBox(width: 8),
        itemBuilder: (BuildContext context, int index) {
          final (String label, IconData icon) = _moods[index];
          return ActionChip(
            avatar: Icon(icon, size: 18),
            label: Text(label),
            onPressed: () => _openMood(context, label),
          );
        },
      ),
    );
  }

  void _openMood(BuildContext context, String label) {
    // Поиск уже умеет показывать подборки по запросу — отдельный экран
    // для настроений не нужен, достаточно открыть поиск с запросом.
    AppRoutes.searchWithQuery(context, label);
  }
}
