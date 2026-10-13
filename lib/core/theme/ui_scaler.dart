import 'dart:io';

import 'package:flutter/material.dart';

/// Масштабирует весь интерфейс приложения.
///
/// Зачем это нужно: на Linux масштаб рабочего стола задаётся разными
/// механизмами (`GDK_SCALE`, `GDK_DPI_SCALE`, `QT_SCALE_FACTOR`), и Flutter
/// под Wayland не всегда получает его корректно — приложение может оказаться
/// нечитаемо мелким или, наоборот, огромным. Этот виджет даёт детерминированный
/// «зум» средствами самого фреймворка, не завися от оконной системы.
///
/// Реализация: дочернее дерево верстается в «виртуальном» размере
/// `реальный / scale`, а затем растягивается на всю доступную площадь.
/// За счёт этого масштабируется всё сразу — текст, отступы, иконки,
/// а обработка нажатий остаётся корректной.
class UiScaler extends StatelessWidget {
  const UiScaler({super.key, required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Небольшие отклонения игнорируем: лишний слой рендеринга ни к чему.
    if ((scale - 1.0).abs() < 0.01) return child;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size available = constraints.biggest;
        // При неограниченных размерах масштабировать нельзя — отдаём как есть.
        if (!available.isFinite || available.isEmpty) return child;

        final Size virtual = Size(
          available.width / scale,
          available.height / scale,
        );

        final MediaQueryData media = MediaQuery.of(context);

        return ClipRect(
          child: FittedBox(
            fit: BoxFit.fill,
            child: SizedBox(
              width: virtual.width,
              height: virtual.height,
              child: MediaQuery(
                data: media.copyWith(
                  size: virtual,
                  // DPR увеличиваем во столько же раз, чтобы картинки
                  // запрашивались в нужном разрешении и не мылились.
                  devicePixelRatio: media.devicePixelRatio * scale,
                ),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Определяет масштаб интерфейса, заданный оконной системой.
///
/// Возвращает `1.0`, если переменные окружения не заданы.
double detectDesktopScale() {
  double parse(String? raw) {
    if (raw == null || raw.isEmpty) return 1.0;
    final double? value = double.tryParse(raw.replaceAll(',', '.'));
    if (value == null || value <= 0) return 1.0;
    return value;
  }

  final String? Function(String) read =
      envReaderOverride ?? (String name) => Platform.environment[name];

  // Набор переменных повторяет то, что используют GTK- и Qt-окружения.
  double scale = 1.0;
  scale *= parse(read('GDK_SCALE'));
  scale *= parse(read('GDK_DPI_SCALE'));
  scale *= parse(read('QT_SCALE_FACTOR'));

  final String? screenFactors = read('QT_SCREEN_SCALE_FACTORS');
  if (screenFactors != null && screenFactors.isNotEmpty) {
    // Формат «1;1.5;2» — берём первый множитель.
    scale *= parse(screenFactors.split(';').first);
  }

  return scale.clamp(0.5, 4.0);
}

/// Переопределяется в тестах: там читать реальное окружение не нужно.
String? Function(String name)? envReaderOverride;
