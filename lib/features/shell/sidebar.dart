import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../core/theme/motion.dart';
import '../../core/utils/format.dart';
import '../../data/local/app_settings.dart';
import '../../data/models/models.dart';
import '../../data/sources/library_source.dart';
import '../../state/auth_controller.dart';
import '../../state/catalog_providers.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
import '../../state/providers.dart';
import '../../state/shell.dart';
import '../../widgets/app_progress.dart';
import '../../widgets/artwork.dart';
import '../../widgets/async_views.dart';
import '../common/navigation.dart';
import '../library/playlist_edit.dart';
import '../playlist/playlist_screen.dart';
import 'content_navigator.dart';
import 'destinations.dart';

// --------------------------------------------------------------- отступы панели
//
// Один источник горизонтальных отступов на всю панель. Раньше строки, поиск,
// заголовки и навигация отсчитывались от 6/8/12/14/16 каждый по-своему, и левый
// край выглядел «лестницей». Теперь любая «карточка» (подсветка строки, поле
// поиска, строка навигации) прижата к краю на [_inset], а её содержимое — ещё
// на [_rowPad]. Отсюда же считаются заголовки, поэтому название категории
// стоит ровно над названием строки.

/// Отступ от края панели до фона строки.
const double _inset = 8;

/// Внутренний отступ строки: от края подсветки до обложки и текста.
const double _rowPad = 8;

/// Горизонталь, по которой выровнены тексты: заголовок категории, название
/// строки, подпись поиска и счётчик.
const double _textInset = _inset + _rowPad;

/// Зазор между кнопками шапки и между подписью и первой кнопкой.
const double _headerGap = 4;

/// Сторона квадратной кнопки шапки: одна на все кнопки, чтобы ряд не
/// разъезжался из-за стандартных 48 пикселей `IconButton`.
const double _headerButton = 36;

/// Высота строки шапки. Одна на заголовок с кнопками и на раскрытый поиск,
/// иначе при открытии поиска панель дёргалась бы по высоте.
const double _headerHeight = 44;

/// Предел ширины счётчика категории. В `AppLayout` он 96, но «123 исполнителя»
/// в него не влезает и обрезается многоточием; здесь счётчик стоит один.
const double _categoryCountMaxWidth = 120;

/// Высота закреплённого заголовка категории вместе с отступами.
const double _categoryHeaderHeight = 36;

/// Высота поля поиска.
const double _searchHeight = 36;

/// Постоянная левая панель широкой раскладки.
///
/// Форма взята у Spotify Desktop и боковой панели swiftify: сверху заголовок
/// библиотеки с кнопками и поиском, ниже — один прокручиваемый список, в
/// котором категории идут друг под другом («Плейлисты» → плейлисты,
/// «Альбомы» → альбомы, «Исполнители» → исполнители). Заголовок категории
/// закрепляется сверху, пока видна его секция, и сворачивает её по клику.
/// У каждого элемента — контекстное меню: открыть, играть, сохранить/убрать, а
/// у своих плейлистов ещё переименовать и удалить.
///
/// Горизонтальные отступы считаются от одной константы [_inset], поэтому левый
/// и правый край строк, заголовков и навигации совпадают.
///
/// «Настройки» вынесены в самый низ панели, отдельным пунктом под списком — как
/// «Settings» в swiftify.
///
/// Если включена настройка «Панель вместо островка», над библиотекой
/// появляется навигация по разделам (Главная, Обзор, Поиск, Библиотека) — тем
/// же вертикальным списком: тогда волнистый островок внизу на широком экране не
/// нужен.
///
/// Панель сворачивается в узкую полосу с обложками (состояние запоминается в
/// настройках — иначе при каждом переходе в широкую раскладку панель
/// разворачивалась бы заново). Порядок сортировки, строка поиска и свёрнутые
/// категории — сессионные: они живут в [librarySidebarProvider] и
/// [_collapsedSectionsProvider].
class LibrarySidebar extends ConsumerStatefulWidget {
  const LibrarySidebar({super.key});

  @override
  ConsumerState<LibrarySidebar> createState() => _LibrarySidebarState();
}

class _LibrarySidebarState extends ConsumerState<LibrarySidebar> {
  /// Ширина во время перетаскивания: настройку сохраняем только в конце,
  /// иначе каждый пиксель писался бы в файл настроек.
  double? _dragging;

  /// Текст поиска. Контроллер живёт здесь, а не в [LibrarySidebarState]:
  /// курсор и выделение — дело виджета, а в состоянии провайдера лежит только
  /// сам запрос. Поле перестраивается при сворачивании панели, но контроллер
  /// не теряется — строка поиска переживает сворачивание.
  final TextEditingController _search = TextEditingController();

  /// Раскрыт ли поиск. В обычном виде шапка — заголовок и кнопки, поиск
  /// открывается по значку и занимает строку целиком. Высоту шапки оба
  /// состояния делят, поэтому она не прыгает.
  bool _searchOpen = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Открывает и закрывает поиск.
  ///
  /// При закрытии запрос сбрасывается: спрятанный фильтр оставлял бы список
  /// отфильтрованным без единого намёка, почему строк так мало.
  void _toggleSearch() {
    final bool open = !_searchOpen;
    setState(() => _searchOpen = open);
    if (!open) {
      _search.clear();
      ref.read(librarySidebarProvider.notifier).setQuery('');
    }
  }

