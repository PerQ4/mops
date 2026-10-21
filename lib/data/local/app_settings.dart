import 'dart:convert';

import '../../core/audio/audio_equalizer.dart';
import '../../core/net/anti_dpi.dart';
import '../../core/theme/seed_colors.dart';
import '../sources/sponsorblock.dart';

/// Качество аудио. YouTube отдаёт свободным клиентам только part-качество
/// (до ~160 kbps Opus / 128 kbps AAC), поэтому «Максимум» — это лучший
/// доступный поток, а не 256 kbps.
enum AudioQuality {
  /// Минимум трафика: ~48–70 kbps.
  low('Экономия трафика', 70),

  /// Компромисс: ~128 kbps.
  medium('Среднее', 128),

  /// Лучший доступный поток (обычно ~160 kbps Opus).
  high('Максимум', 256);

  const AudioQuality(this.label, this.targetKbps);

  final String label;
  final int targetKbps;

  static AudioQuality fromName(String? name) => AudioQuality.values.firstWhere(
        (AudioQuality q) => q.name == name,
        orElse: () => AudioQuality.high,
      );
}

/// Откуда брать ссылку на поток.
///
/// YouTube выдаёт поток разным клиентам по-разному: одним он требует
/// PO-токен, другим — вход. Профили ниже проверены на живых запросах
/// и не требуют ни того, ни другого.
enum StreamSource {
  /// Сначала visionOS, затем Android VR и iOS.
  auto('Автоматически', 'Сначала visionOS, затем Android VR и iOS'),

  /// Клиент очков Apple Vision Pro — отдаёт поток целиком.
  visionOs('visionOS', 'Отдаёт поток целиком — самый надёжный'),

  /// Клиент очков Oculus.
  androidVr('Android VR', 'Клиент очков — самый устойчивый'),

  /// Клиент iPhone.
  ios('iOS', 'Клиент iPhone — запасной вариант'),

  /// Клиент библиотеки по умолчанию.
  library('Клиент библиотеки', 'YouTube всё чаще требует для него PO-токен');

  const StreamSource(this.label, this.description);

  final String label;
  final String description;

  static StreamSource fromName(String? name) =>
      StreamSource.values.firstWhere(
        (StreamSource c) => c.name == name,
        orElse: () => StreamSource.auto,
      );
}

/// Откуда брать текст песни.
///
/// Как в ArchiveTune, источников несколько: сервисы с синхронизацией (TTML и
/// LRC), вкладка «Текст» YouTube Music и субтитры видео. Выбранный источник
/// авторитетен: если в нём пусто, приложение не подменяет результат текстом
/// YouTube. Режим «Авто» перебирает реальные базы, а тексты YouTube берёт
/// только в самом конце — когда ни одна база не ответила.
enum LyricsSource {
  auto(
    'Авто',
    'Перебор баз по порядку; тексты YouTube — в последнюю очередь',
  ),
  music('Текст YouTube Music', 'Вкладка «Текст» — без времён'),
  subtitles('Субтитры видео', 'Дорожка видео — со временем строк'),
  betterLyrics('BetterLyrics', 'Apple Music (TTML) — пословная синхронизация'),
  youlyPlus('YouLy+', 'Зеркала Lyricify — TTML или LRC'),
  lrclib('LRCLIB', 'Открытая база — текст с временами'),
  kugou('KuGou', 'Внешняя база — текст с временами'),
  unison('Unison', 'Внешняя база — текст с временами'),
  musixmatch('Paxsenix', 'Apple Music и Musixmatch — нужен ключ в настройках');

  const LyricsSource(this.label, this.description);

  final String label;
  final String description;

  static LyricsSource fromName(String? name) =>
      LyricsSource.values.firstWhere(
        (LyricsSource v) => v.name == name,
        orElse: () => LyricsSource.auto,
      );
}

/// Режим отображения текста песни (задача 3.1).
///
/// Классический — прежний вид: строки одного размера, активная выделена
/// насыщенностью. V2 усиливает контраст: активная строка крупнее, соседние
/// мельче и прозрачнее. Enhanced добавляет отдельную панель активной строки —
/// на широком экране список и текущая строка стоят рядом.
enum LyricsMode {
  classic('Классический', 'Строки одного размера, активная выделена насыщенностью'),
  v2('V2', 'Крупная активная строка, соседние мельче и прозрачнее'),
  enhanced(
    'Enhanced',
    'Активная строка на отдельной панели, список рядом — на широком экране',
  );

  const LyricsMode(this.label, this.description);

  final String label;
  final String description;

  static LyricsMode fromName(String? name) => LyricsMode.values.firstWhere(
        (LyricsMode v) => v.name == name,
        orElse: () => LyricsMode.classic,
      );
}

/// Стиль анимации текста песни (задача 3.2).
///
/// Один стиль отвечает и за появление активной строки, и за подсветку слов.
/// Длительности и кривые берутся из словаря движений (`AppMotion`), поэтому
/// «Отключить анимации» делает любой из стилей мгновенным.
enum LyricsAnimationStyle {
  none('Нет', 'Строка и слова появляются сразу, без движения'),
  fade('Плавное', 'Мягкое проявление строки и подсветки — как было'),
  spring('Пружинное', 'Появление с отдачей, слово подскакивает заметнее'),
  scale('Масштаб', 'Строка и слово вырастают из меньшего размера');

  const LyricsAnimationStyle(this.label, this.description);

  final String label;
  final String description;

  static LyricsAnimationStyle fromName(String? name) =>
      LyricsAnimationStyle.values.firstWhere(
        (LyricsAnimationStyle v) => v.name == name,
        orElse: () => LyricsAnimationStyle.fade,
      );
}

