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
///
/// Значения отдаются геттерами, а не константами: у приложения есть настройка
/// «Отключить анимации» (задача 7.3), и тогда любая длительность из словаря
/// становится нулевой. Из-за этого [AppMotion] нельзя использовать в `const`
/// выражениях.
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
/// expressive-пространственные, которые и дают «отдачу»; в конце — несколько
/// стандартных кривых Flutter для переходов, у которых свой характер.
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

  // Ниже — стандартные кривые Flutter. Они не из expressive-схемы, но у части
  // движений (переходы маршрутов, прокрутка текста, смена формы кнопки) свой
  // характер, и expressive-кривая его бы изменила. Имена совпадают с
  // `Curves.*`, чтобы связь с исходной кривой была видна без перевода.

  /// Кривая на торможение: движение «доходит» до цели.
  static const Curve easeOutCubic = Curves.easeOutCubic;

  /// Кривая на разгон — обратный ход перехода маршрута.
  static const Curve easeInCubic = Curves.easeInCubic;

  /// Мягкая кривая на торможение — подсветка и мелкие сдвиги.
  static const Curve easeOut = Curves.easeOut;

  /// Кривая с перелётом через цель — отдача после жеста.
  static const Curve easeOutBack = Curves.easeOutBack;

  /// Равномерное движение — там, где важна только конечная точка.
  static const Curve linear = Curves.linear;

  /// Плавное начало и торможение — ступенчатые переходы строки текста песни.
  static const Curve fastOutSlowIn = Curves.fastOutSlowIn;

  /// Мягкий разгон и торможение — прокрутка бегущей строки: текст трогается
  /// и останавливается без рывка.
  static const Curve easeInOut = Curves.easeInOut;
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

  /// Тот же переход без движения.
  ///
  /// Нужен настройке «Отключить анимации»: длительности обнуляются, а кривые
  /// остаются — `CurvedAnimation` с нулевой длительностью просто сразу выдаёт
  /// конечный кадр, и виджеты не успевают показать промежуточное положение.
  MotionTransition get instant => MotionTransition(
    duration: Duration.zero,
    reverseDuration: Duration.zero,
    curve: curve,
    reverseCurve: reverseCurve,
  );

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

  /// Переход маршрута: проявление и сдвиг из [begin] в ноль.
  ///
  /// Один помощник вместо связки `FadeTransition` + `SlideTransition` +
  /// `CurvedAnimation`, которая дублировалась в `navigation.dart` и
  /// `command_palette.dart`. Вызов стоит в `transitionsBuilder`, где виджет
  /// перестраивается вместе с анимацией, поэтому `CurvedAnimation` здесь
  /// уместен.
  Widget routeTransition({
    required Animation<double> animation,
    required Offset begin,
    required Widget child,
  }) {
    final CurvedAnimation curved = CurvedAnimation(
      parent: animation,
      curve: curve,
      reverseCurve: reverseCurve ?? curve,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(begin: begin, end: Offset.zero).animate(curved),
        child: child,
      ),
    );
  }
}

/// Переходы, которыми размечены действия в приложении.
///
/// Каждый переход — геттер, поэтому при включённой настройке «Отключить
/// анимации» он отдаётся мгновенным (см. [animationsDisabled]).
abstract final class AppMotion {
  /// Выключены ли анимации (задача 7.3).
  ///
  /// Общая переменная, а не параметр: словарь читают места без доступа к
  /// `ref` — переходы навигатора, `Scrollable.ensureVisible`, — как и
  /// `artworkLowDataMode` в утилитах обложек. Настройки выставляют её при
  /// каждой смене, поэтому первый же перестроенный виджет берёт новые
  /// значения.
  static bool animationsDisabled = false;

  /// Переход как есть или мгновенный, если анимации выключены.
  static MotionTransition _motion(MotionTransition motion) =>
      animationsDisabled ? motion.instant : motion;

  /// Длительность как есть или нулевая, если анимации выключены.
  static Duration _time(Duration duration) =>
      animationsDisabled ? Duration.zero : duration;

  // ------------------------------------------------------------ переезды

  /// Элемент переезжает на новое место: карточка меняет позицию, лента
  /// прокручивается на элемент.
  static MotionTransition get elementMove => _motion(_elementMove);
  static const MotionTransition _elementMove = MotionTransition(
    duration: MotionDuration.long2,
    curve: MotionCurve.expressiveSpatial,
  );

  /// Короткий переезд: сдвиг на строку, подъём кнопки — резче обычного.
  static MotionTransition get elementMoveSmall => _motion(_elementMoveSmall);
  static const MotionTransition _elementMoveSmall = MotionTransition(
    duration: MotionDuration.medium3,
    curve: MotionCurve.expressiveFastSpatial,
  );