  /// Переключает свёрнутость панели и запоминает выбор.
  ///
  /// Сама свёрнутость на среднем окне не хранится в настройках: там она —
  /// умолчание раскладки. В настройки пишем только выбор, сделанный в широкой
  /// раскладке, чтобы он пережил перезапуск и не был затёрт шириной окна.
  void _toggleCollapsed(bool collapsed) {
    final bool next = !collapsed;
    ref.read(sidebarCollapseOverrideProvider.notifier).set(next);
    if (AppLayout.isExpanded(context.layoutWidth)) {
      ref
          .read(settingsControllerProvider.notifier)
          .update((AppSettings s) => s.copyWith(sidebarCollapsed: next));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double window = context.layoutWidth;
    final bool savedCollapsed = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.sidebarCollapsed),
    );
    // Выбор в сеансе важнее умолчания: иначе на среднем окне панель после
    // клика по кнопке тут же сворачивалась бы обратно.
    final bool collapsed =
        ref.watch(sidebarCollapseOverrideProvider) ??
        AppLayout.sidebarCollapsedByDefault(window, saved: savedCollapsed);
    // Навигация переезжает в панель, только пока сама панель есть: на узком
    // окне её нет, и там разделы живут в плавающем островке.
    final bool navInPanel = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.sidebarNavigation),
    );
    final double saved = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.sidebarWidth),
    );
    // Предел зависит от окна: на 1100 панель в 480 пикселей съедала бы
    // половину. Ту же границу соблюдаем и при перетаскивании за кромку.
    final double limit = AppLayout.sidebarWidthLimit(window);
    final double expanded = (_dragging ?? saved).clamp(
      AppLayout.sidebarMinWidth,
      limit,
    );

    // Ширину анимируем: содержимое справа подстраивается плавно, без рывка.
    // Во время перетаскивания анимация выключена — панель идёт за курсором.
    return AnimatedContainer(
      duration: _dragging == null
          ? AppMotion.resizeFast.duration
          : Duration.zero,
      curve: AppMotion.resizeFast.curve,
      width: collapsed ? AppLayout.sidebarCollapsedWidth : expanded,
      child: Material(
        color: scheme.surfaceContainer,
        child: Stack(
          children: <Widget>[
            // Подрезаем содержимое: во время анимации ширины ничего не должно
            // вылезать за панель.
            ClipRect(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SizedBox(height: 8),
                  _SidebarHeader(
                    collapsed: collapsed,
                    onToggle: () => _toggleCollapsed(collapsed),
                    search: _search,
                    searchOpen: _searchOpen,
                    onSearchToggle: _toggleSearch,
                  ),
                  if (navInPanel) _SidebarNavigation(collapsed: collapsed),
                  Expanded(
                    child: collapsed ? _CollapsedLibrary() : _ExpandedLibrary(),
                  ),
                  // «Настройки» — в самом низу панели, отдельным пунктом под
                  // списком (как «Settings» в swiftify), а не в общем списке.
                  _SidebarFooter(collapsed: collapsed),
                  const SizedBox(height: 8),
                ],
              ),
            ),
            // Ручка ширины: тянем за правый край панели. В свёрнутом виде
            // ширину менять нечего, поэтому ручки нет.
            if (!collapsed)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragUpdate: (DragUpdateDetails details) {
                      setState(() {
                        _dragging = ((_dragging ?? saved) + details.delta.dx)
                            .clamp(AppLayout.sidebarMinWidth, limit);
                      });
                    },
                    onHorizontalDragEnd: (DragEndDetails _) {
                      final double? value = _dragging;
                      if (value != null) {
                        ref
                            .read(settingsControllerProvider.notifier)
                            .setSidebarWidth(value);
                      }
                      setState(() => _dragging = null);
                    },
                    child: const SizedBox(
                      width: AppLayout.sidebarResizeHandleWidth,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Шапка панели: заголовок, кнопки и поиск в одной строке.
///
/// В свёрнутом виде остаётся только кнопка — она же и разворачивает панель.
/// Прятать заголовок, но оставлять кнопку важно: иначе развернуть панель
/// было бы нечем.
///
/// Высота строки постоянна ([_headerHeight]) в обоих состояниях поиска:
/// открытие поля не сдвигает список под шапкой.
///
/// Сортировка — такая же квадратная кнопка, как поиск и создание: отдельная
/// строка под шапкой занимала вертикаль, хотя несла одну подпись. Текущий
/// порядок теперь живёт в подсказке кнопки.
class _SidebarHeader extends ConsumerWidget {
  const _SidebarHeader({
    required this.collapsed,
    required this.onToggle,
    required this.search,
    required this.searchOpen,
    required this.onSearchToggle,
  });

  final bool collapsed;

  /// Переключает свёрнутость. Логика выбора живёт в родителе: там известны
  /// ширина окна и сохранённая настройка.
  final VoidCallback onToggle;

  final TextEditingController search;
  final bool searchOpen;
  final VoidCallback onSearchToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );
    // Порядок нужен и кнопке (подсказка, акцент), и меню (галочка).
    final LibrarySort sort = ref.watch(
      librarySidebarProvider.select((LibrarySidebarState s) => s.sort),
    );
    final Widget toggle = _HeaderIcon(
      tooltip: collapsed ? 'Развернуть библиотеку' : 'Свернуть библиотеку',
      icon: collapsed ? Icons.chevron_right : Icons.chevron_left,
      onPressed: onToggle,
    );

    if (collapsed) {
      return SizedBox(
        height: _headerHeight,
        child: Center(child: toggle),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _inset),
      child: SizedBox(
        height: _headerHeight,
        // Обе строки живут в одном стеке и меняются местами, поэтому высота
        // шапки не зависит от того, открыт поиск или нет.
        child: AnimatedSwitcher(
          duration: AppMotion.rowActions.duration,
          switchInCurve: AppMotion.rowActions.curve,
          switchOutCurve: AppMotion.rowActions.curve,
          child: searchOpen
              ? _LibrarySearchField(
                  key: const ValueKey<String>('sidebar-search'),
                  controller: search,
                  onClose: onSearchToggle,
                )
              : LayoutBuilder(
                  key: const ValueKey<String>('sidebar-actions'),
                  builder: (BuildContext context, BoxConstraints constraints) {
                    // Заголовок показываем, только если подпись влезает
                    // целиком: обрезанное «Б…» выглядело поломкой. Кнопки при
                    // этом не сжимаются — они важнее подписи.
                    final int actions = signedIn ? 5 : 2;
                    final double actionsWidth =
                        actions * _headerButton + (actions - 1) * _headerGap;
                    final bool showTitle =
                        constraints.maxWidth - actionsWidth >=
                        _sectionLabelWidth(context, 'Библиотека') +
                            2 * _rowPad;
                    return Row(
                      children: <Widget>[
                        if (showTitle)
                          const Expanded(child: _SectionLabel('Библиотека'))
                        else
                          const Spacer(),
                        _HeaderIcon(
                          tooltip: 'Поиск в библиотеке',
                          icon: Icons.search,
                          onPressed: onSearchToggle,
                        ),
                        // Сортировка, создание и обновление нужны только
                        // вошедшему: без входа список пуст, и кнопки делали бы
                        // нечего.
                        if (signedIn) ...<Widget>[
                          const SizedBox(width: _headerGap),
                          _HeaderSort(
                            sort: sort,
                            onSelected: ref
                                .read(librarySidebarProvider.notifier)
                                .setSort,
                          ),
                          const SizedBox(width: _headerGap),
                          _HeaderIcon(
                            tooltip: 'Создать плейлист',
                            icon: Icons.playlist_add,
                            onPressed: () =>
                                createPlaylistWithDialog(context, ref),
                          ),
                          const SizedBox(width: _headerGap),
                          _HeaderIcon(
                            tooltip: 'Обновить библиотеку',
                            icon: Icons.refresh,
                            onPressed: () => refreshLibrary(ref),
                          ),
                        ],
                        const SizedBox(width: _headerGap),
                        toggle,
                      ],
                    );
                  },
                ),
        ),
      ),
    );
  }
}

/// Сортировка библиотеки — квадратная кнопка в ряду шапки.
///
/// В подсказке — текущий порядок: подписи рядом с кнопкой нет, и без неё
/// выбранный порядок иначе не прочитать. Нестандартный порядок подсвечиваем
/// цветом, чтобы значок не выглядел «по умолчанию» после смены.
class _HeaderSort extends StatelessWidget {
  const _HeaderSort({required this.sort, required this.onSelected});

  final LibrarySort sort;
  final ValueChanged<LibrarySort> onSelected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<LibrarySort>(
      tooltip: 'Сортировка: ${sort.label}',
      onSelected: onSelected,
      icon: Icon(
        Icons.sort,
        size: 20,
        color: sort == LibrarySort.recent ? null : scheme.primary,
      ),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        minimumSize: const Size(_headerButton, _headerButton),
        maximumSize: const Size(_headerButton, _headerButton),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      // Сортировка одна на весь список: у «вкладок» больше нет своей.
      itemBuilder: (BuildContext context) => <PopupMenuEntry<LibrarySort>>[
        for (final LibrarySort option in LibrarySort.values)
          CheckedPopupMenuItem<LibrarySort>(
            value: option,
            checked: option == sort,
            child: Text(option.label),
          ),
      ],
    );
  }
}

