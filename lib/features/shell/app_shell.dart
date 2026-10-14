import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/local/app_settings.dart';
import '../../state/player_controller.dart';
import '../../state/providers.dart';
import '../player/floating_dock.dart';
import 'content_navigator.dart';
import 'player_panel.dart';
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
    // Плеер должен жить всё время работы приложения, но слушать всё его
    // состояние нельзя: позиция меняется несколько раз в секунду, и оболочка
    // перестраивалась бы вместе со всем содержимым. Следим только за тем,
    // есть ли текущий трек, — этого достаточно, чтобы контроллер жил.
    ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.current?.id),
    );

    final bool wide = context.isExpandedLayout;

    // Правая панель плеера — только в широкой раскладке, только при треке и
    // только если настройка «Плеер справа» включена. На телефоне панели
    // размещать негде: там по нажатию открывается полноэкранный плеер.
    final bool hasTrack = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.current != null),
    );
    final bool panelEnabled = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => s.playerPanelEnabled,
      ),
    );
    // Выключили настройку — сворачиваем панель: иначе при повторном включении
    // она «выпрыгнула» бы сама, хотя пользователь её не открывал.
    ref.listen<bool>(
      settingsControllerProvider.select(
        (AppSettings s) => s.playerPanelEnabled,
      ),
      (bool? _, bool next) {
        if (!next) ref.read(playerRightPanelProvider.notifier).close();
      },
    );
    final bool panelOpen = ref.watch(playerRightPanelProvider);
    final bool rightPanel = panelEnabled && hasTrack;

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
                // Скруглены углы, примыкающие к панелям: слева — к библиотеке,
                // справа — к плееру, когда он развёрнут.
                borderRadius: BorderRadius.horizontal(
                  left: const Radius.circular(AppLayout.contentPanelRadius),
                  right: Radius.circular(
                    rightPanel ? AppLayout.contentPanelRadius : 0,
                  ),
                ),
                child: ColoredBox(
                  color: scheme.surface,
                  child: content,
                ),
              ),
            ),
            // Панель плеера отнимает ширину у содержимого (оно сужается
            // плавно), а док остаётся видимым — он лежит внутри содержимого.
            if (rightPanel) PlayerRightPanelSlot(open: panelOpen),
          ],
        ),
      );
    }

    // Узкая раскладка: навигация живёт в том же плавающем островке
    // (см. [FloatingDock]), поэтому отдельная нижняя панель не нужна.
    return Scaffold(body: content);
  }
}
