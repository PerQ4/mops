import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../state/player_controller.dart';
import '../../state/shell.dart';
import '../explore/explore_screen.dart';
import '../home/home_screen.dart';
import '../library/library_screen.dart';
import '../player/floating_dock.dart';
import '../search/search_screen.dart';
import 'destinations.dart';

/// Каркас приложения.
///
/// Навигация и плеер живут внизу в виде плавающих островков, поэтому
/// содержимое занимает всю ширину окна: боковой колонки нет.
///
///  * **широкая раскладка** — оба островка внизу стоят рядом;
///  * **узкая** — навигация остаётся обычной нижней панелью, а внизу парит
///    только островок плеера.
///
/// Островки накрывают содержимое, а не занимают место в раскладке, поэтому
/// появление плеера ничего не сдвигает.
class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Следим за плеером, чтобы он жил всё время работы приложения.
    ref.watch(playerControllerProvider);

    final int index = ref.watch(shellIndexProvider);
    final bool wide = context.isExpandedLayout;

    const List<Widget> pages = <Widget>[
      HomeScreen(),
      ExploreScreen(),
      SearchScreen(),
      LibraryScreen(),
    ];

    final Widget content = Stack(
      children: <Widget>[
        IndexedStack(index: index, children: pages),
        const Align(
          alignment: Alignment.bottomCenter,
          child: FloatingDock(),
        ),
      ],
    );

    if (wide) {
      // На широком экране навигация — часть нижнего островка.
      return Scaffold(body: content);
    }

    return Scaffold(
      body: content,
      bottomNavigationBar: NavigationBar(
        height: AppLayout.bottomNavHeight,
        selectedIndex: index,
        onDestinationSelected: ref.read(shellIndexProvider.notifier).select,
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