/// Кнопка шапки: одинаковый квадрат и одинаковый зазор у всех, чтобы ряд
/// значков не разъезжался из-за стандартных 48 пикселей `IconButton`.
class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      iconSize: 20,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(
        width: _headerButton,
        height: _headerButton,
      ),
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }
}

/// Стиль подписи шапки и заголовков категорий.
TextStyle? _sectionLabelStyle(BuildContext context) {
  return Theme.of(context).textTheme.labelLarge?.copyWith(
    color: Theme.of(context).colorScheme.onSurfaceVariant,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.4,
  );
}

/// Ширина подписи шапки при текущем шрифте и масштабе текста.
///
/// Нужна, чтобы прятать заголовок до того, как он обрежется многоточием:
/// порог в пикселях не учитывал ни масштаб интерфейса, ни выбранный шрифт.
double _sectionLabelWidth(BuildContext context, String text) {
  final TextPainter painter = TextPainter(
    text: TextSpan(text: text, style: _sectionLabelStyle(context)),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final double width = painter.width;
  painter.dispose();
  return width;
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _rowPad),
      child: Text(
        title,
        // Подпись не должна вылезать за панель: при узкой ширине (и во время
        // анимации сворачивания) она ломала раскладку.
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: _sectionLabelStyle(context),
      ),
    );
  }
}

/// Развёрнутая панель: разделы и список выбранного раздела.
class _ExpandedLibrary extends ConsumerWidget {
  const _ExpandedLibrary();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );

    // Без входа библиотека пуста по определению — показываем приглашение, а не
    // поиск с фильтрами, которыми нечего фильтровать.
    if (!signedIn) {
      return _Hint(
        icon: Icons.login_outlined,
        text: 'Войдите, чтобы видеть свои плейлисты',
        actionLabel: 'Войти',
        onAction: () => AppRoutes.account(context),
      );
    }

    final LibrarySidebarState state = ref.watch(librarySidebarProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Список один на все категории: переключателя разделов больше нет.
        Expanded(child: _LibraryList(state: state)),
      ],
    );
  }
}

/// Строка поиска по своей библиотеке — фильтрует список на месте.
///
/// Живёт в шапке панели и занимает её строку целиком: ширину задаёт `Expanded`
/// шапки, высоту — [_searchHeight]. Крестик закрывает поиск (и сбрасывает
/// запрос) — так в шапке не появляется второй такой же крестик рядом.
class _LibrarySearchField extends ConsumerWidget {
  const _LibrarySearchField({
    super.key,
    required this.controller,
    required this.onClose,
  });

  final TextEditingController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: _searchHeight,
      child: TextField(
        controller: controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        style: Theme.of(context).textTheme.bodyMedium,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Поиск в библиотеке',
          filled: true,
          fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          prefixIcon: const Icon(Icons.search, size: 18),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
          ),
          suffixIcon: IconButton(
            tooltip: 'Закрыть поиск',
            iconSize: 16,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            icon: const Icon(Icons.close),
            onPressed: onClose,
          ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 28,
            minHeight: 28,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppLayout.radiusM),
            borderSide: BorderSide.none,
          ),
        ),
        onChanged: (String value) =>
            ref.read(librarySidebarProvider.notifier).setQuery(value),
      ),
    );
  }
}

/// Навигация по разделам внутри левой панели.
///
/// Показывается при включённой настройке «Панель вместо островка». Список — те
/// же [ShellDestination], что и у плавающего островка, и идёт сверху вниз;
/// «Настройки» из него убраны в самый низ панели ([_SidebarFooter]).
/// [selectShellDestination] ещё и сбрасывает открытые подэкраны, поэтому
/// переход ведёт себя ровно как нажатие на островке.
class _SidebarNavigation extends ConsumerWidget {
  const _SidebarNavigation({required this.collapsed});

  /// Свёрнутая панель: от строки остаётся один значок.
  final bool collapsed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int index = ref.watch(shellIndexProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 4),
        for (final ShellDestination destination in ShellDestination.values)
          _NavRow(
            icon: destination.icon,
            selectedIcon: destination.selectedIcon,
            label: destination.label,
            selected: destination.index == index,
            collapsed: collapsed,
            onTap: () => selectShellDestination(ref, destination.index),
          ),
        const SizedBox(height: 6),
        const Divider(height: 1, indent: _textInset, endIndent: _textInset),
      ],
    );
  }
}

/// «Настройки» в самом низу панели.
///
/// Отдельным пунктом под списком, как «Settings» в swiftify: настройки не
/// относятся ни к библиотеке, ни к разделам, поэтому в общем списке стояли бы
/// неуместно. В обоих состояниях панели — и развёрнутой, и свёрнутой.
class _SidebarFooter extends StatelessWidget {
  const _SidebarFooter({required this.collapsed});

  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Divider(height: 1, indent: _textInset, endIndent: _textInset),
        _NavRow(
          icon: Icons.settings_outlined,
          selectedIcon: Icons.settings,
          label: 'Настройки',
          // Настройки — не раздел верхнего уровня, поэтому активной строку не
          // подсвечиваем: так же ведёт себя кнопка настроек в островке.
          selected: false,
          collapsed: collapsed,
          onTap: () => AppRoutes.settings(context),
        ),
      ],
    );
  }
}

