/// Словарь движений mOps: один язык анимации вместо длительностей и кривых,
/// заданных «на месте» в разных виджетах.
///
/// Значения взяты из motion-схемы Material 3 Expressive, а не подобраны на
/// глаз:
///
/// * шкала длительностей и кривые для цвета и прозрачности — из пакета
///   `material_3_expressive` ([m3e.M3EMotion]). Чисел здесь нет: они остаются
///   в схеме, поэтому обновление пакета обновляет и приложение;
/// * пространственные expressive-кривые с перелётом через цель — те же
///   пружины `expressiveSpatial*`, заранее сведённые в кубические ([Cubic]).
///   Свести пришлось потому, что `AnimatedContainer` и `AnimatedSwitcher`
///   принимают [Curve], а не `SpringDescription`, и перевести пружину в кривую
///   Flutter не умеет. Контрольные точки совпадают с набором end4, по которому
///   сделан десктопный `shredos67/swiftify`; они же стоят в его
///   `qml/motion/*` — оттуда и словарь переходов ниже.
///
/// Именованные переходы ([AppMotion.elementMove] и соседние) — готовые пары
/// «длительность + кривая» для `AnimatedContainer`, `AnimatedSwitcher` и
/// `PageRouteBuilder`. Поля названы так же, как их параметры — `duration`,
/// `reverseDuration`, `curve`, `reverseCurve`, — поэтому переход вставляется в
/// виджет без пересчёта. Смысл словаря в том, что одинаковые действия
/// (появление, уход, нажатие) на разных экранах берут один и тот же переход.
library;

import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart' as m3e;

/// Шкала длительностей motion-схемы M3 Expressive.
///
/// Четыре ступени в каждой четверти: short 50…200 мс, medium 250…400, long
/// 450…600, extraLong 700…1000. Имена — как в схеме, чтобы сверка с ней не
/// требовала перевода.
abstract final class MotionDuration {
  /// 50 мс.
  static const Duration short1 = m3e.M3EMotion.short1;

  /// 100 мс.
  static const Duration short2 = m3e.M3EMotion.short2;

  /// 150 мс.
  static const Duration short3 = m3e.M3EMotion.short3;

  /// 200 мс.
  static const Duration short4 = m3e.M3EMotion.short4;

  /// 250 мс.
  static const Duration medium1 = m3e.M3EMotion.medium1;

  /// 300 мс.
  static const Duration medium2 = m3e.M3EMotion.medium2;

  /// 350 мс.
  static const Duration medium3 = m3e.M3EMotion.medium3;

  /// 400 мс.
  static const Duration medium4 = m3e.M3EMotion.medium4;

  /// 450 мс.
  static const Duration long1 = m3e.M3EMotion.long1;

  /// 500 мс.
  static const Duration long2 = m3e.M3EMotion.long2;

  /// 550 мс.
  static const Duration long3 = m3e.M3EMotion.long3;

  /// 600 мс.
  static const Duration long4 = m3e.M3EMotion.long4;

  /// 700 мс.
  static const Duration extraLong1 = m3e.M3EMotion.extraLong1;

  /// 800 мс.
  static const Duration extraLong2 = m3e.M3EMotion.extraLong2;

  /// 900 мс.
  static const Duration extraLong3 = m3e.M3EMotion.extraLong3;

  /// 1000 мс.
  static const Duration extraLong4 = m3e.M3EMotion.extraLong4;
}

/// Кривые motion-схемы M3 Expressive.
///
/// Сначала обычные — для цвета, прозрачности и служебных поверхностей; затем
/// expressive-пространственные, которые и дают «отдачу».
abstract final class MotionCurve {
  /// Обычная кривая: подходит всему, что не должно бросаться в глаза.
  static const Curve standard = m3e.M3EMotion.standard;

  /// Обычная кривая на разгон — для уходящих элементов.
  static const Curve standardAccelerate = m3e.M3EMotion.standardAccelerate;

  /// Обычная кривая на торможение — для приходящих элементов.
  static const Curve standardDecelerate = m3e.M3EMotion.standardDecelerate;

  /// Акцентированная кривая.
  ///
  /// Берём из Flutter, а не из пакета: в схеме это составная кривая из двух
  /// отрезков (`Curves.easeInOutCubicEmphasized`), а пакет держит только
  /// грубое приближение одним кубиком.
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;

  /// Акцентированная на разгон — уход элемента: он не должен тормозить
  /// на глазах.
  static const Curve emphasizedAccelerate = m3e.M3EMotion.emphasizedAccelerate;

  /// Акцентированная на торможение — появление элемента.
  static const Curve emphasizedDecelerate = m3e.M3EMotion.emphasizedDecelerate;

  /// Быстрая пространственная expressive-кривая: заметный перелёт.
  static const Curve expressiveFastSpatial = Cubic(0.42, 1.67, 0.21, 0.9);

  /// Обычная пространственная expressive-кривая — переезды и нажатия.
  static const Curve expressiveSpatial = Cubic(0.38, 1.21, 0.22, 1);

  /// Медленная пространственная expressive-кривая — крупные перелёты.
  static const Curve expressiveSlowSpatial = Cubic(0.39, 1.29, 0.35, 0.98);

  /// Та же отдача, но для цвета и прозрачности — без перелёта через цель:
  /// прозрачность за границей 0…1 всё равно обрезалась бы.
  static const Curve expressiveEffects = Cubic(0.34, 0.8, 0.34, 1);
}

/// Именованный переход: длительность и кривая одним значением.
///
/// [duration] и [curve] — прямой ход, [reverseDuration] и [reverseCurve] —
/// обратный. Не задан обратный — он равен прямому.
@immutable
class MotionTransition {
  const MotionTransition({
    required this.duration,
    required this.curve,
    this.reverseDuration,
    this.reverseCurve,
  });

