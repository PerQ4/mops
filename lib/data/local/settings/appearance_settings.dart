import '../../../core/theme/seed_colors.dart';
import 'json_read.dart';

/// Стиль палитры Material 3.
///
/// В ArchiveTune стиль выбирается по насыщенности акцентного цвета, но
/// пользователь может задать его и вручную: тональный — самый «цветной»,
/// нейтральный — приглушённый, монохромный — почти серый с одним акцентом.
enum PaletteStylePreference {
  tonal('Тональная'),
  neutral('Нейтральная'),
  monochrome('Монохромная');

  const PaletteStylePreference(this.label);

  final String label;

  static PaletteStylePreference fromName(String? name) =>
      PaletteStylePreference.values.firstWhere(
        (PaletteStylePreference v) => v.name == name,
        orElse: () => PaletteStylePreference.tonal,
      );
}

/// Чем набирается интерфейс (задача 7.4).
///
/// Варианта три: Poppins — как было; системный — шрифт платформы; свой — файл
/// с диска. У всех трёх остаётся фоллбек Montserrat с полной кириллицей:
/// латинский шрифт не должен превращать русский текст в квадраты.
enum FontPreference {
  poppins('Poppins (по умолчанию)', 'Шрифт интерфейса, как в ArchiveTune'),
  system('Системный', 'Шрифт системы'),
  custom('Свой', 'Файл шрифта с диска');

  const FontPreference(this.label, this.description);

  final String label;
  final String description;

  static FontPreference fromName(String? name) =>
      FontPreference.values.firstWhere(
        (FontPreference v) => v.name == name,
        orElse: () => FontPreference.poppins,
      );
}

/// Стиль полосы перемотки в плеере.
///
/// Перенесён из ArchiveTune (`SliderStyle`, `constants/PreferenceKeys.kt:170`):
/// пять вариантов — обычный, «волнистый», толстый, с кружком и тонкий простой.
///
/// Ни один из них не рисует волну: в ArchiveTune дорожка у всех прямая, а
/// «волнистый» отличается от «толстого» только толщиной (6 dp против 12 dp).
/// «Обычный» и «с кружком» — это штатный Slider Material 3, и наборы цветов
/// у них совпадают, то есть выглядят они одинаково.
enum ProgressBarStyle {
  standard('Обычный', 'Ползунок Material 3 на дорожке'),
  wavy('Волнистый', 'Тонкая дорожка, без ползунка'),
  thick('Толстый', 'Толстая дорожка, без ползунка'),
  circular('С кружком', 'Ползунок Material 3, как у «обычного»'),
  simple('Простой', 'Самая тонкая дорожка, без ползунка');

  const ProgressBarStyle(this.label, this.description);

  final String label;
  final String description;

  static ProgressBarStyle fromName(String? name) =>
      ProgressBarStyle.values.firstWhere(
        (ProgressBarStyle v) => v.name == name,
        orElse: () => ProgressBarStyle.standard,
      );
}

/// Выравнивание блока «название и исполнитель» в полноэкранном плеере.
///
/// По центру — прежний вид: текст держит ту же ось, что обложка, транспорт и
/// действия. По левому краю — длинные названия читаются как строки списка и не
/// «пляшут» при смене трека.
enum PlayerInfoAlignment {
  center('По центру', 'Текст на одной оси с обложкой и управлением — как было'),
  left('По левому краю', 'Длинные названия читаются как строка списка');

  const PlayerInfoAlignment(this.label, this.description);

  final String label;
  final String description;

  static PlayerInfoAlignment fromName(String? name) =>
      PlayerInfoAlignment.values.firstWhere(
        (PlayerInfoAlignment v) => v.name == name,
        orElse: () => PlayerInfoAlignment.center,
      );
}

/// Стиль фона полноэкранного плеера.
///
/// Первый шаг переноса настроек внешнего вида ArchiveTune
/// (`PlayerBackgroundStyle`): там вариантов восемь, здесь пока базовые —
/// градиент из цветов обложки, размытая обложка и «жидкий» шейдер (задача 10.2,
/// идея — из `LiquidBackdrop.qml` у shredos67/swiftify).
enum PlayerBackgroundStyle {
  gradient('Градиент', 'Плавный переход из трёх цветов обложки сверху вниз'),
  blur('Размытая обложка', 'Обложка трека, размытая и затемнённая'),
  glow('Свечение', 'Цветные пятна обложки по краям, центр затемнён'),
  coloring('Окрашивание', 'Весь фон залит одним цветом обложки, без перехода'),
  liquid('Жидкость', 'Медленно текущий шейдер из цветов обложки');

