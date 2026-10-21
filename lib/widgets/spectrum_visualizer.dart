import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/audio/audio_level_monitor.dart';
import '../core/theme/motion.dart';
import '../data/local/app_settings.dart';
import '../state/providers.dart';

/// Свет и спектр у обложки, дышащие по реальному звуку.
///
/// Источник — libmpv: монитор отдаёт и общий уровень, и восемь полос частот
/// (см. [AudioLevelMonitor]). Вид выбирается в настройках, но здесь, а не в
/// экране плеера: экран передаёт только размеры и цвета, и добавление вида не
/// должно требовать правок в нём.
///
/// «Гало» — мягкое радиальное свечение позади обложки: несколько размытых пятен
/// цвета палитры, выходящих за её края. Контурных линий нет: яркость и размер
/// пятен идут за уровнем, поэтому в тишине свет спокойный, а на громком месте
/// разгорается. «Полосы» — slim-эквалайзер под обложкой: девять полос с
/// круглыми торцами, низкие частоты в центре, высокие по краям, градиент от
/// основного цвета палитры к акцентному.
///
/// Движение всегда следует за звуком, а не за позицией трека — на паузе монитор
/// отдаёт нули и всё замирает. Между опросами монитора (30 раз в секунду)
/// значения дорисовываются покадрово по кривой из [AppMotion]: без этого
/// полосы дёргались бы шагами. Если полос в сборке libmpv нет, «Полосы» честно
/// показывают свечение, а не выдуманный спектр.
class SpectrumVisualizer extends ConsumerStatefulWidget {
  const SpectrumVisualizer({
    super.key,
    required this.monitor,
    required this.artworkInset,
    required this.cornerRadius,
    required this.colors,
  });

  /// Источник уровня и полос.
  final AudioLevelMonitor monitor;

  /// Насколько обложка отступает внутрь области: свечение и полосы рисуются в
  /// этом зазоре, поэтому обложку не приходится ничем перекрывать.
  final double artworkInset;

  /// Радиус скругления области — как у обложки плюс отступ.
  final double cornerRadius;

  /// Три цвета палитры обложки — те же, что у фона плеера.
  final List<Color> colors;

  @override
  ConsumerState<SpectrumVisualizer> createState() => _SpectrumVisualizerState();
}

