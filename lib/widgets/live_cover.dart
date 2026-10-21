import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/theme/expressive_shape.dart';
import '../core/theme/motion.dart';

/// «Живая обложка» полноэкранного плеера: очень лёгкий дрейф картинки и мягкий
/// свет по краям, который идёт за уровнем звука (задача 8.2).
///
/// Настоящий Canvas — короткое зацикленное видео, но в этом стеке видео нет: см.
/// отчёт по задаче. Здесь своя «живая обложка» без сети и без видео, целиком
/// офлайн.
///
/// Разделение работы выбрано по стоимости кадра:
///
/// * свет по краям и цветовой акцент на кромке — фрагментный шейдер
///   `shaders/live_cover.frag`: он перерисовывает один прямоугольник на GPU и не
///   трогает дерево виджетов;
/// * дрейф картинки — композитный `Transform` вокруг готовой обложки. Двигать
///   нужно саму фотографию, а шейдер её не видит, поэтому это единственный
///   способ обойтись без перерисовки изображения: `Transform` меняет только
///   матрицу слоя, растровая картинка остаётся прежней.
///
/// Обложка передаётся готовым виджетом ([child]) — тем же `Artwork`, что и
/// раньше: перелёт `Hero`, обрезка суперэллипсом и меню по правому клику живут
/// внутри и о «живой обложке» не знают. Внешняя обрезка повторяет ту же форму,
/// чтобы увеличенная картинка не вылезала за скруглённые углы.
///
/// Когда настройка выключена, возвращается [child] без единого лишнего слоя:
/// прежний вид сохраняется пиксель в пиксель.
class LiveCover extends StatefulWidget {
  const LiveCover({
    super.key,
    required this.child,
    required this.enabled,
    required this.animate,
    required this.level,
    required this.colors,
    this.radius = 16,
  });

  /// Обложка как есть — обычно `Artwork` с `heroTag`.
  final Widget child;

  /// Настройка «Живая обложка» (и не включены ли «Отключить анимации»).
  final bool enabled;

  /// Идёт воспроизведение. `false` — дрейф замирает, свет гаснет.
  final bool animate;

  /// Уровень звука 0..1 на момент кадра. `null` — без реакции на звук
  /// (остаётся только дыхание).
  ///
  /// Функция, а не `ValueListenable`: обложка спрашивает уровень ровно тогда,
  /// когда рисует кадр, и подписка на монитор ей не нужна — иначе его тридцать
  /// уведомлений в секунду дёргали бы дерево плеера.
  final double Function()? level;

  /// Два цвета свечения — цвета палитры, как у гало визуализатора.
  final List<Color> colors;

  /// Радиус скругления обложки: тем же радиусом режется свечение и дрейф.
  final double radius;

  @override
  State<LiveCover> createState() => _LiveCoverState();
}

/// Кадр шейдера: время и уровень одним уведомлением.
///
/// Один `Listenable` на оба значения, а не два: перерисовка всё равно общая —
/// время двигает дрейф, уровень задаёт яркость, и разносить их по двум
/// уведомлениям значило бы рисовать кадр дважды.
class _LiveFrame extends ChangeNotifier {
  /// Секунды с начала показа. На паузе не растут.
  double time = 0;

  /// Сглаженный уровень 0..1.
  double level = 0;

  void push(double time, double level) {
    this.time = time;
    this.level = level;
    notifyListeners();
  }
}

class _LiveCoverState extends State<LiveCover> {
  static const String _asset = 'shaders/live_cover.frag';

  ui.FragmentShader? _shader;

  /// Шейдер не загрузился (сборка без runtime effect). Дрейф остаётся: он не
  /// зависит от шейдера, и терять движение из-за одного ассета незачем.
  bool _broken = false;
  bool _loading = false;

  /// Время шейдера в секундах. Считаем такт, а не секундомер: пауза должна
  /// замирать ровно в тот кадр, на котором её нажали (секундомер пришлось бы
  /// останавливать, а скрытое окно — не «догонять» прыжком). Пропущенный такт
  /// лишь чуть замедляет дыхание, что для волны в десятки секунд незаметно.
  double _time = 0;

  final _LiveFrame _frame = _LiveFrame();
  Timer? _timer;

  /// Уровень, который видит шейдер: догоняет цель плавно.
  double _level = 0;

