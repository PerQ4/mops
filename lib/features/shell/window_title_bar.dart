import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/app_settings.dart';
import '../../core/theme/app_theme.dart';
import '../../state/player_controller.dart';
import '../../state/providers.dart';
import '../../state/shell.dart';
import 'destinations.dart';
import 'snap_layout_panel.dart';
import 'window_channel.dart';

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
  /// Панель раскладок живёт в `Overlay` шапки, а не в её дереве.
  ///
  /// Вся шапка — это полоса высотой 34: всё нарисованное за её нижним краем
  /// не получает ни наведения, ни кликов, потому что попадание считается по
  /// границам виджета. Оверлей же занимает всё окно — там панели есть куда
  /// расти.
  OverlayEntry? _snapPanel;

  Timer? _snapShowTimer;
  Timer? _snapHideTimer;

  /// Задержка перед показом: раскладки не должны вспыхивать, когда курсор
  /// просто проходит через «Развернуть» по пути к «Закрыть».
  static const Duration _snapShowDelay = Duration(milliseconds: 350);

  /// Запас на путь от кнопки до панели: между ними несколько пикселей, и без
  /// него панель исчезала бы раньше, чем до неё дотянется курсор.
  static const Duration _snapHideDelay = Duration(milliseconds: 220);

  @override
  void initState() {
    super.initState();
    // Подписываемся на нативные события и спрашиваем текущее состояние: окно
    // могло быть развёрнуто ещё до появления шапки.
    WindowChannel.attach();
  }

  @override
  void dispose() {
    _snapShowTimer?.cancel();
    _snapHideTimer?.cancel();
    _snapPanel?.remove();
    _snapPanel = null;
    super.dispose();
  }

  /// Курсор над кнопкой «Развернуть».
  void _onMaximizeHover(bool hovered) {
    if (hovered) {
      _snapHideTimer?.cancel();
      _snapHideTimer = null;
      _snapShowTimer ??= Timer(_snapShowDelay, _showSnapPanel);
    } else {
      _snapShowTimer?.cancel();
      _snapShowTimer = null;
      _scheduleSnapHide();
    }
  }

  /// Курсор над самой панелью: пока он там, прятать нечего.
  void _onPanelHover(bool hovered) {
    if (hovered) {
      _snapHideTimer?.cancel();
      _snapHideTimer = null;
    } else {
      _scheduleSnapHide();
    }
  }

  void _scheduleSnapHide() {
    _snapHideTimer?.cancel();
    _snapHideTimer = Timer(_snapHideDelay, _hideSnapPanel);
  }

  void _showSnapPanel() {
    _snapShowTimer = null;
    // Шапка могла исчезнуть, пока тикал таймер (полноэкранный клип её гасит).
    if (!mounted || _snapPanel != null) return;

    final OverlayState? overlay = Overlay.maybeOf(context);
    // Без оверлея панель некуда положить. Кнопка при этом работает как
    // обычно, поэтому молча выходим.
    if (overlay == null) return;

    _snapPanel = OverlayEntry(
      builder: (BuildContext context) {
        // Запись оверлея растягивается на всё окно, поэтому панель
        // прижимается к правому верхнему углу. Мышь ловит только она сама:
        // полноэкранная выкладка прозрачна для кликов, и всё, что мимо
        // плиток, уходит в содержимое окна.
        return Align(
          alignment: Alignment.topRight,
          child: Padding(
            // Под шапкой и с отступом от правого края — рядом с кнопками,
            // но не поверх них: полоса шапки остаётся зоной перетаскивания.
            padding: EdgeInsets.only(top: widget.height + 6, right: 8),
            child: SnapLayoutPanel(
              onHoverChanged: _onPanelHover,
              onSelected: _onSnapSelected,
            ),
          ),
        );
      },
    );
    overlay.insert(_snapPanel!);
    // Перестраиваем шапку только ради подсказки кнопки (см. `tooltip` ниже).
    setState(() {});
  }

  void _onSnapSelected(SnapSide side) {
    WindowChannel.snap(side);
    _hideSnapPanel();
  }

  void _hideSnapPanel() {
    final bool wasShown = _snapPanel != null;
    _snapShowTimer?.cancel();
    _snapShowTimer = null;
    _snapHideTimer?.cancel();
    _snapHideTimer = null;
    _snapPanel?.remove();
    _snapPanel = null;
    if (wasShown && mounted) setState(() {});
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
                  if (event.buttons == kPrimaryButton) {
                    WindowChannel.invoke('startDrag');
                  }
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // Состояние после двойного клика придёт событием WM_SIZE,
                  // отдельно спрашивать его не нужно.
                  onDoubleTap: () {
                    _hideSnapPanel();
                    WindowChannel.invoke('toggleMaximize');
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
                    label: 'Свернуть',
                    onTap: () => WindowChannel.invoke('minimize'),
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: WindowChannel.maximized,
                    builder: (BuildContext context, bool maximized, Widget? _) {
                      // Наведение кнопка отдаёт наружу явным `MouseRegion`, а
                      // не через `onShowHoverHighlight`: тот выключен, пока
                      // система считает ввод «касанием», и панель тогда не
                      // появилась бы вовсе.
                      return MouseRegion(
                        onEnter: (PointerEnterEvent _) =>
                            _onMaximizeHover(true),
                        onExit: (PointerExitEvent _) => _onMaximizeHover(false),
                        child: _CircleButton(
                          icon:
                              maximized ? Icons.filter_none : Icons.crop_square,
                          label: maximized ? 'Восстановить' : 'Развернуть',
                          // Пока панель раскладок открыта, подсказку прячем:
                          // она всплывает мгновенно и легла бы ровно на
                          // плитки — панель и так подписана.
                          tooltip: _snapPanel == null,
                          onTap: () {
                            _hideSnapPanel();
                            WindowChannel.invoke('toggleMaximize');
                          },
                        ),
                      );
                    },
                  ),
                  _CircleButton(
                    icon: Icons.close,
                    label: 'Закрыть',
                    danger: true,
                    onTap: () => WindowChannel.invoke('close'),
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
/// Подсветка сделана вручную (`AnimatedContainer`), а не `InkWell`: панель
/// висит выше `Scaffold`, `Material`-предка над ней нет, и штатные чернила
/// Material просто некуда было бы рисовать.
///
/// Кнопка доступна с клавиатуры: `FocusableActionDetector` даёт фокус по Tab
/// и разбирает Enter/Space (они приходят стандартным `ActivateIntent`).
class _CircleButton extends StatefulWidget {
  const _CircleButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.tooltip = true,
    this.danger = false,
  });

  final IconData icon;

  /// Доступное имя кнопки для экранного диктора.
  final String label;
  final VoidCallback onTap;

  /// Показывать ли всплывающую подсказку.
  final bool tooltip;
  final bool danger;

  @override
  State<_CircleButton> createState() => _CircleButtonState();
}

