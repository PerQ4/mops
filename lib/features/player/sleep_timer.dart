import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/player_controller.dart';

// Таймер сна: остановить музыку через N минут или после текущего трека.
//
// Общий файл для двух точек входа — пункта меню плеера и строки в настройках:
// набор вариантов и применение выбора должны совпадать, иначе «5 минут» в
// разных местах означали бы разное. Состояние при этом одно — поле
// `PlayerUiState.sleepTimer` в контроллере, поэтому выбор из настроек сразу
// виден в плеере и наоборот.

/// Варианты отсчёта в минутах — как в ArchiveTune (`playback/SleepTimer.kt`).
const List<int> kSleepTimerMinutes = <int>[5, 10, 15, 30, 45, 60];

/// Подпись состояния таймера для строки настроек, пункта меню и подсказки.
String sleepTimerLabel(int value) {
  if (value == kSleepTimerAfterTrack) return 'После текущего трека';
  if (value > 0) return '$value мин';
  return 'Выключен';
}

/// Открывает выбор таймера сна и применяет выбранное.
///
/// Меню не возвращает значение: выбор сразу уходит в контроллер — состояние
/// общее для всего приложения, и «применить» отдельно нечего.
Future<void> showSleepTimerMenu(BuildContext context, WidgetRef ref) async {
  final PlayerController controller =
      ref.read(playerControllerProvider.notifier);
  final int current = ref.read(playerControllerProvider).sleepTimer;

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext sheetContext) {
      final ColorScheme scheme = Theme.of(sheetContext).colorScheme;

      void apply(int value) {
        if (value == 0) {
          controller.clearSleepTimer();
        } else {
          controller.startSleepTimer(value);
        }
        Navigator.of(sheetContext).pop();
      }

      Widget option({
        required String title,
        required int value,
        IconData? icon,
      }) {
        final bool selected = current == value;
        return ListTile(
          leading: icon == null ? null : Icon(icon),
          title: Text(title),
          selected: selected,
          trailing: selected ? Icon(Icons.check, color: scheme.primary) : null,
          onTap: () => apply(value),
        );
      }

      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Таймер сна'),
            ),
            for (final int minutes in kSleepTimerMinutes)
              option(title: '$minutes мин', value: minutes),
            option(
              title: 'После текущего трека',
              value: kSleepTimerAfterTrack,
            ),
            // «Выключить» показываем только у включённого таймера: у
            // выключенного это была бы строка без действия.
            if (current != 0) ...<Widget>[
              const Divider(height: 1),
              option(
                title: 'Выключить таймер',
                value: 0,
                icon: Icons.timer_off_outlined,
              ),
            ],
          ],
        ),
      );
    },
  );
}
