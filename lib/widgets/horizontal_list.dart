import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/layout.dart';
import '../core/theme/motion.dart';

/// Размер круглой кнопки-стрелки у края ленты.
const double _arrowSize = 36;

/// Половина пикселя: край считается достигнутым, даже если прокрутка не встала
/// ровно в ноль из-за дробных размеров.
const double _edge = 0.5;

/// Горизонтальная лента, которую можно листать мышью.
///
/// В Flutter на десктопе этого «из коробки» нет: перетаскивание разрешено
/// только тач-устройствам — `dragDevices` по умолчанию не содержит мышь.
/// Здесь мышь, трекпад и стилус добавлены в список устройств перетаскивания,
/// а снизу видна тонкая полоса прокрутки — иначе непонятно, что у ленты есть
/// продолжение.
///
/// Обычное (вертикальное) колесо ленту НЕ листает: оно прокручивает страницу.
/// Раньше оно превращалось в горизонтальную прокрутку ленты и гасилось, из-за
/// чего страница под лентой «застревала». Листают ленту Shift+колесо,
/// перетаскивание мышью, полоса прокрутки и стрелки по краям — так же, как
/// это делают полки на десктопе.
class HorizontalList extends StatefulWidget {
  const HorizontalList({
    super.key,
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
    this.padding = EdgeInsets.zero,
    this.separator = 0,
    this.showScrollbar = true,
  });

  /// Высота ленты: карточки фиксированной высоты, поэтому лента не «прыгает».
  final double height;

  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final EdgeInsets padding;

  /// Зазор между элементами.
  final double separator;

  /// Показывать полосу прокрутки.
  ///
  /// У рядов чипов она только мешает: чипы и так обрезаны краем, и понятно,
  /// что ряд листается. У лент карточек полоса нужна — там о продолжении
  /// догадаться неоткуда.
  ///
  /// На десктопе полоса показывается всегда, когда ленте есть куда листать:
  /// без неё продолжение ленты не видно. На узком и тач-экране значение
  /// соблюдается как есть.
  final bool showScrollbar;

  @override
  State<HorizontalList> createState() => _HorizontalListState();
}

class _HorizontalListState extends State<HorizontalList> {
  final ScrollController _controller = ScrollController();

  /// Курсор над лентой: только тогда показываем стрелки.
  bool _hovered = false;

  /// Лента не помещается целиком — стрелки и полоса вообще имеют смысл.
  bool _scrollable = false;