  const PlayerBackgroundStyle(this.label, this.description);

  final String label;
  final String description;

  static PlayerBackgroundStyle fromName(String? name) =>
      PlayerBackgroundStyle.values.firstWhere(
        (PlayerBackgroundStyle v) => v.name == name,
        orElse: () => PlayerBackgroundStyle.gradient,
      );
}

/// Источник цвета для фонового стиля «Жидкость».
///
/// «Из обложки» — как было: три цвета берутся у текущего трека. «Из темы» —
/// цвета палитры приложения: фон перестаёт зависеть от обложки и держится в
/// одном тоне.
enum LiquidColorSource {
  artwork('Из обложки', 'Цвета текущего трека'),
  theme('Из темы', 'Цвета палитры приложения');

  const LiquidColorSource(this.label, this.description);

  final String label;
  final String description;

  static LiquidColorSource fromName(String? name) =>
      LiquidColorSource.values.firstWhere(
        (LiquidColorSource v) => v.name == name,
        orElse: () => LiquidColorSource.artwork,
      );
}

/// Вид визуализатора у обложки (задача 10.8).
///
/// «Гало» — прежний вид: одно кольцо по общему уровню. «Полосы» — настоящий
/// спектр частот из libmpv. Полосы требуют фильтра `lavfi` в сборке; если его
/// нет, визуализатор честно показывает гало, а не выдуманное движение.
enum VisualizerStyle {
  halo('Свечение', 'Мягкий свет позади обложки дышит по громкости'),
  bars('Эквалайзер', 'Полосы под обложкой: низкие частоты в центре');

  const VisualizerStyle(this.label, this.description);

  final String label;
  final String description;

  static VisualizerStyle fromName(String? name) =>
      VisualizerStyle.values.firstWhere(
        (VisualizerStyle v) => v.name == name,
        orElse: () => VisualizerStyle.halo,
      );
}

/// Фон мини-плеера — островка внизу экрана.
///
/// Меняется только заливка внутри островка: кромки, радиусы и стык с
/// навигацией остаются прежними (см. `floating_dock.dart`).
enum MiniPlayerBackgroundStyle {
  theme('Тема', 'Плотная поверхность темы — как было'),
  gradient('Градиент', 'Переход из акцентных цветов темы'),
  glow('Свечение', 'Мягкое цветное пятно, гаснущее к правому краю островка');

  const MiniPlayerBackgroundStyle(this.label, this.description);

  final String label;
  final String description;

  static MiniPlayerBackgroundStyle fromName(String? name) =>
      MiniPlayerBackgroundStyle.values.firstWhere(
        (MiniPlayerBackgroundStyle v) => v.name == name,
        orElse: () => MiniPlayerBackgroundStyle.theme,
      );
}

/// Внешний вид: тема, палитра, шрифт, масштаб, плотность и оформление плеера.
///
/// Домен не знает о раскладке и воспроизведении: `AppSettings` собирает его
/// вместе с остальными и отдаёт наружу прежними плоскими геттерами, поэтому
/// экраны и движки о перегруппировке не знают.
class AppearanceSettings {
  const AppearanceSettings({
    this.themeMode = ThemeModePreference.system,
    this.colorSource = ColorSource.seed,
    this.seedColorIndex = 0,
    this.useMaterialExpressive = true,
    this.pureBlack = false,
    this.paletteStyle = PaletteStylePreference.tonal,
    this.fontPreference = FontPreference.poppins,
    this.customFontPath = '',
    this.disableAnimations = false,
    this.forceHighRefreshRate = false,
    this.uiScale = 0.0,
    // Плотные строки выключены по умолчанию: иначе вид списков изменился бы
    // сам после обновления.
    this.compactRows = false,
    this.progressBarStyle = ProgressBarStyle.standard,
    this.volumeSliderStyle = ProgressBarStyle.standard,
    // Название и исполнитель по центру — прежний вид: левый край включают
    // осознанно, чтобы старые настройки не меняли плеер после обновления.
    this.playerInfoAlignment = PlayerInfoAlignment.center,
    this.miniPlayerBackgroundStyle = MiniPlayerBackgroundStyle.theme,
    this.playerBackgroundStyle = PlayerBackgroundStyle.gradient,
    // «Жидкость»: значения по умолчанию совпадают с прежним видом фона.
    this.liquidSpeed = 1.0,
    this.liquidScale = 1.0,
    this.liquidSaturation = 1.0,
    this.liquidColorSource = LiquidColorSource.artwork,
    this.disableBlur = false,
    this.blurRadius = 48,
    this.visualizerEnabled = false,
    this.visualizerStyle = VisualizerStyle.halo,
    // «Живая обложка» выключена: без неё вид плеера остаётся прежним.
    this.liveCoverEnabled = false,
    this.titleBarCentered = true,
    this.titleBarMatchesBackground = false,
  });

