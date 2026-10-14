import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../state/player_controller.dart';
import '../player/floating_dock.dart';
import 'content_navigator.dart';
import 'sidebar.dart';

/// Каркас приложения.
///
/// Содержимое живёт во вложенном навигаторе (см. [ContentNavigator]), поверх
/// которого нарисован плавающий док. Поэтому подэкран — альбом, плейлист,
/// исполнитель, настройки — не перекрывает док: он виден и там.
///
///  * **широкая раскладка** — слева постоянная панель библиотеки, справа
///    содержимое отдельной скруглённой панелью, внизу док из двух островков;
///  * **узкая** — боковой панели нет, но док тот же: навигация остаётся
///    плавающим островком, а не превращается в стандартную нижнюю панель.
class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Следим за плеером, чтобы он жил всё время работы приложения.
    ref.watch(playerControllerProvider);

    final bool wide = context.isExpandedLayout;

    final Widget content = Stack(
      children: <Widget>[
        const Positioned.fill(child: ContentNavigator()),
        const Align(alignment: Alignment.bottomCenter, child: FloatingDock()),
      ],
    );

    if (wide) {
      final ColorScheme scheme = Theme.of(context).colorScheme;
      // Фон всего каркаса — цвет боковой панели. Основная область лежит на
      // нём отдельной панелью со скруглением со стороны панели, поэтому в
      // «вырезах» скругления виден именно фон панели: содержимое читается
      // как самостоятельная панель поверх библиотеки (как в Spotify Desktop).
      return Scaffold(
        backgroundColor: scheme.surfaceContainer,
        body: Row(
          children: <Widget>[
            const LibrarySidebar(),
            Expanded(
              child: ClipRRect(
                // Скруглены только углы, примыкающие к боковой панели.
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(AppLayout.contentPanelRadius),
                ),
                child: ColoredBox(
                  color: scheme.surface,
                  child: content,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Узкая раскладка: навигация живёт в том же плавающем островке
    // (см. [FloatingDock]), поэтому отдельная нижняя панель не нужна.
    return Scaffold(body: content);
  }
}
