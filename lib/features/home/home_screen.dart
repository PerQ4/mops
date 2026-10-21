import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/catalog_providers.dart';
import '../../widgets/app_progress.dart';
import '../../widgets/artwork.dart';
import '../../widgets/horizontal_list.dart';
import '../../widgets/async_views.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/media_card.dart';
import '../../widgets/section_list.dart';
import '../../widgets/track_menu.dart';
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
              // Верхние блоки («Слушать снова», «Быстрый выбор») вынимаются из
              // ленты, чтобы не стоять дважды. Остальное — как раньше.
              final HomeTopBlocks top = splitHomeTop(data);
              // К порядку ArchiveTune приводим только первую порцию:
              // догруженные секции идут в порядке ответа. Иначе при подгрузке
              // секция с высоким приоритетом вставилась бы в середину и лента
              // дёрнулась бы у пользователя под руками.
              final List<BrowseSection> sections = <BrowseSection>[
                ...top.sections,
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
                    header: _HomeHeader(top: top),
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
      child: Center(child: AppProgress()),
    );
  }
}

/// Заглушка загрузки главной — как `HomeStatePane` с `LoadingIndicator`
/// (HomeScreen.kt:182-188, 248-249): экран целиком занят центрированным
/// индикатором Material 3 Expressive.
///
/// Индикатор берём из пакета `material_3_expressive` через общую обёртку
/// [AppProgress] (порт `androidx.compose.material3.LoadingIndicator`), поэтому
/// форма и размеры (48) совпадают с оригиналом и с остальными экранами.
class _HomeLoadingPane extends StatelessWidget {
  const _HomeLoadingPane();

  @override
  Widget build(BuildContext context) {
    return const Center(child: AppProgress());
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

/// Верхние блоки главной: чипы категорий, «Слушать снова» и быстрый набор.
///
/// Все три блока появляются только при реальных данных: чипы — из раздела
/// «Настроения и жанры» YouTube, полка и плитки — из секций главной. Чего
/// разбор не отдал, того на экране нет.
class _HomeHeader extends StatelessWidget {
  const _HomeHeader({required this.top});

  final HomeTopBlocks top;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _CategoryChips(),
        if (top.listenAgain != null)
          _ListenAgainShelf(section: top.listenAgain!),
        if (top.quickPicks != null)
          _QuickPicksTiles(section: top.quickPicks!),
      ],
    );
  }
}

/// Чипы категорий — быстрые фильтры поиска.
///
/// Подписи — реальные названия из раздела «Настроения и жанры» YouTube Music
/// (`CatalogSource.moodCategories`), а не заданный в коде список: чего каталог
/// не вернул, того на экране нет.
class _CategoryChips extends ConsumerWidget {
  const _CategoryChips();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Пока список грузится или не пришёл — ряда нет: подставлять выдуманные
    // подписи нельзя.
    final List<String> categories =
        ref.watch(moodCategoriesProvider).value ?? const <String>[];
    if (categories.isEmpty) return const SizedBox.shrink();

    return HorizontalList(
      // Высота ряда как в `HomeCategoryChips`: `heightIn(min = 68.dp)`.
      height: 68,
      // Отступы ряда — `padding(horizontal = 16.dp, vertical = 10.dp)`.
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      showScrollbar: false,
      separator: 8,
      itemCount: categories.length,
      itemBuilder: (BuildContext context, int index) {
        final String label = categories[index];
        // `HomeCategoryChips` держит чип высотой 32 по центру ряда. В
        // горизонтальном `ListView` ребёнок иначе растянулся бы на всю
        // высоту, поэтому центрируем явно.
        return Align(
          alignment: Alignment.center,
          child: _CategoryChip(
            label: label,
            onTap: () => _openCategory(context, label),
          ),
        );
      },
    );
  }

  void _openCategory(BuildContext context, String label) {
    // Отдельного экрана для настроений нет, а содержимое категории YouTube
    // открывает по `params` из кнопки раздела — перехода с параметрами в
    // приложении нет. Поэтому чип открывает поиск по названию, как и раньше.
    AppRoutes.searchWithQuery(context, label);
  }
}

/// Заголовок блока — вид `HomeSectionHeader` (HomeScreenComponents.kt:210-270):
/// высота ≥64, отступы 16/8, подпись `titleLarge` semibold.
class _BlockTitle extends StatelessWidget {
  const _BlockTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

/// Полка «Слушать снова» — карточки недавно слушавшегося.
///
/// Секцию берём у YouTube как есть (`splitHomeTop`): локальной истории в
/// проекте пока нет. Заголовок — родной заголовок секции, без переименования.
class _ListenAgainShelf extends ConsumerWidget {
  const _ListenAgainShelf({required this.section});