  final ThemeModePreference themeMode;
  final ColorSource colorSource;
  final int seedColorIndex;
  final bool useMaterialExpressive;

  /// Отключить анимации (задача 7.3).
  ///
  /// Когда включено, все длительности из `AppMotion` становятся нулевыми:
  /// переходы и раскрытия происходят мгновенно. Значение переживает
  /// перезапуск, как и остальные настройки.
  final bool disableAnimations;

  /// Просить у платформы максимальную частоту обновления (7.3).
  ///
  /// Флаг хранится для платформ, которые умеют такой запрос (в ArchiveTune —
  /// `force_high_refresh_rate` для Android). На десктопе запроса нет:
  /// приложение и так рисует с частотой экрана, поэтому в настройках пункт
  /// показан неактивным с пояснением, а не выключенным «насовсем».
  final bool forceHighRefreshRate;

  /// Стиль палитры: тональная, нейтральная или монохромная.
  final PaletteStylePreference paletteStyle;

  /// Чем набирается интерфейс (задача 7.4).
  final FontPreference fontPreference;

  /// Путь к файлу своего шрифта. Хранится всегда, даже когда выбран другой
  /// вариант: вернувшись к «Своему», пользователь не ищет файл заново.
  final String customFontPath;

  /// Чистый чёрный фон в тёмной теме — как отдельный переключатель в
  /// ArchiveTune: фон и поверхности становятся #000000.
  final bool pureBlack;

  /// Масштаб интерфейса. `0` — автоматически (по масштабу рабочего стола).
  final double uiScale;

  /// Плотные строки треков и библиотеки (пункт 11.2).
  ///
  /// Выключено по умолчанию: мобильная высота 72 — прежний вид, а компактный
  /// режим включают осознанно, когда на экране нужно больше строк.
  final bool compactRows;

  /// Стиль полосы перемотки в плеере (как пять `SliderStyle` в ArchiveTune).
  final ProgressBarStyle progressBarStyle;

  /// Стиль ползунка громкости — тот же набор, что у полосы перемотки.
  final ProgressBarStyle volumeSliderStyle;

  /// Выравнивание названия и исполнителя в полноэкранном плеере.
  ///
  /// Меняет только оси текста: место блока в раскладке и высота строки
  /// остаются прежними.
  final PlayerInfoAlignment playerInfoAlignment;

  /// Фон мини-плеера: тема, градиент или свечение.
  final MiniPlayerBackgroundStyle miniPlayerBackgroundStyle;

  /// Фон полноэкранного плеера — стиль из ArchiveTune.
  final PlayerBackgroundStyle playerBackgroundStyle;

  /// Скорость течения жидкости — множитель времени шейдера. 1 — как было.
  final double liquidSpeed;

  /// Масштаб пятен: во сколько раз крупнее «волокна» жидкости. 1 — как было.
  final double liquidScale;

  /// Насыщенность цвета: 1 — цвета как есть, 0 — серый. Влияет и на статичную
  /// подложку, которая показывается, пока шейдер недоступен.
  final double liquidSaturation;

  /// Откуда «Жидкость» берёт цвета: из обложки трека или из палитры приложения.
  final LiquidColorSource liquidColorSource;

  /// Отключить размытие (как в ArchiveTune): фон рисуется без блюра.
  final bool disableBlur;

  /// Сила размытия фона (0–64). Как `BlurRadiusKey` в ArchiveTune.
  final double blurRadius;

  /// «Гало» вокруг обложки, дышащее по уровню звука (задача 10.3).
  ///
  /// По умолчанию **выключено**: уровень берётся у libmpv опросом свойства
  /// `af-metadata`, а такой опрос — лишняя работа, которая нужна не всем. Там,
  /// где сборка libmpv фильтра не имеет (Windows), визуализатор честно скажет об
  /// этом и не будет двигаться.
  final bool visualizerEnabled;

