import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/motion.dart';

/// Однострочный текст, который плавно прокручивается, если не влезает.
///
/// Прокрутка включается только при реальном переполнении: измеряем строку
/// `TextPainter`-ом и сравниваем с доступной шириной. Если текст помещается,
/// виджет рисует обычный [Text] и не держит ни одного кадра — иначе постоянная
/// перерисовка не давала бы тестам дождаться покоя (`pumpAndSettle`).
///
/// Полный цикл — «стоим, едем вправо, стоим, едем обратно»: у краёв есть
/// пауза, чтобы начало и конец успевали прочитать. Полный текст при наведении
/// показывает всплывающая подсказка.
class MarqueeText extends StatefulWidget {
  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.playing = true,
    this.allowAnimation = true,
    this.velocity = 30,
    this.edgePause = const Duration(milliseconds: 1400),
    this.tooltip = true,
  });

  /// Текст, который показываем и прокручиваем.
  final String text;

  /// Стиль текста. Как у [Text], поверх стиля окружения.
  final TextStyle? style;

  /// Идёт ли воспроизведение. На паузе строка замирает на текущем месте:
  /// читать название, пока трек стоит, всё равно удобнее без движения.
  final bool playing;

  /// Выключатель анимации. Сейчас в настройках такого пункта нет, но ведущий
  /// может добавить его позже — тогда достаточно передать сюда значение.
  final bool allowAnimation;

  /// Скорость прокрутки в логических пикселях в секунду.
  final double velocity;

  /// Пауза у каждого края перед обратным ходом.
  final Duration edgePause;

  /// Показывать ли полный текст всплывающей подсказкой при наведении.
  final bool tooltip;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  /// Один контроллер на виджет: цикл «туда-обратно» задаёт [TweenSequence],
  /// поэтому при смене размера не нужно пересоздавать контроллер.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

  /// Ключ текущего режима. Нужен, чтобы не перезапускать прокрутку на каждой
  /// перестройке родителя (плеер перестраивается несколько раз в секунду).
  String? _phaseKey;

  /// Что делать в отложенном колбэке. Запуск анимации из `build` нельзя:
  /// `repeat()` уведомляет слушателей, а это уже перестройка во время сборки.
  bool _pendingRun = false;
  bool _pendingReset = false;
  Duration _pendingDuration = Duration.zero;
  bool _syncScheduled = false;

  /// Предыдущие метрики — чтобы при смене трека или ширины начать с начала,
  /// а при паузе/возобновлении продолжить с того же места.
  String? _lastText;
  double? _lastWidth;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _sync({
    required bool run,
    required bool reset,
    required Duration duration,
    required String key,
  }) {
    if (_phaseKey == key) return;
    _phaseKey = key;

    _pendingRun = run;
    _pendingReset = reset;
    _pendingDuration = duration;

    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (!mounted) return;

      if (_pendingReset) _controller.value = 0;
      if (_pendingRun) {
        _controller.duration = _pendingDuration;
        // `repeat` продолжает с текущего значения: после паузы полоса едет
        // дальше, а не дёргается в начало.
        _controller.repeat();
      } else {
        _controller.stop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle style =
        DefaultTextStyle.of(context).style.merge(widget.style);
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final TextDirection direction = Directionality.of(context);
    final bool reduceMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // Скрытый маршрут или закрытая панель выключают тикер: прокрутка не должна
    // тратить кадры, пока её не видно.
    final bool tickerEnabled = TickerMode.valuesOf(context).enabled;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;

        final TextPainter painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          textDirection: direction,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        final double textWidth = painter.width;
        final double height = painter.height;
        painter.dispose();

        final bool overflows = width.isFinite && textWidth > width + 0.5;

        // Помещается — обычный текст, никакой анимации.
        if (!overflows) {
          _lastText = widget.text;
          _lastWidth = width;
          _sync(
            run: false,
            reset: true,
            duration: Duration.zero,
            key: 'static|${widget.text}|${width.round()}',
          );
          return Text(
            widget.text,
            style: widget.style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        }

        final double overflow = math.max(0.0, textWidth - width);
        final Duration move = Duration(
          milliseconds: math.max(
            700,
            (overflow / math.max(1.0, widget.velocity) * 1000).round(),
          ),
        );
        final Duration total = widget.edgePause * 2 + move * 2;
        final double holdWeight = widget.edgePause.inMilliseconds.toDouble();
        final double moveWeight = move.inMilliseconds.toDouble();

        final Animation<double> shift = _controller.drive(
          TweenSequence<double>(<TweenSequenceItem<double>>[
            TweenSequenceItem<double>(
              tween: ConstantTween<double>(0),
              weight: holdWeight,
            ),
            TweenSequenceItem<double>(
              tween: Tween<double>(begin: 0, end: 1)
                  .chain(CurveTween(curve: MotionCurve.easeInOut)),
              weight: moveWeight,
            ),
            TweenSequenceItem<double>(
              tween: ConstantTween<double>(1),
              weight: holdWeight,
            ),
            TweenSequenceItem<double>(
              tween: Tween<double>(begin: 1, end: 0)
                  .chain(CurveTween(curve: MotionCurve.easeInOut)),
              weight: moveWeight,
            ),
          ]),
        );

        final bool geometryChanged =
            _lastText != widget.text || _lastWidth != width;
        _lastText = widget.text;
        _lastWidth = width;

        final bool run = widget.playing &&
            widget.allowAnimation &&
            !reduceMotion &&
            tickerEnabled;

        _sync(
          run: run,
          // Новый трек или другая ширина — начинаем с начала. Выключенные
          // анимации тоже возвращают строку в начало, а остановка по паузе —
          // нет: она оставляет строку там, где застала.
          reset: geometryChanged ||
              !widget.allowAnimation ||
              reduceMotion,
          duration: total,
          key: 'run|${widget.text}|${width.round()}|${overflow.round()}|'
              '$run|${total.inMilliseconds}',
        );

        Widget text = Text(
          widget.text,
          style: widget.style,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible,
        );
        text = AnimatedBuilder(
          animation: shift,
          child: text,
          builder: (BuildContext context, Widget? child) => Transform.translate(
            offset: Offset(-overflow * shift.value, 0),
            child: child,
          ),
        );

        final Widget clipped = SizedBox(
          width: width,
          height: height,
          child: ClipRect(
            // Ширина не ограничена: строка рисуется целиком и уезжает под
            // обрезку, а не переносится и не обрезается многоточием.
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: 0,
              maxWidth: double.infinity,
              minHeight: height,
              maxHeight: height,
              child: text,
            ),
          ),
        );

        if (!widget.tooltip) return clipped;
        return Tooltip(
          message: widget.text,
          waitDuration: const Duration(milliseconds: 500),
          child: clipped,
        );
      },
    );
  }
}
