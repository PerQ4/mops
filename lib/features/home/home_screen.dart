import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/catalog_providers.dart';
import '../../widgets/async_views.dart';
import '../../widgets/section_list.dart';
import '../common/navigation.dart';

/// Главная страница: подборки YouTube Music.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<BrowseSection>> sections =
        ref.watch(homeSectionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Главная'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Настройки',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => AppRoutes.settings(context),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: sections.when(
        data: (List<BrowseSection> data) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(homeSectionsProvider);
            await ref.read(homeSectionsProvider.future);
          },
          child: SectionListView(
            sections: data,
            header: _Greeting(hasSections: data.isNotEmpty),
            emptyPlaceholder: const EmptyView(
              icon: Icons.explore_off_outlined,
              title: 'Подборки недоступны',
              subtitle: 'YouTube Music не вернул ни одной секции. '
                  'Попробуйте обновить или сменить регион в настройках.',
            ),
          ),
        ),
        loading: () => const SectionSkeleton(),
        error: (Object error, StackTrace _) => ErrorView(
          error: error,
          onRetry: () => ref.invalidate(homeSectionsProvider),
        ),
      ),
    );
  }
}

/// Приветствие: подсказывает, вошли ли вы в аккаунт.
class _Greeting extends ConsumerWidget {
  const _Greeting({required this.hasSections});

  final bool hasSections;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AuthState auth = ref.watch(authControllerProvider);
    final TextTheme text = Theme.of(context).textTheme;

    final String greeting;
    if (auth.isSignedIn) {
      final String? name = auth.session?.displayName;
      greeting = name == null || name.isEmpty
          ? 'С возвращением'
          : 'С возвращением, $name';
    } else {
      greeting = 'Добрый день';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            greeting,
            style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (!auth.isSignedIn) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              'Войдите, чтобы видеть свои плейлисты и лайки',
              style: text.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
