import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../state/player_controller.dart';
import '../common/navigation.dart';
import '../explore/explore_screen.dart';
import '../home/home_screen.dart';
import '../library/library_screen.dart';
import '../player/floating_dock.dart';
import '../search/search_screen.dart';

/// Разделы верхнего уровня.
enum ShellDestination {
  home('Главная', Icons.home_outlined, Icons.home),
  explore('Обзор', Icons.explore_outlined, Icons.explore),
  search('Поиск', Icons.search_outlined, Icons.search),
  library('Библиотека', Icons.library_music_outlined, Icons.library_music);

  const ShellDestination(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Каркас приложения.
///
/// Плеер — плавающий островок поверх содержимого, он не занимает место в
/// раскладке. Поэтому переключение разделов, открытие очереди и смена
/// раскладки ничего не сдвигают: меняется только навигация.
///
///  * **узкая** — нижняя навигация, островок парит над ней;
///  * **широкая** — боковая навигация фиксированной ширины, островок внизу.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    // Следим за плеером, чтобы он жил всё время работы приложения.
    ref.watch(playerControllerProvider);

    final double width = context.layoutWidth;
    final bool expanded = AppLayout.isExpanded(width);

    const List<Widget> pages = <Widget>[
      HomeScreen(),
      ExploreScreen(),
      SearchScreen(),
      LibraryScreen(),
    ];

    // Островок лежит поверх содержимого и не участвует в его раскладке.
    final Widget content = Stack(
      children: <Widget>[
        IndexedStack(index: _index, children: pages),
        const Align(
          alignment: Alignment.bottomCenter,
          child: FloatingDock(),
        ),
      ],
    );

    if (expanded) {
      return Scaffold(
        body: Row(
          children: <Widget>[
            _NavigationRail(
              index: _index,
              onSelect: (int value) => setState(() => _index = value),
              extended: AppLayout.useExtendedRail(width),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: content),
          ],
        ),
      );
    }

    return Scaffold(
      body: content,
      bottomNavigationBar: NavigationBar(
        height: AppLayout.bottomNavHeight,
        selectedIndex: _index,
        onDestinationSelected: (int value) => setState(() => _index = value),
        destinations: <NavigationDestination>[
          for (final ShellDestination d in ShellDestination.values)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: d.label,
            ),
        ],
      ),
    );
  }
}

/// Боковая навигация с фиксированной шириной.
class _NavigationRail extends StatelessWidget {
  const _NavigationRail({
    required this.index,
    required this.onSelect,
    required this.extended,
  });

  final int index;
  final ValueChanged<int> onSelect;
  final bool extended;

  @override
  Widget build(BuildContext context) {
    return NavigationRail(
      // Ширина задана явно: иначе панель меняет её сама и всё «дёргается».
      minWidth: AppLayout.railWidth,
      minExtendedWidth: AppLayout.railExtendedWidth,
      extended: extended,
      labelType:
          extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
      selectedIndex: index,
      onDestinationSelected: onSelect,
      destinations: <NavigationRailDestination>[
        for (final ShellDestination d in ShellDestination.values)
          NavigationRailDestination(
            icon: Icon(d.icon),
            selectedIcon: Icon(d.selectedIcon),
            label: Text(d.label),
          ),
      ],
      // Логотип живёт в шапке страницы, чтобы не дублироваться.
      trailing: Expanded(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: IconButton(
              tooltip: 'Настройки',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => AppRoutes.settings(context),
            ),
          ),
        ),
      ),
    );
  }
}
