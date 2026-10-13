import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/ui_scaler.dart';
import 'providers.dart';

/// Считает компенсацию масштаба интерфейса.
///
/// Правило выведено из того, как оконные системы обходятся с дробным масштабом:
///
///  * **DPR меньше системного масштаба** — движок масштаб не получил
///    (типично для GTK3 и дробных значений: 125% → DPR 1). Интерфейс мелкий,
///    его нужно увеличить до системного масштаба.
///  * **DPR равен или больше системного** — система уже отдаёт увеличенный DPR
///    и сама понижает масштаб при выводе (так делает Mutter: при 125% отдаёт
///    DPR 2 и сжимает кадр). Вмешиваться нельзя, иначе интерфейс станет мелким.
///
/// Уменьшение автоматически не применяется никогда: если интерфейс кажется
/// крупным, пользователь задаёт масштаб вручную (в настройках или `Ctrl -`).
double computeUiCompensation(DesktopScaleInfo desktop, double engineDpr) {
  if (desktop.isDefault || engineDpr <= 0) return 1.0;

  final double ratio = desktop.scale / engineDpr;

  // Оконная система масштаб уже применила — не трогаем.
  if (ratio <= 1.0) return 1.0;

  // Расхождение меньше 5% незаметно — лишний слой рендеринга не нужен.
  if (ratio < 1.05) return 1.0;

  return ratio.clamp(1.0, 2.5);
}

/// Итоговый масштаб для интерфейса: ручной выбор либо автокомпенсация.
double resolveUiScale(BuildContext context, WidgetRef ref) {
  final double chosen = ref.watch(
    settingsControllerProvider.select((s) => s.uiScale),
  );
  if (chosen > 0) return chosen;

  final DesktopScaleInfo desktop = ref.watch(desktopScaleProvider);
  if (desktop.isDefault) return 1.0;

  final double deviceDpr = MediaQuery.of(context).devicePixelRatio;
  return computeUiCompensation(desktop, deviceDpr);
}
