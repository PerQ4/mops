import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../state/player_controller.dart';
import '../../state/shell.dart';
import '../player/floating_dock.dart';
import 'content_navigator.dart';
import 'destinations.dart';
import 'sidebar.dart';

/// Каркас приложения.
///
/// Содержимое живёт во вложенном навигаторе (см. [ContentNavigator]), поверх
/// которого нарисован плавающий док. Поэтому подэкран — альбом, плейлист,
/// исполнитель, настройки — не перекрывает док: он виден и там.
///
///  * **широкая раскладка** — слева постоянная панель навигации и библиотеки,
///    справа содержимое, внизу док из двух островков;
///  * **узкая** — навигация остаётся обычной нижней панелью, внизу парит
///    только островок плеера.
class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Следим за плеером, чтобы он жил всё время работы приложения.
    ref.watch(playerControllerProvider);

    final int index = ref.watch(shellIndexProvider);
    final bool wide = context.isExpandedLayout;

    final Widget content = Stack(
      children: <Widget>[
        const Positioned.fill(child: ContentNavigator()),
        const Align(alignment: Alignment.bottomCenter, child: FloatingDock()),
      ],
    );

    if (wide) {
      // Панель занимает свою ширину, содержимое — всё остальное. Док
      // центрируется по области содержимого, поэтому не наезжает на панель.
      return Scaffold(
        body: Row(
          children: <Widget>[
            const LibrarySidebar(),
            Expanded(child: content),
          ],
        ),
      );
    }

    return Scaffold(
      body: content,
      bottomNavigationBar: NavigationBar(
        height: AppLayout.bottomNavHeight,
        selectedIndex: index,
        onDestinationSelected: (int value) =>
            selectShellDestination(ref, value),
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
