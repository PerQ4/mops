import 'dart:ui' show PathMetric, Tangent;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/audio/audio_level_monitor.dart';
import '../data/local/app_settings.dart';
import '../state/providers.dart';

/// «Гало» вокруг обложки, дышащее по реальному звуку, и спектр полос.
///
/// Источник — libmpv: монитор отдаёт и общий уровень, и восемь полос частот
/// (см. [AudioLevelMonitor]). Вид выбирается в настройках, но здесь, а не в
/// экране плеера: экран передаёт только размеры и цвета, и добавление вида не
/// должно требовать правок в нём.
///
/// «Гало» — прежний вид: толщина и яркость кольца идут за уровнем. «Полосы» —
/// восемь полос, зеркально разложенных по краю обложки: низкие частоты внизу,
/// высокие — по сторонам. Движение всегда следует за звуком, а не за позицией
/// трека — на паузе монитор отдаёт нули и ничего не рисуется. Если полос в
/// сборке libmpv нет, «Полосы» честно показывают гало, а не выдуманный спектр.
class SpectrumVisualizer extends ConsumerWidget {
  const SpectrumVisualizer({
    super.key,
    required this.monitor,
    required this.artworkInset,
    required this.cornerRadius,
    required this.colors,
  });

  /// Источник уровня и полос.
  final AudioLevelMonitor monitor;

  /// Насколько обложка отступает внутрь области гало: кольцо и полосы рисуются
  /// в этом зазоре, поэтому обложку не приходится ничем перекрывать.
  final double artworkInset;

  /// Радиус скругления гало — как у обложки плюс отступ.
  final double cornerRadius;

  /// Три цвета палитры обложки — те же, что у фона плеера.
  final List<Color> colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final VisualizerStyle style = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => s.visualizerStyle,
      ),
    );
    // Перерисовывается только визуализатор: подписка идёт на монитор, а не на
    // весь экран.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: monitor,
        builder: (BuildContext context, Widget? child) {
          final bool bars =
              style == VisualizerStyle.bars && monitor.spectrumAvailable;
          return CustomPaint(
            size: Size.infinite,
            painter: bars
                ? _BarsPainter(
                    // Копия: painter сравнивает старое и новое содержимое, а
                    // монитор обновляет свой список на месте.
                    bands: List<double>.of(monitor.bands),
                    inset: artworkInset,
                    cornerRadius: cornerRadius,
                    colors: colors,
                  )
                : _HaloPainter(
                    level: monitor.level,
                    inset: artworkInset,
                    cornerRadius: cornerRadius,
                    colors: colors,
                  ),
          );
        },
      ),
    );
  }
}

/// Честная подпись вместо выдуманной анимации.
///
/// Если данных нет (в сборке libmpv нет ни графа `lavfi`, ни `astats`),
/// показать «живой» визуализатор нечем: любое движение здесь было бы не связано
/// со звуком. Вместо этого пишем причину словами самого mpv.
class SpectrumUnavailableNote extends StatelessWidget {
  const SpectrumUnavailableNote({super.key, required this.monitor});

  final AudioLevelMonitor monitor;

  /// Высота подписи: по ней в `_ArtworkStage` уменьшается обложка, чтобы колонка
  /// не переполнилась на низком окне.
  static const double height = 34;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: monitor,
      builder: (BuildContext context, Widget? child) {
        if (monitor.availability != AudioLevelAvailability.unavailable) {
          return const SizedBox.shrink();
        }
        final String? reason = monitor.reason;
        return SizedBox(
          height: height,
          child: Center(
            child: Text(
              reason == null
                  ? 'Визуализатор: данные о звуке недоступны'
                  : 'Визуализатор: данные о звуке недоступны — $reason',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        );
      },
    );
  }
}

class _HaloPainter extends CustomPainter {
  const _HaloPainter({
    required this.level,
    required this.inset,
    required this.cornerRadius,
    required this.colors,
  });

  final double level;
  final double inset;
  final double cornerRadius;
  final List<Color> colors;

