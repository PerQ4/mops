import 'package:cached_network_image/cached_network_image.dart';
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
import 'home_sections.dart';

/// Главная страница.
///
/// Форма взята у ArchiveTune: тональный градиент под шапкой, строка настроений,
/// затем секции в порядке из спецификации. Треки идут списком, альбомы,
/// исполнители и плейлисты — каруселью карточек. Заголовок страницы не
/// дублирует приветствие: имя пользователя показывается только в аватаре.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<BrowseSection>> base =
        ref.watch(homeSectionsProvider);
    // Догруженные секции и признак «идёт догрузка». Пока контроллер не готов,
    // берём пустое состояние: оно ничего не ломает.
    final HomeFeedState more =
        ref.watch(homeFeedProvider).value ?? const HomeFeedState();

    return Scaffold(
      appBar: AppBar(
        // Логотип вместо слова «Главная»: раздел и так виден в навигации.
        automaticallyImplyLeading: false,
        // Высота шапки — по спецификации (64), а не стандартные 56.
        toolbarHeight: AppLayout.appBarHeight,
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
      body: Stack(
        children: <Widget>[
          // Градиент лежит под содержимым и не ловит нажатия.
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _ToneGradient(),
          ),
          base.when(
            data: (List<BrowseSection> data) {
              // К порядку ArchiveTune приводим только первую порцию:
              // догруженные секции идут в порядке ответа. Иначе при подгрузке
              // секция с высоким приоритетом вставилась бы в середину и лента
              // дёрнулась бы у пользователя под руками.
              final List<BrowseSection> sections = <BrowseSection>[
                ...curateHomeSections(data),
                ...more.sections,
              ];
              return RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(homeSectionsProvider);
                  await ref.read(homeSectionsProvider.future);
                  // Накопленные порции тоже сбрасываем: лента собирается заново.
                  await ref.read(homeFeedProvider.future);
                },
                child: NotificationListener<ScrollNotification>(
                  // Догружаем, когда до конца остаётся примерно экран.
                  onNotification: (ScrollNotification notification) =>
                      _loadMoreNearEnd(notification, ref, !more.finished),
                  child: SectionListView(
                    sections: sections,
                    // Отступ сверху — внутри экрана, а не у шапки: так шапка
                    // остаётся своей высоты, а лента не прилипает к ней.
                    padding: const EdgeInsets.only(top: 16),
                    header: const _MoodRow(),
                    emptyPlaceholder: const EmptyState(
                      icon: Icons.explore_off_outlined,
                      title: 'Подборки недоступны',
                      subtitle: 'YouTube Music не вернул ни одной секции. '
                          'Попробуйте обновить или сменить регион в настройках.',
                    ),
                  ),
                ),
              );
            },
            loading: () => const SectionSkeleton(),
            error: (Object error, StackTrace _) => ErrorState(
              message: describeError(error),
              onRetry: () => ref.invalidate(homeSectionsProvider),
            ),
          ),
          // Индикатор догрузки висит над плавающим островком.
          if (more.loadingMore)
            const Positioned(
              left: 0,
              right: 0,
              bottom: AppLayout.floatingDockClearance + 12,
              child: Center(child: _LoadingMoreIndicator()),
            ),
        ],
      ),
    );
  }
}

/// Догружает ленту, когда до конца остаётся примерно экран.
///
/// Слушаем уведомления прокрутки: вертикальные идут от самой ленты,
/// горизонтальные — от каруселей и строки настроений, их пропускаем.
/// Уведомления о смене размеров сюда не приходят, поэтому при первом
/// построении догрузка сама не запускается — только при прокрутке.
bool _loadMoreNearEnd(
  ScrollNotification notification,
  WidgetRef ref,
  bool hasMore,
) {
  if (!hasMore) return false;

  final ScrollMetrics metrics = notification.metrics;
  final AxisDirection direction = metrics.axisDirection;
  final bool vertical =
      direction == AxisDirection.up || direction == AxisDirection.down;
  if (!vertical) return false;

  if (metrics.extentAfter <= metrics.viewportDimension) {
    ref.read(homeFeedProvider.notifier).loadMore();
  }
  // false — не перехватываем: уведомления нужны и RefreshIndicator.
  return false;
}

