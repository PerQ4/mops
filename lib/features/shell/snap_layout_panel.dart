import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'window_channel.dart';

/// Панель раскладок окна: половина слева, половина справа, весь экран.
///
/// Своя панель вместо системного Snap Layouts: системный требует, чтобы
/// родительское окно получало `WM_NCHITTEST` над кнопкой «Развернуть», а
/// клиентскую область занимает дочернее окно Flutter. Отдать эту точку
/// системе — значит потерять наведение и подсветку кнопки. Здесь же кнопка
/// живёт обычной жизнью, а раскладки рисует Flutter.
///
/// Панель показывается из `Overlay` шапки (см. `window_title_bar.dart`),
/// поэтому в дерево она не попадает, пока курсор не задержится на кнопке.
class SnapLayoutPanel extends StatelessWidget {
  const SnapLayoutPanel({
    super.key,
    required this.onHoverChanged,
    required this.onSelected,
  });

  /// Ширина панели в логических пикселях. Фиксированная: три плитки должны
  /// быть одинаковыми, а не подстраиваться под длину подписи.
  static const double width = 248;

  /// Курсор вошёл на панель или ушёл с неё. Шапка по этому сигналу держит
  /// панель открытой, пока курсор внутри.
  final ValueChanged<bool> onHoverChanged;

  /// Выбрана раскладка. Нативную команду отправляет шапка — панель только
  /// сообщает, что именно нажали.
  final ValueChanged<SnapSide> onSelected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    final Widget panel = MouseRegion(
      onEnter: (PointerEnterEvent _) => onHoverChanged(true),
      onExit: (PointerExitEvent _) => onHoverChanged(false),
      child: Material(
        color: scheme.surfaceContainerHigh,
        elevation: 6,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: width,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _SnapTile(
                    side: SnapSide.left,
                    caption: 'Слева',
                    label: 'Левая половина экрана',
                    onTap: () => onSelected(SnapSide.left),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _SnapTile(
                    side: SnapSide.right,
                    caption: 'Справа',
                    label: 'Правая половина экрана',
                    onTap: () => onSelected(SnapSide.right),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _SnapTile(
                    side: SnapSide.max,
                    caption: 'Экран',
                    label: 'Развернуть на весь экран',
                    onTap: () => onSelected(SnapSide.max),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Появление с подъёмом на пару пикселей: панель выезжает из-под шапки,
    // а не возникает из ниоткуда. Длительность — из словаря переходов,
    // поэтому настройка «Отключить анимации» её тоже отключает.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: AppMotion.overlayEnter.duration,
      curve: AppMotion.overlayEnter.curve,
      child: panel,
      builder: (BuildContext context, double value, Widget? child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * -4),
            child: child,
          ),
        );
      },
    );
  }
}

/// Одна плитка: схема раскладки и короткая подпись.
class _SnapTile extends StatefulWidget {
  const _SnapTile({
    required this.side,
    required this.caption,
    required this.label,
    required this.onTap,
  });

  final SnapSide side;

  /// Подпись на плитке — короткая, чтобы влезла в узкую плитку.
  final String caption;

  /// Полное имя для экранного диктора.
  final String label;

  final VoidCallback onTap;

  @override
  State<_SnapTile> createState() => _SnapTileState();
}

class _SnapTileState extends State<_SnapTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Semantics(
      button: true,
      label: widget.label,
      // Подпись плитки короче полного имени («Слева» против «Левая половина
      // экрана»): диктору отдаём только полное, иначе он прочитает оба.
      excludeSemantics: true,
      child: MouseRegion(
        onEnter: (PointerEnterEvent _) => setState(() => _hover = true),
        onExit: (PointerExitEvent _) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: AppMotion.quickChange.duration,
            curve: AppMotion.quickChange.curve,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
            decoration: BoxDecoration(
              color: _hover ? AppStateLayers.hover(scheme) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              // Рамка есть всегда, просто прозрачная: иначе при наведении
              // плитка становилась бы на два пикселя больше и ряд дёргался.
              border: Border.all(
                color: _hover ? scheme.primary : Colors.transparent,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  width: 46,
                  height: 27,
                  child: CustomPaint(
                    painter: _SnapPreviewPainter(
                      side: widget.side,
                      outline: scheme.outline,
                      fill: scheme.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  widget.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _hover
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Схема раскладки: контур окна и закрашенная часть, которую оно займёт.
class _SnapPreviewPainter extends CustomPainter {
  const _SnapPreviewPainter({
    required this.side,
    required this.outline,
    required this.fill,
  });

  final SnapSide side;
  final Color outline;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final RRect frame = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1),
      const Radius.circular(4),
    );
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = outline;
    canvas.drawRRect(frame, stroke);

    final RRect area = RRect.fromRectAndRadius(
      Rect.fromLTWH(3, 3, size.width - 6, size.height - 6),
      const Radius.circular(2.5),
    );
    canvas.save();
    canvas.clipRRect(area);
    final Paint fillPaint = Paint()..color = fill;
    switch (side) {
      case SnapSide.left:
        canvas.drawRect(
          Rect.fromLTWH(area.left, area.top, area.width / 2, area.height),
          fillPaint,
        );
      case SnapSide.right:
        canvas.drawRect(
          Rect.fromLTWH(area.center.dx, area.top, area.width / 2, area.height),
          fillPaint,
        );
      case SnapSide.max:
        canvas.drawRect(area.outerRect, fillPaint);
    }
    canvas.restore();

    // Линия посередине: без неё закрашенная половина читалась бы просто как
    // прямоугольник, а не как часть окна, рядом с которой осталось место.
    if (side != SnapSide.max) {
      canvas.drawLine(
        Offset(area.center.dx, area.top),
        Offset(area.center.dx, area.bottom),
        Paint()
          ..strokeWidth = 1
          ..color = outline.withValues(alpha: 0.6),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SnapPreviewPainter oldDelegate) {
    return oldDelegate.side != side ||
        oldDelegate.outline != outline ||
        oldDelegate.fill != fill;
  }
}