  /// Виден ли виджет (скрытый маршрут не должен тикать).
  bool _tickerEnabled = true;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) unawaited(_load());
    _syncTicking();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // `TickerMode` выключается, когда экран перекрыт другим маршрутом: таймер
    // обязан это уважать, иначе плеер под настройками продолжит считать кадры.
    final bool enabled = TickerMode.valuesOf(context).enabled;
    if (enabled != _tickerEnabled) {
      _tickerEnabled = enabled;
      _syncTicking();
    }
  }

  @override
  void didUpdateWidget(covariant LiveCover old) {
    super.didUpdateWidget(old);
    if (!old.enabled && widget.enabled) unawaited(_load());
    if (old.enabled != widget.enabled || old.animate != widget.animate) {
      _syncTicking();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _frame.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_shader != null || _loading || _broken) return;
    _loading = true;
    try {
      final ui.FragmentProgram program =
          await ui.FragmentProgram.fromAsset(_asset);
      if (!mounted) return;
      setState(() => _shader = program.fragmentShader());
    } on Object catch (error) {
      // Тихая деградация: остаётся дрейф без света. Причина — в журнал, чтобы
      // отсутствие свечения не выглядело загадкой.
      debugPrint('Живая обложка: шейдер недоступен ($error)');
      if (mounted) setState(() => _broken = true);
    } finally {
      _loading = false;
    }
    _syncTicking();
  }

  void _syncTicking() {
    // На паузе уровень гаснет не мгновенно: пока он не догорел, кадры нужны,
    // иначе свет застыл бы на последней яркости.
    final bool wants = widget.enabled &&
        _tickerEnabled &&
        (widget.animate || _level > 0.004);
    if (!wants) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(AppMotion.backdropFrame, (_) => _tick());
  }

  void _tick() {
    final double target = widget.animate ? (widget.level?.call() ?? 0) : 0;
    // Спад медленнее атаки: свечение не должно мигать на каждом слоге. Шаг
    // крупнее, чем у монитора, поэтому здесь только догоняем, а не сглаживаем.
    _level += (target - _level) * (target > _level ? 0.35 : 0.12);
    if (target == 0 && _level < 0.003) _level = 0;
    // На паузе время стоит: дрейф замирает там, где его застали. Живая обложка
    // на паузе выглядела бы как невыключенное воспроизведение.
    if (widget.animate) {
      _time += AppMotion.backdropFrame.inMicroseconds / 1000000;
    }
    _frame.push(_time, _level);
    if (!widget.animate && _level == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Два цвета свечения: альфа не нужна — прозрачность задаёт шейдер.
  List<Color> _glowColors() {
    final List<Color> filled = <Color>[
      for (final Color color in widget.colors.take(2))
        color.withValues(alpha: 1),
    ];
    while (filled.length < 2) {
      filled.add(filled.isEmpty ? const Color(0xFFFFFFFF) : filled.last);
    }
    return filled;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    Widget content = AnimatedBuilder(
      animation: _frame,
      // Обложка передаётся готовой: перестройка `Transform` не должна трогать
      // её поддерево.
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        // Медленные несинхронные волны: зум с периодом около 40 секунд, сдвиг —
        // около 60. Синхронные волны читались бы как одно биение, а не как
        // дыхание.
        final double t = _frame.time;
        final double zoom =
            1.022 + 0.006 * math.sin(t * 0.16) + 0.004 * _frame.level;
        // Сдвиг — в долях стороны, а не в пикселях: запас зума (не меньше 0,8 %
        // с каждой стороны) должен перекрывать его на любой величине обложки,
        // иначе на краю открылся бы фон плеера.
        final double dx = 0.0045 * math.sin(t * 0.11 + 0.7);
        final double dy = 0.0035 * math.sin(t * 0.087 + 2.1);
        return FractionalTranslation(
          translation: Offset(dx, dy),
          // Низкое качество фильтра достаточно: увеличение около 2 %, зато
          // картинка не «звенит» на резких краях обложки.
          child: Transform.scale(
            scale: zoom,
            filterQuality: FilterQuality.low,
            child: child,
          ),
        );
      },
    );

    final ui.FragmentShader? shader = _shader;
    if (shader != null) {
      // Свет рисуется поверх обложки, но под пальцем и курсором его нет:
      // `CustomPaint` не перехватывает нажатия, поэтому меню по правому клику и
      // перелёт работают как раньше.
      content = CustomPaint(
        foregroundPainter: _LiveCoverPainter(
          shader: shader,
          frame: _frame,
          colors: _glowColors(),
          radius: widget.radius,
        ),
        child: content,
      );
    }

    return _clip(context, content);
  }

  /// Обрезка по той же форме, что у обложки.
  ///
  /// Увеличенная картинка иначе вылезала бы за скруглённые углы. Форму берём из
  /// темы, а не из настроек: `Artwork` определяет суперэллипс так же, поэтому
  /// внешняя обрезка совпадает с его собственной.
  Widget _clip(BuildContext context, Widget child) {
    final BorderRadius radius = BorderRadius.circular(widget.radius);
    final ExpressiveShape? shape =
        Theme.of(context).extension<ExpressiveShape>();
    if (shape?.superellipse ?? false) {
      return ClipPath(
        clipper: ShapeBorderClipper(
          shape: RoundedSuperellipseBorder(borderRadius: radius),
        ),
        child: child,
      );
    }
    return ClipRRect(borderRadius: radius, child: child);
  }
}

class _LiveCoverPainter extends CustomPainter {
  _LiveCoverPainter({
    required this.shader,
    required this.frame,
    required this.colors,
    required this.radius,
  }) : super(repaint: frame);

  final ui.FragmentShader shader;

  /// Время и уровень: painter перерисовывается по этому уведомлению.
  final _LiveFrame frame;

  final List<Color> colors;

  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // Индексы и порядок — как объявлены униформы в шейдере.
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, frame.time)
      ..setFloat(3, frame.level)
      ..setFloat(4, colors[0].r)
      ..setFloat(5, colors[0].g)
      ..setFloat(6, colors[0].b)
      ..setFloat(7, colors[1].r)
      ..setFloat(8, colors[1].g)
      ..setFloat(9, colors[1].b)
      ..setFloat(10, radius);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _LiveCoverPainter old) =>
      old.shader != shader ||
      old.frame != frame ||
      !listEquals(old.colors, colors) ||
      old.radius != radius;
}
