import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../core/utils/format.dart';
import '../../data/local/app_settings.dart';
import '../../data/models/models.dart';
import '../../data/sources/library_source.dart';
import '../../state/auth_controller.dart';
import '../../state/catalog_providers.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
import '../../state/providers.dart';
import '../../widgets/artwork.dart';
import '../../widgets/async_views.dart';
import '../common/navigation.dart';
import '../playlist/playlist_screen.dart';

/// Постоянная левая панель широкой раскладки.
///
/// Форма взята у Spotify Desktop: сверху заголовок библиотеки, ниже — поиск,
/// переключатель раздела («Плейлисты / Альбомы / Исполнители»), сортировка и
/// сам список. У каждого элемента — контекстное меню: открыть, играть,
/// сохранить/убрать, а у своих плейлистов ещё переименовать и удалить.
///
/// Панель сворачивается в узкую полосу с обложками (состояние запоминается в
/// настройках — иначе при каждом переходе в широкую раскладку панель
/// разворачивалась бы заново). Выбранный раздел, порядок сортировки и строка
/// поиска — сессионные: они живут в [librarySidebarProvider].
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

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
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
      settingsControllerProvider.select(
        (AppSettings s) => s.sidebarCollapsed,
      ),
    );
    // Выбор в сеансе важнее умолчания: иначе на среднем окне панель после
    // клика по кнопке тут же сворачивалась бы обратно.
    final bool collapsed = ref.watch(sidebarCollapseOverrideProvider) ??
        AppLayout.sidebarCollapsedByDefault(window, saved: savedCollapsed);
    final double saved = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.sidebarWidth),
    );
    // Предел зависит от окна: на 1100 панель в 480 пикселей съедала бы
    // половину. Ту же границу соблюдаем и при перетаскивании за кромку.
    final double limit = AppLayout.sidebarWidthLimit(window);
    final double expanded =
        (_dragging ?? saved).clamp(AppLayout.sidebarMinWidth, limit);

    // Ширину анимируем: содержимое справа подстраивается плавно, без рывка.
    // Во время перетаскивания анимация выключена — панель идёт за курсором.
    return AnimatedContainer(
      duration: _dragging == null
          ? const Duration(milliseconds: 220)
          : Duration.zero,
      curve: Curves.easeOutCubic,
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
                  ),
                  Expanded(
                    child: collapsed
                        ? _CollapsedLibrary()
                        : _ExpandedLibrary(search: _search),
                  ),
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
                        _dragging =
                            ((_dragging ?? saved) + details.delta.dx)
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

/// Шапка панели: заголовок и кнопки обновления и сворачивания.
///
/// В свёрнутом виде остаётся только кнопка — она же и разворачивает панель.
/// Прятать заголовок, но оставлять кнопку важно: иначе развернуть панель
/// было бы нечем.
class _SidebarHeader extends ConsumerWidget {
  const _SidebarHeader({required this.collapsed, required this.onToggle});

  final bool collapsed;

  /// Переключает свёрнутость. Логика выбора живёт в родителе: там известны
  /// ширина окна и сохранённая настройка.
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );
    final IconButton toggle = IconButton(
      tooltip: collapsed ? 'Развернуть библиотеку' : 'Свернуть библиотеку',
      iconSize: 20,
      icon: Icon(collapsed ? Icons.chevron_right : Icons.chevron_left),
      onPressed: onToggle,
    );

    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: Center(child: toggle),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 0),
      child: Row(
        children: <Widget>[
          const Expanded(child: _SectionLabel('Библиотека')),
          // Обновление показываем только вошедшему: без входа список всё
          // равно пуст, и кнопка обновляла бы нечего.
          if (signedIn)
            IconButton(
              tooltip: 'Обновить библиотеку',
              iconSize: 18,
              icon: const Icon(Icons.refresh),
              onPressed: () => refreshLibrary(ref),
            ),
          toggle,
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 16, 6),
      child: Text(
        title,
        // Подпись не должна вылезать за панель: при узкой ширине (и во время
        // анимации сворачивания) она ломала раскладку.
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// Развёрнутая панель: поиск, разделы и список выбранного раздела.
class _ExpandedLibrary extends ConsumerWidget {
  const _ExpandedLibrary({required this.search});

  final TextEditingController search;

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
    final LibrarySidebarController controller =
        ref.read(librarySidebarProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _LibrarySearchField(controller: search, query: state.query),
        _SectionChips(
          selected: state.section,
          onSelected: controller.selectSection,
        ),
        Expanded(
          child: _LibraryList(state: state, onSort: controller.setSort),
        ),
      ],
    );
  }
}

