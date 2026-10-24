import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Текст, который у правого края не обрывается многоточием, а плавно гаснет.
///
/// Многоточие — честный, но грубый способ сказать «дальше не влезло»: посреди
/// слова остаётся вертикальный обрыв и три точки. Здесь последние [fadeWidth]
/// пикселей строки уходят в прозрачность, поэтому глаз читает начало, а хвост
/// растворяется — так же, как это делают подписи в мобильных плеерах.
///
/// Затухание включается только тогда, когда текст действительно не влезает:
/// для короткого названия прозрачного хвоста быть не должно, иначе оно
/// выглядело бы обрезанным на пустом месте. Поэтому ширина текста сначала
/// измеряется тем же [TextPainter], которым его рисует [Text], и сравнивается
/// с доступной.
class FadeText extends StatelessWidget {
  const FadeText({
    super.key,
    this.text,
    this.inlineSpan,
    this.style,
    this.maxLines = 1,
    this.fadeWidth = 24,
    this.textAlign,
    this.overflow = TextOverflow.ellipsis,
  }) : assert(
         text != null || inlineSpan != null,
         'FadeText: нужен text или inlineSpan',
       );

  /// Простой текст. Взаимоисключающий с [inlineSpan].
  final String? text;

  /// Текст со спанами — когда в строке есть ссылки или разноцветные куски
  /// (подпись трека с кликабельными исполнителями).
  final InlineSpan? inlineSpan;

  final TextStyle? style;
  final int maxLines;

  /// Ширина растворяющейся полосы у правого края.
  final double fadeWidth;

  final TextAlign? textAlign;

  /// Что делать с многоточием. В режиме затухания не используется: там хвост
  /// прячет маска, а не «…» (иначе точки горели бы внутри прозрачности).
  /// Остаётся для многострочного случая, где затухание не включается.
  final TextOverflow overflow;

  /// Допуск при сравнении ширин: раскладка меряет и рисует один и тот же
  /// текст, но округление может дать доли пикселя.
  static const double _epsilon = 0.5;

  @override
  Widget build(BuildContext context) {
    final InlineSpan span = inlineSpan ?? TextSpan(text: text);

    // Многострочный текст так не погасить: маска — прямоугольник на весь
    // параграф, и прозрачными стали бы концы ВСЕХ строк, а не только
    // последней. Отдельная маска по последней строке потребовала бы своего
    // `RenderParagraph`, поэтому здесь честно остаётся многоточие.
    if (maxLines != 1) {
      return Text.rich(
        span,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Без конечной ширины мерить не с чем: отдаём обычный текст.
        if (!constraints.hasBoundedWidth) {
          return Text.rich(
            span,
            style: style,
            maxLines: 1,
            overflow: overflow,
            textAlign: textAlign,
          );
        }

        final double width = constraints.maxWidth;
        final bool overflows = _overflows(context, span, width);

        // Ширину задаём явно: параграф, который переносится по словам,
        // заканчивается раньше правого края, и маска, построенная по его
        // собственным границам, гасила бы середину строки вместо края.
        final Widget child = SizedBox(
          width: width,
          child: Text.rich(
            span,
            style: style,
            maxLines: 1,
            // Без переноса: иначе строка ломается по последнему целому слову и
            // между ним и краем остаётся пустое место — гаснуть было бы нечему,
            // и обрыв выглядел бы как закончившийся текст. Одной строкой хвост
            // уходит под маску всегда.
            softWrap: !overflows,
            // Вместо «…» — маска: хвост и так растворяется.
            overflow: overflows ? TextOverflow.clip : overflow,
            textAlign: textAlign,
          ),
        );

        if (!overflows) return child;

        return ShaderMask(
          // `dstIn` оставляет от текста только то, что пропустила маска:
          // альфа градиента работает как прозрачность самого текста.
          blendMode: BlendMode.dstIn,
          shaderCallback: (Rect bounds) => _fadeShader(bounds),
          child: child,
        );
      },
    );
  }

  /// Влезает ли строка в [width].
  ///
  /// Меряем без ограничения ширины и сравниваем с доступной: `TextPainter`
  /// с `maxLines: 1` и конечной шириной может перенести слово на вторую
  /// строку и отчитаться о переполнении так, что настоящая ширина строки
  /// окажется меньше — а нам нужна именно «длина текста против места».
  bool _overflows(BuildContext context, InlineSpan span, double width) {
    // `Text.rich` подмешивает стиль в корень спана; здесь делаем то же самое,
    // иначе измерение шло бы другим кеглем и ширины не совпали.
    final TextStyle effective = (style == null || style!.inherit)
        ? DefaultTextStyle.of(context).style.merge(style)
        : style!;
    final TextPainter painter = TextPainter(
      text: TextSpan(style: effective, children: <InlineSpan>[span]),
      maxLines: 1,
      textAlign: textAlign ?? TextAlign.start,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    )..layout();
    final double intrinsic = painter.width;
    painter.dispose();
    return intrinsic > width + _epsilon;
  }

  /// Градиент маски: непрозрачный до начала полосы затухания, дальше — в ноль.
  Shader _fadeShader(Rect bounds) {
    // Полоса не может быть шире самого текста, иначе `stops` выйдут за 1.
    // В очень узкой колонке (сжатая панель) 24 пикселя съедали бы половину
    // строки — там полоса ужимается вместе с текстом.
    final double fade = math.min(fadeWidth, bounds.width * 0.25);
    final double start = bounds.width <= 0 ? 0 : 1 - fade / bounds.width;
    return LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: <Color>[
        Colors.white,
        Colors.white,
        Colors.white.withValues(alpha: 0),
      ],
      stops: <double>[0, start, 1],
    ).createShader(bounds);
  }
}
