import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/app_settings.dart';
import '../state/providers.dart';

/// Живой фон плеера: «жидкость» из цветов обложки на фрагментном шейдере.
///
/// Рисует `shaders/liquid_backdrop.frag` (пояснения — в самом шейдере). Время фон
/// получает отсюда и только пока [animate] истинно: на паузе таймер
/// останавливается вместе с секундомером, поэтому время не растёт, перерисовки не
/// запрашиваются и картинка замирает на месте — кадры на простое не тратятся.
///
/// Настройки «Жидкости» (скорость, масштаб пятен, насыщенность, источник цвета)
/// читаются из [AppSettings] здесь же, а не передаются вызывающим: фон — часть
/// того же виджета, и стиль «Градиент» эти значения не трогает. Значения по
/// умолчанию совпадают с прежним видом.
///
/// Два обстоятельства, из-за которых анимация может не пойти, и оба не «падающие»:
///
/// * шейдер не загрузился (`FragmentProgram` недоступен — например, в среде
///   тестов) — рисуется статичный градиент ровно из тех же цветов, а причина
///   пишется в журнал;
/// * не идёт воспроизведение — время стоит, то есть фон просто неподвижен.
class LiquidBackdrop extends ConsumerWidget {
  const LiquidBackdrop({super.key, required this.colors, this.animate = true});

  /// Три цвета палитры обложки (первый — основной), как у градиента фона.
  /// Используются, только когда источник цвета — «Из обложки».
  final List<Color> colors;

  /// Идёт воспроизведение. `false` — фон замирает.
  final bool animate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Только эти четыре значения и нужны фону: `select` не даёт перестраивать
    // шейдер на каждое изменение любой другой настройки.
    final (
      double speed,
      double scale,
      double saturation,
      LiquidColorSource source,
    ) = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => (
          s.liquidSpeed,
          s.liquidScale,
          s.liquidSaturation,
          s.liquidColorSource,
        ),
      ),
    );

    final List<Color> base = source == LiquidColorSource.theme
        ? liquidThemeColors(Theme.of(context).colorScheme)
        : colors;
    return _LiquidSurface(
      colors: _liquidPalette(base, saturation),
      flowSpeed: speed,
      blobScale: scale,
      animate: animate,
    );
  }
}

/// Живой предпросмотр «Жидкости» для диалога настроек.
///
/// Тот же шейдер, что и у фона плеера, но время в нём идёт всегда: предпросмотр
/// не зависит от воспроизведения и не замирает вместе с паузой.
class LiquidPreview extends StatefulWidget {
  const LiquidPreview({
    super.key,
    required this.colors,
    required this.speed,
    required this.scale,
    required this.saturation,
  });

  /// Три базовых цвета (до применения насыщенности).
  final List<Color> colors;

  /// Скорость течения — как настройка «Скорость течения».
  final double speed;

  /// Масштаб пятен — как настройка «Масштаб пятен».
  final double scale;

  /// Насыщенность — как одноимённая настройка.
  final double saturation;

  @override
  State<LiquidPreview> createState() => _LiquidPreviewState();
}

class _LiquidPreviewState extends State<LiquidPreview> {
  @override
  Widget build(BuildContext context) => _LiquidSurface(
        colors: _liquidPalette(widget.colors, widget.saturation),
        flowSpeed: widget.speed,
        blobScale: widget.scale,
        animate: true,
      );
}

/// Три цвета «Жидкости» из палитры приложения — для источника «Из темы».
///
/// Роли те же, что у градиента фона, — контейнеры primary / secondary /
/// tertiary. Одних ролей мало: в нейтральной палитре контейнеры совпадают почти
/// вплотную, а в невыразительной тональной совпадают primary и secondary, и
/// «жидкость» выглядела залитой одним цветом (жалоба владельца). Поэтому тон
/// задаём лесенкой от основного контейнера: каждый следующий цвет на шаг
/// светлее в тёмной теме и темнее в светлой. Оттенок остаётся своим у каждой
/// роли, так что цветная палитра остаётся цветной, а нейтральная — не плоской.
List<Color> liquidThemeColors(ColorScheme scheme) {
  final List<HSLColor> roles = <HSLColor>[
    HSLColor.fromColor(scheme.primaryContainer),
    HSLColor.fromColor(scheme.secondaryContainer),
    HSLColor.fromColor(scheme.tertiaryContainer),
  ];
  // Тон берём от основного цвета, а не от каждого контейнера: у secondary и
  // tertiary он может совпасть с primary (нейтральная палитра) или оказаться
  // рядом (невыразительная тональная). Роли при этом сохраняют свой оттенок.
  final double step = scheme.brightness == Brightness.dark ? 0.09 : -0.09;
  final double base = roles[0].lightness;
  return <Color>[
    roles[0].toColor(),
    roles[1].withLightness((base + step).clamp(0.0, 1.0)).toColor(),
    roles[2].withLightness((base + step * 2).clamp(0.0, 1.0)).toColor(),
  ];
}

/// Ровно три цвета: у шейдера три цветовые униформы. Меньше — повторяем
/// последний, больше — лишние не нужны.
///
/// Альфу обнуляем в непрозрачность: шейдер выводит сплошной кадр, поэтому
/// статичная подложка должна быть такой же, иначе подмена шейдера на неё была
/// бы заметна по прозрачности. Насыщенность применяем здесь, а не в шейдере:
/// так статичная подложка и жидкость выглядят одинаково.
List<Color> _liquidPalette(List<Color> source, double saturation) {
  final List<Color> filled = <Color>[
    for (final Color color in source.take(3))
      _saturate(color.withValues(alpha: 1), saturation),
  ];
  while (filled.length < 3) {
    filled.add(filled.isEmpty ? const Color(0xFF000000) : filled.last);
  }
  return filled;
}

