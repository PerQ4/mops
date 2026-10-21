import 'json_read.dart';

/// Режим правой панели плеера.
///
/// Это два разных способа пользоваться одной панелью, поэтому выбор
/// запоминается:
///
/// - «Плеер» — крупная обложка и управление, очередь почти не видна (только
///   следующий трек);
/// - «Очередь» — компактная строка трека, а всё оставшееся место отдано
///   очереди.
enum RightPanelMode {
  player('Плеер', 'Крупная обложка и управление'),
  queue('Очередь', 'Строка трека и полный список');

  const RightPanelMode(this.label, this.description);

  final String label;
  final String description;

  static RightPanelMode fromName(String? name) =>
      RightPanelMode.values.firstWhere(
        (RightPanelMode v) => v.name == name,
        orElse: () => RightPanelMode.queue,
      );
}

/// Чувствительность свайпа по островку плеера.
enum SwipeSensitivity {
  low('Низкая', 0.40),
  normal('Обычная', 0.25),
  high('Высокая', 0.12);

  const SwipeSensitivity(this.label, this.thresholdFraction);

  final String label;

  /// Доля ширины островка, которую нужно протащить, чтобы переключить трек.
  /// Чем меньше доля, тем выше чувствительность: жест срабатывает раньше.
  final double thresholdFraction;

  static SwipeSensitivity fromName(String? name) =>
      SwipeSensitivity.values.firstWhere(
        (SwipeSensitivity v) => v.name == name,
        orElse: () => SwipeSensitivity.normal,
      );
}

/// Что делает горизонтальный свайп по строке трека в списке.
enum TrackSwipeAction {
  off('Выключено'),
  playNext('Играть следующим'),
  enqueue('В очередь');

  const TrackSwipeAction(this.label);

  final String label;

  static TrackSwipeAction fromName(String? name) =>
      TrackSwipeAction.values.firstWhere(
        (TrackSwipeAction v) => v.name == name,
        orElse: () => TrackSwipeAction.off,
      );
}

/// Раскладка: панели, их ширины, сворачивание и жесты по спискам.
///
/// Вынесено отдельно от внешнего вида: это геометрия рабочего места, а не
/// палитра или шрифт.
class LayoutSettings {
  const LayoutSettings({
    this.playerPanelWidth = 280,
    this.playerPanelMode = RightPanelMode.queue,
    this.sidebarWidth = 280,
    this.miniSwipeSensitivity = SwipeSensitivity.normal,
    this.trackSwipeAction = TrackSwipeAction.off,
    this.sidebarCollapsed = false,
    // Панель вместо островка: навигация переезжает в левую панель.
    this.sidebarNavigation = false,
    this.playerPanelEnabled = true,
  });

  /// Ширина правой панели плеера. Меняется перетаскиванием за её край.
  final double playerPanelWidth;

  /// Что показывает правая панель: плеер с крупной обложкой или очередь.
  final RightPanelMode playerPanelMode;

  /// Ширина боковой панели библиотеки. Меняется перетаскиванием за её край.
  final double sidebarWidth;

  /// Насколько охотно свайп по островку плеера переключает трек.
  final SwipeSensitivity miniSwipeSensitivity;

  /// Что делает свайп по строке трека. Значение хранится, но применяется
  /// в строке списка — а она вне этого модуля — см. отчёт.
  final TrackSwipeAction trackSwipeAction;

  /// Свёрнута ли боковая панель библиотеки в узкую полосу с обложками.
  ///
  /// Состояние хранится в настройках, а не в виджете: панель исчезает и
  /// появляется вместе с раскладкой, и сворачивать её заново при каждом
  /// переходе в широкий режим было бы навязчиво.
  final bool sidebarCollapsed;

  /// Берёт ли левая панель на себя навигацию по разделам (Главная, Поиск,
  /// Библиотека, Настройки) — как в боковой панели swiftify.
  ///
  /// Тогда плавающий островок навигации внизу не нужен. На компактном окне
  /// панели нет вообще, поэтому там настройка ни на что не влияет: навигация
  /// остаётся островком.
  final bool sidebarNavigation;

  /// Разворачивать ли островок плеера в отдельную панель справа.
  ///
  /// По умолчанию **включено**: навигация стоит слева, плеер — справа, и
  /// развернуть его в полноценную панель (как библиотеку слева) — очевидный
  /// жест. Выключение оставляет только островок: нажатие на него открывает
  /// полноэкранный плеер, как раньше. Настройка действует лишь в широкой
  /// раскладке — на телефоне правую панель размещать негде.
  final bool playerPanelEnabled;

  LayoutSettings copyWith({
    double? playerPanelWidth,
    RightPanelMode? playerPanelMode,
    double? sidebarWidth,
    SwipeSensitivity? miniSwipeSensitivity,
    TrackSwipeAction? trackSwipeAction,
    bool? sidebarCollapsed,
    bool? sidebarNavigation,
    bool? playerPanelEnabled,
  }) {
    return LayoutSettings(
      playerPanelWidth: playerPanelWidth ?? this.playerPanelWidth,
      playerPanelMode: playerPanelMode ?? this.playerPanelMode,
      sidebarWidth: sidebarWidth ?? this.sidebarWidth,
      miniSwipeSensitivity: miniSwipeSensitivity ?? this.miniSwipeSensitivity,
      trackSwipeAction: trackSwipeAction ?? this.trackSwipeAction,
      sidebarCollapsed: sidebarCollapsed ?? this.sidebarCollapsed,
      sidebarNavigation: sidebarNavigation ?? this.sidebarNavigation,
      playerPanelEnabled: playerPanelEnabled ?? this.playerPanelEnabled,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'playerPanelWidth': playerPanelWidth,
    'playerPanelMode': playerPanelMode.name,
    'sidebarWidth': sidebarWidth,
    'miniSwipeSensitivity': miniSwipeSensitivity.name,
    'trackSwipeAction': trackSwipeAction.name,
    'sidebarCollapsed': sidebarCollapsed,
    'sidebarNavigation': sidebarNavigation,
    'playerPanelEnabled': playerPanelEnabled,
  };

  factory LayoutSettings.fromJson(Map<String, dynamic> json) {
    return LayoutSettings(
      playerPanelWidth: readDouble(json['playerPanelWidth'], 280),
      playerPanelMode: readEnumByName(
        json['playerPanelMode'],
        RightPanelMode.values,
        RightPanelMode.queue,
      ),
      sidebarWidth: readDouble(json['sidebarWidth'], 280),
      miniSwipeSensitivity: readEnumByName(
        json['miniSwipeSensitivity'],
        SwipeSensitivity.values,
        SwipeSensitivity.normal,
      ),
      trackSwipeAction: readEnumByName(
        json['trackSwipeAction'],
        TrackSwipeAction.values,
        TrackSwipeAction.off,
      ),
      sidebarCollapsed: readBool(json['sidebarCollapsed'], false),
      sidebarNavigation: readBool(json['sidebarNavigation'], false),
      playerPanelEnabled: readBool(json['playerPanelEnabled'], true),
    );
  }
}