  /// Есть куда листать назад/вперёд: у начала и конца стрелка прячется.
  bool _canBack = false;
  bool _canForward = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Десктопная раскладка: не тач-платформа и окно шире телефонного.
  ///
  /// Ширина важна отдельно от платформы: на узком окне десктопа лента должна
  /// вести себя как на телефоне — стрелки закрывали бы сами карточки.
  bool _isDesktop(BuildContext context) {
    final bool touchFirst = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    return !touchFirst &&
        !AppLayout.isCompact(MediaQuery.sizeOf(context).width);
  }

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
  }

  /// Пересчитывает, куда можно листать. Вызывается по нотификациям прокрутки —
  /// они приходят после раскладки, поэтому `setState` здесь безопасен.
  void _updateMetrics(ScrollMetrics metrics) {
    final bool scrollable = metrics.maxScrollExtent > _edge;
    final bool back =
        scrollable && metrics.pixels > metrics.minScrollExtent + _edge;
    final bool forward =
        scrollable && metrics.pixels < metrics.maxScrollExtent - _edge;
    if (scrollable == _scrollable &&
        back == _canBack &&
        forward == _canForward) {
      return;
    }
    setState(() {
      _scrollable = scrollable;
      _canBack = back;
      _canForward = forward;
    });
  }

  bool _onScrollMetrics(ScrollMetricsNotification notification) {
    _updateMetrics(notification.metrics);
    return false;
  }

  bool _onScroll(ScrollNotification notification) {
    _updateMetrics(notification.metrics);
    return false;
  }

  /// Shift+колесо — горизонтальная прокрутка ленты.
  ///
  /// Без Shift событие даже не регистрируем: вертикальное колесо должно
  /// доходить до страницы. Регистрация в `pointerSignalResolver` и есть
  /// «перехват» — победившее событие дальше не передаётся.
  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!HardwareKeyboard.instance.isShiftPressed) return;
    if (!_controller.hasClients) return;

    // На Windows Shift+колесо приходит вертикальным (dy), на трекпаде вбок —
    // горизонтальным (dx). Берём то, что есть, чтобы работало одинаково.
    final double delta = event.scrollDelta.dy != 0
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    if (delta == 0) return;

    final ScrollPosition position = _controller.position;
    final bool canScroll = delta > 0
        ? position.pixels < position.maxScrollExtent - _edge
        : position.pixels > position.minScrollExtent + _edge;
    // У самого края событие не забираем: пусть страница листается, иначе она
    // «застревала» бы над лентой — та же беда, из-за которой колесо перестало
    // листать ленту.
    if (!canScroll) return;

    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (PointerSignalEvent event) {
        if (!_controller.hasClients) return;
        // `pointerScroll` сам ограничивает прокрутку краями и шлёт обычные
        // нотификации — стрелки узнают о новом положении без своей логики.
        _controller.position.pointerScroll(delta);
      },
    );
  }

  /// Листает на ширину окна ленты — как страницу.
  void _page(bool forward) {
    if (!_controller.hasClients) return;
    final ScrollPosition position = _controller.position;
    final double step = position.viewportDimension;
    if (step <= 0) return;
    final double target =
        forward ? position.pixels + step : position.pixels - step;
    final MotionTransition motion = AppMotion.elementMove;
    position.moveTo(
      target,
      duration: motion.duration,
      curve: motion.curve,
      clamp: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool desktop = _isDesktop(context);
    return SizedBox(
      height: widget.height,
      child: MouseRegion(
        onEnter: (PointerEnterEvent _) => _setHovered(true),
        onExit: (PointerExitEvent _) => _setHovered(false),
        child: Listener(
          onPointerSignal: _handlePointerSignal,
          child: Stack(
            children: <Widget>[
              NotificationListener<ScrollMetricsNotification>(
                onNotification: _onScrollMetrics,
                child: NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: ScrollConfiguration(
                    // Мышь и стилус перетаскивают ленту наравне с пальцем.
                    // Колесо перехватывает только [_handlePointerSignal] и
                    // только с Shift — обычное колесо прокручивает страницу.
                    behavior: ScrollConfiguration.of(context).copyWith(
                      dragDevices: <PointerDeviceKind>{
                        PointerDeviceKind.touch,
                        PointerDeviceKind.mouse,
                        PointerDeviceKind.trackpad,
                        PointerDeviceKind.stylus,
                      },
                    ),
                    child: Scrollbar(
                      controller: _controller,
                      // На десктопе полоса постоянная, если ленте есть куда
                      // листать: она и подсказывает о продолжении. На узком
                      // экране решает сам экран (`showScrollbar`).
                      thumbVisibility: desktop || widget.showScrollbar,
                      child: ListView.separated(
                        controller: _controller,
                        scrollDirection: Axis.horizontal,
                        padding: widget.padding,
                        itemCount: widget.itemCount,
                        separatorBuilder: (BuildContext context, int _) =>
                            SizedBox(width: widget.separator),
                        itemBuilder: widget.itemBuilder,
                      ),
                    ),
                  ),
                ),
              ),
              if (desktop) ...<Widget>[
                _arrow(forward: false),
                _arrow(forward: true),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Круглая стрелка у края: появляется с наведением, гаснет, когда листать
  /// некуда. Скрытая стрелка не ловит мышь — под ней остаётся лента.
  Widget _arrow({required bool forward}) {
    final bool visible =
        _hovered && _scrollable && (forward ? _canForward : _canBack);
    final MotionTransition fade = AppMotion.hoverFade;
    return Positioned(
      left: forward ? null : 4,
      right: forward ? 4 : null,
      top: (widget.height - _arrowSize) / 2,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: fade.duration,
          curve: fade.curve,
          child: _CarouselArrow(
            icon: forward ? Icons.chevron_right : Icons.chevron_left,
            tooltip: forward ? 'Прокрутить вправо' : 'Прокрутить влево',
            onTap: () => _page(forward),
          ),
        ),
      ),
    );
  }
}

/// Кнопка-стрелка ленты: круг на полупрозрачной поверхности.
class _CarouselArrow extends StatelessWidget {
  const _CarouselArrow({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Material(
      // Полупрозрачная: карточка под стрелкой должна угадываться.
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.9),
      elevation: 1,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        iconSize: 20,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(
          width: _arrowSize,
          height: _arrowSize,
        ),
        icon: Icon(icon, color: scheme.onSurfaceVariant),
      ),
    );
  }
}
