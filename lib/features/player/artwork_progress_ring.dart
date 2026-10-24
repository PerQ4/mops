import 'dart:math' as math;
import 'dart:ui' show PathMetric, Tangent;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/motion.dart';
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
  });

  /// Сторона обложки, вокруг которой идёт кольцо.
  final double side;

  /// Скругление обложки. Полностью круглое — кольцо выйдет кругом.
  final BorderRadius shape;

  /// Сторона обложки, на которой закреплены пропорции кольца, — островок.
  ///
  /// Эталон (`M3ECircularProgressTheme.defaults`) рассчитан на индикатор
  /// 48 dp: штрих 4, амплитуда 1.6, длина волны 15, — и в мини-плеере
  /// ArchiveTune (`MiniPlayerComponents.kt`) обложка 42 обёрнута индикатором
  /// 52 dp. На нашей стороне 44 те же пропорции дают штрих 3.67, амплитуду
  /// 1.47 и волну 13.75 — эти значения и берём.
  ///
  /// Раньше здесь стояла волна длиной 2: гребни «чаще» дали период **меньше
  /// толщины штриха**, синус выродился в дрожание вдоль кромки, и кольцо
  /// читалось рваным облаком, а не волной. Волна обязана быть заметно длиннее
  /// штриха — иначе это не форма, а шум.
  static const double _refSide = 44;

  /// Толщина штриха на стороне [_refSide].
  static const double _refStroke = 3.5;

  /// Амплитуда волны на стороне [_refSide].
  ///
  /// Заметно меньше половины штриха, но не «ниточка»: волна должна читаться
  /// как волна, а не как дрожание кромки.
  static const double _refAmplitude = 2.8;

  /// Длина волны на стороне [_refSide].
  ///
  /// Волна короткая — примерно треть толщины штриха на гребень. Эталонные 15
  /// на 48 давали на кольце вокруг обложки всего десяток огромных горбов: на
  /// кольце из 150 px длины волна в 14 px выглядит как бугор, а не как рябь.
  /// Здесь гребней около тридцати, и волна видна и на островке, и в панели.
  static const double _refWavelength = 11;

  /// Предел толщины кольца.
  ///
  /// Пропорция от 44 на крупной обложке панели давала 16 px — это уже плита
  /// вокруг картинки, а не кольцо. Толщина растёт вместе с обложкой только до
  /// предела; дальше кольцо остаётся кольцом.
  static const double _maxStroke = 6;

  /// Предел амплитуды волны — в тех же пропорциях к пределу штриха.
  static const double _maxAmplitude = 4.5;

  /// Толщина кольца для обложки [side].
  static double strokeFor(double side) =>
      (side * (_refStroke / _refSide)).clamp(1.5, _maxStroke);

  /// Амплитуда волны для обложки [side].
  static double amplitudeFor(double side) =>
      (side * (_refAmplitude / _refSide)).clamp(0.6, _maxAmplitude);

  /// Длина волны для обложки [side].
  static double wavelengthFor(double side) =>
      (side * (_refWavelength / _refSide)).clamp(4.0, 52.0);

  /// Габарит кольца вокруг обложки со стороной [side].
  ///
  /// Осевая линия идёт по кромке, раздутой на полштриха, сам штрих ложится на
  /// неё половиной наружу, а волна добавляет амплитуду — значит за каждую
  /// сторону обложки выходит `штрих + амплитуда`. Считаем точно, а не
  /// постоянным множителем: штрих ограничен сверху, и на крупной обложке доля
  /// габарита от стороны меньше.
  static double extent(double side) =>
      side + 2 * (strokeFor(side) + amplitudeFor(side));

  /// Сторона обложки, которая впишется в ширину [width] вместе с кольцом.
  ///
  /// Компоновка знает доступную ширину, а не сторону. Решаем подстановкой:
  /// вычет (штрих и амплитуда) зависит от стороны слабо и ограничен сверху,
  /// поэтому трёх шагов хватает с запасом.
  static double sideForWidth(double width) {
    double side = width;
    for (int i = 0; i < 3; i++) {
      side = width - 2 * (strokeFor(side) + amplitudeFor(side));
    }
    return math.max(0, side);
  }

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
    final double stroke = strokeFor(side);
    final double box = extent(side);

    // Осевая линия кольца: контур обложки, раздутый на полтолщины, — тогда
    // внутренний край штриха ложится ровно на кромку обложки. Круг — частный
    // случай: радиус равен половине стороны.
    final RRect axis = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(box / 2, box / 2),
        width: side + stroke,
        height: side + stroke,
      ),
      Radius.circular(shape.topLeft.x + stroke / 2),
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
          strokeWidth: stroke,
          amplitude: amplitudeFor(side),
          wavelength: wavelengthFor(side),
          activeColor: scheme.primary,
          // Дорожка из эталона (`MiniPlayer.kt`, стиль без фона обложки):
          // `colorScheme.outline` с альфой 0.18 — заметно, но не спорит с
          // заливкой `primary`.
          trackColor: scheme.outline.withValues(alpha: 0.18),
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
    required this.amplitude,
    required this.wavelength,
    required this.activeColor,
    required this.trackColor,
  });

  /// `null` — прогресс неизвестен, кольцо неопределённое.
  final double? progress;
  final double size;

  /// Осевая линия кольца.
  final RRect axis;
  final double strokeWidth;
  final double amplitude;
  final double wavelength;
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
    duration: AppMotion.progressSpin,
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
              amplitude: widget.amplitude,
              wavelength: widget.wavelength,
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
    required this.wavelength,
    required this.rotation,
  });

  /// `null` — неопределённый прогресс.
  final double? progress;
  final RRect axis;
  final double strokeWidth;
  final Color activeColor;
  final Color trackColor;
  final double amplitude;

  /// Длина волны, логические пиксели. Приходит от размера обложки.
  final double wavelength;

  /// Поворот всего кольца — для неопределённого состояния.
  final double rotation;

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

    // Старт — сверху по центру, как у эталонного кругового индикатора (там
    // дуга начинается с −90° и идёт по часовой стрелке). Путь `RRect` в Skia
    // начинается не сверху: он идёт по часовой от низа левой кромки, поэтому
    // смещение считаем оттуда — левая сторона, четверть скругления, половина
    // верхней стороны. Прежняя формула `width/2 - radius` давала для круга
    // 9 часов, а для квадрата — середину левой стороны, и заливка начиналась
    // не сверху.
    final double start = _topCenterOffset(axis);
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
        // Зазор между заливкой и дорожкой — из эталона: `gapAngle * radius`,
        // то есть `gapSize + (штрих + дорожка) / 2`. У M3 `gapSize` равен
        // толщине кольца, поэтому зазор = два штриха. Как и в эталоне, на
        // самом старте зазор ужимается до длины заливки, иначе он «съел» бы
        // дорожку целиком.
        final double gap = 2 * strokeWidth;
        final double applied = math.min(active, gap);
        final double trackLength = total - active - applied * 2;
        if (trackLength > 0) {
          canvas.drawPath(
            _segment(
              metric,
              center,
              total,
              start + active + applied,
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

  /// Смещение начала кольца до верхней точки осевой линии.
  ///
  /// Путь `RRect` в Skia начинается внизу левой кромки и идёт по часовой
  /// стрелке; до верхней точки по центру — левая сторона, четверть
  /// скругления и половина верхней стороны.
  static double _topCenterOffset(RRect axis) {
    final double radius = axis.tlRadiusX;
    return (axis.height - 2 * radius) +
        math.pi * radius / 2 +
        (axis.width / 2 - radius);
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
    // Шаг выборки привязан к волне, а не к длине: короткая волна требует
    // плотной выборки. Прежние 1.5 px на шаг оставляли на гребень меньше двух
    // точек, и волна вырождалась в случайную рябь — именно так кольцо и
    // выглядело «багованным».
    final double waves = waveK * total;
    final int steps = math.max(96, (waves * 8).round());
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
      old.wavelength != wavelength ||
      old.rotation != rotation;
}
