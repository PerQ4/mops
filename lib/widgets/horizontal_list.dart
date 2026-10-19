import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Горизонтальная лента, которую можно листать мышью.
///
/// В Flutter на десктопе этого «из коробки» нет: перетаскивание разрешено
/// только тач-устройствам — `dragDevices` по умолчанию не содержит мышь.
/// Здесь мышь, трекпад и стилус добавлены в список устройств перетаскивания,
/// а снизу видна тонкая полоса прокрутки — иначе непонятно, что у ленты есть
/// продолжение.
///
/// Колесо мыши ленту НЕ листает: вертикальное колесо прокручивает страницу.
/// Раньше оно превращалось в горизонтальную прокрутку ленты и гасилось, из-за
/// чего страница под лентой «застревала».
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

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: ScrollConfiguration(
        // Мышь и стилус перетаскивают ленту наравне с пальцем. Колесо мыши
        // здесь НЕ перехватываем: раньше вертикальное колесо превращалось в
        // горизонтальную прокрутку ленты и гасилось, из-за чего страница под
        // ней «застревала». Теперь колесо всегда прокручивает страницу, а
        // лента листается перетаскиванием (мышью/пальцем) или полосой
        // прокрутки.
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
    );
  }
}
