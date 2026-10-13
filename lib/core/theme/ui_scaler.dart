import 'dart:io';

import 'package:flutter/material.dart';

/// Масштабирует весь интерфейс приложения.
///
/// Зачем это нужно: Flutter на Linux работает через GTK3, а тот умеет только
/// целочисленный масштаб. Если в системе задан дробный (например, GNOME с
/// масштабом 1.25), движок получает DPR = 1 и интерфейс оказывается
/// нечитаемо мелким. Этот виджет даёт детерминированный «зум» средствами
/// самого фреймворка, не завися от оконной системы.
///
/// Реализация: дочернее дерево верстается в «виртуальном» размере
/// `реальный / scale`, а затем растягивается на всю доступную площадь.
/// Так масштабируется всё сразу — текст, отступы, иконки, — а обработка
/// нажатий остаётся корректной.
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

/// Откуда взят масштаб — показывается в настройках и пишется в лог.
@immutable
class DesktopScaleInfo {
  const DesktopScaleInfo({required this.scale, required this.source});

  /// Масштаб, который просит оконная система.
  final double scale;

  /// Человекочитаемое описание источника (для диагностики).
  final String source;

  bool get isDefault => scale <= 1.01;

  static const DesktopScaleInfo none = DesktopScaleInfo(
    scale: 1.0,
    source: 'система масштаб не задаёт',
  );
}

/// Определяет масштаб интерфейса, заданный оконной системой.
///
/// Источники перебираются по очереди; берётся **максимум**, а не произведение:
/// переменные GTK, Qt и конфиг рабочего стола описывают одно и то же разными
/// способами, и перемножение дало бы двойное увеличение.
DesktopScaleInfo detectDesktopScaleInfo() {
  // 1. Явное переопределение — удобно для скриптов и отладки.
  final String? forced = _read('MOPS_UI_SCALE');
  if (forced != null && forced.isNotEmpty) {
    final double? value = _parse(forced);
    if (value != null) {
      return DesktopScaleInfo(scale: value, source: 'переменная MOPS_UI_SCALE');
    }
  }

  double best = 1.0;
  String source = DesktopScaleInfo.none.source;

  void consider(double? value, String description) {
    if (value == null || value <= 1.01) return;
    if (value > best) {
      best = value;
      source = description;
    }
  }

  // 2. Переменные окружения GTK: масштаб и множитель DPI перемножаются —
  //    так они и задуманы (GDK_SCALE=2 + GDK_DPI_SCALE=0.5 даёт 1.0).
  final double gdk = (_parse(_read('GDK_SCALE')) ?? 1.0) *
      (_parse(_read('GDK_DPI_SCALE')) ?? 1.0);
  consider(gdk, 'GDK_SCALE / GDK_DPI_SCALE ($gdk)');

  // 3. Переменные Qt — встречаются даже в GTK-окружении.
  double qt = _parse(_read('QT_SCALE_FACTOR')) ?? 1.0;
  final String? screenFactors = _read('QT_SCREEN_SCALE_FACTORS');
  if (screenFactors != null && screenFactors.isNotEmpty) {
    qt *= _parse(screenFactors.split(';').first) ?? 1.0;
  }
  consider(qt, 'QT_SCALE_FACTOR ($qt)');

  // 4. GNOME: дробный масштаб основного монитора в monitors.xml.
  final double? gnome = _scaleFromGnome();
  consider(gnome, 'GNOME, масштаб монитора ($gnome)');

  // 5. KDE: ScaleFactor в kdeglobals.
  final double? kde = _scaleFromKde();
  consider(kde, 'KDE, ScaleFactor ($kde)');

  return DesktopScaleInfo(scale: best.clamp(0.5, 4.0), source: source);
}

/// Читает `<scale>` основного логического монитора из `~/.config/monitors.xml`.
///
/// Именно здесь GNOME хранит дробный масштаб (1.25, 1.5, …), который
/// GTK3-приложения не получают.
double? _scaleFromGnome() {
  final File? file = _configFile('monitors.xml');
  if (file == null) return null;

  try {
    final String xml = file.readAsStringSync();
    final List<String> blocks = xml.split('<logicalmonitor>');
    if (blocks.length < 2) return null;

    // Берём логический монитор с <primary>yes</primary>, иначе первый.
    String? chunk;
    for (final String block in blocks.skip(1)) {
      if (block.contains('<primary>yes</primary>')) {
        chunk = block;
        break;
      }
    }
    chunk ??= blocks[1];

    final RegExpMatch? match =
        RegExp(r'<scale>\s*([\d.,]+)\s*</scale>').firstMatch(chunk);
    if (match == null) return null;
    return _parse(match.group(1));
  } on FileSystemException {
    return null;
  }
}

/// Читает `ScaleFactor` из `~/.config/kdeglobals`.
double? _scaleFromKde() {
  final File? file = _configFile('kdeglobals');
  if (file == null) return null;

  try {
    final List<String> lines = file.readAsLinesSync();
    for (final String line in lines) {
      final int eq = line.indexOf('=');
      if (eq <= 0) continue;
      if (line.substring(0, eq).trim() != 'ScaleFactor') continue;
      return _parse(line.substring(eq + 1));
    }
  } on FileSystemException {
    return null;
  }
  return null;
}

File? _configFile(String name) {
  final String? home = _read('HOME');
  if (home == null || home.isEmpty) return null;
  final File file = File('$home/.config/$name');
  return file.existsSync() ? file : null;
}

double? _parse(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final double? value = double.tryParse(raw.replaceAll(',', '.').trim());
  if (value == null || value <= 0) return null;
  return value;
}

String? _read(String name) {
  final String? Function(String)? override = envReaderOverride;
  if (override != null) return override(name);
  try {
    // ignore: avoid_dynamic_calls
    return Platform.environment[name];
  } on Object {
    return null;
  }
}

/// Переопределяется в тестах: там читать реальное окружение не нужно.
String? Function(String name)? envReaderOverride;
