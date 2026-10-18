import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/audio/audio_level_monitor.dart';

/// «Гало» вокруг обложки, дышащее по реальному уровню звука.
///
/// Полос здесь нет и быть не может: libmpv отдаёт один общий уровень (RMS) на
/// весь трек, а не спектр по частотам — фильтров `aspectralstats`/`showcqt` в
/// поставляемой сборке нет (см. [AudioLevelMonitor]). Поэтому гало дышит целиком:
/// толщина и яркость кольца идут за уровнем. Движение всегда следует за звуком, а
/// не за позицией трека — на паузе монитор отдаёт ноль и кольцо не рисуется.
class SpectrumVisualizer extends StatelessWidget {
  const SpectrumVisualizer({
    super.key,
    required this.monitor,
    required this.artworkInset,
    required this.cornerRadius,
    required this.colors,
  });

  /// Источник уровня.
  final AudioLevelMonitor monitor;

  /// Насколько обложка отступает внутрь области гало: кольцо рисуется в этом
  /// зазоре, поэтому обложку не приходится ничем перекрывать.
  final double artworkInset;

  /// Радиус скругления гало — как у обложки плюс отступ.
  final double cornerRadius;

  /// Три цвета палитры обложки — те же, что у фона плеера.
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    // Перерисовывается только гало: подписка идёт на монитор, а не на весь экран.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: monitor,
        builder: (BuildContext context, Widget? child) => CustomPaint(
          size: Size.infinite,
          painter: _HaloPainter(
            level: monitor.level,
            inset: artworkInset,
            cornerRadius: cornerRadius,
            colors: colors,
          ),
        ),
      ),
    );
  }
}

/// Честная подпись вместо выдуманной анимации.
///
/// Если уровня нет (в сборке libmpv для Windows нет фильтра `astats`), показать
/// «живое» гало нечем: любое движение здесь было бы не связано со звуком. Вместо
/// этого пишем причину словами самого mpv.
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
                  ? 'Визуализатор: уровень звука недоступен'
                  : 'Визуализатор: уровень звука недоступен — $reason',
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

  Color _color(int index) =>
      index < colors.length ? colors[index] : colors.last;

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