  /// Вид визуализатора: гало по уровню или спектр полос (задача 10.8).
  final VisualizerStyle visualizerStyle;

  /// «Живая обложка» в полноэкранном плеере (задача 8.2): обложка очень легко
  /// дышит и светится по краю в такт музыке.
  ///
  /// По умолчанию **выключено**: без настройки вид плеера остаётся прежним,
  /// пиксель в пиксель. Уровень берётся у того же `AudioLevelMonitor`, что и у
  /// визуализатора, поэтому включение поднимает опрос `af-metadata` у libmpv —
  /// лишняя работа, которая нужна не всем.
  final bool liveCoverEnabled;

  /// Заголовок окна по центру (иначе — слева, у логотипа). Только Windows.
  final bool titleBarCentered;

  /// Красить шапку окна в цвет фона приложения (иначе — в самый тёмный тон
  /// палитры, как рамка окна). Только Windows.
  final bool titleBarMatchesBackground;

  bool get isUiScaleAuto => uiScale <= 0;

  int get safeSeedIndex =>
      (seedColorIndex >= 0 && seedColorIndex < kSeedColors.length)
      ? seedColorIndex
      : 0;

  AppearanceSettings copyWith({
    ThemeModePreference? themeMode,
    ColorSource? colorSource,
    int? seedColorIndex,
    bool? useMaterialExpressive,
    bool? pureBlack,
    PaletteStylePreference? paletteStyle,
    FontPreference? fontPreference,
    String? customFontPath,
    bool? disableAnimations,
    bool? forceHighRefreshRate,
    double? uiScale,
    bool? compactRows,
    ProgressBarStyle? progressBarStyle,
    ProgressBarStyle? volumeSliderStyle,
    PlayerInfoAlignment? playerInfoAlignment,
    MiniPlayerBackgroundStyle? miniPlayerBackgroundStyle,
    PlayerBackgroundStyle? playerBackgroundStyle,
    double? liquidSpeed,
    double? liquidScale,
    double? liquidSaturation,
    LiquidColorSource? liquidColorSource,
    bool? disableBlur,
    double? blurRadius,
    bool? visualizerEnabled,
    VisualizerStyle? visualizerStyle,
    bool? liveCoverEnabled,
    bool? titleBarCentered,
    bool? titleBarMatchesBackground,
  }) {
    return AppearanceSettings(
      themeMode: themeMode ?? this.themeMode,
      colorSource: colorSource ?? this.colorSource,
      seedColorIndex: seedColorIndex ?? this.seedColorIndex,
      useMaterialExpressive:
          useMaterialExpressive ?? this.useMaterialExpressive,
      pureBlack: pureBlack ?? this.pureBlack,
      paletteStyle: paletteStyle ?? this.paletteStyle,
      fontPreference: fontPreference ?? this.fontPreference,
      customFontPath: customFontPath ?? this.customFontPath,
      disableAnimations: disableAnimations ?? this.disableAnimations,
      forceHighRefreshRate: forceHighRefreshRate ?? this.forceHighRefreshRate,
      uiScale: uiScale ?? this.uiScale,
      compactRows: compactRows ?? this.compactRows,
      progressBarStyle: progressBarStyle ?? this.progressBarStyle,
      volumeSliderStyle: volumeSliderStyle ?? this.volumeSliderStyle,
      playerInfoAlignment: playerInfoAlignment ?? this.playerInfoAlignment,
      miniPlayerBackgroundStyle:
          miniPlayerBackgroundStyle ?? this.miniPlayerBackgroundStyle,
      playerBackgroundStyle:
          playerBackgroundStyle ?? this.playerBackgroundStyle,
      liquidSpeed: liquidSpeed ?? this.liquidSpeed,
      liquidScale: liquidScale ?? this.liquidScale,
      liquidSaturation: liquidSaturation ?? this.liquidSaturation,
      liquidColorSource: liquidColorSource ?? this.liquidColorSource,
      disableBlur: disableBlur ?? this.disableBlur,
      blurRadius: blurRadius ?? this.blurRadius,
      visualizerEnabled: visualizerEnabled ?? this.visualizerEnabled,
      visualizerStyle: visualizerStyle ?? this.visualizerStyle,
      liveCoverEnabled: liveCoverEnabled ?? this.liveCoverEnabled,
      titleBarCentered: titleBarCentered ?? this.titleBarCentered,
      titleBarMatchesBackground:
          titleBarMatchesBackground ?? this.titleBarMatchesBackground,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'themeMode': themeMode.name,
    'colorSource': colorSource.name,
    'seedColorIndex': seedColorIndex,
    'useMaterialExpressive': useMaterialExpressive,
    'pureBlack': pureBlack,
    'paletteStyle': paletteStyle.name,
    'fontPreference': fontPreference.name,
    'customFontPath': customFontPath,
    'disableAnimations': disableAnimations,
    'forceHighRefreshRate': forceHighRefreshRate,
    'uiScale': uiScale,
    'compactRows': compactRows,
    'progressBarStyle': progressBarStyle.name,
    'volumeSliderStyle': volumeSliderStyle.name,
    'playerInfoAlignment': playerInfoAlignment.name,
    'miniPlayerBackgroundStyle': miniPlayerBackgroundStyle.name,
    'playerBackgroundStyle': playerBackgroundStyle.name,
    'liquidSpeed': liquidSpeed,
    'liquidScale': liquidScale,
    'liquidSaturation': liquidSaturation,
    'liquidColorSource': liquidColorSource.name,
    'disableBlur': disableBlur,
    'blurRadius': blurRadius,
    'visualizerEnabled': visualizerEnabled,
    'visualizerStyle': visualizerStyle.name,
    'liveCoverEnabled': liveCoverEnabled,
    'titleBarCentered': titleBarCentered,
    'titleBarMatchesBackground': titleBarMatchesBackground,
  };

  factory AppearanceSettings.fromJson(Map<String, dynamic> json) {
    return AppearanceSettings(
      themeMode: readEnumByName(
        json['themeMode'],
        ThemeModePreference.values,
        ThemeModePreference.system,
      ),
      colorSource: readEnumByName(
        json['colorSource'],
        ColorSource.values,
        ColorSource.seed,
      ),
      seedColorIndex: readInt(json['seedColorIndex'], 0),
      useMaterialExpressive: readBool(json['useMaterialExpressive'], true),
      pureBlack: readBool(json['pureBlack'], false),
      paletteStyle: readEnumByName(
        json['paletteStyle'],
        PaletteStylePreference.values,
        PaletteStylePreference.tonal,
      ),
      fontPreference: readEnumByName(
        json['fontPreference'],
        FontPreference.values,
        FontPreference.poppins,
      ),
      customFontPath: readString(json['customFontPath'], ''),
      disableAnimations: readBool(json['disableAnimations'], false),
      forceHighRefreshRate: readBool(json['forceHighRefreshRate'], false),
      uiScale: readDouble(json['uiScale'], 0.0),
      compactRows: readBool(json['compactRows'], false),
      progressBarStyle: readEnumByName(
        json['progressBarStyle'],
        ProgressBarStyle.values,
        ProgressBarStyle.standard,
      ),
      volumeSliderStyle: readEnumByName(
        json['volumeSliderStyle'],
        ProgressBarStyle.values,
        ProgressBarStyle.standard,
      ),
      playerInfoAlignment: readEnumByName(
        json['playerInfoAlignment'],
        PlayerInfoAlignment.values,
        PlayerInfoAlignment.center,
      ),
      miniPlayerBackgroundStyle: readEnumByName(
        json['miniPlayerBackgroundStyle'],
        MiniPlayerBackgroundStyle.values,
        MiniPlayerBackgroundStyle.theme,
      ),
      playerBackgroundStyle: readEnumByName(
        json['playerBackgroundStyle'],
        PlayerBackgroundStyle.values,
        PlayerBackgroundStyle.gradient,
      ),
      liquidSpeed: readDouble(json['liquidSpeed'], 1.0),
      liquidScale: readDouble(json['liquidScale'], 1.0),
      liquidSaturation: readDouble(json['liquidSaturation'], 1.0),
      liquidColorSource: readEnumByName(
        json['liquidColorSource'],
        LiquidColorSource.values,
        LiquidColorSource.artwork,
      ),
      disableBlur: readBool(json['disableBlur'], false),
      blurRadius: readDouble(json['blurRadius'], 48),
      visualizerEnabled: readBool(json['visualizerEnabled'], false),
      visualizerStyle: readEnumByName(
        json['visualizerStyle'],
        VisualizerStyle.values,
        VisualizerStyle.halo,
      ),
      liveCoverEnabled: readBool(json['liveCoverEnabled'], false),
      titleBarCentered: readBool(json['titleBarCentered'], true),
      titleBarMatchesBackground: readBool(
        json['titleBarMatchesBackground'],
        false,
      ),
    );
  }
}
