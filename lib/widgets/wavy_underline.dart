import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Короткая волнистая линия после подписи — деталь из десктопного Swiftify
/// (Qt Quick), где заголовки секций подписаны как «Library ~~~~».
///
/// Виджет переиспользуемый: он ничего не знает о заголовках и просто рисует
/// волну заданной длины цветом акцента. Высота выводится из амплитуды, поэтому
/// в строке он занимает ровно своё место и не ломает раскладку соседей.
class WavyUnderline extends StatelessWidget {
  const WavyUnderline({
    super.key,
    this.width = 46,
    this.amplitude = 2.6,
    this.strokeWidth = 1.6,
    this.color,
  });

  /// Длина линии.
  final double width;

  /// Высота «гребня» волны в обе стороны от середины.
  final double amplitude;

  /// Толщина штриха.
  final double strokeWidth;

  /// Цвет линии; `null` — цвет акцента темы.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color stroke = color ?? Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: width,
      height: amplitude * 2 + strokeWidth,
      child: CustomPaint(
        painter: _WavyUnderlinePainter(
          color: stroke,
          amplitude: amplitude,
          strokeWidth: strokeWidth,
        ),
      ),
    );
  }
}

/// Рисует волну дугами Безье: каждая «полуволна» — дуга вверх или вниз.
class _WavyUnderlinePainter extends CustomPainter {
  const _WavyUnderlinePainter({
    required this.color,
    required this.amplitude,
    required this.strokeWidth,
  });

  final Color color;
  final double amplitude;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final double mid = size.height / 2;
    final double width = size.width;
    // Длина одного «зуба» — 6: при короткой линии волна не превращается в
    // точку, при длинной — не мельтешит.
    final int teeth = math.max(2, (width / 6).round());

    final Path path = Path()..moveTo(0, mid);
    for (int i = 0; i < teeth; i++) {
      final double x0 = width * i / teeth;
      final double x1 = width * (i + 1) / teeth;
      // Чётные зубы идут вверх, нечётные — вниз: получается ровная волна.
      final double peak = i.isEven ? mid - amplitude : mid + amplitude;
      path.quadraticBezierTo((x0 + x1) / 2, peak, x1, mid);
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_WavyUnderlinePainter old) =>
      old.color != color ||
      old.amplitude != amplitude ||
      old.strokeWidth != strokeWidth;
}