/// Строка навигации в панели: значок, подпись и выделение выбранного.
class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.collapsed,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final BorderRadius radius = BorderRadius.circular(AppLayout.radiusM);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _inset, vertical: 1),
      child: Tooltip(
        // В развёрнутой панели подпись и так видна — подсказка не нужна.
        message: collapsed ? label : '',
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Container(
            height: AppLayout.sidebarNavRowHeight,
            decoration: selected
                ? BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: radius,
                  )
                : null,
            padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : _rowPad),
            child: Row(
              mainAxisAlignment: collapsed
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: <Widget>[
                Icon(
                  selected ? selectedIcon : icon,
                  size: 20,
                  color: selected
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant,
                ),
                if (!collapsed) ...<Widget>[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: selected
                            ? scheme.onSecondaryContainer
                            : scheme.onSurface,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Список библиотеки: все категории одним прокручиваемым списком сверху вниз.
///
/// Форма взята у боковой панели swiftify: не «вкладки», а заголовки категорий
/// («Плейлисты», «Альбомы», «Исполнители») друг под другом. Строки берём у тех
/// же провайдеров, что и экран «Коллекция», поэтому новых запросов не
/// появляется; поиск и сортировка применяются ко всем категориям сразу.
class _LibraryList extends ConsumerWidget {
  const _LibraryList({required this.state, this.compact = false});

  final LibrarySidebarState state;

  /// Свёрнутая полоса: вместо строк — одни обложки.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<LibraryPlaylists> playlists = ref.watch(
      likedPlaylistsProvider,
    );
    final AsyncValue<List<Album>> albums = ref.watch(likedAlbumsProvider);
    final AsyncValue<List<Artist>> artists = ref.watch(libraryArtistsProvider);

    // Пока не загрузилась ни одна категория, показываем состояние целиком:
    // иначе на старте мигали бы три заголовка с пустыми списками.
    if (!playlists.hasValue && !albums.hasValue && !artists.hasValue) {
      if (playlists.hasError || albums.hasError || artists.hasError) {
        return _errorView(
          context,
          compact: compact,
          text: 'Не удалось загрузить библиотеку',
          // Повтор перечитывает все категории сразу: списка разделов, где
          // можно было бы обновить один, больше нет.
          onRetry: () => refreshLibrary(ref),
        );
      }
      return _loadingView(context, compact: compact);
    }

    final List<_LibGroup> groups = <_LibGroup>[];
    // Порядок важен: он же порядок заголовков сверху вниз.
    final int found =
        _addGroup<Playlist>(
          groups: groups,
          state: state,
          section: LibrarySection.playlists,
          countLabel: playlistCountLabel,
          emptyText: 'Плейлистов пока нет',
          source: playlists.whenData((LibraryPlaylists data) => data.playlists),
          titleOf: (Playlist p) => p.title,
          ownerOf: (Playlist p) => p.author ?? '',
          rowBuilder: (Playlist p, bool compact) =>
              _PlaylistRow(playlist: p, compact: compact),
        ) +
        _addGroup<Album>(
          groups: groups,
          state: state,
          section: LibrarySection.albums,
          countLabel: _albumCountLabel,
          emptyText: 'Альбомов пока нет',
          source: albums,
          titleOf: (Album a) => a.title,
          ownerOf: (Album a) => a.artistLine,
          rowBuilder: (Album a, bool compact) =>
              _AlbumRow(album: a, compact: compact),
        ) +
        _addGroup<Artist>(
          groups: groups,
          state: state,
          section: LibrarySection.artists,
          countLabel: artistCountLabel,
          emptyText: 'Исполнителей пока нет',
          source: artists,
          titleOf: (Artist a) => a.name,
          ownerOf: (Artist a) => a.name,
          rowBuilder: (Artist a, bool compact) =>
              _ArtistRow(artist: a, compact: compact),
        );

    if (compact) {
      // В полосе значков категории не подписаны — разделяем их чертой.
      final List<Widget Function(bool compact)> rail =
          <Widget Function(bool compact)>[];
      for (final _LibGroup group in groups) {
        if (group.rows.isEmpty) continue;
        if (rail.isNotEmpty) rail.add((bool _) => const _RailDivider());
        rail.addAll(group.rows);
      }
      return ListView.builder(
        // Прокрутка одна на весь список: категории идут подряд, отдельного
        // «раздела» с собственным смещением больше нет.
        key: const PageStorageKey<String>('library-rail'),
        padding: const EdgeInsets.only(bottom: 12),
        itemCount: rail.length,
        itemBuilder: (BuildContext context, int index) => rail[index](true),
      );
    }

    // От строки инструментов остался один счётчик найденного: без поиска она
    // была пустой полосой между шапкой и первой категорией, а сортировка
    // переехала в саму шапку.
    final Widget? foundRow = state.query.isEmpty
        ? null
        : _LibraryFoundRow(found: found);

    // Ищем, но совпадений нет ни в одной категории: вместо трёх заголовков с
    // нулями показываем одну понятную подсказку. Пустые строки категорий при
    // этом не рисуются вовсе — иначе подсказка дублировалась бы трижды.
    if (state.query.isNotEmpty && found == 0) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ?foundRow,
          const Expanded(
            child: _Hint(icon: Icons.search_off, text: 'Ничего не найдено'),
          ),
        ],
      );
    }

    final Set<LibrarySection> collapsedSections = ref.watch(
      _collapsedSectionsProvider,
    );
    final _CollapsedSectionsController sections = ref.read(
      _collapsedSectionsProvider.notifier,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ?foundRow,
        Expanded(
          child: CustomScrollView(
            key: const PageStorageKey<String>('library-list'),
            slivers: <Widget>[
              for (final _LibGroup group in groups)
                SliverMainAxisGroup(
                  slivers: <Widget>[
                    // Заголовок закрепляется сверху, пока видна его категория,
                    // и уступает место следующему: в длинном списке всегда
                    // понятно, какая это категория.
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _CategoryHeaderDelegate(
                        title: group.section.label,
                        count: group.count,
                        countLabel: group.countLabel(group.count),
                        collapsed: collapsedSections.contains(group.section),
                        onTap: () => sections.toggle(group.section),
                      ),
                    ),
                    if (collapsedSections.contains(group.section))
                      const SliverToBoxAdapter(child: SizedBox.shrink())
                    else if (group.rows.isEmpty)
                      // Пустую категорию подписываем только без фильтра: при
                      // поиске ноль уже виден в счётчике заголовка.
                      SliverToBoxAdapter(
                        child: state.query.isEmpty
                            ? _CategoryEmpty(text: group.emptyText)
                            : const SizedBox.shrink(),
                      )
                    else
                      SliverList.builder(
                        itemCount: group.rows.length,
                        itemBuilder: (BuildContext context, int index) =>
                            group.rows[index](false),
                      ),
                  ],
                ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 12)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Категория библиотеки вместе с её отфильтрованными строками.
final class _LibGroup {
  _LibGroup({
    required this.section,
    required this.count,
    required this.countLabel,
    required this.emptyText,
    required this.rows,
  });

  final LibrarySection section;
  final int count;
  final String Function(int count) countLabel;
  final String emptyText;

  /// Строки: `compact` — свёрнутая полоса с одними обложками.
  final List<Widget Function(bool compact)> rows;
}

/// Добавляет категорию в список групп.
///
/// Возвращает число показанных строк (с учётом фильтра). Каждая категория
/// приходит своим провайдером, поэтому «склеиваем» их здесь, а не в слое
/// состояния: провайдеры независимы и грузятся параллельно.
int _addGroup<T>({
  required List<_LibGroup> groups,
  required LibrarySidebarState state,
  required LibrarySection section,
  required String Function(int count) countLabel,
  required String emptyText,
  required AsyncValue<List<T>> source,
  required String Function(T item) titleOf,
  required String Function(T item) ownerOf,
  required Widget Function(T item, bool compact) rowBuilder,
}) {
  final List<T>? data = source.value;
  // Категория ещё грузится или упала — пропускаем её блок: остальные видны, а
  // не подменяются одним состоянием на весь список.
  if (data == null) return 0;

  final List<T> visible = _arrange(
    data,
    state: state,
    title: titleOf,
    owner: ownerOf,
  );
  groups.add(
    _LibGroup(
      section: section,
      count: visible.length,
      countLabel: countLabel,
      emptyText: emptyText,
      rows: <Widget Function(bool compact)>[
        for (final T item in visible)
          (bool compact) => rowBuilder(item, compact),
      ],
    ),
  );
  return visible.length;
}

/// Свёрнутые категории библиотеки.
///
/// Состояние сессионное и в настройки не пишется: это временный взгляд на
/// список, а не оформление. Живёт в Riverpod, а не в `State` списка, потому что
/// `_LibraryList` пересоздаётся при сворачивании панели — иначе категории
/// разворачивались бы сами.
class _CollapsedSectionsController extends Notifier<Set<LibrarySection>> {
  @override
  Set<LibrarySection> build() => const <LibrarySection>{};

  void toggle(LibrarySection section) {
    final Set<LibrarySection> next = Set<LibrarySection>.of(state);
    if (!next.remove(section)) next.add(section);
    state = next;
  }
}

final NotifierProvider<_CollapsedSectionsController, Set<LibrarySection>>
_collapsedSectionsProvider =
    NotifierProvider<_CollapsedSectionsController, Set<LibrarySection>>(
      _CollapsedSectionsController.new,
    );

/// Разделитель между категориями в свёрнутой полосе.
class _RailDivider extends StatelessWidget {
  const _RailDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: _textInset, vertical: 4),
      child: Divider(height: 1),
    );
  }
}