class _SpectrumVisualizerState extends ConsumerState<SpectrumVisualizer>
    with SingleTickerProviderStateMixin {
  /// Полосы и уровень догоняют цель по кривой из словаря движений.
  ///
  /// Цель приходит от монитора тридцать раз в секунду. Рисовать её напрямую
  /// нельзя: шаг в 33 мс на быстрой атаке читается как дёрганье. Поэтому между
  /// опросами значения едут к цели по кривой, которую задаёт
  /// [MotionTransition] из [AppMotion].
  late final List<_Follow> _bands = <_Follow>[];
  late _Follow _level;

  late final Ticker _ticker;

  /// Собственное монотонное время: `Ticker` после остановки начинает отсчёт
  /// заново, а перезапускать интерполяцию с нуля нельзя.
  Duration _clock = Duration.zero;
  Duration? _lastTick;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _level = _Follow(curve: _breathCurve);
    _resizeBands(widget.monitor.bands.length);
    widget.monitor.addListener(_onMonitor);
    _readTargets(instant: true);
  }

  @override
  void didUpdateWidget(covariant SpectrumVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.monitor != widget.monitor) {
      oldWidget.monitor.removeListener(_onMonitor);
      widget.monitor.addListener(_onMonitor);
      _resizeBands(widget.monitor.bands.length);
      _readTargets(instant: true);
    }
  }

  @override
  void dispose() {
    widget.monitor.removeListener(_onMonitor);
    _ticker.dispose();
    super.dispose();
  }

  /// Общий уровень дышит медленнее полос: свечение не должно повторять каждую
  /// долю секунды, иначе оно превращается в мигание.
  Duration get _levelSpan => AppMotion.spectrumBreath.duration;

  Curve get _breathCurve => AppMotion.spectrumBreath.curve;

  Duration get _bandSpan => AppMotion.spectrumFollow.duration;

  Curve get _bandCurve => AppMotion.spectrumFollow.curve;

  void _resizeBands(int count) {
    final int size = count <= 0 ? AudioLevelMonitor.bandCount : count;
    while (_bands.length < size) {
      _bands.add(_Follow(curve: _bandCurve));
    }
    while (_bands.length > size) {
      _bands.removeLast();
    }
  }

  void _onMonitor() {
    _readTargets(instant: AppMotion.animationsDisabled);
    if (!mounted) return;
    setState(() {});
  }

  void _readTargets({required bool instant}) {
    final Duration now = _clock;
    final List<double> source = widget.monitor.bands;
    _resizeBands(source.length);
    if (instant) {
      _level.jump(widget.monitor.level);
      for (int i = 0; i < _bands.length; i++) {
        _bands[i].jump(i < source.length ? source[i] : 0);
      }
      _stopTicker();
      return;
    }
    _level.aim(widget.monitor.level, now);
    for (int i = 0; i < _bands.length; i++) {
      _bands[i].aim(i < source.length ? source[i] : 0, now);
    }
    _ensureTicker();
  }

  bool get _needsTick =>
      _level.isMoving || _bands.any((_Follow f) => f.isMoving);

  void _ensureTicker() {
    if (_ticker.isActive || !_needsTick) return;
    _lastTick = null;
    _ticker.start();
  }

  void _stopTicker() {
    if (_ticker.isActive) _ticker.stop();
    _lastTick = null;
  }

  void _onTick(Duration elapsed) {
    final Duration? last = _lastTick;
    _lastTick = elapsed;
    // Первый кадр после остановки не должен добавлять к времени весь простой:
    // он уже прожит, и значения должны просто продолжить путь с текущего места.
    if (last != null) _clock += elapsed - last;

    bool moving = false;
    if (_level.advance(_clock, _levelSpan)) moving = true;
    for (final _Follow band in _bands) {
      if (band.advance(_clock, _bandSpan)) moving = true;
    }
    if (!mounted) return;
    setState(() {});
    if (!moving) _stopTicker();
  }

  @override
  Widget build(BuildContext context) {
    final VisualizerStyle style = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.visualizerStyle),
    );
    final bool bars =
        style == VisualizerStyle.bars && widget.monitor.spectrumAvailable;
    // Перерисовывается только визуализатор: подписка идёт на монитор, а не на
    // весь экран.
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: bars
            ? SpectrumBarsPainter(
                // Копия: painter сравнивает старое и новое содержимое, а
                // значения берутся из изменяемых состояний интерполяции.
                bands: <double>[for (final _Follow f in _bands) f.value],
                level: _level.value,
                inset: widget.artworkInset,
                colors: widget.colors,
              )
            : SpectrumHaloPainter(
                level: _level.value,
                inset: widget.artworkInset,
                cornerRadius: widget.cornerRadius,
                colors: widget.colors,
              ),
      ),
    );
  }
}

/// Значение 0..1, которое догоняет цель по кривой и длительности из словаря.
///
/// Длительность приходит на каждый кадр, а не хранится: настройка «Отключить
/// анимации» обнуляет её через [AppMotion], и тогда значение должно вставать на
/// цель сразу.
class _Follow {
  _Follow({required this.curve});

  final Curve curve;

  double value = 0;
  double _from = 0;
  double _target = 0;
  Duration _startedAt = Duration.zero;

  /// Идёт ли ещё движение к цели.
  bool get isMoving => value != _target;

  /// Новая цель: движение начинается от текущего положения, поэтому значения
  /// не прыгают даже когда цель меняется тридцать раз в секунду.
  void aim(double target, Duration now) {
    final double next = target.clamp(0.0, 1.0);
    if ((next - _target).abs() < 0.0005) return;
    _from = value;
    _target = next;
    _startedAt = now;
  }

  /// Без движения — для «Отключить анимации» и первого кадра.
  void jump(double target) {
    value = _from = _target = target.clamp(0.0, 1.0);
    _startedAt = Duration.zero;
  }