/// Индикатор догрузки главной.
///
/// Показывается только пока идёт запрос следующей порции и не занимает места
/// в раскладке: лежит поверх содержимого над плавающим островком.
class _LoadingMoreIndicator extends StatelessWidget {
  const _LoadingMoreIndicator();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(AppLayout.radiusXL),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      ),
    );
  }
}

/// Тональный градиент фона экрана из спецификации ArchiveTune.
///
/// Высота 430, переход `primaryContainer` α0.30 → `secondaryContainer` α0.14 →
/// прозрачный. Он задаёт «объём» шапки, не мешая читать содержимое.
class _ToneGradient extends StatelessWidget {
  const _ToneGradient();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: SizedBox(
        height: 430,
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                scheme.primaryContainer.withValues(alpha: 0.30),
                scheme.secondaryContainer.withValues(alpha: 0.14),
                Colors.transparent,
              ],
              stops: const <double>[0.0, 0.55, 1.0],
            ),
          ),
        ),
      ),
    );
  }
}

/// Кнопки в шапке: аватар аккаунта, новые релизы, настройки.
///
/// Настройки показываются только в узкой раскладке — на широкой они живут
/// в боковой навигации, и дублировать их не нужно.
class _HomeActions extends ConsumerWidget {
  const _HomeActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool compact = context.isCompactLayout;
    // Следим только за тем, что влияет на вид кнопки: вход и ссылку аватара.
    final (bool signedIn, String? avatarUrl) = ref.watch(
      authControllerProvider.select(
        (AuthState s) => (s.isSignedIn, s.session?.avatarUrl),
      ),
    );

    return Row(
      children: <Widget>[
        _AccountButton(signedIn: signedIn, avatarUrl: avatarUrl),
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

/// Кнопка аккаунта: аватар из сессии, а если его нет — прежняя иконка.
///
/// Аватар тянем через кэш (`CachedNetworkImageProvider`), как и обложки:
/// без него при каждом открытии главной картинка грузилась бы заново.
class _AccountButton extends StatelessWidget {
  const _AccountButton({required this.signedIn, required this.avatarUrl});

  final bool signedIn;
  final String? avatarUrl;

  @override
  Widget build(BuildContext context) {
    final String? url = avatarUrl;
    if (url == null || url.isEmpty) {
      return IconButton.filledTonal(
        tooltip: signedIn ? 'Аккаунт' : 'Войти',
        icon: Icon(
          signedIn ? Icons.account_circle : Icons.login_outlined,
          size: 20,
        ),
        onPressed: () => AppRoutes.account(context),
      );
    }

    return IconButton(
      tooltip: 'Аккаунт',
      onPressed: () => AppRoutes.account(context),
      // Круглая обрезка: у аватара Google своя форма, а в шапке нужен круг.
      icon: ClipOval(
        child: Image(
          image: CachedNetworkImageProvider(url),
          width: 32,
          height: 32,
          fit: BoxFit.cover,
          // Битый аватар не должен оставлять пустое место — показываем иконку.
          errorBuilder: (
            BuildContext context,
            Object error,
            StackTrace? stackTrace,
          ) =>
              const Icon(Icons.account_circle, size: 24),
        ),
      ),
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
      // Высота ряда чипов. В спецификации ≥68, но такие «плиты» выглядят
      // раздутыми — берём 48: строка читается как ряд чипов, а не кнопок.
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _moods.length,
        separatorBuilder: (BuildContext context, int _) =>
            const SizedBox(width: 8),
        itemBuilder: (BuildContext context, int index) {
          final (String label, IconData icon) = _moods[index];
          return _MoodChip(
            label: label,
            icon: icon,
            onTap: () => _openMood(context, label),
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

/// Крупный чип настроения в стиле ArchiveTune.
///
/// Не `ActionChip`: нужна фиксированная высота 68 и фон `surfaceContainerHigh`
/// α0.78; стандартный чип так не растянуть без «прыжков» при смене темы.
class _MoodChip extends StatelessWidget {
  const _MoodChip({
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
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.78),
      // Скругление-«капсула»: 48 / 2 = 24.
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Text(
                label,
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