/// Заголовок категории в списке: название, счётчик и признак свёрнутости.
///
/// Счётчик стоит справа и ограничен по ширине: длинная подпись («123
/// исполнителя») иначе выдавила бы название категории. В свёрнутой категории
/// он остаётся единственным содержимым — по нему видно, сколько строк скрыто.
class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({
    required this.title,
    required this.count,
    required this.countLabel,
    required this.collapsed,
  });

  final String title;
  final int count;

  /// «14 плейлистов» — подпись для широкой панели. На узкой остаётся число:
  /// иначе подпись съедала название категории.
  final String countLabel;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle? titleStyle = Theme.of(context).textTheme.labelLarge
        ?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        );
    final TextStyle? countStyle = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: scheme.onSurfaceVariant);

    return SizedBox(
      height: _categoryHeaderHeight,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final String countText = constraints.maxWidth < 260
              ? '$count'
              : countLabel;
          return Padding(
            padding: const EdgeInsets.fromLTRB(_textInset, 8, _textInset, 4),
            child: Row(
              children: <Widget>[
                // Название забирает свободное место, поэтому счётчик и стрелка
                // прижаты к правому краю, а не липнут к названию.
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                ),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: _categoryCountMaxWidth,
                  ),
                  child: Text(
                    countText,
                    maxLines: 1,
                    softWrap: false,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: countStyle,
                  ),
                ),
                const SizedBox(width: 2),
                // Стрелка подсказывает, что заголовок нажимается, и показывает
                // состояние: вниз — развёрнуто, вправо — свёрнуто.
                AnimatedRotation(
                  turns: collapsed ? -0.25 : 0,
                  duration: AppMotion.rowActions.duration,
                  curve: AppMotion.rowActions.curve,
                  child: Icon(
                    Icons.expand_more,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Закреплённый заголовок категории.
///
/// `pinned` держит его сверху, пока видна секция, и следующий заголовок
/// выталкивает предыдущий — как `sticky_headers`, но без новой зависимости.
class _CategoryHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _CategoryHeaderDelegate({
    required this.title,
    required this.count,
    required this.countLabel,
    required this.collapsed,
    required this.onTap,
  });

  final String title;
  final int count;
  final String countLabel;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  double get minExtent => _categoryHeaderHeight;

  @override
  double get maxExtent => _categoryHeaderHeight;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Material(
      // Фон обязан быть непрозрачным и совпадать с панелью: иначе под
      // закреплённым заголовком просвечивали бы уезжающие строки.
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: InkWell(
        onTap: onTap,
        child: _CategoryHeader(
          title: title,
          count: count,
          countLabel: countLabel,
          collapsed: collapsed,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _CategoryHeaderDelegate oldDelegate) =>
      oldDelegate.title != title ||
      oldDelegate.count != count ||
      oldDelegate.countLabel != countLabel ||
      oldDelegate.collapsed != collapsed;
}

/// Пустая категория: одна приглушённая строка вместо списка.
class _CategoryEmpty extends StatelessWidget {
  const _CategoryEmpty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(_textInset, 4, _textInset, 8),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// Сколько строк нашлось при поиске.
///
/// Счётчики категорий стоят в их заголовках, поэтому общее число нужно только
/// при фильтре; без него строки нет вовсе — список начинается сразу под
/// шапкой, без пустой полосы.
class _LibraryFoundRow extends StatelessWidget {
  const _LibraryFoundRow({required this.found});

  final int found;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(_textInset, 2, _textInset, 4),
      child: Text(
        'Найдено: $found',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelMedium
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// Строка элемента библиотеки: обложка, название, подпись и действия.
///
/// Кнопки появляются при наведении, активная строка подсвечена фоном. Пока
/// курсор не наведён, кнопки не занимают место вовсе — иначе под них всегда
/// резервировалось бы место и название обрезалось даже без наведения.
class _LibraryRow extends ConsumerStatefulWidget {
  const _LibraryRow({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.active,
    required this.onTap,
    required this.onPlay,
    required this.menu,
    required this.onMenu,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final bool active;
  final VoidCallback onTap;

  /// Запуск элемента. `null` — запускать нечего, кнопки «Играть» нет.
  final Future<void> Function()? onPlay;

  /// Пункты контекстного меню.
  final List<_MenuEntry> menu;
  final ValueChanged<_EntryAction> onMenu;

  @override
  ConsumerState<_LibraryRow> createState() => _LibraryRowState();
}

class _LibraryRowState extends ConsumerState<_LibraryRow> {
  bool _hovered = false;
  bool _focused = false;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final bool compactRows = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.compactRows),
    );
    // Плотный режим сжимает строку целиком: высоту, обложку (её размер задают
    // строки-владельцы) и кегль подписи. Одной высоты было бы мало — текст
    // выглядел бы приплюснутым.
    final double rowHeight = compactRows
        ? AppLayout.libraryRowHeightCompact
        : AppLayout.libraryRowHeight;
    final double rowGap = compactRows
        ? AppLayout.libraryRowGapCompact
        : AppLayout.libraryRowGap;
    final double rowMargin = compactRows
        ? AppLayout.libraryRowVerticalMarginCompact
        : AppLayout.libraryRowVerticalMargin;
    // Действия нужны и с клавиатуры: Tab доводит фокус до строки, и без этого
    // кнопки «Играть» и «…» оставались недостижимыми — строились только под
    // курсором. Фокус дочерней кнопки тоже держит их на месте.
    final bool showActions = _hovered || _focused || widget.active;

    return SizedBox(
      height: rowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _inset),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(AppLayout.radiusS),
            onFocusChange: (bool focused) => setState(() => _focused = focused),
            // Правый клик — то же меню, что у «…», но у курсора: кнопка
            // появляется только при наведении и фокусе, и целиться в неё после
            // клика не нужно.
            onSecondaryTapUp: (TapUpDetails details) =>
                _openMenuAt(details.globalPosition),
            child: Container(
              decoration: widget.active
                  ? BoxDecoration(
                      color: scheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(AppLayout.radiusS),
                    )
                  : null,
              margin: EdgeInsets.symmetric(vertical: rowMargin),
              padding: const EdgeInsets.symmetric(horizontal: _rowPad),
              child: Row(
                children: <Widget>[
                  widget.leading,
                  SizedBox(width: rowGap),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              (compactRows ? text.bodyMedium : text.bodyLarge)
                                  ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: widget.active
                                        ? scheme.onSecondaryContainer
                                        : scheme.onSurface,
                                  ),
                        ),
                        if (widget.subtitle != null) ...<Widget>[
                          SizedBox(
                            height: compactRows
                                ? AppLayout.trackTitleGapCompact
                                : AppLayout.trackTitleGap,
                          ),
                          Text(
                            widget.subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                (compactRows ? text.labelSmall : text.bodySmall)
                                    ?.copyWith(
                                      color: widget.active
                                          ? scheme.onSecondaryContainer
                                                .withValues(alpha: 0.7)
                                          : scheme.onSurfaceVariant,
                                    ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  AnimatedSize(
                    duration: AppMotion.rowActions.duration,
                    curve: AppMotion.rowActions.curve,
                    alignment: Alignment.centerRight,
                    child: showActions
                        // Ширину ведёт AnimatedSize, а прозрачность — отдельная
                        // анимация появления: так кнопки проявляются, а не
                        // выскакивают, и название не дёргается дважды.
                        ? TweenAnimationBuilder<double>(
                            tween: Tween<double>(begin: 0, end: 1),
                            duration: AppMotion.rowActions.duration,
                            curve: AppMotion.rowActions.curve,
                            builder: (
                              BuildContext context,
                              double opacity,
                              Widget? child,
                            ) => Opacity(opacity: opacity, child: child),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                if (widget.onPlay != null)
                                  _busy
                                      ? const SizedBox(
                                          width: 32,
                                          height: 32,
                                          child: Center(
                                            child: AppProgress(size: 24),
                                          ),
                                        )
                                      : IconButton(
                                          tooltip: 'Играть',
                                          iconSize: 20,
                                          padding: EdgeInsets.zero,
                                          // Кнопки действий компактны: на узкой
                                          // панели (220) стандартные 48
                                          // пикселей оставляли названию считаные
                                          // пиксели.
                                          constraints:
                                              const BoxConstraints.tightFor(
                                                width: 32,
                                                height: 32,
                                              ),
                                          style: IconButton.styleFrom(
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                          ),
                                          icon: const Icon(
                                            Icons.play_arrow_rounded,
                                          ),
                                          onPressed: _play,
                                        ),
                                PopupMenuButton<_EntryAction>(
                                  tooltip: 'Действия',
                                  iconSize: 20,
                                  padding: EdgeInsets.zero,
                                  style: IconButton.styleFrom(
                                    minimumSize: const Size(32, 32),
                                    maximumSize: const Size(32, 32),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  icon: const Icon(Icons.more_vert),
                                  onSelected: widget.onMenu,
                                  itemBuilder: (BuildContext context) =>
                                      _menuItems(scheme),
                                ),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Пункты меню — один список на кнопку «…» и на правый клик: иначе
  /// действия рано или поздно разошлись бы.
  List<PopupMenuEntry<_EntryAction>> _menuItems(ColorScheme scheme) {
    return <PopupMenuEntry<_EntryAction>>[
      for (final _MenuEntry entry in widget.menu)
        PopupMenuItem<_EntryAction>(
          value: entry.action,
          child: Row(
            children: <Widget>[
              Icon(
                entry.icon,
                size: 18,
                color: entry.destructive ? scheme.error : null,
              ),
              const SizedBox(width: 12),
              Text(
                entry.label,
                style: entry.destructive
                    ? TextStyle(color: scheme.error)
                    : null,
              ),
            ],
          ),
        ),
    ];
  }

  /// Меню строки у курсора.
  ///
  /// Позиция считается от оверлея, а не от строки: так меню не уезжает за
  /// край панели, когда строка стоит у нижней границы окна.
  Future<void> _openMenuAt(Offset globalPosition) async {
    final RenderBox? overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final _EntryAction? action = await showMenu<_EntryAction>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: _menuItems(Theme.of(context).colorScheme),
    );
    // Строка могла уйти из списка, пока меню было открыто (обновилась
    // библиотека) — тогда обработчик уже ни к чему.
    if (action == null || !mounted) return;
    widget.onMenu(action);
  }

  /// Запуск с индикатором: пока идёт загрузка треков, кнопка показывает
  /// спиннер, а повторное нажатие ничего не делает.
  Future<void> _play() async {
    final Future<void> Function()? run = widget.onPlay;
    if (run == null || _busy) return;
    setState(() => _busy = true);
    try {
      await run();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Строка плейлиста.
class _PlaylistRow extends ConsumerStatefulWidget {
  const _PlaylistRow({required this.playlist, required this.compact});

  final Playlist playlist;

  /// Свёрнутая панель: от строки остаётся только обложка.
  final bool compact;

  @override
  ConsumerState<_PlaylistRow> createState() => _PlaylistRowState();
}

class _PlaylistRowState extends ConsumerState<_PlaylistRow> {
  Playlist get _playlist => widget.playlist;

  @override
  Widget build(BuildContext context) {
    // Активной считаем строку плейлиста, из которого играет текущий трек.
    final bool active = ref.watch(
      playerControllerProvider.select(
        (PlayerUiState s) => s.current?.playlistId == _playlist.id,
      ),
    );
    // Размер обложки меняется вместе со строкой: в плотном режиме она меньше.
    final bool compactRows = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.compactRows),
    );
    final double artworkSize = compactRows
        ? AppLayout.libraryArtworkCompact
        : AppLayout.libraryArtwork;

    if (widget.compact) {
      return _CompactEntry(
        title: _playlist.title,
        url: _playlist.thumbnails.sized(96),
        icon: Icons.queue_music,
        active: active,
        onTap: () => AppRoutes.playlist(context, _playlist.id),
      );
    }

    // Править можно всё, кроме «Мне нравится»: это снятие лайка, а не плейлист.
    // Чужой плейлист сервер честно отклонит — данных о владении у списка нет.
    final bool editable = !LibrarySource.isLikedPlaylist(_playlist.id);
    final bool saved = ref.watch(
      savedIdsProvider.select((Set<String> ids) => ids.contains(_playlist.id)),
    );

    return _LibraryRow(
      leading: Artwork(
        url: _playlist.thumbnails.sized(96),
        size: artworkSize,
        radius: BorderRadius.circular(4),
        icon: Icons.queue_music,
      ),
      title: _playlist.title,
      subtitle: _subtitle(),
      active: active,
      onTap: () => AppRoutes.playlist(context, _playlist.id),
      onPlay: _play,
      menu: <_MenuEntry>[
        const _MenuEntry(_EntryAction.open, 'Открыть', Icons.open_in_new),
        const _MenuEntry(_EntryAction.play, 'Играть', Icons.play_arrow_rounded),
        if (editable && saved)
          const _MenuEntry(
            _EntryAction.unsave,
            'Убрать из библиотеки',
            Icons.remove_circle_outline,
          )
        else if (editable)
          const _MenuEntry(
            _EntryAction.save,
            'Сохранить в библиотеку',
            Icons.library_add_outlined,
          ),
        if (editable)
          const _MenuEntry(
            _EntryAction.rename,
            'Переименовать',
            Icons.edit_outlined,
          ),
        if (editable)
          const _MenuEntry(
            _EntryAction.delete,
            'Удалить плейлист',
            Icons.delete_outline,
            destructive: true,
          ),
      ],
      onMenu: _onMenu,
    );
  }

  String? _subtitle() {
    final String? author = _playlist.author;
    if (author != null && author.isNotEmpty) return author;
    final String count = trackCountLabel(_playlist.trackCount);
    return count.isEmpty ? 'Плейлист' : count;
  }

  void _onMenu(_EntryAction action) {
    switch (action) {
      case _EntryAction.open:
        AppRoutes.playlist(context, _playlist.id);
      case _EntryAction.play:
        _play();
      case _EntryAction.unsave:
        _setSaved(false);
      case _EntryAction.save:
        _setSaved(true);
      case _EntryAction.rename:
        _rename();
      case _EntryAction.delete:
        _delete();
      case _EntryAction.subscribe:
      case _EntryAction.unsubscribe:
        // В строке плейлиста этих действий нет.
        break;
    }
  }

  /// Добавляет плейлист в библиотеку или убирает его оттуда. Ключ состояния и
  /// id для мутации у плейлиста совпадают — префикс `VL` снимает сам источник.
  Future<void> _setSaved(bool saved) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(savedIdsProvider.notifier)
          .toggle(id: _playlist.id, playlistId: _playlist.id);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            saved
                ? '«${_playlist.title}» сохранён в библиотеке'
                : '«${_playlist.title}» убран из библиотеки',
          ),
        ),
      );
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }

  /// Переименование: диалог и подтверждение те же, что на странице плейлиста.
  Future<void> _rename() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? title = await showRenamePlaylistDialog(
      context,
      _playlist.title,
    );
    if (title == null) return;
    try {
      await ref.read(librarySourceProvider).renamePlaylist(_playlist.id, title);
      invalidatePlaylistCaches(ref, _playlist.id);
      messenger.showSnackBar(
        SnackBar(content: Text('Плейлист переименован в «$title»')),
      );
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }

  /// Удаление — только после подтверждения: действие необратимое.
  Future<void> _delete() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool confirmed =
        await confirmDeletePlaylistDialog(context, _playlist.title) ?? false;
    if (!confirmed) return;
    try {
      await ref.read(librarySourceProvider).deletePlaylist(_playlist.id);
      invalidatePlaylistCaches(ref, _playlist.id);
      messenger.showSnackBar(
        SnackBar(content: Text('Плейлист «${_playlist.title}» удалён')),
      );
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }

  /// Запускает плейлист.
  ///
  /// В списке библиотеки треки обычно не приходят — догружаем страницу по id.
  /// У «Мне нравится» отдельный авторизованный источник: общий каталог гостю
  /// отдаёт его пустым.
  Future<void> _play() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final Playlist full = _playlist.tracks.isNotEmpty
          ? _playlist
          : LibrarySource.isLikedPlaylist(_playlist.id)
          ? await ref.read(likedSongsPlaylistProvider.future)
          : await ref.read(catalogSourceProvider).playlist(_playlist.id);
      if (full.tracks.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('В плейлисте нет треков')),
        );
        return;
      }
      await ref.read(playerControllerProvider.notifier).playQueue(full.tracks);
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Не удалось запустить плейлист')),
      );
    }
  }
}

/// Строка сохранённого альбома.
class _AlbumRow extends ConsumerStatefulWidget {
  const _AlbumRow({required this.album, required this.compact});

  final Album album;
  final bool compact;

  @override
  ConsumerState<_AlbumRow> createState() => _AlbumRowState();
}

class _AlbumRowState extends ConsumerState<_AlbumRow> {
  Album get _album => widget.album;

  @override
  Widget build(BuildContext context) {
    // Треки альбома несут его browse-id — по нему и подсвечиваем строку.
    final bool active = ref.watch(
      playerControllerProvider.select(
        (PlayerUiState s) => s.current?.album?.id == _album.id,
      ),
    );
    final bool compactRows = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.compactRows),
    );
    final double artworkSize = compactRows
        ? AppLayout.libraryArtworkCompact
        : AppLayout.libraryArtwork;

    if (widget.compact) {
      return _CompactEntry(
        title: _album.title,
        url: _album.thumbnails.sized(96),
        icon: Icons.album_outlined,
        active: active,
        onTap: () => AppRoutes.album(context, _album.id),
      );
    }

    final bool saved = ref.watch(
      savedIdsProvider.select((Set<String> ids) => ids.contains(_album.id)),
    );

    return _LibraryRow(
      leading: Artwork(
        url: _album.thumbnails.sized(96),
        size: artworkSize,
        radius: BorderRadius.circular(6),
        icon: Icons.album_outlined,
      ),
      title: _album.title,
      subtitle: _subtitle(),
      active: active,
      onTap: () => AppRoutes.album(context, _album.id),
      onPlay: _play,
      menu: <_MenuEntry>[
        const _MenuEntry(_EntryAction.open, 'Открыть', Icons.open_in_new),
        const _MenuEntry(_EntryAction.play, 'Играть', Icons.play_arrow_rounded),
        if (saved)
          const _MenuEntry(
            _EntryAction.unsave,
            'Убрать из библиотеки',
            Icons.remove_circle_outline,
          )
        else
          const _MenuEntry(
            _EntryAction.save,
            'Сохранить в библиотеку',
            Icons.library_add_outlined,
          ),
      ],
      onMenu: _onMenu,
    );
  }

  String? _subtitle() {
    if (_album.artistLine.isNotEmpty) return _album.artistLine;
    final String? year = _album.year;
    return year != null && year.isNotEmpty ? year : null;
  }

  void _onMenu(_EntryAction action) {
    switch (action) {
      case _EntryAction.open:
        AppRoutes.album(context, _album.id);
      case _EntryAction.play:
        _play();
      case _EntryAction.unsave:
        _setSaved(false);
      case _EntryAction.save:
        _setSaved(true);
      case _EntryAction.rename:
      case _EntryAction.delete:
      case _EntryAction.subscribe:
      case _EntryAction.unsubscribe:
        break;
    }
  }

  /// Добавляет альбом в библиотеку или убирает его оттуда.
  ///
  /// В списке у альбома нет звукового id (`OLAK5uy_…`), который принимает
  /// мутация, — он приходит только со страницы. Поэтому догружаем страницу и
  /// берём id оттуда.
  Future<void> _setSaved(bool saved) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final Album full = await ref.read(catalogSourceProvider).album(_album.id);
      final String? playlistId = full.audioPlaylistId;
      if (playlistId == null || playlistId.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Не удалось определить альбом')),
        );
        return;
      }
      await ref
          .read(savedIdsProvider.notifier)
          .toggle(id: _album.id, playlistId: playlistId);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            saved
                ? '«${_album.title}» сохранён в библиотеке'
                : '«${_album.title}» убран из библиотеки',
          ),
        ),
      );
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }

  Future<void> _play() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final Album full = await ref.read(catalogSourceProvider).album(_album.id);
      if (full.tracks.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('В альбоме нет треков')),
        );
        return;
      }
      await ref.read(playerControllerProvider.notifier).playQueue(full.tracks);
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Не удалось запустить альбом')),
      );
    }
  }
}