  final BrowseSection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Обложка карточки — 128 по сетке; высота карточки целиком — как в
    // карусели секций (`_CardCarousel`): обложка + две строки подписи.
    const double cardWidth = AppLayout.gridThumbnailHeight;

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _BlockTitle(section.title),
          HorizontalList(
            height: cardWidth + 96,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            separator: 24,
            itemCount: section.items.length,
            itemBuilder: (BuildContext context, int index) {
              final BrowseItem item = section.items[index];
              final Widget card = BrowseItemCard(
                item: item,
                width: cardWidth,
                onPlay: item is ArtistItem
                    ? null
                    : (BrowseItem value) => playBrowseItem(
                          context,
                          ref,
                          value,
                          playContext: tracksOf(section),
                        ),
                onTap: (BrowseItem value) =>
                    openBrowseItem(context, ref, value),
              );
              // У треков долгое нажатие открывает меню — как в карусели
              // секций, иначе из полки меню не вызвать.
              if (item is TrackItem) {
                return GestureDetector(
                  onLongPress: () => showTrackMenu(context, item.track),
                  child: card,
                );
              }
              return card;
            },
          ),
        ],
      ),
    );
  }
}

/// Быстрый набор плиткой — квадратные плитки «Быстрого выбора».
///
/// Форма взята у `SpeedDialSection` (HomeScreenComponents.kt:791-1144):
/// контейнер `surfaceContainerLow` со скруглением large, сетка плиток с
/// зазором 10. Плитка — обложка во всю площадь, градиент и подпись снизу,
/// как `SpeedDialGridItem`. Локальных «закреплённых» элементов в проекте нет,
/// поэтому плитки строятся из секции YouTube, а не из хранилища закреплений;
/// без секции блока нет.
class _QuickPicksTiles extends ConsumerWidget {
  const _QuickPicksTiles({required this.section});

  final BrowseSection section;

  /// Минимальная ширина плитки. По ней считается число колонок: на узком окне
  /// их три (как 3×3 в оригинале), на широком — больше, чтобы плитки не
  /// растягивались во весь экран.
  static const double _minTileWidth = 200;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Track> tracks = tracksOf(section);

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _BlockTitle(section.title),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppLayout.radiusL),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final int columns =
                        (constraints.maxWidth / _minTileWidth)
                            .floor()
                            .clamp(3, 6);
                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                      ),
                      itemCount: section.items.length,
                      itemBuilder: (BuildContext context, int index) {
                        final BrowseItem item = section.items[index];
                        return _QuickTile(
                          item: item,
                          onTap: () => openBrowseItem(context, ref, item),
                          onPlay: () => playBrowseItem(
                            context,
                            ref,
                            item,
                            playContext: tracks,
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Плитка быстрого набора: обложка, градиент и подпись снизу.
class _QuickTile extends StatelessWidget {
  const _QuickTile({
    required this.item,
    required this.onTap,
    required this.onPlay,
  });

  final BrowseItem item;
  final VoidCallback onTap;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(AppLayout.radiusM),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // У исполнителя обложка открывает страницу, у остального — играет:
        // как у карточек карусели.
        onTap: item is ArtistItem ? onTap : onPlay,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // Скругление задаёт `Material` снаружи, поэтому обложке своё не
            // нужно — иначе по углам проступал бы фон контейнера.
            Artwork(url: item.image, radius: BorderRadius.zero),
            // Градиент под подписью — как `labelGradient` в `SpeedDialGridItem`.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 86,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.34),
                      Colors.black.withValues(alpha: 0.78),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 10,
              right: 6,
              bottom: 8,
              child: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Чип категории — вид невыбранного `FilterChip` из `HomeCategoryChips`
/// (HomeScreenComponents.kt:169-203).
///
/// Высота 32 (`FilterChipDefaults.Height`), фон `surfaceContainerHigh` α0.78,
/// подпись `onSurfaceVariant`, скругление 12 — это `UnselectedShape =
/// CornerMedium` из токенов AndroidX (`ChipsTokens.kt`). Ведущего значка у
/// невыбранного чипа в оригинале нет: галочка `done` появляется только у
/// выбранного, а чип главной ленты ничего не фильтрует — он открывает поиск.
/// Поэтому значка здесь нет.
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
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
