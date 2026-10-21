import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/app_settings.dart';
import '../../core/theme/motion.dart';
import '../../state/player_controller.dart';
import '../../state/providers.dart';
import '../../state/shell.dart';
import 'destinations.dart';

/// Есть ли у окна своя заголовочная панель (только Windows).
bool get hasCustomTitleBar => Platform.isWindows;

/// Заголовочная панель окна в стиле Material 3 Expressive.
///
/// Содержимое динамическое: пока играет трек — его название, иначе название
/// раздела. Заголовок по центру или сбоку (настройка). Кнопки — круглые, как
/// в чистом Android/M3, а не системные прямоугольники Windows.
class WindowTitleBar extends ConsumerStatefulWidget {
  const WindowTitleBar({super.key, this.height = 34});

  final double height;

  @override
  ConsumerState<WindowTitleBar> createState() => _WindowTitleBarState();
}

class _WindowTitleBarState extends ConsumerState<WindowTitleBar> {
  static const MethodChannel _channel = MethodChannel('mops/window');

  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    _syncMaximized();
  }

  Future<void> _syncMaximized() async {
    try {
      final bool value =
          await _channel.invokeMethod<bool>('isMaximized') ?? false;
      if (mounted) setState(() => _maximized = value);
    } on Object {
      // Канал есть только на Windows.
    }
  }

  void _invoke(String method) {
    _channel.invokeMethod<void>(method).catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    final bool centered = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.titleBarCentered),
    );
    final bool matchBackground = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => s.titleBarMatchesBackground,
      ),
    );
    // Динамический заголовок: трек важнее раздела.
    final String? track = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.current?.title),
    );
    final int index = ref.watch(shellIndexProvider);
    final String title = track ?? ShellDestination.values[index].label;

    final Widget titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: text.labelMedium?.copyWith(
        color: scheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        // По умолчанию — самый тёмный тон палитры: шапка читается как рамка
        // окна. Настройкой цвет возвращается к фону боковых панелей: шапка
        // становится их продолжением и вместе с ними образует рамку окна.
        color: matchBackground
            ? scheme.surfaceContainer
            : scheme.surfaceContainerLowest,
        // Разделительной линии нет намеренно: цвет шапки и содержимого и так
        // разный, а светлая полоска в один пиксель читалась как дефект
        // отрисовки — под шапкой будто оставалась микро-тень.
      ),
      child: SizedBox(
        height: widget.height,
        child: Stack(
          children: <Widget>[
            // Фон всей шапки — зона перетаскивания окна. Лежит внизу: всё, что
            // не кнопка, проваливается сюда, и окно тянется за любое место.
            Positioned.fill(
              child: Listener(
                onPointerDown: (PointerDownEvent event) {
                  if (event.buttons == kPrimaryButton) _invoke('startDrag');
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: () {
                    _invoke('toggleMaximize');
                    _syncMaximized();
                  },
                ),
              ),
            ),
            // Логотип и заголовок — только картинка и текст, клики пропускают
            // к зоне перетаскивания (иначе текст «съедал» бы перетаскивание).
            Positioned.fill(
              child: IgnorePointer(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: <Widget>[
                      Image.asset(
                        'assets/icon/mops_icon.png',
                        width: 18,
                        height: 18,
                        filterQuality: FilterQuality.medium,
                      ),
                      const SizedBox(width: 8),
                      if (!centered)
                        Expanded(child: titleText)
                      else
                        const Spacer(),
                      // Место под кнопки, чтобы заголовок не заезжал под них.
                      const SizedBox(width: 96),
                    ],
                  ),
                ),
              ),
            ),
            if (centered)
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 130),
                      child: titleText,
                    ),
                  ),
                ),
              ),
            // Кнопки — поверх всего: их клики не уходят в перетаскивание.
            Positioned(
              right: 6,
              top: 0,
              bottom: 0,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _CircleButton(
                    icon: Icons.remove,
                    onTap: () => _invoke('minimize'),
                  ),
                  _CircleButton(
                    icon: _maximized ? Icons.filter_none : Icons.crop_square,
                    onTap: () {
                      _invoke('toggleMaximize');
                      _syncMaximized();
                    },
                  ),
                  _CircleButton(
                    icon: Icons.close,
                    danger: true,
                    onTap: () => _invoke('close'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Круглая кнопка окна в духе M3 Expressive: круг, при наведении — заливка.
/// У закрытия заливка красная, как принято в Windows.
///
/// Подсветка сделана вручную (`MouseRegion` + `AnimatedContainer`), а не
/// `InkWell`: панель висит выше `Scaffold`, `Material`-предка над ней нет, и
/// штатные чернила Material просто некуда было бы рисовать.
class _CircleButton extends StatefulWidget {
  const _CircleButton({
    required this.icon,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool danger;

  @override
  State<_CircleButton> createState() => _CircleButtonState();
}

class _CircleButtonState extends State<_CircleButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color hoverColor = widget.danger
        ? const Color(0xFFC42B1C)
        : scheme.onSurface.withValues(alpha: 0.12);
    final Color pressedColor = widget.danger
        ? const Color(0xFFA81F14)
        : scheme.onSurface.withValues(alpha: 0.20);
    final bool filled = _hover || _pressed;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _pressed = false;
        }),
        child: GestureDetector(
          // Клик ловит вся площадка кнопки, а не только глиф иконки.
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedContainer(
            duration: AppMotion.quickChange.duration,
            curve: AppMotion.quickChange.curve,
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: !filled
                  ? Colors.transparent
                  : (_pressed ? pressedColor : hoverColor),
            ),
            child: Icon(
              widget.icon,
              size: 15,
              color: filled && widget.danger
                  ? Colors.white
                  : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
