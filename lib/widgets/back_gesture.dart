import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../features/shell/content_navigator.dart';

/// Жест «назад», как в приложениях Android.
///
/// Поддерживается три способа, потому что на десктопе нет одного общего:
///
/// - **свайп двумя пальцами по тачпаду слева направо** — основной, его и
///   просил пользователь. Flutter отдаёт жесты тачпада событиями
///   `PointerPanZoom`, поэтому ловим именно их: обычное колесо приходит
///   `PointerScrollEvent` и занято прокруткой, а жест двумя пальцами — нет;
/// - **кнопка «назад» на мыши** (`kBackMouseButton`), если она есть;
/// - **Alt + ←** — привычное сочетание на десктопе.
///
/// Виджет ставится внутри корневого навигатора (оболочка), поэтому события
/// всплывают к нему и от подэкранов тоже.
class BackGesture extends StatefulWidget {
  const BackGesture({super.key, required this.child});

  final Widget child;

  /// Сколько нужно протащить двумя пальцами, чтобы это считалось жестом.
  static const double swipeThreshold = 110;

  @override
  State<BackGesture> createState() => _BackGestureState();
}

class _BackGestureState extends State<BackGesture> {
  /// Накопленное смещение текущего жеста тачпада.
  double _panDx = 0;

  /// Закрывает верхний экран: сначала подэкран оболочки, потом полноэкранный
  /// плеер. Порядок важен — плеер открывается в корневом навигаторе поверх
  /// всего, и «назад» должен закрывать его первым делом.
  void _goBack() {
    final NavigatorState? nested = contentNavigatorKey.currentState;
    if (nested != null && nested.canPop()) {
      nested.maybePop();
      return;
    }
    // Через `Navigator.of` отсюда не достать: виджет оборачивает навигатор
    // целиком, то есть его контекст лежит выше. Поэтому ключ.
    rootNavigatorKey.currentState?.maybePop();
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    _panDx += event.panDelta.dx;
    debugPrint('ВРЕМЕННО: panZoom dx=$_panDx');
  }

  void _onPanZoomEnd(PointerPanZoomEndEvent event) {
    final double dx = _panDx;
    _panDx = 0;
    // Свайп вправо — назад. Влево не трогаем: там «вперёд» нет, а случайный
    // жест в обратную сторону не должен ничего закрывать.
    if (dx >= BackGesture.swipeThreshold) _goBack();
  }

  @override
  void initState() {
    super.initState();
    // Клавиатуру слушаем глобально, а не через `Shortcuts`: сочетание должно
    // работать независимо от того, где сейчас фокус — в списке, в поле поиска
    // или на кнопке.
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// Alt + ← и кнопка «назад» на клавиатуре.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final bool alt = HardwareKeyboard.instance.isAltPressed;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft && alt) {
      _goBack();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.browserBack) {
      _goBack();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // `opaque`: жест двумя пальцами начинается и над пустым местом, и над
      // кнопкой — обработчик должен получать его в любом случае.
      behavior: HitTestBehavior.opaque,
      onPointerPanZoomStart: (PointerPanZoomStartEvent event) => _panDx = 0,
      onPointerPanZoomUpdate: _onPanZoomUpdate,
      onPointerPanZoomEnd: _onPanZoomEnd,
      onPointerDown: (PointerDownEvent event) {
        // Кнопка «назад» на мыши: Flutter присылает её как нажатие с
        // соответствующим битом, а не как отдельный жест.
        if (event.buttons == kBackMouseButton) _goBack();
      },
      child: widget.child,
    );
  }
}
