import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../features/shell/content_navigator.dart';

/// Прогресс жеста «назад», 0…1.
///
/// Читают маршруты: пока жест идёт, верхний экран едет за пальцем и темнеет —
/// как в системной анимации Android. Без этого жест срабатывал «молча»: экран
/// просто исчезал в конце.
final ValueNotifier<double> backGestureProgress = ValueNotifier<double>(0);

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

class _BackGestureState extends State<BackGesture>
    with SingleTickerProviderStateMixin {
  /// Накопленное смещение текущего жеста тачпада.
  double _panDx = 0;

  /// Возврат экрана на место, если жест не добрал порога.
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  @override
  void initState() {
    super.initState();
    _settle.addListener(() {
      backGestureProgress.value = _settle.value;
    });
    // Клавиатуру слушаем глобально, а не через `Shortcuts`: сочетание должно
    // работать независимо от того, где сейчас фокус.
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    _settle.dispose();
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

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

  void _onPanZoomStart(PointerPanZoomStartEvent event) {
    // Новый жест начинается с нуля; незаконченный «возврат» отменяем.
    _settle.stop();
    _panDx = 0;
    _settle.value = 0;
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    _panDx += event.panDelta.dx;
    // Пока жест идёт, верхний экран едет за пальцем: прогресс 0..1 ведёт
    // `_settle`, а его слушатель отдаёт значение в `backGestureProgress` —
    // его читает `PredictiveBack`. Раньше прогресс никто не выставлял, и
    // экран сдвигался «молча», хотя контроллер `_settle` уже был заведён.
    _settle.value = (_panDx / BackGesture.swipeThreshold).clamp(0.0, 1.0);
  }

  void _onPanZoomEnd(PointerPanZoomEndEvent event) {
    final double dx = _panDx;
    _panDx = 0;
    // Свайп вправо — назад. Влево не трогаем: там «вперёд» нет, а случайный
    // жест в обратную сторону не должен ничего закрывать.
    if (dx >= BackGesture.swipeThreshold) {
      // Порог набран — маршрут закрывается; прогресс гасим, иначе следующий
      // экран открылся бы уже сдвинутым.
      _settle.value = 0;
      _goBack();
      return;
    }
    // Порог не добрали — плавно возвращаем экран на место (как и задумано
    // в комментарии к `_settle`).
    _settle.animateTo(0, curve: Curves.easeOutCubic);
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
      onPointerPanZoomStart: _onPanZoomStart,
      onPointerPanZoomUpdate: _onPanZoomUpdate,
      onPointerPanZoomEnd: _onPanZoomEnd,
      onPointerDown: (PointerDownEvent event) {
        // Кнопка «назад» на мыши: Flutter присылает её как нажатие с
        // соответствующим битом, а не как отдельный жест. Проверяем бит, а не
        // равенство: вместе с «назад» может быть зажата и другая кнопка.
        if (event.buttons & kBackMouseButton != 0) _goBack();
      },
      child: widget.child,
    );
  }
}

/// Верхний экран, который едет за пальцем во время жеста «назад».
///
/// Как в системной анимации Android: уходящий экран сдвигается вправо и
/// темнеет, а из-под него показывается предыдущий. Нижние маршруты не
/// трогаем — их всё равно не видно, а сдвиг открыл бы фон вместо страницы.
class PredictiveBack extends StatelessWidget {
  const PredictiveBack({super.key, required this.child});

  final Widget child;

  /// Насколько экран уходит в сторону на полном жесте.
  static const double _shift = 0.28;

  @override
  Widget build(BuildContext context) {
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    // Сдвигаем только верхний маршрут: остальные лежат под ним.
    if (route == null || !route.isCurrent) return child;

    return ValueListenableBuilder<double>(
      valueListenable: backGestureProgress,
      builder: (BuildContext context, double progress, Widget? inner) {
        if (progress <= 0.001) return inner!;
        final double width = MediaQuery.sizeOf(context).width;
        return Transform.translate(
          offset: Offset(progress * width * _shift, 0),
          child: Stack(
            children: <Widget>[
              inner!,
              // Затемнение уходящего экрана — оно же гасит и «оторванный»
              // край, чтобы сдвиг читался как уход в глубину.
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.28 * progress),
                  ),
                ),
              ),
            ],
          ),
        );
      },
      child: child,
    );
  }
}