/// Строка исполнителя, чьи треки сохранены в библиотеке.
class _ArtistRow extends ConsumerStatefulWidget {
  const _ArtistRow({required this.artist, required this.compact});

  final Artist artist;
  final bool compact;

  @override
  ConsumerState<_ArtistRow> createState() => _ArtistRowState();
}

class _ArtistRowState extends ConsumerState<_ArtistRow> {
  Artist get _artist => widget.artist;

  @override
  Widget build(BuildContext context) {
    // Исполнитель активен, если его имя есть у играющего трека.
    final bool active = ref.watch(
      playerControllerProvider.select(
        (PlayerUiState s) =>
            s.current?.artists.any((ArtistRef a) => a.id == _artist.id) ??
            false,
      ),
    );
    final bool compactRows = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.compactRows),
    );
    final double artworkSize = compactRows
        ? AppLayout.libraryArtworkCompact
        : AppLayout.libraryArtwork;

    if (widget.compact) {
      return _CompactEntry(
        title: _artist.name,
        url: _artist.thumbnails.sized(96),
        icon: Icons.person_outline,
        circular: true,
        active: active,
        onTap: () => AppRoutes.artist(context, _artist.id),
      );
    }

    final bool subscribed = ref.watch(
      subscribedIdsProvider.select(
        (Set<String> ids) => ids.contains(_artist.id),
      ),
    );

    return _LibraryRow(
      leading: Artwork(
        url: _artist.thumbnails.sized(96),
        size: artworkSize,
        radius: BorderRadius.circular(artworkSize / 2),
        icon: Icons.person_outline,
      ),
      title: _artist.name,
      subtitle: null,
      active: active,
      onTap: () => AppRoutes.artist(context, _artist.id),
      onPlay: _play,
      menu: <_MenuEntry>[
        const _MenuEntry(_EntryAction.open, 'Открыть', Icons.open_in_new),
        const _MenuEntry(_EntryAction.play, 'Играть', Icons.play_arrow_rounded),
        if (subscribed)
          const _MenuEntry(
            _EntryAction.unsubscribe,
            'Отписаться',
            Icons.notifications_off_outlined,
          )
        else
          const _MenuEntry(
            _EntryAction.subscribe,
            'Подписаться',
            Icons.notifications_none,
          ),
      ],
      onMenu: _onMenu,
    );
  }

  void _onMenu(_EntryAction action) {
    switch (action) {
      case _EntryAction.open:
        AppRoutes.artist(context, _artist.id);
      case _EntryAction.play:
        _play();
      case _EntryAction.subscribe:
        _toggleSubscription(subscribed: true);
      case _EntryAction.unsubscribe:
        _toggleSubscription(subscribed: false);
      case _EntryAction.save:
      case _EntryAction.unsave:
      case _EntryAction.rename:
      case _EntryAction.delete:
        break;
    }
  }

  Future<void> _toggleSubscription({required bool subscribed}) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(subscribedIdsProvider.notifier).toggle(_artist.id);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            subscribed
                ? 'Вы подписались на «${_artist.name}»'
                : 'Вы отписались от «${_artist.name}»',
          ),
        ),
      );
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }

  Future<void> _play() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final Artist full = await ref
          .read(catalogSourceProvider)
          .artist(_artist.id);
      if (full.topTracks.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('У исполнителя нет треков')),
        );
        return;
      }
      await ref
          .read(playerControllerProvider.notifier)
          .playQueue(full.topTracks, shuffle: true);
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Не удалось запустить исполнителя')),
      );
    }
  }
}