  // ------------------------------------------------- появление и уход

  /// Элемент появляется: вперёд — с торможением, назад (уход) — по обычной
  /// быстрой кривой. Один переход закрывает обе половины `AnimatedSwitcher`.
  static MotionTransition get elementMoveEnter => _motion(_elementMoveEnter);
  static const MotionTransition _elementMoveEnter = MotionTransition(
    duration: MotionDuration.medium4,
    curve: MotionCurve.emphasizedDecelerate,
    reverseDuration: MotionDuration.short4,
    reverseCurve: MotionCurve.emphasizedAccelerate,
  );

  /// Элемент уходит — тот же переход, читаемый от ухода: если экран сам
  /// называет, чем он закрывается, брать надо этот.
  static MotionTransition get elementMoveExit => _motion(_elementMoveExit);
  static const MotionTransition _elementMoveExit = MotionTransition(
    duration: MotionDuration.short4,
    curve: MotionCurve.emphasizedAccelerate,
    reverseDuration: MotionDuration.medium4,
    reverseCurve: MotionCurve.emphasizedDecelerate,
  );

  /// Элемент меняет размер или форму.
  static MotionTransition get elementResize => _motion(_elementResize);
  static const MotionTransition _elementResize = MotionTransition(
    duration: MotionDuration.medium2,
    curve: MotionCurve.emphasized,
  );

  /// Появление подэкрана: проявляется и чуть поднимается. Обратный ход —
  /// тем же характером, поэтому у перехода своя обратная кривая.
  static MotionTransition get pageEnter => _motion(_pageEnter);
  static const MotionTransition _pageEnter = MotionTransition(
    duration: Duration(milliseconds: 260),
    curve: MotionCurve.easeOutCubic,
    reverseDuration: Duration(milliseconds: 200),
    reverseCurve: MotionCurve.easeInCubic,
  );

  /// Появление панели поверх экрана — палитра команд.
  static MotionTransition get overlayEnter => _motion(_overlayEnter);
  static const MotionTransition _overlayEnter = MotionTransition(
    duration: Duration(milliseconds: 200),
    curve: MotionCurve.easeOutCubic,
    reverseDuration: Duration(milliseconds: 150),
    reverseCurve: MotionCurve.easeInCubic,
  );

  /// Раскрытие и сворачивание блока изменением размера: островок плеера и
  /// правая панель. От [elementResize] отличается только длительностью —
  /// здесь важна быстрота, а не подчёркнутая expressive-кривая.
  static MotionTransition get panelResize => _motion(_panelResize);
  static const MotionTransition _panelResize = MotionTransition(
    duration: Duration(milliseconds: 260),
    curve: MotionCurve.easeOutCubic,
  );

  /// Раскрытие панели вверх из островка плеера.
  static MotionTransition get dockPanel => _motion(_dockPanel);
  static const MotionTransition _dockPanel = MotionTransition(
    duration: Duration(milliseconds: 240),
    curve: MotionCurve.easeOutCubic,
  );

  /// Быстрое изменение размера: ширина боковой панели, подсветка выбранного
  /// пункта навигации и раскрытие его подписи.
  static MotionTransition get resizeFast => _motion(_resizeFast);
  static const MotionTransition _resizeFast = MotionTransition(
    duration: Duration(milliseconds: 220),
    curve: MotionCurve.easeOutCubic,
  );

  /// Появление кнопок действия в строке списка.
  static MotionTransition get rowActions => _motion(_rowActions);
  static const MotionTransition _rowActions = MotionTransition(
    duration: Duration(milliseconds: 150),
    curve: MotionCurve.easeOutCubic,
  );

  /// Быстрая смена цвета или прозрачности: кнопки своей шапки окна и кнопки
  /// поверх встроенного браузера.
  static MotionTransition get quickChange => _motion(_quickChange);
  static const MotionTransition _quickChange = MotionTransition(
    duration: Duration(milliseconds: 120),
    curve: MotionCurve.easeOut,
  );

  /// Плавное раскрытие текста в нижней панели текста песни.
  static MotionTransition get fadeSmall => _motion(_fadeSmall);
  static const MotionTransition _fadeSmall = MotionTransition(
    duration: Duration(milliseconds: 160),
    curve: MotionCurve.easeOut,
  );

  /// Плавный перевод градиента фона полноэкранного плеера при смене трека.
  static MotionTransition get backdropShift => _motion(_backdropShift);
  static const MotionTransition _backdropShift = MotionTransition(
    duration: Duration(milliseconds: 900),
    curve: MotionCurve.easeOutCubic,
  );