/// Какие каталоги Paxsenix спрашивать.
///
/// Как `paxsenixProviders` в ArchiveTune: ключ у Paxsenix один, а каталоги за
/// ним разные — Apple Music, Spotify и Musixmatch. Включаются по отдельности:
/// не всем нужен каждый, а лишний каталог — это лишний запрос и лишние
/// варианты в списке найденного.
class PaxsenixOptions {
  const PaxsenixOptions({
    this.appleMusic = true,
    this.spotify = true,
    this.musixmatch = true,
  });

  /// Apple Music — TTML с временем каждого слова (караоке).
  final bool appleMusic;

  /// Spotify — обычный текст или LRC.
  final bool spotify;

  /// Musixmatch — текст с временами строк.
  final bool musixmatch;

  /// Хоть один каталог включён: если ни одного, спрашивать нечего.
  bool get any => appleMusic || spotify || musixmatch;

  @override
  bool operator ==(Object other) =>
      other is PaxsenixOptions &&
      other.appleMusic == appleMusic &&
      other.spotify == spotify &&
      other.musixmatch == musixmatch;

  @override
  int get hashCode => Object.hash(appleMusic, spotify, musixmatch);
}

/// Порядок источников текста по умолчанию — как `DefaultLyricsProviderOrder`
/// в ArchiveTune. Первый в списке — приоритетный.
/// Порядок подобран по тому, что реально отвечает и что даёт подробнее
/// разметку. Хосты отброшенных источников недоступны из этой сети: они лишь
/// держали поиск открытым до таймаута, ничего не принося, поэтому из проекта
/// они удалены целиком.
const List<LyricsSource> kDefaultLyricsOrder = <LyricsSource>[
  LyricsSource.youlyPlus,
  LyricsSource.betterLyrics,
  LyricsSource.musixmatch,
  LyricsSource.kugou,
  LyricsSource.lrclib,
  LyricsSource.unison,
];

/// Разбирает список имён источников, отбрасывая неизвестные.
///
/// Имена, которых больше нет в [LyricsSource] (например, удалённые источники),
/// молча пропускаются: у пользователя в сохранённых настройках они могут
/// остаться, и это не должно ни ронять разбор, ни терять остальные.
List<LyricsSource> _parseSourceNames(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <LyricsSource>[];
  final List<LyricsSource> parsed = <LyricsSource>[];
  for (final String name in raw.split(',')) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) continue;
    final LyricsSource? source = LyricsSource.values
        .cast<LyricsSource?>()
        .firstWhere((LyricsSource? v) => v?.name == trimmed, orElse: () => null);
    if (source != null && !parsed.contains(source)) parsed.add(source);
  }
  return parsed;
}

/// Разбирает сохранённый порядок источников; при мусоре — порядок по умолчанию.
List<LyricsSource> _parseLyricsOrder(String? raw) {
  final List<LyricsSource> parsed = _parseSourceNames(raw);
  return parsed.isEmpty ? kDefaultLyricsOrder : parsed;
}

/// Разбирает сохранённые полосы эквалайзера.
///
/// Набор неверной длины или с мусором откатывается к плоскому: применить
/// «половину» настроек хуже, чем вернуть эквалайзер к нулю.
List<double> _parseEqualizerBands(String? raw) {
  if (raw == null || raw.trim().isEmpty) return kEqualizerFlatBands;
  final List<String> parts = raw.split(',');
  if (parts.length != kEqualizerBandCount) return kEqualizerFlatBands;
  final List<double> bands = <double>[];
  for (final String part in parts) {
    final double? value = double.tryParse(part.trim());
    if (value == null) return kEqualizerFlatBands;
    bands.add(value.clamp(-kEqualizerMaxGainDb, kEqualizerMaxGainDb));
  }
  return bands;
}

/// Разбирает сохранённый набор категорий SponsorBlock.
///
/// `null` — ключа в файле нет (настройки с прошлой версии): берём набор по
/// умолчанию. Пустая строка — пользователь снял все галочки: это осознанный
/// выбор «ничего не пропускать», и подменять его умолчанием нельзя.
List<SponsorBlockCategory> _parseSponsorCategories(String? raw) {
  if (raw == null) return kDefaultSponsorBlockCategories;
  final List<SponsorBlockCategory> parsed = <SponsorBlockCategory>[];
  for (final String name in raw.split(',')) {
    final SponsorBlockCategory? category =
        SponsorBlockCategory.fromApiName(name.trim());
    if (category != null && !parsed.contains(category)) parsed.add(category);
  }
  return parsed;
}

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

/// Фон мини-плеера — островка внизу экрана.
///
/// Меняется только заливка внутри островка: кромки, радиусы и стык с
/// навигацией остаются прежними (см. `floating_dock.dart`).
enum MiniPlayerBackgroundStyle {
  theme('Тема', 'Плотная поверхность темы — как было'),
  gradient('Градиент', 'Переход из акцентных цветов темы'),
  glow(
    'Свечение',
    'Мягкое цветное пятно, гаснущее к правому краю островка',
  );

  const MiniPlayerBackgroundStyle(this.label, this.description);

  final String label;
  final String description;

