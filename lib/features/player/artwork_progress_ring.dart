import 'dart:math' as math;
import 'dart:ui' show PathMetric, Tangent;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/player_controller.dart';

/// Кольцо прогресса вокруг обложки — волнистое, как
/// `CircularWavyProgressIndicator` в ArchiveTune
/// (`ui/player/MiniPlayerComponents.kt`): залитая часть идёт по периметру
/// обложки и показывает позицию трека, пока трек грузится — неопределённое
/// (крутится).
///
/// В `material_3_expressive` есть готовый `M3EProgressIndicator.circularWavy`,
/// но он гонит волну постоянно, даже когда значение известно. Для кольца это
/// лишнее: островок и панель крутили бы кадры без остановки (и `pumpAndSettle`
/// в тестах не дожидался бы тишины). Поэтому волну рисуем сами по той же
/// формуле, что и пакет (`radius + amplitude * sin(arcLength * waveK)`):
/// у определённого кольца она стоит, у неопределённого — крутится.
///
/// Форму кольца задаёт форма обложки: в островке обложка круглая, в правой
/// панели — скруглённый квадрат (как и крупная обложка полноэкранного плеера).
///
/// Позицию слушаем точечно (`select`): тик позиции перестраивает только кольцо,
/// а не обложку и не всё вокруг.
class ArtworkProgressRing extends ConsumerWidget {
  const ArtworkProgressRing({
    super.key,
    required this.side,
    required this.shape,
    this.strokeWidth = 3.5,
  });

  /// Сторона обложки, вокруг которой идёт кольцо.
  final double side;

  /// Скругление обложки. Полностью круглое — кольцо выйдет кругом.
  final BorderRadius shape;

  /// Толщина кольца — как у дорожки полосы перемотки.
  final double strokeWidth;

  /// Амплитуда волны, логические пиксели.
  ///
  /// Не 1.6 как в пакете: к кольцу добавляется ещё и толщина штриха, и вдвоём
  /// они давали вокруг небольшой обложки островка слишком толстую «колбасу».
  static const double waveAmplitude = 1.0;

  /// Толщина кольца в правой панели: обложка крупная, тонкая линия на ней
  /// потерялась бы.
  static const double panelStroke = 5;

  /// Габарит кольца вокруг обложки со стороной [side].
  ///
  /// Кольцо центрируется на кромке обложки, а волна выходит за неё на
  /// [waveAmplitude] — поэтому места нужно на толщину и амплитуду с каждой
  /// стороны. Компоновка (островок, панель) считает по этому значению, чтобы
  /// кольцо не обрезалось.
  static double extent(double side, double strokeWidth) =>
      side + 2 * (strokeWidth + waveAmplitude);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Прогресс и загрузку берём одним значением: запись сравнивается по
    // значению, поэтому перестройка приходит только на смену позиции или
    // состояния загрузки.
    final (double progress, bool loading) = ref.watch(
      playerControllerProvider.select(
        (PlayerUiState s) => (_progressOf(s), s.isLoading),
      ),
    );
    final double box = extent(side, strokeWidth);

    // Осевая линия кольца: контур обложки, раздутый на полтолщины, — тогда
    // внутренний край штриха ложится ровно на кромку обложки. Круг — частный
    // случай: радиус равен половине стороны.
    final RRect axis = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(box / 2, box / 2),
        width: side + strokeWidth,
        height: side + strokeWidth,
      ),
      Radius.circular(shape.topLeft.x + strokeWidth / 2),
    );

    // Кольцо только показывает прогресс: нажатия по обложке (и по всему
    // островку) оно не перехватывает.
    return IgnorePointer(
      child: SizedBox(
        width: box,
        height: box,
        child: _WavyRing(
          // Пока трек грузится — неопределённое кольцо (крутится), как в эталоне.
          progress: loading ? null : progress,
          size: box,
          axis: axis,
          strokeWidth: strokeWidth,
          activeColor: scheme.primary,
          trackColor: scheme.onSurface.withValues(alpha: 0.16),
        ),
      ),
    );
  }
}

/// Прогресс от 0 до 1 с тем же запасным источником длительности, что и у
/// полосы перемотки: у потока через посредника движок длительность не отдаёт,
/// и без запаса кольцо всегда стояло бы на нуле.
double _progressOf(PlayerUiState s) {
  final Duration engine = s.playback.duration;
  final Duration duration =
      engine > Duration.zero ? engine : (s.current?.duration ?? Duration.zero);
  if (duration.inMilliseconds <= 0) return 0;
  return (s.playback.position.inMilliseconds / duration.inMilliseconds)
      .clamp(0.0, 1.0);
}

/// Кольцо вдоль осевой линии [axis] — круга или скруглённого квадрата.
class _WavyRing extends StatefulWidget {
  const _WavyRing({
    required this.progress,
    required this.size,
    required this.axis,
    required this.strokeWidth,
    required this.activeColor,
    required this.trackColor,
  });

  /// `null` — прогресс неизвестен, кольцо неопределённое.
  final double? progress;
  final double size;

  /// Осевая линия кольца.
  final RRect axis;
  final double strokeWidth;
  final Color activeColor;
  final Color trackColor;

  @override
  State<_WavyRing> createState() => _WavyRingState();
}