  Color _color(int index) {
    if (colors.isEmpty) return const Color(0xFFFFFFFF);
    return index < colors.length ? colors[index] : colors.last;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Тишина — ничего не рисуем: пустое гало честнее выдуманного движения.
    if (level <= 0.002) return;

    final Rect rect = (Offset.zero & size).deflate(inset);
    if (rect.isEmpty) return;
    final RRect shape =
        RRect.fromRectAndRadius(rect, Radius.circular(cornerRadius));

    // Мягкое свечение: широкий мазок малой прозрачности. Размытие — только по
    // контуру кольца, площадь маленькая, поэтому оно не бьёт по кадрам.
    canvas.drawRRect(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10 + 26 * level
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 8 + 14 * level)
        ..color = _color(1).withValues(alpha: 0.08 + 0.30 * level),
    );

    // Основное кольцо: чем громче, тем толще и ярче.
    canvas.drawRRect(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 + 5 * level
        ..color = _color(0).withValues(alpha: 0.30 + 0.60 * level),
    );

    // Внутренняя линия — «второе дыхание» гало, ближе к обложке.
    canvas.drawRRect(
      shape.deflate(5 + 5 * level),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = _color(2).withValues(alpha: 0.18 + 0.45 * level),
    );
  }

  @override
  bool shouldRepaint(covariant _HaloPainter old) =>
      old.level != level ||
      old.inset != inset ||
      old.cornerRadius != cornerRadius ||
      !listEquals(old.colors, colors);
}

/// Спектр по краю обложки: полосы растут наружу из внутреннего прямоугольника.
///
/// Полос восемь, а рисуется шестнадцать: набор зеркалится, иначе на большом
/// кольце восемь штрихов выглядели бы редкими. Низкие частоты оказываются внизу
/// и вверху, высокие — по бокам. Длина штриха — уровень полосы, цвет — палитра
/// обложки: так спектр читается и на светлой, и на тёмной обложке.
class _BarsPainter extends CustomPainter {
  const _BarsPainter({
    required this.bands,
    required this.inset,
    required this.cornerRadius,
    required this.colors,
  });

  final List<double> bands;
  final double inset;
  final double cornerRadius;
  final List<Color> colors;

  static const int _bars = 16;

  Color _color(int index) {
    if (colors.isEmpty) return const Color(0xFFFFFFFF);
    return index < colors.length ? colors[index] : colors.last;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (bands.isEmpty) return;
    final Rect rect = (Offset.zero & size).deflate(inset);
    if (rect.isEmpty) return;

    final Path path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(cornerRadius)),
      );
    final double perimeter = path
        .computeMetrics()
        .fold(0.0, (double sum, PathMetric m) => sum + m.length);
    if (perimeter <= 0) return;

    // Длина — в зазоре между обложкой и краем: дальше начинается обложка.
    final double maxLength = (inset - 3).clamp(1.0, inset);
    final double thickness = (perimeter / _bars * 0.5).clamp(2.0, 6.0);
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    int index = 0;
    for (final PathMetric metric in path.computeMetrics()) {
      for (int i = 0; i < _bars; i++) {
        final double offset = (i + 0.5) / _bars * metric.length;
        final Tangent? tangent = metric.getTangentForOffset(offset);
        if (tangent == null) continue;
        final double value = _valueAt(index++);
        // Нормаль наружу: путь обходится по часовой стрелке, поэтому поворот
        // касательной на −90° даёт направление от обложки к краю.
        final Offset direction = tangent.vector;
        final Offset normal = Offset(direction.dy, -direction.dx);
        final Offset start = tangent.position + normal * 2;
        final Offset end = start + normal * (1 + maxLength * value);

        paint
          ..strokeWidth = thickness
          ..color = Color.lerp(_color(0), _color(2), value)!
              .withValues(alpha: 0.30 + 0.65 * value);
        canvas.drawLine(start, end, paint);
      }
    }
  }

  /// Значение штриха: первая половина — полосы от низких к высоким, вторая —
  /// обратно, чтобы спектр был симметричным.
  double _valueAt(int index) {
    final int n = bands.length;
    final int i = index < n ? index : (2 * n - 1 - index) % n;
    return bands[i].clamp(0.0, 1.0);
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) =>
      !listEquals(old.bands, bands) ||
      old.inset != inset ||
      old.cornerRadius != cornerRadius ||
      !listEquals(old.colors, colors);
}