  static MiniPlayerBackgroundStyle fromName(String? name) =>
      MiniPlayerBackgroundStyle.values.firstWhere(
        (MiniPlayerBackgroundStyle v) => v.name == name,
        orElse: () => MiniPlayerBackgroundStyle.theme,
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

/// Где искать треки.
///
/// В ArchiveTune поиск можно ограничить своей библиотекой — так быстрее
/// находить уже знакомое и не уходить в бесконечную выдачу YouTube.
enum SearchSource {
  online('Онлайн', 'Искать по всему YouTube Music'),
  libraryOnly('Только библиотека', 'Искать среди лайкнутых и сохранённых');

  const SearchSource(this.label, this.description);

  final String label;
  final String description;

  static SearchSource fromName(String? name) => SearchSource.values.firstWhere(
        (SearchSource v) => v.name == name,
        orElse: () => SearchSource.online,
      );
}

/// Длина топов и чартов.
///
/// Как `TopSize` в ArchiveTune (`ContentSettings.kt`), только не строкой, а
/// набором: серверу длину не передать, поэтому каталог обрезает уже разобранные
/// полки. Значение по умолчанию — 50, как в оригинале.
enum TopSize {
  ten('10', 10),
  twenty('20', 20),
  fifty('50', 50),
  hundred('100', 100);

  const TopSize(this.label, this.value);

  final String label;

  /// Сколько элементов оставлять в полке топа.
  final int value;

  static TopSize fromName(String? name) => TopSize.values.firstWhere(
        (TopSize v) => v.name == name,
        orElse: () => TopSize.fifty,
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

/// Все настройки приложения. Сериализуется в JSON и хранится в
/// shared_preferences одной строкой — так меньше кода и атомарная запись.
class AppSettings {
  const AppSettings({
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
    this.playerPanelWidth = 280,
    this.playerPanelMode = RightPanelMode.queue,
    this.sidebarWidth = 280,
    this.lyricsSource = LyricsSource.auto,
    this.audioQuality = AudioQuality.high,
    this.lowDataMode = false,
    this.streamClient = StreamSource.auto,
    this.showLyricsInPlayer = true,
    this.lyricsTextScale = 1.0,
    this.lyricsLineSpacing = 1.35,
    this.lyricsLineBlur = true,
    this.lyricsMode = LyricsMode.classic,
    this.lyricsAnimationStyle = LyricsAnimationStyle.fade,
    this.lyricsProviderOrder = kDefaultLyricsOrder,
    // Источники, выключенные пользователем (как `providerPreferenceKeys`
    // в ArchiveTune). Храним именно выключенные: новый источник по умолчанию
    // включён, а не пропадает из поиска.
    this.lyricsDisabledProviders = const <LyricsSource>[],
    // Под-провайдеры Paxsenix (как `paxsenixProviders` в ArchiveTune).
    this.paxsenixAppleMusic = true,
    this.paxsenixSpotify = true,
    this.paxsenixMusixmatch = true,
    // Романизация: пять отдельных переключателей как `LyricsRomanize*Key`
    // в ArchiveTune. Язык по тексту определяется сам, выбирать его не нужно.
    this.romanizeJapanese = true,
    this.romanizeKorean = true,
    this.romanizeChinese = true,
    this.romanizeHindi = true,
    this.romanizeOther = true,
    this.autoPlayNext = true,
    this.restoreQueue = true,
    this.searchSource = SearchSource.online,
    // Что прятать в выдаче каталога и поиска, как `HideExplicitKey` и
    // `HideVideoKey` в ArchiveTune. По умолчанию ничего не прячем.
    this.hideExplicit = false,
    this.hideVideo = false,
    // Длина топов и чартов (как `TopSize`).
    this.topSize = TopSize.fifty,
    this.miniSwipeSensitivity = SwipeSensitivity.normal,
    this.trackSwipeAction = TrackSwipeAction.off,
    this.streamingRegion = 'RU',
    this.streamingLanguage = 'ru',
    this.oauthClientId = '',
    this.oauthClientSecret = '',
    this.musixmatchApiKey = '',
    this.discordRichPresence = false,
    this.discordApplicationId = '',
    this.lastVolume = 1.0,
    this.lastSpeed = 1.0,
    this.uiScale = 0.0,
    this.bypass = const AntiDpiConfig(),
    this.autoDetectProxy = true,
    this.sidebarCollapsed = false,
    // Панель вместо островка: навигация переезжает в левую панель.
    this.sidebarNavigation = false,
    this.playerPanelEnabled = true,
    this.progressBarStyle = ProgressBarStyle.standard,
    this.playerBackgroundStyle = PlayerBackgroundStyle.gradient,
    // «Жидкость»: значения по умолчанию совпадают с прежним видом фона.
    this.liquidSpeed = 1.0,
    this.liquidScale = 1.0,
    this.liquidSaturation = 1.0,
    this.liquidColorSource = LiquidColorSource.artwork,
    this.disableBlur = false,
    this.blurRadius = 48,
    this.visualizerEnabled = false,
    // Эквалайзер выключен и «плоский»: частоты не тронуты, а цепочка фильтров
    // не строится. Пресет хранится отдельно от полос, чтобы интерфейс мог
    // показать, какой набор выбран, даже когда пользователь подправил полосы.
    this.equalizerEnabled = false,
    this.equalizerBands = kEqualizerFlatBands,
    this.equalizerPresetId = 'flat',
    // Оба «улучшателя» по умолчанию выключены: это вмешательство в звук, а не
    // настройка по умолчанию.
    this.skipSilence = false,
    this.audioNormalization = false,
    this.pauseOnDeviceMute = true,
    this.volumeSliderStyle = ProgressBarStyle.standard,
    this.miniPlayerBackgroundStyle = MiniPlayerBackgroundStyle.theme,
    this.titleBarCentered = true,
    this.titleBarMatchesBackground = false,
    // SponsorBlock выключен по умолчанию: это вмешательство в воспроизведение
    // (перемотка через куски видео), и включать его нужно осознанно.
    this.sponsorBlockEnabled = false,
    this.sponsorBlockCategories = kDefaultSponsorBlockCategories,
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

  /// Откуда брать текст песни.
  final LyricsSource lyricsSource;

  /// Ширина боковой панели библиотеки. Меняется перетаскиванием за её край.
  final double sidebarWidth;

  /// Ширина правой панели плеера. Меняется перетаскиванием за её край.
  final double playerPanelWidth;

  /// Что показывает правая панель: плеер с крупной обложкой или очередь.
  final RightPanelMode playerPanelMode;

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
  final AudioQuality audioQuality;

  /// Режим низкого расхода трафика.
  ///
  /// Как `LowDataModeKey` в ArchiveTune, только без слежения за типом сети:
  /// решение всегда за пользователем (на десктопе лимитный интернет бывает и
  /// по Wi-Fi). Включённый режим понижает запрашиваемый размер обложек и
  /// крупные превью видео (`i.ytimg.com`) не запрашивает вовсе — см.
  /// `core/utils/artwork_urls.dart`.
  final bool lowDataMode;

  /// Клиент YouTube, у которого запрашивается ссылка на поток.
  final StreamSource streamClient;

  final bool showLyricsInPlayer;

  /// Множитель размера текста песни (0.8–1.4). Позволяет крупнее показывать
  /// слова, не меняя системный масштаб всего интерфейса.
  final double lyricsTextScale;

  /// Межстрочный интервал текста песни (как `LyricsLineSpacingKey`).
  final double lyricsLineSpacing;

  /// Размывать неактивные строки текста (как `LyricsLineBlurKey`).
  final bool lyricsLineBlur;

  /// Режим отображения текста: классический, V2 или Enhanced (задача 3.1).
  final LyricsMode lyricsMode;

  /// Стиль появления строки и подсветки слов (задача 3.2).
  final LyricsAnimationStyle lyricsAnimationStyle;

  /// Порядок источников текста в режиме «Авто» — как `LyricsProviderOrderKey`
  /// в ArchiveTune. Первый источник в списке — приоритетный.
  final List<LyricsSource> lyricsProviderOrder;

  /// Источники текста, выключенные пользователем. Выключенный источник не
  /// спрашивается вовсе — ни в «Авто», ни в списке найденного.
  final List<LyricsSource> lyricsDisabledProviders;

  /// Каталоги Paxsenix: Apple Music.
  final bool paxsenixAppleMusic;

  /// Каталоги Paxsenix: Spotify.
  final bool paxsenixSpotify;

  /// Каталоги Paxsenix: Musixmatch.
  final bool paxsenixMusixmatch;

  /// Романизация японского текста (кана, `々`, `〆`).
  final bool romanizeJapanese;

  /// Романизация корейского текста (слоги хангыля).
  final bool romanizeKorean;

  /// Романизация китайского текста (иероглифы без каны и хангыля).
  final bool romanizeChinese;

  /// Романизация текста на хинди (деванагари).
  final bool romanizeHindi;

  /// Романизация остальных нелатинских письменностей (тайский, арабский,
  /// кириллица, греческий и другие).
  final bool romanizeOther;

  final bool autoPlayNext;

  /// Восстанавливать очередь и позицию прошлой сессии при запуске.
  ///
  /// По умолчанию включено: вернуться к тому, что играло, — ожидаемое
  /// поведение. Восстановление идёт без автозапуска: очередь на месте, но звук
  /// пойдёт только после нажатия «играть».
  final bool restoreQueue;

  /// Где искать: по всему YouTube Music или только по своей библиотеке.
  final SearchSource searchSource;

  /// Прятать explicit-треки (мат) в выдаче каталога и поиска.
  final bool hideExplicit;

  /// Прятать клипы (видео) в выдаче каталога и поиска.
  final bool hideVideo;

  /// Сколько элементов оставлять в топах и чартах.
  final TopSize topSize;

  /// Насколько охотно свайп по островку плеера переключает трек.
  final SwipeSensitivity miniSwipeSensitivity;

  /// Что делает свайп по строке трека. Значение хранится, но применяется
  /// в строке списка — а она вне этого модуля — см. отчёт.
  final TrackSwipeAction trackSwipeAction;
  final String streamingRegion;
  final String streamingLanguage;
  final String oauthClientId;
  final String oauthClientSecret;

  /// Ключ Paxsenix — через него подключается Musixmatch (как в ArchiveTune).
  final String musixmatchApiKey;

  /// Отправлять текущий трек в Discord (Rich Presence).
  final bool discordRichPresence;

  /// Application ID приложения Discord. Без него presence не отправляется.
  final String discordApplicationId;
  final double lastVolume;
  final double lastSpeed;

  /// Масштаб интерфейса. `0` — автоматически (по масштабу рабочего стола).
  final double uiScale;

  /// Обход блокировок провайдера (подмена хоста, прокси).
  final AntiDpiConfig bypass;

  /// Искать ли локальный прокси автоматически, чтобы заработал звук.
  ///
  /// Провайдер блокирует медиахосты отдельно, и подмена хоста их не обходит.
  /// Локальный прокси (v2rayA, v2rayN, Clash…) решает задачу целиком,
  /// поэтому приложение пробует найти его само.
  final bool autoDetectProxy;

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

  /// Стиль полосы перемотки в плеере (как пять `SliderStyle` в ArchiveTune).
  final ProgressBarStyle progressBarStyle;

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

  /// Включён ли эквалайзер. Отдельный флаг: «плоский, но включённый» — это
  /// рабочее состояние (пользователь двигает полосы от нуля), и выключать
  /// эквалайзер только потому, что все полосы пока в нуле, нельзя.
  final bool equalizerEnabled;

  /// Усиления полос эквалайзера в дБ (ровно [kEqualizerBandCount] значений).
  final List<double> equalizerBands;

  /// Имя выбранного пресета — только для интерфейса.
  final String equalizerPresetId;

  /// Убирать паузы из потока при воспроизведении.
  final bool skipSilence;

  /// Выравнивать громкость между тихими и громкими местами.
  final bool audioNormalization;

  /// Ставить воспроизведение на паузу, когда пропадает устройство вывода,
  /// в которое шёл звук (выдернули наушники, отвалился Bluetooth).
  ///
  /// По умолчанию включено: играть «в тишину» — худший из вариантов.
  final bool pauseOnDeviceMute;

  /// Стиль ползунка громкости — тот же набор, что у полосы перемотки.
  final ProgressBarStyle volumeSliderStyle;

  /// Фон мини-плеера: тема, градиент или свечение.
  final MiniPlayerBackgroundStyle miniPlayerBackgroundStyle;

  /// Заголовок окна по центру (иначе — слева, у логотипа). Только Windows.
  final bool titleBarCentered;

  /// Красить шапку окна в цвет фона приложения (иначе — в самый тёмный тон
  /// палитры, как рамка окна). Только Windows.
  final bool titleBarMatchesBackground;

  /// Пропускать вставки, размеченные на SponsorBlock.
  ///
  /// Это перемотка через чужие метки: она короче трека, но и «неожиданная»,
  /// поэтому по умолчанию выключена.
  final bool sponsorBlockEnabled;

  /// Какие категории вставок пропускать. Пустой список — ничего.
  final List<SponsorBlockCategory> sponsorBlockCategories;

  bool get isUiScaleAuto => uiScale <= 0;

  /// Включён ли источник текста.
  ///
  /// «Авто» — не источник, а режим перебора: выключать его нечем, поэтому в
  /// списке источников он не участвует и всегда считается включённым.
  bool isLyricsSourceEnabled(LyricsSource source) =>
      source != LyricsSource.auto && !lyricsDisabledProviders.contains(source);

  /// Источники, которые можно включать и выключать, — всё, кроме «Авто».
  static List<LyricsSource> get toggleableLyricsSources => LyricsSource.values
      .where((LyricsSource s) => s != LyricsSource.auto)
      .toList(growable: false);

  /// Каталоги Paxsenix одним значением — так источник получает их одним
  /// параметром, а не тремя.
  PaxsenixOptions get paxsenixOptions => PaxsenixOptions(
        appleMusic: paxsenixAppleMusic,
        spotify: paxsenixSpotify,
        musixmatch: paxsenixMusixmatch,
      );

  int get safeSeedIndex =>
      (seedColorIndex >= 0 && seedColorIndex < kSeedColors.length) ? seedColorIndex : 0;

  AppSettings copyWith({
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
    double? playerPanelWidth,
    RightPanelMode? playerPanelMode,
    double? sidebarWidth,
    LyricsSource? lyricsSource,
    AudioQuality? audioQuality,
    bool? lowDataMode,
    StreamSource? streamClient,
    bool? showLyricsInPlayer,
    double? lyricsTextScale,
    double? lyricsLineSpacing,
    bool? lyricsLineBlur,
    LyricsMode? lyricsMode,
    LyricsAnimationStyle? lyricsAnimationStyle,
    List<LyricsSource>? lyricsProviderOrder,
    List<LyricsSource>? lyricsDisabledProviders,
    bool? paxsenixAppleMusic,
    bool? paxsenixSpotify,
    bool? paxsenixMusixmatch,
    bool? romanizeJapanese,
    bool? romanizeKorean,
    bool? romanizeChinese,
    bool? romanizeHindi,
    bool? romanizeOther,
    bool? autoPlayNext,
    bool? restoreQueue,
    SearchSource? searchSource,
    bool? hideExplicit,
    bool? hideVideo,
    TopSize? topSize,
    SwipeSensitivity? miniSwipeSensitivity,
    TrackSwipeAction? trackSwipeAction,
    String? streamingRegion,
    String? streamingLanguage,
    String? oauthClientId,
    String? oauthClientSecret,
    String? musixmatchApiKey,
    bool? discordRichPresence,
    String? discordApplicationId,
    double? lastVolume,
    double? lastSpeed,
    double? uiScale,
    AntiDpiConfig? bypass,
    bool? autoDetectProxy,
    bool? sidebarCollapsed,
    bool? sidebarNavigation,
    bool? playerPanelEnabled,
    ProgressBarStyle? progressBarStyle,
    PlayerBackgroundStyle? playerBackgroundStyle,
    double? liquidSpeed,
    double? liquidScale,
    double? liquidSaturation,
    LiquidColorSource? liquidColorSource,
    bool? disableBlur,
    double? blurRadius,
    bool? visualizerEnabled,
    bool? equalizerEnabled,
    List<double>? equalizerBands,
    String? equalizerPresetId,
    bool? skipSilence,
    bool? audioNormalization,
    bool? pauseOnDeviceMute,
    ProgressBarStyle? volumeSliderStyle,
    MiniPlayerBackgroundStyle? miniPlayerBackgroundStyle,
    bool? titleBarCentered,
    bool? titleBarMatchesBackground,
    bool? sponsorBlockEnabled,
    List<SponsorBlockCategory>? sponsorBlockCategories,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      colorSource: colorSource ?? this.colorSource,
      seedColorIndex: seedColorIndex ?? this.seedColorIndex,
      useMaterialExpressive: useMaterialExpressive ?? this.useMaterialExpressive,
      pureBlack: pureBlack ?? this.pureBlack,
      paletteStyle: paletteStyle ?? this.paletteStyle,
      fontPreference: fontPreference ?? this.fontPreference,
      customFontPath: customFontPath ?? this.customFontPath,
      disableAnimations: disableAnimations ?? this.disableAnimations,
      forceHighRefreshRate: forceHighRefreshRate ?? this.forceHighRefreshRate,
      playerPanelWidth: playerPanelWidth ?? this.playerPanelWidth,
      playerPanelMode: playerPanelMode ?? this.playerPanelMode,
      sidebarWidth: sidebarWidth ?? this.sidebarWidth,
      lyricsSource: lyricsSource ?? this.lyricsSource,
      audioQuality: audioQuality ?? this.audioQuality,
      lowDataMode: lowDataMode ?? this.lowDataMode,
      streamClient: streamClient ?? this.streamClient,
      showLyricsInPlayer: showLyricsInPlayer ?? this.showLyricsInPlayer,
      lyricsTextScale: lyricsTextScale ?? this.lyricsTextScale,
      lyricsLineSpacing: lyricsLineSpacing ?? this.lyricsLineSpacing,
      lyricsLineBlur: lyricsLineBlur ?? this.lyricsLineBlur,
      lyricsMode: lyricsMode ?? this.lyricsMode,
      lyricsAnimationStyle:
          lyricsAnimationStyle ?? this.lyricsAnimationStyle,
      lyricsProviderOrder: lyricsProviderOrder ?? this.lyricsProviderOrder,
      lyricsDisabledProviders:
          lyricsDisabledProviders ?? this.lyricsDisabledProviders,
      paxsenixAppleMusic: paxsenixAppleMusic ?? this.paxsenixAppleMusic,
      paxsenixSpotify: paxsenixSpotify ?? this.paxsenixSpotify,
      paxsenixMusixmatch: paxsenixMusixmatch ?? this.paxsenixMusixmatch,
      romanizeJapanese: romanizeJapanese ?? this.romanizeJapanese,
      romanizeKorean: romanizeKorean ?? this.romanizeKorean,
      romanizeChinese: romanizeChinese ?? this.romanizeChinese,
      romanizeHindi: romanizeHindi ?? this.romanizeHindi,
      romanizeOther: romanizeOther ?? this.romanizeOther,
      autoPlayNext: autoPlayNext ?? this.autoPlayNext,
      restoreQueue: restoreQueue ?? this.restoreQueue,
      searchSource: searchSource ?? this.searchSource,
      hideExplicit: hideExplicit ?? this.hideExplicit,
      hideVideo: hideVideo ?? this.hideVideo,
      topSize: topSize ?? this.topSize,
      miniSwipeSensitivity: miniSwipeSensitivity ?? this.miniSwipeSensitivity,
      trackSwipeAction: trackSwipeAction ?? this.trackSwipeAction,
      streamingRegion: streamingRegion ?? this.streamingRegion,
      streamingLanguage: streamingLanguage ?? this.streamingLanguage,
      oauthClientId: oauthClientId ?? this.oauthClientId,
      oauthClientSecret: oauthClientSecret ?? this.oauthClientSecret,
      musixmatchApiKey: musixmatchApiKey ?? this.musixmatchApiKey,
      discordRichPresence: discordRichPresence ?? this.discordRichPresence,
      discordApplicationId: discordApplicationId ?? this.discordApplicationId,
      lastVolume: lastVolume ?? this.lastVolume,
      lastSpeed: lastSpeed ?? this.lastSpeed,
      uiScale: uiScale ?? this.uiScale,
      bypass: bypass ?? this.bypass,
      autoDetectProxy: autoDetectProxy ?? this.autoDetectProxy,
      sidebarCollapsed: sidebarCollapsed ?? this.sidebarCollapsed,
      sidebarNavigation: sidebarNavigation ?? this.sidebarNavigation,
      playerPanelEnabled: playerPanelEnabled ?? this.playerPanelEnabled,
      progressBarStyle: progressBarStyle ?? this.progressBarStyle,
      playerBackgroundStyle:
          playerBackgroundStyle ?? this.playerBackgroundStyle,
      liquidSpeed: liquidSpeed ?? this.liquidSpeed,
      liquidScale: liquidScale ?? this.liquidScale,
      liquidSaturation: liquidSaturation ?? this.liquidSaturation,
      liquidColorSource: liquidColorSource ?? this.liquidColorSource,
      disableBlur: disableBlur ?? this.disableBlur,
      blurRadius: blurRadius ?? this.blurRadius,
      visualizerEnabled: visualizerEnabled ?? this.visualizerEnabled,
      equalizerEnabled: equalizerEnabled ?? this.equalizerEnabled,
      equalizerBands: equalizerBands ?? this.equalizerBands,
      equalizerPresetId: equalizerPresetId ?? this.equalizerPresetId,
      skipSilence: skipSilence ?? this.skipSilence,
      audioNormalization: audioNormalization ?? this.audioNormalization,
      pauseOnDeviceMute: pauseOnDeviceMute ?? this.pauseOnDeviceMute,
      volumeSliderStyle: volumeSliderStyle ?? this.volumeSliderStyle,
      miniPlayerBackgroundStyle:
          miniPlayerBackgroundStyle ?? this.miniPlayerBackgroundStyle,
      titleBarCentered: titleBarCentered ?? this.titleBarCentered,
      titleBarMatchesBackground:
          titleBarMatchesBackground ?? this.titleBarMatchesBackground,
      sponsorBlockEnabled: sponsorBlockEnabled ?? this.sponsorBlockEnabled,
      sponsorBlockCategories:
          sponsorBlockCategories ?? this.sponsorBlockCategories,
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
        'playerPanelWidth': playerPanelWidth,
        'playerPanelMode': playerPanelMode.name,
        'sidebarWidth': sidebarWidth,
        'lyricsSource': lyricsSource.name,
        'audioQuality': audioQuality.name,
        'lowDataMode': lowDataMode,
        'streamClient': streamClient.name,
        'showLyricsInPlayer': showLyricsInPlayer,
        'lyricsTextScale': lyricsTextScale,
        'lyricsLineSpacing': lyricsLineSpacing,
        'lyricsLineBlur': lyricsLineBlur,
        'lyricsMode': lyricsMode.name,
        'lyricsAnimationStyle': lyricsAnimationStyle.name,
        'lyricsProviderOrder':
            lyricsProviderOrder.map((LyricsSource s) => s.name).join(','),
        'lyricsDisabledProviders':
            lyricsDisabledProviders.map((LyricsSource s) => s.name).join(','),
        'paxsenixAppleMusic': paxsenixAppleMusic,
        'paxsenixSpotify': paxsenixSpotify,
        'paxsenixMusixmatch': paxsenixMusixmatch,
        'romanizeJapanese': romanizeJapanese,
        'romanizeKorean': romanizeKorean,
        'romanizeChinese': romanizeChinese,
        'romanizeHindi': romanizeHindi,
        'romanizeOther': romanizeOther,
        'autoPlayNext': autoPlayNext,
        'restoreQueue': restoreQueue,
        'searchSource': searchSource.name,
        'hideExplicit': hideExplicit,
        'hideVideo': hideVideo,
        'topSize': topSize.name,
        'miniSwipeSensitivity': miniSwipeSensitivity.name,
        'trackSwipeAction': trackSwipeAction.name,
        'streamingRegion': streamingRegion,
        'streamingLanguage': streamingLanguage,
        'oauthClientId': oauthClientId,
        'oauthClientSecret': oauthClientSecret,
        'musixmatchApiKey': musixmatchApiKey,
        'discordRichPresence': discordRichPresence,
        'discordApplicationId': discordApplicationId,
        'lastVolume': lastVolume,
        'lastSpeed': lastSpeed,
        'uiScale': uiScale,
        'bypass': bypass.toJson(),
        'autoDetectProxy': autoDetectProxy,
        'sidebarCollapsed': sidebarCollapsed,
        'sidebarNavigation': sidebarNavigation,
        'playerPanelEnabled': playerPanelEnabled,
        'progressBarStyle': progressBarStyle.name,
        'playerBackgroundStyle': playerBackgroundStyle.name,
        'liquidSpeed': liquidSpeed,
        'liquidScale': liquidScale,
        'liquidSaturation': liquidSaturation,
        'liquidColorSource': liquidColorSource.name,
        'disableBlur': disableBlur,
        'blurRadius': blurRadius,
        'visualizerEnabled': visualizerEnabled,
        'equalizerEnabled': equalizerEnabled,
        'equalizerBands': equalizerBands.join(','),
        'equalizerPresetId': equalizerPresetId,
        'skipSilence': skipSilence,
        'audioNormalization': audioNormalization,
        'pauseOnDeviceMute': pauseOnDeviceMute,
        'volumeSliderStyle': volumeSliderStyle.name,
        'miniPlayerBackgroundStyle': miniPlayerBackgroundStyle.name,
        'titleBarCentered': titleBarCentered,
        'titleBarMatchesBackground': titleBarMatchesBackground,
        'sponsorBlockEnabled': sponsorBlockEnabled,
        'sponsorBlockCategories': sponsorBlockCategories
            .map((SponsorBlockCategory c) => c.apiName)
            .join(','),
      };

  String encode() => jsonEncode(toJson());

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      themeMode: ThemeModePreference.fromName(json['themeMode'] as String?),
      colorSource: ColorSource.fromName(json['colorSource'] as String?),
      seedColorIndex: (json['seedColorIndex'] as num?)?.toInt() ?? 0,
      useMaterialExpressive: json['useMaterialExpressive'] as bool? ?? true,
      pureBlack: json['pureBlack'] as bool? ?? false,
      paletteStyle:
          PaletteStylePreference.fromName(json['paletteStyle'] as String?),
      fontPreference: FontPreference.fromName(
        json['fontPreference'] as String?,
      ),
      customFontPath: json['customFontPath'] as String? ?? '',
      disableAnimations: json['disableAnimations'] as bool? ?? false,
      forceHighRefreshRate: json['forceHighRefreshRate'] as bool? ?? false,
      playerPanelWidth: (json['playerPanelWidth'] as num?)?.toDouble() ?? 280,
      playerPanelMode:
          RightPanelMode.fromName(json['playerPanelMode'] as String?),
      sidebarWidth: (json['sidebarWidth'] as num?)?.toDouble() ?? 280,
      lyricsSource: LyricsSource.fromName(json['lyricsSource'] as String?),
      audioQuality: AudioQuality.fromName(json['audioQuality'] as String?),
      lowDataMode: json['lowDataMode'] as bool? ?? false,
      streamClient: StreamSource.fromName(json['streamClient'] as String?),
      showLyricsInPlayer: json['showLyricsInPlayer'] as bool? ?? true,
      lyricsTextScale: (json['lyricsTextScale'] as num?)?.toDouble() ?? 1.0,
      lyricsLineSpacing: (json['lyricsLineSpacing'] as num?)?.toDouble() ?? 1.35,
      lyricsLineBlur: json['lyricsLineBlur'] as bool? ?? true,
      lyricsMode: LyricsMode.fromName(json['lyricsMode'] as String?),
      lyricsAnimationStyle: LyricsAnimationStyle.fromName(
        json['lyricsAnimationStyle'] as String?,
      ),
      lyricsProviderOrder: _parseLyricsOrder(
        json['lyricsProviderOrder'] as String?,
      ),
      lyricsDisabledProviders: _parseSourceNames(
        json['lyricsDisabledProviders'] as String?,
      ),
      paxsenixAppleMusic: json['paxsenixAppleMusic'] as bool? ?? true,
      paxsenixSpotify: json['paxsenixSpotify'] as bool? ?? true,
      paxsenixMusixmatch: json['paxsenixMusixmatch'] as bool? ?? true,
      romanizeJapanese: json['romanizeJapanese'] as bool? ?? true,
      romanizeKorean: json['romanizeKorean'] as bool? ?? true,
      romanizeChinese: json['romanizeChinese'] as bool? ?? true,
      romanizeHindi: json['romanizeHindi'] as bool? ?? true,
      romanizeOther: json['romanizeOther'] as bool? ?? true,
      autoPlayNext: json['autoPlayNext'] as bool? ?? true,
      restoreQueue: json['restoreQueue'] as bool? ?? true,
      searchSource: SearchSource.fromName(json['searchSource'] as String?),
      hideExplicit: json['hideExplicit'] as bool? ?? false,
      hideVideo: json['hideVideo'] as bool? ?? false,
      topSize: TopSize.fromName(json['topSize'] as String?),
      miniSwipeSensitivity:
          SwipeSensitivity.fromName(json['miniSwipeSensitivity'] as String?),
      trackSwipeAction:
          TrackSwipeAction.fromName(json['trackSwipeAction'] as String?),
      streamingRegion: json['streamingRegion'] as String? ?? 'RU',
      streamingLanguage: json['streamingLanguage'] as String? ?? 'ru',
      oauthClientId: json['oauthClientId'] as String? ?? '',
      oauthClientSecret: json['oauthClientSecret'] as String? ?? '',
      musixmatchApiKey: json['musixmatchApiKey'] as String? ?? '',
      discordRichPresence: json['discordRichPresence'] as bool? ?? false,
      discordApplicationId: json['discordApplicationId'] as String? ?? '',
      lastVolume: (json['lastVolume'] as num?)?.toDouble() ?? 1.0,
      lastSpeed: (json['lastSpeed'] as num?)?.toDouble() ?? 1.0,
      uiScale: (json['uiScale'] as num?)?.toDouble() ?? 0.0,
      bypass: json['bypass'] is Map<String, dynamic>
          ? AntiDpiConfig.fromJson(json['bypass'] as Map<String, dynamic>)
          : const AntiDpiConfig(),
      autoDetectProxy: json['autoDetectProxy'] as bool? ?? true,
      sidebarCollapsed: json['sidebarCollapsed'] as bool? ?? false,
      sidebarNavigation: json['sidebarNavigation'] as bool? ?? false,
      playerPanelEnabled: json['playerPanelEnabled'] as bool? ?? true,
      progressBarStyle: ProgressBarStyle.fromName(json['progressBarStyle'] as String?),
      playerBackgroundStyle: PlayerBackgroundStyle.fromName(
        json['playerBackgroundStyle'] as String?,
      ),
      liquidSpeed: (json['liquidSpeed'] as num?)?.toDouble() ?? 1.0,
      liquidScale: (json['liquidScale'] as num?)?.toDouble() ?? 1.0,
      liquidSaturation: (json['liquidSaturation'] as num?)?.toDouble() ?? 1.0,
      liquidColorSource:
          LiquidColorSource.fromName(json['liquidColorSource'] as String?),
      disableBlur: json['disableBlur'] as bool? ?? false,
      blurRadius: (json['blurRadius'] as num?)?.toDouble() ?? 48,
      visualizerEnabled: json['visualizerEnabled'] as bool? ?? false,
      equalizerEnabled: json['equalizerEnabled'] as bool? ?? false,
      equalizerBands: _parseEqualizerBands(json['equalizerBands'] as String?),
      equalizerPresetId: json['equalizerPresetId'] as String? ?? 'flat',
      skipSilence: json['skipSilence'] as bool? ?? false,
      audioNormalization: json['audioNormalization'] as bool? ?? false,
      pauseOnDeviceMute: json['pauseOnDeviceMute'] as bool? ?? true,
      volumeSliderStyle: ProgressBarStyle.fromName(
        json['volumeSliderStyle'] as String?,
      ),
      miniPlayerBackgroundStyle: MiniPlayerBackgroundStyle.fromName(
        json['miniPlayerBackgroundStyle'] as String?,
      ),
      titleBarCentered: json['titleBarCentered'] as bool? ?? true,
      titleBarMatchesBackground:
          json['titleBarMatchesBackground'] as bool? ?? false,
      sponsorBlockEnabled: json['sponsorBlockEnabled'] as bool? ?? false,
      // Отсутствующий ключ (`null`) — настройки с прошлой версии, набор по
      // умолчанию; пустая строка — пользователь снял все категории.
      sponsorBlockCategories: _parseSponsorCategories(
        json['sponsorBlockCategories'] as String?,
      ),
    );
  }

  factory AppSettings.decode(String? raw) {
    if (raw == null || raw.isEmpty) return const AppSettings();
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return AppSettings.fromJson(decoded);
    } on FormatException {
      // Битый JSON — откатываемся на значения по умолчанию.
    }
    return const AppSettings();
  }
}