/// Множитель насыщенности: 1 — цвет как есть, 0 — серый той же светлоты.
/// `HSLColor` меняет только насыщенность, поэтому от настройки фон не
/// темнеет и не светлеет.
Color _saturate(Color color, double factor) {
  if (factor == 1.0) return color;
  final HSLColor hsl = HSLColor.fromColor(color);
  return hsl.withSaturation((hsl.saturation * factor).clamp(0.0, 1.0)).toColor();
}

/// Общая для фона и предпросмотра отрисовка жидкости: шейдер, его загрузка,
/// часы и статичная подложка-замена. Различаются только цвета, параметры и то,
/// идёт ли время — сама отрисовка одна, поэтому предпросмотр в настройках
/// показывает ровно то же, что и плеер.
class _LiquidSurface extends StatefulWidget {
  const _LiquidSurface({
    required this.colors,
    required this.flowSpeed,
    required this.blobScale,
    required this.animate,
  });

  final List<Color> colors;
  final double flowSpeed;
  final double blobScale;
  final bool animate;

  @override
  State<_LiquidSurface> createState() => _LiquidSurfaceState();
}

class _LiquidSurfaceState extends State<_LiquidSurface> {
  static const String _asset = 'shaders/liquid_backdrop.frag';

  /// Шаг анимации: ~30 кадров в секунду. Чаще незаметно, реже — заметно дёргается.
  static const Duration _frame = Duration(milliseconds: 33);

  ui.FragmentShader? _shader;

  /// Шейдер не загрузился: рисуем статичный градиент из тех же цветов.
  bool _broken = false;

  /// Время для шейдера. Секундомер, а не счётчик тиков: при пропущенном такте
  /// жидкость не «ускоряется», а просто чуть позже доходит до того же места.
  final Stopwatch _clock = Stopwatch();
  final ValueNotifier<double> _time = ValueNotifier<double>(0);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _syncTicking();
  }

  @override
  void didUpdateWidget(covariant _LiquidSurface old) {
    super.didUpdateWidget(old);
    if (old.animate != widget.animate) _syncTicking();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _time.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final ui.FragmentProgram program =
          await ui.FragmentProgram.fromAsset(_asset);
      if (!mounted) return;
      setState(() => _shader = program.fragmentShader());
      _syncTicking();
    } on Object catch (error) {
      // Причина честно уходит в журнал, а на экране остаётся статичный градиент.
      // Это не запасная «анимация-обманка»: кадры здесь не тратятся вообще.
      debugPrint('Liquid backdrop: шейдер недоступен ($error)');
      if (mounted) setState(() => _broken = true);
    }
  }

  void _syncTicking() {
    if (widget.animate && _shader != null) {
      _clock.start();
      _timer ??= Timer.periodic(
        _frame,
        (_) => _time.value = _clock.elapsedMicroseconds / 1000000.0,
      );
      return;
    }
    _timer?.cancel();
    _timer = null;
    _clock.stop();
  }

  @override
  Widget build(BuildContext context) {
    final ui.FragmentShader? shader = _shader;
    if (shader == null || _broken) return _StaticPalette(colors: widget.colors);
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _LiquidPainter(
          shader: shader,
          time: _time,
          colors: widget.colors,
          flowSpeed: widget.flowSpeed,
          blobScale: widget.blobScale,
        ),
      ),
    );
  }
}

class _LiquidPainter extends CustomPainter {
  _LiquidPainter({
    required this.shader,
    required this.time,
    required this.colors,
    required this.flowSpeed,
    required this.blobScale,
  }) : super(repaint: time);

  final ui.FragmentShader shader;

  /// Время шейдера: painter перерисовывается по этому уведомлению.
  final ValueListenable<double> time;

  final List<Color> colors;

  /// Множитель времени в шейдере: скорость течения из настроек.
  final double flowSpeed;

  /// Масштаб пятен: во сколько раз крупнее «волокна» жидкости из настроек.
  final double blobScale;

  @override
  void paint(Canvas canvas, Size size) {
    // Индексы и порядок — как объявлены униформы в шейдере.
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, time.value)
      ..setFloat(3, colors[0].r)
      ..setFloat(4, colors[0].g)
      ..setFloat(5, colors[0].b)
      ..setFloat(6, colors[1].r)
      ..setFloat(7, colors[1].g)
      ..setFloat(8, colors[1].b)
      ..setFloat(9, colors[2].r)
      ..setFloat(10, colors[2].g)
      ..setFloat(11, colors[2].b)
      ..setFloat(12, flowSpeed)
      ..setFloat(13, blobScale);

    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _LiquidPainter old) =>
      old.shader != shader ||
      !listEquals(old.colors, colors) ||
      old.flowSpeed != flowSpeed ||
      old.blobScale != blobScale;
}

/// Статичная подложка тех же цветов, что у жидкости: нужна, пока шейдер грузится,
/// и остаётся совсем, если он не загрузился.
///
/// Композиция — как у стиля «Градиент» (`_GradientBackdrop` в
/// `now_playing_screen.dart`): три точки 0.0 / 0.5 / 1.0. Цвета приходят уже
/// непрозрачными, чтобы подмена шейдера на подложку не меняла яркость кадра.
class _StaticPalette extends StatelessWidget {
  const _StaticPalette({required this.colors});

  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
          stops: const <double>[0.0, 0.5, 1.0],
        ),
      ),
    );
  }
}