/// Строка поиска по своей библиотеке — фильтрует список на месте.
class _LibrarySearchField extends ConsumerWidget {
  const _LibrarySearchField({required this.controller, required this.query});

  final TextEditingController controller;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: TextField(
        controller: controller,
        textInputAction: TextInputAction.search,
        style: Theme.of(context).textTheme.bodyMedium,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Поиск в библиотеке',
          filled: true,
          fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          prefixIcon: const Icon(Icons.search, size: 18),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 36,
            minHeight: 36,
          ),
          suffixIcon: query.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Очистить',
                  iconSize: 16,
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    // `clear` не зовёт `onChanged` — сбрасываем запрос сами,
                    // иначе список остался бы отфильтрованным.
                    controller.clear();
                    ref.read(librarySidebarProvider.notifier).setQuery('');
                  },
                ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
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

/// Переключатель раздела библиотеки.
///
/// Капсулы переносятся на следующую строку: при узкой панели три подписи в
/// одну строку не влезают, а обрезать «Исполнителей» до «Испол…» нехорошо.
class _SectionChips extends StatelessWidget {
  const _SectionChips({required this.selected, required this.onSelected});

  final LibrarySection selected;
  final ValueChanged<LibrarySection> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: <Widget>[
          for (final LibrarySection section in LibrarySection.values)
            ChoiceChip(
              selected: section == selected,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              labelPadding: const EdgeInsets.symmetric(horizontal: 2),
              avatar: Icon(_sectionIcon(section), size: 16),
              label: Text(section.label),
              onSelected: (_) => onSelected(section),
            ),
        ],
      ),
    );
  }
}

/// Список выбранного раздела: данные берём у того же провайдера, что и экран
/// «Коллекция», поэтому новых запросов не появляется.
class _LibraryList extends ConsumerWidget {
  const _LibraryList({
    required this.state,
    required this.onSort,
    this.compact = false,
  });

  final LibrarySidebarState state;
  final ValueChanged<LibrarySort> onSort;