  /// Длительность прямого хода.
  final Duration duration;

  /// Кривая прямого хода.
  final Curve curve;

  /// Длительность обратного хода; не задана — обратный ход идёт как прямой.
  final Duration? reverseDuration;

  /// Кривая обратного хода; не задана — обратный ход идёт как прямой.
  final Curve? reverseCurve;

  /// Прямая кривая как `Animatable` — для `animation.drive(...)`.
  ///
  /// Именно `CurveTween`, а не `CurvedAnimation`: последний подписывается на
  /// родителя и требует `dispose`, то есть его нельзя создавать в `build`.
  CurveTween get tween => CurveTween(curve: curve);

  /// Тот же переход для `showModalBottomSheet` и `MenuStyle`.
  AnimationStyle get style {
    return AnimationStyle(
      duration: duration,
      reverseDuration: reverseDuration ?? duration,
      curve: curve,
      reverseCurve: reverseCurve ?? curve,
    );
  }

  /// Переключение содержимого: появление берёт прямой ход перехода, уход —
  /// обратный.
  Widget switcher({
    required Widget child,
    AnimatedSwitcherLayoutBuilder layoutBuilder =
        AnimatedSwitcher.defaultLayoutBuilder,
  }) {
    return AnimatedSwitcher(
      duration: duration,
      reverseDuration: reverseDuration,
      switchInCurve: curve,
      switchOutCurve: reverseCurve ?? curve,
      layoutBuilder: layoutBuilder,
      child: child,
    );
  }
}

/// Переходы, которыми размечены действия в приложении.
abstract final class AppMotion {
  /// Элемент переезжает на новое место: карточка меняет позицию, лента
  /// прокручивается на элемент.
  static const MotionTransition elementMove = MotionTransition(
    duration: MotionDuration.long2,
    curve: MotionCurve.expressiveSpatial,
  );

  /// Короткий переезд: сдвиг на строку, подъём кнопки — резче обычного.
  static const MotionTransition elementMoveSmall = MotionTransition(
    duration: MotionDuration.medium3,
    curve: MotionCurve.expressiveFastSpatial,
  );

  /// Элемент появляется: вперёд — с торможением, назад (уход) — по обычной
  /// быстрой кривой. Один переход закрывает обе половины `AnimatedSwitcher`.
  static const MotionTransition elementMoveEnter = MotionTransition(
    duration: MotionDuration.medium4,
    curve: MotionCurve.emphasizedDecelerate,
    reverseDuration: MotionDuration.short4,
    reverseCurve: MotionCurve.emphasizedAccelerate,
  );

  /// Элемент уходит — тот же переход, читаемый от ухода: если экран сам
  /// называет, чем он закрывается, брать надо этот.
  static const MotionTransition elementMoveExit = MotionTransition(
    duration: MotionDuration.short4,
    curve: MotionCurve.emphasizedAccelerate,
    reverseDuration: MotionDuration.medium4,
    reverseCurve: MotionCurve.emphasizedDecelerate,
  );

  /// Элемент меняет размер или форму.
  static const MotionTransition elementResize = MotionTransition(
    duration: MotionDuration.medium2,
    curve: MotionCurve.emphasized,
  );

  /// Анимация крупного перелёта — обложка из карточки в плеер.
  ///
  /// Длительность задаёт маршрут, кривую — сам перелёт: в Flutter `Hero`
  /// летит по анимации маршрута, поэтому переход и нужен целиком.
  static const MotionTransition heroFlight = MotionTransition(
    duration: MotionDuration.long1,
    curve: MotionCurve.emphasizedDecelerate,
    reverseDuration: MotionDuration.medium2,
    reverseCurve: MotionCurve.emphasizedAccelerate,
  );

  /// Нажатие с отдачей: строка «проседает» под пальцем и пружинит обратно.
  static const MotionTransition clickBounce = MotionTransition(
    duration: MotionDuration.medium4,
    curve: MotionCurve.expressiveSpatial,
  );

  /// Наведение и подсветка: меняются цвет и прозрачность, без перелёта и без
  /// движения геометрии.
  static const MotionTransition hoverFade = MotionTransition(
    duration: MotionDuration.medium3,
    curve: MotionCurve.standard,
  );

  /// Возврат на место после жеста: строка списка из-под пальца, экран из-под
  /// свайпа «назад». Жест уже закончился, поэтому ход только тормозит.
  static const MotionTransition snapBack = MotionTransition(
    duration: MotionDuration.short4,
    curve: MotionCurve.standardDecelerate,
  );

  /// Проявление обложки из кэша.
  static const MotionTransition artworkFade = MotionTransition(
    duration: MotionDuration.short3,
    curve: MotionCurve.standardDecelerate,
  );

  // Прежние имена словаря. Часть кода (настройки) зовёт их напрямую, поэтому
  // они остаются: значения теперь те же, что у схемы, а не подобранные на глаз.

  /// Длительность мелкого отклика — 200 мс.
  static const Duration fast = MotionDuration.short4;

  /// Длительность среднего движения — 300 мс.
  static const Duration medium = MotionDuration.medium2;

  /// Длительность крупного движения — 500 мс.
  static const Duration slow = MotionDuration.long2;

  /// Кривая мелкого отклика — обычная кривая схемы.
  static const Curve snappy = MotionCurve.standard;

  /// Кривая появления — акцентированная на торможение.
  static const Curve gentle = MotionCurve.emphasizedDecelerate;

  /// Кривая смены положения — пространственная expressive.
  static const Curve spring = MotionCurve.expressiveSpatial;

  /// Кривая нажатия — быстрая пространственная expressive.
  static const Curve springSnappy = MotionCurve.expressiveFastSpatial;
}