  /// Сдвинуть значение к цели на текущий момент. `true` — движение не
  /// закончено, кадры нужны дальше.
  bool advance(Duration now, Duration span) {
    if (span <= Duration.zero) {
      value = _target;
      return false;
    }
    final double t = (now - _startedAt).inMicroseconds / span.inMicroseconds;
    if (t >= 1) {
      value = _target;
      return false;
    }
    final double eased = curve.transform(t.clamp(0.0, 1.0));
    value = (_from + (_target - _from) * eased).clamp(0.0, 1.0);
    return value != _target;
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

/// Мягкое радиальное свечение позади обложки.
///
/// Три круга света разного размера, цвета и смещения: основной источник снизу,
/// второй — сверху-справа другим цветом палитры, общая дымка связывает их.
/// Внутренняя часть пятен скрыта самой обложкой — виден только мягкий ореол в
/// зазоре, и он неодинаков по сторонам, поэтому свечение не читается ровной
/// рамкой. Свет складывается с фоном, а не закрашивает его, — так он выглядит
/// светом, а не цветной тенью.
///
/// Ни одной контурной линии: форма задаётся градиентом, а не обводкой.
class SpectrumHaloPainter extends CustomPainter {
  const SpectrumHaloPainter({
    required this.level,
    required this.inset,
    required this.cornerRadius,
    required this.colors,
  });

  final double level;
  final double inset;
  final double cornerRadius;
  final List<Color> colors;

  /// Ниже этого уровня света нет: пустое свечение честнее выдуманного.
  static const double _quiet = 0.003;

  Color _color(int index) {
    if (colors.isEmpty) return const Color(0xFFFFFFFF);
    return index < colors.length ? colors[index] : colors.last;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final double p = level.clamp(0.0, 1.0);
    if (p <= _quiet || size.isEmpty) return;
    final Rect art = (Offset.zero & size).deflate(inset);
    if (art.isEmpty) return;

    final double s = size.shortestSide;
    final Rect bounds = Offset.zero & size;
    // Мягкое появление на самом пороге: свечение не включается рывком.
    final double onset = (p / 0.06).clamp(0.0, 1.0);

    // Контейнерные роли в тёмной схеме тёмные: без подъёма светлоты свечение
    // было бы не светом, а тенью. Оттенок при этом остаётся палитры обложки.
    // В светлой схеме роли наоборот светлые, поэтому там цвет слегка
    // приглушается, а свет кладётся обычным наложением: аддитивное на светлом
    // фоне выжигало бы его в белый.
    final bool onLight = _color(0).computeLuminance() > 0.45;
    final BlendMode blend = onLight ? BlendMode.srcOver : BlendMode.plus;
    final double weight = onLight ? 0.55 : 1.0;
    Color lit(int index, double lightness) {
      final HSLColor hsl = HSLColor.fromColor(_color(index));
      final double l = onLight
          ? math.min(hsl.lightness, lightness - 0.12)
          : math.max(hsl.lightness, lightness);
      return hsl.withLightness(l.clamp(0.0, 1.0)).toColor();
    }

    canvas.saveLayer(bounds, Paint());
    // Свет живёт в мягком скруглённом прямоугольнике: так он не задевает углы
    // области, где обложка скруглена сильнее всего.
    canvas.clipRRect(
      RRect.fromRectAndRadius(
        bounds,
        Radius.circular(math.max(0.0, cornerRadius)),
      ),
    );

    // Круг света с длинным хвостом. Складываем свет, а не краску: несколько
    // источников дают живую неровность, и свечение читается как свет из-под
    // обложки, а не как цветная тень.
    void glow(Offset center, double radius, Color color, double alpha) {
      if (radius <= 0) return;
      final double a = (alpha * weight).clamp(0.0, 1.0);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..blendMode = blend
          ..shader = RadialGradient(
            colors: <Color>[
              color.withValues(alpha: a),
              color.withValues(alpha: a * 0.62),
              color.withValues(alpha: a * 0.20),
              color.withValues(alpha: 0),
            ],
            stops: const <double>[0.0, 0.40, 0.76, 1.0],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }

    // Основной источник — снизу-слева: там свет выглядывает шире всего, а верх
    // обложки остаётся в тени. Яркость и размер растут с уровнем, поэтому в
    // тишине свет едва тлеет, а на громком месте разгорается.
    glow(
      Offset(
        size.width * 0.38 - s * 0.030 * p,
        size.height * 0.62 + s * 0.020 * p,
      ),
      s * (0.58 + 0.10 * p),
      lit(0, 0.62),
      (0.18 + 0.42 * p) * onset,
    );

    // Второй источник — у правого края, другим цветом палитры: два пятна
    // разного оттенка не дают свечению слиться в ровную рамку. Сверху его нет
    // намеренно: иначе верхняя кромка обложки светится ровной линией.
    glow(
      Offset(size.width * 0.82, size.height * 0.44),
      s * (0.34 + 0.06 * p),
      lit(2, 0.56),
      (0.06 + 0.16 * p) * onset,
    );

    // Общая цветная дымка: связывает пятна и держит оттенок палитры, но центр
    // смещён вниз — верхняя кромка обложки остаётся в тени, иначе свечение
    // читается ровной рамкой.
    glow(
      Offset(size.width * 0.50, size.height * 0.68),
      s * (0.62 + 0.04 * p),
      lit(1, 0.48),
      (0.10 + 0.14 * p) * onset,
    );

    // Свет гаснет к краям области: без маски он обрывался бы о её границу
    // ровным прямоугольником.
    final double fade = s * 0.045;
    final Paint mask = Paint()..blendMode = BlendMode.dstIn;
    canvas.drawRect(
      bounds,
      mask
        ..shader = LinearGradient(
          colors: const <Color>[
            Color(0x00FFFFFF),
            Color(0xFFFFFFFF),
            Color(0xFFFFFFFF),
            Color(0x00FFFFFF),
          ],
          stops: <double>[0, fade / size.width, 1 - fade / size.width, 1],
        ).createShader(bounds),
    );
    canvas.drawRect(
      bounds,
      mask
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const <Color>[
            Color(0x00FFFFFF),
            Color(0xFFFFFFFF),
            Color(0xFFFFFFFF),
            Color(0x00FFFFFF),
          ],
          stops: <double>[0, fade / size.height, 1 - fade / size.height, 1],
        ).createShader(bounds),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant SpectrumHaloPainter old) =>
      old.level != level ||
      old.inset != inset ||
      old.cornerRadius != cornerRadius ||
      !listEquals(old.colors, colors);
}

/// Slim-эквалайзер под обложкой.
///
/// Девять полос с круглыми торцами: низкие частоты в центре, высокие — по
/// краям, поэтому ряд растёт из середины симметрично. Ширина ряда — доля
/// обложки, высота — в пределах зазора: полосы не заходят ни на обложку, ни за
/// край области. Цвет каждой полосы — точка градиента от первого цвета палитры
/// к третьему, поэтому ряд читается как один градиент, а не как набор штрихов.
class SpectrumBarsPainter extends CustomPainter {
  const SpectrumBarsPainter({
    required this.bands,
    required this.level,
    required this.inset,
    required this.colors,
  });

  final List<double> bands;
  final double level;
  final double inset;
  final List<Color> colors;

  /// Девять полос: центр — низкие частоты, края — высокие.
  static const int barCount = 9;

  /// Ниже этой высоты полоса перестаёт читаться как полоса.
  static const double _minHeight = 2.5;

  Color _color(int index) {
    if (colors.isEmpty) return const Color(0xFFFFFFFF);
    return index < colors.length ? colors[index] : colors.last;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || bands.isEmpty) return;
    final Rect art = (Offset.zero & size).deflate(inset);
    // Для полос нужен зазор хотя бы в несколько пикселей, иначе они не
    // помещаются между обложкой и краем области.
    if (art.isEmpty || inset < 8) return;

    // Полная тишина — ряд гаснет целиком: в покое визуализатор не должен
    // оставлять после себя застывшие точки.
    final double peak = bands.fold<double>(
      0,
      (double m, double b) => math.max(m, b),
    );
    final double presence = (peak / 0.05).clamp(0.0, 1.0);
    if (presence <= 0.001) return;

    // Низ ряда — у самого края области, верх — чуть ниже обложки: так
    // эквалайзер занимает весь отведённый зазор и не касается ни того, ни
    // другого.
    final double edge = (inset * 0.12).clamp(1.5, 3.0);
    final double bottom = size.height - edge;
    final double top = size.height - inset + edge;
    final double maxHeight = bottom - top;
    if (maxHeight <= _minHeight) return;
    final double minHeight = math.min(_minHeight, maxHeight);

    final double span = (art.width * 0.56).clamp(96.0, 280.0);
    final double pitch = span / (barCount - 1);
    final double thickness = (pitch * 0.44).clamp(3.0, 7.0);

    final double p = level.clamp(0.0, 1.0);
    // Роли палитры выравниваются по светлоте: в тёмной схеме контейнеры тёмные
    // и полосы сливались бы с фоном, в светлой — наоборот, светлее фона.
    final bool onLight = _color(0).computeLuminance() > 0.45;
    Color lit(Color color, double darkL, double lightL) {
      final HSLColor hsl = HSLColor.fromColor(color);
      final double l = onLight
          ? math.min(hsl.lightness, lightL)
          : math.max(hsl.lightness, darkL);
      return hsl.withLightness(l.clamp(0.0, 1.0)).toColor();
    }

    final Color primary = lit(_color(0), 0.70, 0.50);
    final Color accent = lit(_color(2), 0.64, 0.46);

    // Подсветка под рядом: мягкое цветное пятно, чтобы эквалайзер не висел в
    // пустоте. Оно тоже живёт в зазоре и не касается обложки.
    final Rect glowRect = Rect.fromCenter(
      center: Offset(size.width / 2, bottom - maxHeight * 0.45),
      width: span + thickness * 3,
      height: maxHeight + edge * 2,
    );
    canvas.drawRect(
      glowRect,
      Paint()
        // На светлом фоне аддитивное свечение выжигает подложку в белый —
        // там подкрашиваем обычным наложением.
        ..blendMode = onLight ? BlendMode.srcOver : BlendMode.plus
        ..shader = LinearGradient(
          colors: <Color>[
            primary.withValues(
              alpha: (0.18 + 0.22 * p) * (onLight ? 0.7 : 1) * presence,
            ),
            accent.withValues(
              alpha: (0.18 + 0.22 * p) * (onLight ? 0.7 : 1) * presence,
            ),
          ],
        ).createShader(glowRect)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, inset * 0.50),
    );

    final double center = size.width / 2;
    final Paint paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = thickness;

    for (int i = 0; i < barCount; i++) {
      final int offset = i - barCount ~/ 2;
      final double t = offset.abs() / (barCount ~/ 2);
      final double value = _valueAt(t);
      // Лёгкая кривая: тихие полосы чуть выше нуля и не дрожат на месте.
      final double shaped = math.pow(value, 0.85).toDouble();
      final double height = minHeight + (maxHeight - minHeight) * shaped;
      final double x = center + offset * pitch;
      final Color color = Color.lerp(
        primary,
        accent,
        (offset + barCount ~/ 2) / (barCount - 1),
      )!;
      paint.color = color.withValues(alpha: (0.34 + 0.66 * shaped) * presence);
      canvas.drawLine(Offset(x, bottom - height), Offset(x, bottom), paint);
    }
  }

  /// Значение полосы на доле [t] от центра (0 — низкие, 1 — высокие).
  ///
  /// Полос восемь, а столбиков девять: между центральным и крайними значения
  /// берутся с линейной вставкой, поэтому ряд симметричен и без провала в
  /// середине.
  double _valueAt(double t) {
    final int n = bands.length;
    if (n == 1) return bands.first.clamp(0.0, 1.0);
    final double position = t.clamp(0.0, 1.0) * (n - 1);
    final int lower = position.floor();
    final int upper = math.min(lower + 1, n - 1);
    final double mix = position - lower;
    final double a = bands[lower].clamp(0.0, 1.0);
    final double b = bands[upper].clamp(0.0, 1.0);
    return a + (b - a) * mix;
  }

  @override
  bool shouldRepaint(covariant SpectrumBarsPainter old) =>
      old.level != level ||
      old.inset != inset ||
      !listEquals(old.bands, bands) ||
      !listEquals(old.colors, colors);
}
