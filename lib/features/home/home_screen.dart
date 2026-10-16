import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart' as m3e;

import '../../core/theme/layout.dart';
import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/catalog_providers.dart';
import '../../widgets/horizontal_list.dart';
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
                    // Индикатор догрузки — нижним элементом ленты, как
                    // `home_loading_more` в `HomeContent` (HomeScreen.kt:637-653).
                    footer: more.loadingMore ? const _LoadingMoreFooter() : null,
                    emptyPlaceholder: EmptyState(
                      icon: Icons.music_note_outlined,
                      // Как `HomeStatePane` (HomeScreen.kt:190-197): значок,
                      // сообщение и кнопка повтора — отдельной строки-подписи
                      // в оригинале нет.
                      title: 'Не найдено результатов',
                      action: FilledButton.tonal(
                        onPressed: () => ref.invalidate(homeSectionsProvider),
                        child: const Text('Повторить'),
                      ),
                    ),
                  ),
                ),
              );
            },
            loading: () => const _HomeLoadingPane(),
            error: (Object error, StackTrace _) => ErrorState(
              message: describeError(error),
              onRetry: () => ref.invalidate(homeSectionsProvider),
            ),
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

/// Индикатор догрузки главной — нижний элемент ленты.
///
/// Как `home_loading_more` в `HomeContent` (`HomeScreen.kt:637-653`): блок на
/// всю ширину с отступом 32 по кругу и центрированным `LoadingIndicator`.
class _LoadingMoreFooter extends StatelessWidget {
  const _LoadingMoreFooter();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(32),
      child: Center(child: m3e.M3ELoadingIndicator()),
    );
  }
}

/// Заглушка загрузки главной — как `HomeStatePane` с `LoadingIndicator`
/// (HomeScreen.kt:182-188, 248-249): экран целиком занят центрированным
/// индикатором Material 3 Expressive.
///
/// Индикатор берём из уже подключённого пакета `material_3_expressive`
/// (`M3ELoadingIndicator` — порт `androidx.compose.material3.LoadingIndicator`),
/// поэтому форма и размеры (48) совпадают с оригиналом.
class _HomeLoadingPane extends StatelessWidget {
  const _HomeLoadingPane();

  @override
  Widget build(BuildContext context) {
    return const Center(child: m3e.M3ELoadingIndicator());
  }
}

/// Тональный градиент фона экрана из спецификации ArchiveTune.
///
/// Высота 430, переход `primaryContainer` α0.30 → `secondaryContainer` α0.14 →
/// прозрачный. Промежуточная остановка — 0.42, как `Brush.verticalGradient`
/// в `HomeContent`. Градиент задаёт «объём» шапки, не мешая читать содержимое.
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
              stops: const <double>[0.0, 0.42, 1.0],
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
  static const List<String> _moods = <String>[
    'Хорошее настроение',
    'Спокойное',
    'Энергичное',
    'Для работы',
    'Романтика',
    'Новинки',
  ];

  @override
  Widget build(BuildContext context) {
    return HorizontalList(
      // Высота ряда как в `HomeCategoryChips`: `heightIn(min = 68.dp)`.
      height: 68,
      // Отступы ряда — `padding(horizontal = 16.dp, vertical = 10.dp)`.
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      showScrollbar: false,
      separator: 8,
      itemCount: _moods.length,
      itemBuilder: (BuildContext context, int index) {
        final String label = _moods[index];
        // `HomeCategoryChips` держит чип высотой 32 по центру ряда. В
        // горизонтальном `ListView` ребёнок иначе растянулся бы на всю
        // высоту, поэтому центрируем явно.
        return Align(
          alignment: Alignment.center,
          child: _MoodChip(
            label: label,
            onTap: () => _openMood(context, label),
          ),
        );
      },
    );
  }

  void _openMood(BuildContext context, String label) {
    // Поиск уже умеет показывать подборки по запросу — отдельный экран
    // для настроений не нужен, достаточно открыть поиск с запросом.
    AppRoutes.searchWithQuery(context, label);
  }
}

/// Чип настроения — вид невыбранного `FilterChip` из `HomeCategoryChips`
/// (HomeScreenComponents.kt:169-203).
///
/// Высота 32 (`FilterChipDefaults.Height`), фон `surfaceContainerHigh` α0.78,
/// подпись `onSurfaceVariant`, скругление 12 — это `UnselectedShape =
/// CornerMedium` из токенов AndroidX (`ChipsTokens.kt`). Ведущего значка у
/// невыбранного чипа в оригинале нет: галочка `done` появляется только у
/// выбранного, а чип главной ленты ничего не фильтрует — он открывает поиск.
/// Поэтому значка здесь нет.
class _MoodChip extends StatelessWidget {
  const _MoodChip({
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      // `FilterChipDefaults.Height` = 32.
      height: 32,
      child: Material(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.78),
        // UnselectedShape = CornerMedium = 12 (ChipsTokens.kt).
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            // Отступ подписи без ведущего значка: `FilterChipDefaults` держит
            // по 8 с каждой стороны чипа, текст — ещё по 8.
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