/// Свёрнутая панель: от элементов остаются одни обложки.
class _CollapsedLibrary extends ConsumerWidget {
  const _CollapsedLibrary();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );

    // В свёрнутой полосе места под текст нет — без входа показываем только знак.
    if (!signedIn) {
      return Center(
        child: Icon(
          Icons.login_outlined,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }

    final LibrarySidebarState state = ref.watch(librarySidebarProvider);
    return _LibraryList(state: state, compact: true);
  }
}

/// Компактный вариант списка: только обложки.
///
/// [compact] переключает и строки, и состояния загрузки/ошибки: в полосе
/// шириной 72 текст и отступы не помещаются.
class _CompactEntry extends StatelessWidget {
  const _CompactEntry({
    required this.title,
    required this.url,
    required this.icon,
    required this.active,
    required this.onTap,
    this.circular = false,
  });

  final String title;
  final String? url;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final bool circular;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _inset, vertical: 3),
        child: Tooltip(
          message: title,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppLayout.radiusS),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: active
                  ? BoxDecoration(
                      color: scheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(AppLayout.radiusS),
                    )
                  : null,
              child: Artwork(
                url: url,
                size: 40,
                radius: BorderRadius.circular(circular ? 20 : 8),
                icon: icon,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Пункт контекстного меню элемента библиотеки.
@immutable
class _MenuEntry {
  const _MenuEntry(
    this.action,
    this.label,
    this.icon, {
    this.destructive = false,
  });

  final _EntryAction action;
  final String label;
  final IconData icon;

  /// Опасное действие (удаление) — подпись красная, как в меню плейлиста.
  final bool destructive;
}

/// Что можно сделать с элементом библиотеки.
enum _EntryAction {
  open,
  play,
  save,
  unsave,
  rename,
  delete,
  subscribe,
  unsubscribe,
}

/// Фильтрует список по строке поиска и сортирует выбранным порядком.
///
/// Порядок «по дате добавления» — исходный порядок сервера: он приходит от
/// недавно добавленного к старому, отдельного поля с датой в ответе нет.
List<T> _arrange<T>(
  List<T> items, {
  required LibrarySidebarState state,
  required String Function(T) title,
  required String Function(T) owner,
}) {
  final String needle = state.query.trim().toLowerCase();
  final List<T> visible = needle.isEmpty
      ? List<T>.of(items)
      : items
            .where(
              (T item) =>
                  title(item).toLowerCase().contains(needle) ||
                  owner(item).toLowerCase().contains(needle),
            )
            .toList();

  switch (state.sort) {
    case LibrarySort.recent:
      break;
    case LibrarySort.title:
      visible.sort(
        (T a, T b) => title(a).toLowerCase().compareTo(title(b).toLowerCase()),
      );
    case LibrarySort.owner:
      visible.sort((T a, T b) {
        final int byOwner = owner(a)
            .toLowerCase()
            .compareTo(owner(b).toLowerCase());
        return byOwner != 0
            ? byOwner
            : title(a).toLowerCase().compareTo(title(b).toLowerCase());
      });
  }
  return visible;
}

/// «5 альбомов» — у альбомов своего счётчика в `format.dart` нет.
String _albumCountLabel(int count) =>
    '$count ${_pluralRu(count, 'альбом', 'альбома', 'альбомов')}';

String _pluralRu(int count, String one, String few, String many) {
  final int n = count.abs() % 100;
  final int n1 = n % 10;
  if (n >= 11 && n <= 14) return many;
  if (n1 == 1) return one;
  if (n1 >= 2 && n1 <= 4) return few;
  return many;
}

/// Индикатор загрузки: в свёрнутой полосе он меньше и с меньшими отступами,
/// иначе 36 в круге на 72 пикселя выглядел бы сплющенным.
Widget _loadingView(BuildContext context, {required bool compact}) {
  return Center(
    child: Padding(
      padding: EdgeInsets.all(compact ? 8 : 24),
      child: AppProgress(size: compact ? 24 : 32),
    ),
  );
}

/// Ошибка загрузки раздела: подсказка с повтором или просто знак в полосе.
Widget _errorView(
  BuildContext context, {
  required bool compact,
  required String text,
  required VoidCallback onRetry,
}) {
  if (compact) {
    return Center(
      child: Icon(
        Icons.error_outline,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
  return _Hint(
    icon: Icons.error_outline,
    text: text,
    actionLabel: 'Повторить',
    onAction: onRetry,
  );
}

/// Короткая подсказка вместо пустого списка или ошибки.
class _Hint extends StatelessWidget {
  const _Hint({
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(_textInset, 12, _textInset, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 22, color: scheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (actionLabel != null && onAction != null) ...<Widget>[
            const SizedBox(height: 4),
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}