  /// Смена содержимого сцены плеера — обложка вместо текста. Кривая линейна,
  /// как и по умолчанию у `AnimatedSwitcher`: содержимое здесь равноправно,
  /// и подчёркивать одну из половин нечем.
  static MotionTransition get stageSwitch => _motion(_stageSwitch);
  static const MotionTransition _stageSwitch = MotionTransition(
    duration: Duration(milliseconds: 220),
    curve: MotionCurve.linear,
  );

  /// Смена формы кнопки воспроизведения.
  static MotionTransition get controlMorph => _motion(_controlMorph);
  static const MotionTransition _controlMorph = MotionTransition(
    duration: Duration(milliseconds: 90),
    curve: MotionCurve.linear,
  );

  /// Анимация крупного перелёта — обложка из карточки в плеер.
  ///
  /// Длительность задаёт маршрут, кривую — сам перелёт: в Flutter `Hero`
  /// летит по анимации маршрута, поэтому переход и нужен целиком.
  static MotionTransition get heroFlight => _motion(_heroFlight);
  static const MotionTransition _heroFlight = MotionTransition(
    duration: MotionDuration.long1,
    curve: MotionCurve.emphasizedDecelerate,
    reverseDuration: MotionDuration.medium2,
    reverseCurve: MotionCurve.emphasizedAccelerate,
  );

  // ------------------------------------------------------------ визуализатор

  /// Полосы визуализатора догоняют уровень звука.
  ///
  /// Монитор отдаёт значения тридцать раз в секунду, а рисуется экран чаще —
  /// без этого перехода полосы шли бы шагами по 33 мс. Пространственная
  /// expressive-кривая даёт мягкую пружинную подачу: атака быстрая, спад
  /// догоняет без рывка.
  static MotionTransition get spectrumFollow => _motion(_spectrumFollow);
  static const MotionTransition _spectrumFollow = MotionTransition(
    duration: MotionDuration.short4,
    curve: MotionCurve.expressiveSpatial,
  );

  /// Свечение за обложкой дышит по общему уровню.
  ///
  /// Медленнее полос и без перелёта: свет не должен повторять каждую долю
  /// секунды, иначе он читается как мигание, а не как дыхание.
  static MotionTransition get spectrumBreath => _motion(_spectrumBreath);
  static const MotionTransition _spectrumBreath = MotionTransition(
    duration: MotionDuration.medium1,
    curve: MotionCurve.expressiveEffects,
  );

  // --------------------------------------------------------------- таймеры

  /// Такт жидкого фона плеера — ~30 кадров в секунду: чаще незаметно, реже
  /// заметно дёргается.
  ///
  /// Не геттер и не обнуляется настройкой «Отключить анимации»: это не
  /// переход интерфейса, а шаг `Timer.periodic`, и нулевой шаг гнал бы
  /// таймер без паузы. Фон останавливают пауза трека и `TickerMode`.
  static const Duration backdropFrame = Duration(milliseconds: 33);

  /// Оборот неопределённого кольца вокруг обложки — круг в секунду.
  ///
  /// Тоже не обнуляется: `AnimationController.repeat` с нулевым периодом
  /// делит на ноль, а неопределённый прогресс без движения теряет смысл.
  static const Duration progressSpin = MotionDuration.extraLong4;

  // --------------------------------------------------------------- нажатия

  /// Нажатие капсулы-фильтра: она сжимается под курсором и отпускается.
  /// Отдача здесь была бы лишней — капсула мелкая.
  static MotionTransition get chipPress => _motion(_chipPress);
  static const MotionTransition _chipPress = MotionTransition(
    duration: Duration(milliseconds: 180),
    curve: MotionCurve.easeOut,
  );

  /// Нажатие с отдачей: строка «проседает» под пальцем и пружинит обратно.
  static MotionTransition get clickBounce => _motion(_clickBounce);
  static const MotionTransition _clickBounce = MotionTransition(
    duration: MotionDuration.medium4,
    curve: MotionCurve.expressiveSpatial,
  );

  /// Наведение и подсветка: меняются цвет и прозрачность, без перелёта и без
  /// движения геометрии.
  static MotionTransition get hoverFade => _motion(_hoverFade);
  static const MotionTransition _hoverFade = MotionTransition(
    duration: MotionDuration.medium3,
    curve: MotionCurve.standard,
  );

  /// Возврат на место после жеста: строка списка из-под пальца, экран из-под
  /// свайпа «назад». Жест уже закончился, поэтому ход только тормозит.
  static MotionTransition get snapBack => _motion(_snapBack);
  static const MotionTransition _snapBack = MotionTransition(
    duration: MotionDuration.short4,
    curve: MotionCurve.standardDecelerate,
  );