  /// Свёрнутая полоса: вместо строк — одни обложки.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (state.section) {
      case LibrarySection.playlists:
        return ref.watch(likedPlaylistsProvider).when(
              data: (List<Playlist> data) => _body<Playlist>(
                context: context,
                data: data,
                title: (Playlist p) => p.title,
                owner: (Playlist p) => p.author ?? '',
                countLabel: playlistCountLabel,
                emptyIcon: Icons.queue_music,
                emptyText: 'Плейлистов нет',
                rowBuilder: (Playlist p, bool compact) =>
                    _PlaylistRow(playlist: p, compact: compact),
              ),
              loading: () => _loadingView(context, compact: compact),
              error: (Object error, StackTrace _) => _errorView(
                context,
                compact: compact,
                text: 'Не удалось загрузить плейлисты',
                onRetry: () => ref.invalidate(likedPlaylistsProvider),
              ),
            );
      case LibrarySection.albums:
        return ref.watch(likedAlbumsProvider).when(
              data: (List<Album> data) => _body<Album>(
                context: context,
                data: data,
                title: (Album a) => a.title,
                owner: (Album a) => a.artistLine,
                countLabel: _albumCountLabel,
                emptyIcon: Icons.album_outlined,
                emptyText: 'Альбомов нет',
                rowBuilder: (Album a, bool compact) =>
                    _AlbumRow(album: a, compact: compact),
              ),
              loading: () => _loadingView(context, compact: compact),
              error: (Object error, StackTrace _) => _errorView(
                context,
                compact: compact,
                text: 'Не удалось загрузить альбомы',
                onRetry: () => ref.invalidate(likedAlbumsProvider),
              ),
            );
      case LibrarySection.artists:
        return ref.watch(libraryArtistsProvider).when(
              data: (List<Artist> data) => _body<Artist>(
                context: context,
                data: data,
                title: (Artist a) => a.name,
                owner: (Artist a) => a.name,
                countLabel: artistCountLabel,
                emptyIcon: Icons.person_outline,
                emptyText: 'Исполнителей нет',
                rowBuilder: (Artist a, bool compact) =>
                    _ArtistRow(artist: a, compact: compact),
              ),
              loading: () => _loadingView(context, compact: compact),
              error: (Object error, StackTrace _) => _errorView(
                context,
                compact: compact,
                text: 'Не удалось загрузить исполнителей',
                onRetry: () => ref.invalidate(libraryArtistsProvider),
              ),
            );
    }
  }

  /// Тело раздела: строка со счётчиком и сортировкой плюс сам список.
  Widget _body<T>({
    required BuildContext context,
    required List<T> data,
    required String Function(T) title,
    required String Function(T) owner,
    required String Function(int) countLabel,
    required IconData emptyIcon,
    required String emptyText,
    required Widget Function(T item, bool compact) rowBuilder,
  }) {
    final List<T> visible =
        _arrange(data, state: state, title: title, owner: owner);

    if (compact) {
      // В полосе шириной 72 текста нет — только обложки. Счётчик и сортировку
      // здесь показывать негде, поэтому виден лишь знак пустого раздела.
      if (data.isEmpty) {
        return Center(
          child: Icon(
            emptyIcon,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
      }
      if (visible.isEmpty) {
        return Center(
          child: Icon(
            Icons.search_off,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
      }
      return ListView.builder(
        // Прокрутка у каждого раздела своя: ключ хранит смещение в
        // PageStorage, поэтому возврат в раздел восстанавливает позицию.
        key: PageStorageKey<String>('library-rail-${state.section.name}'),
        padding: const EdgeInsets.only(bottom: 12),
        itemCount: visible.length,
        itemBuilder: (BuildContext context, int index) =>
            rowBuilder(visible[index], true),
      );
    }

    if (data.isEmpty) {
      return _Hint(icon: emptyIcon, text: emptyText);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _LibraryToolbar(
          label: state.query.isEmpty
              ? countLabel(visible.length)
              : 'Найдено: ${visible.length}',
          section: state.section,
          sort: state.sort,
          onSort: onSort,
        ),
        Expanded(
          child: visible.isEmpty
              ? _Hint(icon: Icons.search_off, text: 'Ничего не найдено')
              : ListView.builder(
                  // Прокрутка хранится отдельно для каждого раздела: ключ
                  // записывает смещение в PageStorage, и при возврате в раздел
                  // список открывается там же, где его оставили.
                  key: PageStorageKey<String>('library-${state.section.name}'),
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: visible.length,
                  itemBuilder: (BuildContext context, int index) =>
                      rowBuilder(visible[index], false),
                ),
        ),
      ],
    );
  }
}

/// Счётчик и кнопка сортировки над списком.
class _LibraryToolbar extends StatelessWidget {
  const _LibraryToolbar({
    required this.label,
    required this.section,
    required this.sort,
    required this.onSort,
  });

  final String label;
  final LibrarySection section;
  final LibrarySort sort;
  final ValueChanged<LibrarySort> onSort;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle? style = Theme.of(context).textTheme.labelMedium
        ?.copyWith(color: scheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          PopupMenuButton<LibrarySort>(
            tooltip: 'Сортировка',
            onSelected: onSort,
            itemBuilder: (BuildContext context) => <PopupMenuEntry<LibrarySort>>[
              for (final LibrarySort option in _sortsFor(section))
                CheckedPopupMenuItem<LibrarySort>(
                  value: option,
                  checked: option == sort,
                  child: Text(_sortLabel(option, section)),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.sort, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  // Подпись ограничена: при узкой панели она иначе выдавила бы
                  // счётчик и вылезла за край.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Text(
                      _sortLabel(sort, section),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Строка элемента библиотеки: обложка, название, подпись и действия.
///
/// Кнопки появляются при наведении, активная строка подсвечена фоном. Пока
/// курсор не наведён, кнопки не занимают место вовсе — иначе под них всегда
/// резервировалось бы место и название обрезалось даже без наведения.
class _LibraryRow extends StatefulWidget {
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
  State<_LibraryRow> createState() => _LibraryRowState();
}

class _LibraryRowState extends State<_LibraryRow> {
  bool _hovered = false;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final bool showActions = _hovered || widget.active;

    return SizedBox(
      height: 64,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: InkWell(
          onTap: widget.onTap,
          child: Container(
            decoration: widget.active
                ? BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(AppLayout.radiusS),
                  )
                : null,
            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: <Widget>[
                widget.leading,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: widget.active
                              ? scheme.onSecondaryContainer
                              : scheme.onSurface,
                        ),
                      ),
                      if (widget.subtitle != null) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          widget.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(
                            color: widget.active
                                ? scheme.onSecondaryContainer.withValues(
                                    alpha: 0.7,
                                  )
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.centerRight,
                  child: showActions
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (widget.onPlay != null)
                              _busy
                                  ? const SizedBox(
                                      width: 32,
                                      height: 32,
                                      child: Padding(
                                        padding: EdgeInsets.all(6),
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    )
                                  : IconButton(
                                      tooltip: 'Играть',
                                      iconSize: 20,
                                      padding: EdgeInsets.zero,
                                      // Кнопки действий компактны: на узкой
                                      // панели (220) стандартные 48 пикселей
                                      // оставляли названию считаные пиксели.
                                      constraints: const BoxConstraints.tightFor(
                                        width: 32,
                                        height: 32,
                                      ),
                                      style: IconButton.styleFrom(
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      icon: const Icon(Icons.play_arrow_rounded),
                                      onPressed: _play,
                                    ),
                            PopupMenuButton<_EntryAction>(
                              tooltip: 'Действия',
                              iconSize: 20,
                              padding: EdgeInsets.zero,
                              style: IconButton.styleFrom(
                                minimumSize: const Size(32, 32),
                                maximumSize: const Size(32, 32),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              icon: const Icon(Icons.more_vert),
                              onSelected: widget.onMenu,
                              itemBuilder: (BuildContext context) =>
                                  <PopupMenuEntry<_EntryAction>>[
                                for (final _MenuEntry entry in widget.menu)
                                  PopupMenuItem<_EntryAction>(
                                    value: entry.action,
                                    child: Row(
                                      children: <Widget>[
                                        Icon(
                                          entry.icon,
                                          size: 18,
                                          color: entry.destructive
                                              ? scheme.error
                                              : null,
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
                              ],
                            ),
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
      savedIdsProvider.select(
        (Set<String> ids) => ids.contains(_playlist.id),
      ),
    );

    return _LibraryRow(
      leading: Artwork(
        url: _playlist.thumbnails.sized(96),
        size: 48,
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
    final String? title =
        await showRenamePlaylistDialog(context, _playlist.title);
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
        size: 48,
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
      final Album full =
          await ref.read(catalogSourceProvider).album(_album.id);
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
      final Album full =
          await ref.read(catalogSourceProvider).album(_album.id);
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
            s.current?.artists.any((ArtistRef a) => a.id == _artist.id) ?? false,
      ),
    );

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
      subscribedIdsProvider.select((Set<String> ids) => ids.contains(_artist.id)),
    );

    return _LibraryRow(
      leading: Artwork(
        url: _artist.thumbnails.sized(96),
        size: 48,
        radius: BorderRadius.circular(24),
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
      await ref
          .read(subscribedIdsProvider.notifier)
          .toggle(_artist.id);
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
      final Artist full =
          await ref.read(catalogSourceProvider).artist(_artist.id);
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
    final LibrarySidebarController controller =
        ref.read(librarySidebarProvider.notifier);
    return _LibraryList(
      state: state,
      onSort: controller.setSort,
      compact: true,
    );
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
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

/// Значок раздела — тот же, что у одноимённого чипа на экране «Коллекция».
IconData _sectionIcon(LibrarySection section) => switch (section) {
      LibrarySection.playlists => Icons.queue_music,
      LibrarySection.albums => Icons.album,
      LibrarySection.artists => Icons.person,
    };

/// Доступные порядки для раздела.
///
/// У исполнителей «по владельцу» совпадает с «по названию» — владелец и есть
/// сам исполнитель, — поэтому вариант не показываем.
List<LibrarySort> _sortsFor(LibrarySection section) =>
    section == LibrarySection.artists
        ? const <LibrarySort>[LibrarySort.recent, LibrarySort.title]
        : LibrarySort.values;

String _sortLabel(LibrarySort sort, LibrarySection section) => switch (sort) {
      LibrarySort.recent => sort.label,
      LibrarySort.title => sort.label,
      LibrarySort.owner =>
        section == LibrarySection.albums ? 'По исполнителю' : sort.label,
    };

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
          .where((T item) =>
              title(item).toLowerCase().contains(needle) ||
              owner(item).toLowerCase().contains(needle))
          .toList();

  switch (state.sort) {
    case LibrarySort.recent:
      break;
    case LibrarySort.title:
      visible.sort(
        (T a, T b) =>
            title(a).toLowerCase().compareTo(title(b).toLowerCase()),
      );
    case LibrarySort.owner:
      visible.sort((T a, T b) {
        final int byOwner =
            owner(a).toLowerCase().compareTo(owner(b).toLowerCase());
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
      child: SizedBox(
        width: compact ? 20 : 32,
        height: compact ? 20 : 32,
        child: const CircularProgressIndicator(strokeWidth: 2),
      ),
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
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 12),
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