class _CircleButtonState extends State<_CircleButton> {
  bool _hover = false;
  bool _pressed = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Слои состояний — из общего словаря, а не своими альфами: здесь были
    // 0.12 и 0.20, в настройках 0.06, у иконок 0.12. Красные кнопки окна
    // остаются своими: это семантический цвет закрытия, а не слой темы.
    final Color hoverColor =
        widget.danger ? const Color(0xFFC42B1C) : AppStateLayers.hover(scheme);
    final Color pressedColor =
        widget.danger ? const Color(0xFFA81F14) : AppStateLayers.pressed(scheme);
    final bool filled = _hover || _pressed;

    // `Tooltip` требует предка `Overlay`, а шапка висит в `MaterialApp.builder`
    // выше навигатора. Свой оверлей ей даёт `app.dart`; проверка оставлена
    // страховкой: без оверлея `Tooltip` падает с «No Overlay widget found».
    final bool canShowHint = widget.tooltip && Overlay.maybeOf(context) != null;

    final Widget button = Semantics(
      button: true,
      label: widget.label,
      child: FocusableActionDetector(
        onShowHoverHighlight: (bool value) => setState(() => _hover = value),
        onFocusChange: (bool value) => setState(() => _focused = value),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (ActivateIntent _) {
              widget.onTap();
              return null;
            },
          ),
        },
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
              // Кольцо — только при фокусе с клавиатуры: мышью оно не
              // нужно, а без него непонятно, какая кнопка сейчас активна.
              border: _focused
                  ? Border.all(color: scheme.primary, width: 1.5)
                  : null,
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: canShowHint
          ? Tooltip(
              message: widget.label,
              // Имя кнопки уже задано в `Semantics` — иначе диктор прочитал бы
              // его дважды: как подпись и как подсказку.
              excludeFromSemantics: true,
              child: button,
            )
          : button,
    );
  }
}