  /// Возврат островка плеера после перетаскивания — с лёгким перелётом:
  /// отдача, как у выразительных компонентов Material 3.
  static MotionTransition get dockReturn => _motion(_dockReturn);
  static const MotionTransition _dockReturn = MotionTransition(
    duration: Duration(milliseconds: 280),
    curve: MotionCurve.easeOutBack,
  );

  /// Проявление обложки из кэша.
  static MotionTransition get artworkFade => _motion(_artworkFade);
  static const MotionTransition _artworkFade = MotionTransition(
    duration: MotionDuration.short3,
    curve: MotionCurve.standardDecelerate,
  );

  // ------------------------------------------------------------ текст песни

  /// Прокрутка текста к выбранной строке при поиске.
  static MotionTransition get lyricsScroll => _motion(_lyricsScroll);
  static const MotionTransition _lyricsScroll = MotionTransition(
    duration: Duration(milliseconds: 320),
    curve: MotionCurve.easeOutCubic,
  );

  /// Строка текста становится активной: она «загорается» быстрее, чем гаснет.
  static MotionTransition get lyricsLineFadeIn => _motion(_lyricsLineFadeIn);
  static const MotionTransition _lyricsLineFadeIn = MotionTransition(
    duration: Duration(milliseconds: 330),
    curve: MotionCurve.fastOutSlowIn,
  );

  /// Активная строка гаснет — медленнее, чем загорается.
  static MotionTransition get lyricsLineFadeOut => _motion(_lyricsLineFadeOut);
  static const MotionTransition _lyricsLineFadeOut = MotionTransition(
    duration: Duration(milliseconds: 500),
    curve: MotionCurve.fastOutSlowIn,
  );

  /// Размытие неактивной строки текста по расстоянию до активной.
  static MotionTransition get lyricsLineBlur => _motion(_lyricsLineBlur);
  static const MotionTransition _lyricsLineBlur = MotionTransition(
    duration: Duration(milliseconds: 300),
    curve: MotionCurve.fastOutSlowIn,
  );

  /// Масштаб строки текста: активная крупнее остальных.
  static MotionTransition get lyricsLineScale => _motion(_lyricsLineScale);
  static const MotionTransition _lyricsLineScale = MotionTransition(
    duration: Duration(milliseconds: 166),
    curve: MotionCurve.fastOutSlowIn,
  );

  /// Появление активной строки текста «пружиной» (стиль «Пружинное»).
  ///
  /// Это не `SpringSimulation`: строка появляется один раз и должна
  /// остановиться сама, поэтому отдачу даёт expressive-кривая с перелётом.
  /// Пружина в `TweenAnimationBuilder` не затухала бы без внешнего таймера.
  static MotionTransition get lyricsLineSpring => _motion(_lyricsLineSpring);
  static const MotionTransition _lyricsLineSpring = MotionTransition(
    duration: MotionDuration.medium3,
    curve: MotionCurve.expressiveFastSpatial,
  );

  /// Появление активной строки из меньшего размера (стиль «Масштаб»).
  ///
  /// Без перелёта: это рост, а не отдача, поэтому expressive-кривая здесь
  /// только подчёркивала бы конец движения.
  static MotionTransition get lyricsLineGrow => _motion(_lyricsLineGrow);
  static const MotionTransition _lyricsLineGrow = MotionTransition(
    duration: MotionDuration.medium2,
    curve: MotionCurve.emphasizedDecelerate,
  );

  // ------------------------------------------- прежние имена словаря

  // Часть кода (настройки) зовёт их напрямую, поэтому они остаются: значения
  // теперь те же, что у схемы, а не подобранные на глаз.

  /// Длительность мелкого отклика — 200 мс.
  static Duration get fast => _time(MotionDuration.short4);

  /// Длительность среднего движения — 300 мс.
  static Duration get medium => _time(MotionDuration.medium2);

  /// Длительность крупного движения — 500 мс.
  static Duration get slow => _time(MotionDuration.long2);

  /// Кривая мелкого отклика — обычная кривая схемы.
  static const Curve snappy = MotionCurve.standard;

  /// Кривая появления — акцентированная на торможение.
  static const Curve gentle = MotionCurve.emphasizedDecelerate;

  /// Кривая смены положения — пространственная expressive.
  static const Curve spring = MotionCurve.expressiveSpatial;

  /// Кривая нажатия — быстрая пространственная expressive.
  static const Curve springSnappy = MotionCurve.expressiveFastSpatial;
}
