import 'dart:convert';

import '../../core/net/anti_dpi.dart';
import '../../core/theme/seed_colors.dart';

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
/// градиент из цветов обложки и размытая обложка.
enum PlayerBackgroundStyle {
  gradient('Градиент', 'Градиент из цветов обложки'),
  blur('Размытая обложка', 'Обложка трека, размытая и затемнённая');

  const PlayerBackgroundStyle(this.label, this.description);

  final String label;
  final String description;

  static PlayerBackgroundStyle fromName(String? name) =>
      PlayerBackgroundStyle.values.firstWhere(
        (PlayerBackgroundStyle v) => v.name == name,
        orElse: () => PlayerBackgroundStyle.gradient,
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
    this.playerPanelWidth = 280,
    this.playerPanelMode = RightPanelMode.queue,
    this.sidebarWidth = 280,
    this.lyricsSource = LyricsSource.auto,
    this.audioQuality = AudioQuality.high,
    this.streamClient = StreamSource.auto,
    this.showLyricsInPlayer = true,
    this.lyricsTextScale = 1.0,
    this.lyricsLineSpacing = 1.35,
    this.lyricsLineBlur = true,
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
    this.playerPanelEnabled = true,
    this.progressBarStyle = ProgressBarStyle.standard,
    this.playerBackgroundStyle = PlayerBackgroundStyle.gradient,
    this.disableBlur = false,
    this.blurRadius = 48,
    this.volumeSliderStyle = ProgressBarStyle.standard,
    this.titleBarCentered = true,
    this.titleBarMatchesBackground = false,
  });

  final ThemeModePreference themeMode;
  final ColorSource colorSource;
  final int seedColorIndex;
  final bool useMaterialExpressive;

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

  /// Чистый чёрный фон в тёмной теме — как отдельный переключатель в
  /// ArchiveTune: фон и поверхности становятся #000000.
  final bool pureBlack;
  final AudioQuality audioQuality;

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

  /// Отключить размытие (как в ArchiveTune): фон рисуется без блюра.
  final bool disableBlur;

  /// Сила размытия фона (0–64). Как `BlurRadiusKey` в ArchiveTune.
  final double blurRadius;

  /// Стиль ползунка громкости — тот же набор, что у полосы перемотки.
  final ProgressBarStyle volumeSliderStyle;

  /// Заголовок окна по центру (иначе — слева, у логотипа). Только Windows.
  final bool titleBarCentered;

  /// Красить шапку окна в цвет фона приложения (иначе — в самый тёмный тон
  /// палитры, как рамка окна). Только Windows.
  final bool titleBarMatchesBackground;

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
    double? playerPanelWidth,
    RightPanelMode? playerPanelMode,
    double? sidebarWidth,
    LyricsSource? lyricsSource,
    AudioQuality? audioQuality,
    StreamSource? streamClient,
    bool? showLyricsInPlayer,
    double? lyricsTextScale,
    double? lyricsLineSpacing,
    bool? lyricsLineBlur,
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
    bool? playerPanelEnabled,
    ProgressBarStyle? progressBarStyle,
    PlayerBackgroundStyle? playerBackgroundStyle,
    bool? disableBlur,
    double? blurRadius,
    ProgressBarStyle? volumeSliderStyle,
    bool? titleBarCentered,
    bool? titleBarMatchesBackground,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      colorSource: colorSource ?? this.colorSource,
      seedColorIndex: seedColorIndex ?? this.seedColorIndex,
      useMaterialExpressive: useMaterialExpressive ?? this.useMaterialExpressive,
      pureBlack: pureBlack ?? this.pureBlack,
      paletteStyle: paletteStyle ?? this.paletteStyle,
      playerPanelWidth: playerPanelWidth ?? this.playerPanelWidth,
      playerPanelMode: playerPanelMode ?? this.playerPanelMode,
      sidebarWidth: sidebarWidth ?? this.sidebarWidth,
      lyricsSource: lyricsSource ?? this.lyricsSource,
      audioQuality: audioQuality ?? this.audioQuality,
      streamClient: streamClient ?? this.streamClient,
      showLyricsInPlayer: showLyricsInPlayer ?? this.showLyricsInPlayer,
      lyricsTextScale: lyricsTextScale ?? this.lyricsTextScale,
      lyricsLineSpacing: lyricsLineSpacing ?? this.lyricsLineSpacing,
      lyricsLineBlur: lyricsLineBlur ?? this.lyricsLineBlur,
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
      playerPanelEnabled: playerPanelEnabled ?? this.playerPanelEnabled,
      progressBarStyle: progressBarStyle ?? this.progressBarStyle,
      playerBackgroundStyle:
          playerBackgroundStyle ?? this.playerBackgroundStyle,
      disableBlur: disableBlur ?? this.disableBlur,
      blurRadius: blurRadius ?? this.blurRadius,
      volumeSliderStyle: volumeSliderStyle ?? this.volumeSliderStyle,
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
        'playerPanelWidth': playerPanelWidth,
        'playerPanelMode': playerPanelMode.name,
        'sidebarWidth': sidebarWidth,
        'lyricsSource': lyricsSource.name,
        'audioQuality': audioQuality.name,
        'streamClient': streamClient.name,
        'showLyricsInPlayer': showLyricsInPlayer,
        'lyricsTextScale': lyricsTextScale,
        'lyricsLineSpacing': lyricsLineSpacing,
        'lyricsLineBlur': lyricsLineBlur,
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
        'playerPanelEnabled': playerPanelEnabled,
        'progressBarStyle': progressBarStyle.name,
        'playerBackgroundStyle': playerBackgroundStyle.name,
        'disableBlur': disableBlur,
        'blurRadius': blurRadius,
        'volumeSliderStyle': volumeSliderStyle.name,
        'titleBarCentered': titleBarCentered,
        'titleBarMatchesBackground': titleBarMatchesBackground,
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
      playerPanelWidth: (json['playerPanelWidth'] as num?)?.toDouble() ?? 280,
      playerPanelMode:
          RightPanelMode.fromName(json['playerPanelMode'] as String?),
      sidebarWidth: (json['sidebarWidth'] as num?)?.toDouble() ?? 280,
      lyricsSource: LyricsSource.fromName(json['lyricsSource'] as String?),
      audioQuality: AudioQuality.fromName(json['audioQuality'] as String?),
      streamClient: StreamSource.fromName(json['streamClient'] as String?),
      showLyricsInPlayer: json['showLyricsInPlayer'] as bool? ?? true,
      lyricsTextScale: (json['lyricsTextScale'] as num?)?.toDouble() ?? 1.0,
      lyricsLineSpacing: (json['lyricsLineSpacing'] as num?)?.toDouble() ?? 1.35,
      lyricsLineBlur: json['lyricsLineBlur'] as bool? ?? true,
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
      playerPanelEnabled: json['playerPanelEnabled'] as bool? ?? true,
      progressBarStyle: ProgressBarStyle.fromName(json['progressBarStyle'] as String?),
      playerBackgroundStyle: PlayerBackgroundStyle.fromName(
        json['playerBackgroundStyle'] as String?,
      ),
      disableBlur: json['disableBlur'] as bool? ?? false,
      blurRadius: (json['blurRadius'] as num?)?.toDouble() ?? 48,
      volumeSliderStyle: ProgressBarStyle.fromName(
        json['volumeSliderStyle'] as String?,
      ),
      titleBarCentered: json['titleBarCentered'] as bool? ?? true,
      titleBarMatchesBackground:
          json['titleBarMatchesBackground'] as bool? ?? false,
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
