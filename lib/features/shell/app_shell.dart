import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/player_controller.dart';
import '../common/navigation.dart';
import '../explore/explore_screen.dart';
import '../home/home_screen.dart';
import '../library/library_screen.dart';
import '../player/player_bar.dart';
import '../search/search_screen.dart';

/// Разделы верхнего уровня.
enum ShellDestination {
  home('Главная', Icons.home_outlined, Icons.home),
  explore('Обзор', Icons.explore_outlined, Icons.explore),
  search('Поиск', Icons.search_outlined, Icons.search),
  library('Коллекция', Icons.library_music_outlined, Icons.library_music);

  const ShellDestination(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Каркас приложения: навигация слева (широкие экраны) или снизу (узкие),
/// постоянная панель плеера и переходы к деталям.
///
/// Экраны живут в [IndexedStack], поэтому позиция прокрутки и загруженные
/// данные не теряются при переключении разделов.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;

  /// Порог, после которого снизу-навигация уступает место боковой.
  static const double _railBreakpoint = 960;

  /// Порог, после которого боковая навигация разворачивается с подписями.
  static const double _extendedBreakpoint = 1320;

  void _select(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    // Следим за плеером, чтобы он жил всё время работы приложения.
    ref.watch(playerControllerProvider);

    final double width = MediaQuery.sizeOf(context).width;
    final bool useRail = width >= _railBreakpoint;

    const List<Widget> pages = <Widget>[
      HomeScreen(),
      ExploreScreen(),
      SearchScreen(),
      LibraryScreen(),
    ];

    final Widget content = Column(
      children: <Widget>[
        Expanded(
          child: IndexedStack(index: _index, children: pages),
        ),
        const PlayerBar(),
      ],
    );

    if (useRail) {
      return Scaffold(
        body: Row(
          children: <Widget>[
            NavigationRail(
              extended: width >= _extendedBreakpoint,
              selectedIndex: _index,
              onDestinationSelected: _select,
              labelType: width >= _extendedBreakpoint
                  ? NavigationRailLabelType.none
                  : NavigationRailLabelType.all,
              destinations: <NavigationRailDestination>[
                for (final ShellDestination destination in ShellDestination.values)
                  NavigationRailDestination(
                    icon: Icon(destination.icon),
                    selectedIcon: Icon(destination.selectedIcon),
                    label: Text(destination.label),
                  ),
              ],
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
        selectedIndex: _index,
        onDestinationSelected: _select,
        destinations: <NavigationDestination>[
          for (final ShellDestination destination in ShellDestination.values)
            NavigationDestination(
              icon: Icon(destination.icon),
              selectedIcon: Icon(destination.selectedIcon),
              label: destination.label,
            ),
        ],
      ),
    );
  }
}
