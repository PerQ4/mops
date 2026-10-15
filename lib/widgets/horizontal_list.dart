import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Горизонтальная лента, которую можно прокрутить мышью.
///
/// В Flutter на десктопе этого «из коробки» нет, и лента остаётся
/// неподвижной сразу по двум причинам:
///
/// 1. колесо мыши приходит вертикальным, а горизонтальный список вертикальное
///    смещение игнорирует;
/// 2. перетаскивание разрешено только тач-устройствам — `dragDevices` по
///    умолчанию не содержит мышь.
///
/// Здесь обе причины устранены: колесо пробрасывается в горизонталь, мышь
/// добавлена в список устройств перетаскивания, а снизу видна тонкая полоса
/// прокрутки — иначе непонятно, что у ленты есть продолжение.
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
  final bool showScrollbar;

  @override
  State<HorizontalList> createState() => _HorizontalListState();
}

class _HorizontalListState extends State<HorizontalList> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Прокручивает ленту по вертикальному колесу.
  ///
  /// Берём именно вертикальное смещение: горизонтальное колесо (или сдвиг
  /// тачпадом вбок) приходит уже горизонтальным и работает само.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!_controller.hasClients) return;

    final double delta = event.scrollDelta.dy != 0
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    final ScrollPosition position = _controller.position;
    final double target = (position.pixels + delta)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target == position.pixels) return;

    _controller.jumpTo(target);
    // Событие обработано — гасим его, иначе колесо прокрутит ещё и страницу
    // под лентой.
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {});
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: Listener(
        onPointerSignal: _onPointerSignal,
        child: ScrollConfiguration(
          // Мышь и стилус перетаскивают ленту наравне с пальцем.
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
            thumbVisibility: widget.showScrollbar,
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
    );
  }
}