class _WavyRingState extends State<_WavyRing>
    with SingleTickerProviderStateMixin {
  /// Оборот неопределённого кольца в секунду. Определённое кольцо контроллер
  /// не крутит: волна у него стоит.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

  @override
  void initState() {
    super.initState();
    if (widget.progress == null) _controller.repeat();
  }

  @override
  void didUpdateWidget(_WavyRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Вращение нужно только неопределённому кольцу; переключаем на ходу,
    // чтобы загрузка не оставляла за собой бегущие кадры.
    if (widget.progress == null) {
      if (!_controller.isAnimating) _controller.repeat();
    } else if (_controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? _) {
          return CustomPaint(
            size: Size.square(widget.size),
            painter: _WavyRingPainter(
              progress: widget.progress,
              axis: widget.axis,
              strokeWidth: widget.strokeWidth,
              activeColor: widget.activeColor,
              trackColor: widget.trackColor,
              amplitude: ArtworkProgressRing.waveAmplitude,
              rotation: widget.progress == null
                  ? _controller.value * 2 * math.pi
                  : 0,
            ),
          );
        },
      ),
    );
  }
}

class _WavyRingPainter extends CustomPainter {
  _WavyRingPainter({
    required this.progress,
    required this.axis,
    required this.strokeWidth,
    required this.activeColor,
    required this.trackColor,
    required this.amplitude,
    required this.rotation,
  });

  /// `null` — неопределённый прогресс.
  final double? progress;
  final RRect axis;
  final double strokeWidth;
  final Color activeColor;
  final Color trackColor;
  final double amplitude;

  /// Поворот всего кольца — для неопределённого состояния.
  final double rotation;

  /// Длина волны, логические пиксели.
  ///
  /// 10, а не 15 как у пакета: так гребни идут заметно чаще. Значение
  /// фиксированное (как и в эталонном индикаторе), поэтому на крупной обложке
  /// панели волн просто больше.
  static const double wavelength = 10;

  @override
  void paint(Canvas canvas, Size size) {
    final Path base = Path()..addRRect(axis);
    final PathMetric metric = base.computeMetrics().first;
    final double total = metric.length;
    if (total <= 0) return;

    final double waves = math.max(1, (total / wavelength).roundToDouble());
    final double waveK = waves / total;

    final Paint activePaint = _strokePaint(activeColor);
    final Paint trackPaint = _strokePaint(trackColor);

    // Старт — сверху по центру, как у кругового индикатора (там −90°).
    final double start = axis.width / 2 - axis.tlRadiusX;
    final Offset center = axis.center;

    canvas.save();
    if (rotation != 0) {
      final Offset pivot = size.center(Offset.zero);
      canvas
        ..translate(pivot.dx, pivot.dy)
        ..rotate(rotation)
        ..translate(-pivot.dx, -pivot.dy);
    }

    final double? p = progress;
    if (p == null) {
      // Неопределённое: плоская дорожка плюс бегущая по кругу волнистая дуга.
      canvas.drawPath(
        _segment(metric, center, total, start, total, 0, waveK),
        trackPaint,
      );
      canvas.drawPath(
        _segment(metric, center, total, start, total * 0.3, amplitude, waveK),
        activePaint,
      );
    } else {
      final double clamped = p.clamp(0.0, 1.0);
      final double active = clamped * total;
      if (clamped >= 1.0) {
        canvas.drawPath(
          _segment(metric, center, total, start, total, amplitude, waveK),
          activePaint,
        );
      } else {
        // Разрыв между заливкой и дорожкой — как `gapSize` у пакета.
        final double gap = strokeWidth;
        final double trackLength = total - active - gap * 2;
        if (trackLength > 0) {
          canvas.drawPath(
            _segment(
              metric,
              center,
              total,
              start + active + gap,
              trackLength,
              0,
              waveK,
            ),
            trackPaint,
          );
        }
        if (active > 0) {
          canvas.drawPath(
            _segment(metric, center, total, start, active, amplitude, waveK),
            activePaint,
          );
        }
      }
    }
    canvas.restore();
  }

  Paint _strokePaint(Color color) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = strokeWidth
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = color
    ..isAntiAlias = true;

  /// Волнистый отрезок вдоль осевой линии.
  ///
  /// Каждую точку сдвигаем по нормали на синус от пройденного пути: так волна
  /// одинакова и на прямых участках, и на скруглениях. Направление контура не
  /// задаём заранее — нормаль разворачиваем по радиусу от центра, чтобы волна
  /// всегда шла наружу, а не пряталась под обложку.
  Path _segment(
    PathMetric metric,
    Offset center,
    double total,
    double offset,
    double length,
    double amplitude,
    double waveK,
  ) {
    final Path path = Path();
    final int steps = math.max(24, (length / 1.5).ceil());
    for (int i = 0; i <= steps; i++) {
      final double t = i / steps;
      final double distance = (offset + length * t) % total;
      final Tangent? tangent = metric.getTangentForOffset(distance);
      if (tangent == null) continue;
      Offset normal = Offset(
        math.sin(tangent.angle),
        -math.cos(tangent.angle),
      );
      final Offset radial = tangent.position - center;
      if (normal.dx * radial.dx + normal.dy * radial.dy < 0) {
        normal = -normal;
      }
      final double wave = amplitude * math.sin(distance * waveK);
      final Offset point = tangent.position + normal * wave;
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    return path;
  }

  @override
  bool shouldRepaint(_WavyRingPainter old) =>
      old.progress != progress ||
      old.axis != axis ||
      old.strokeWidth != strokeWidth ||
      old.activeColor != activeColor ||
      old.trackColor != trackColor ||
      old.amplitude != amplitude ||
      old.rotation != rotation;
}
