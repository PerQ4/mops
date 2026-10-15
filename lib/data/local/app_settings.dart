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
  megalobiz('Megalobiz', 'Внешняя база — текст с временами'),
  simpmusic('SimpMusic', 'Индекс по id видео — текст с временами'),
  unison('Unison', 'Внешняя база — текст с временами'),
  musixmatch('Musixmatch', 'Через Paxsenix — нужен ключ в настройках');

  const LyricsSource(this.label, this.description);

  final String label;
  final String description;

  static LyricsSource fromName(String? name) =>
      LyricsSource.values.firstWhere(
        (LyricsSource v) => v.name == name,
        orElse: () => LyricsSource.auto,
      );
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
    this.crossfadeSeconds = 0,
    this.autoPlayNext = true,
    this.searchSource = SearchSource.online,
    this.miniSwipeSensitivity = SwipeSensitivity.normal,
    this.trackSwipeAction = TrackSwipeAction.off,
    this.streamingRegion = 'RU',
    this.streamingLanguage = 'ru',
    this.oauthClientId = '',
    this.oauthClientSecret = '',
    this.musixmatchApiKey = '',
    this.lastVolume = 1.0,
    this.lastSpeed = 1.0,
    this.uiScale = 0.0,
    this.bypass = const AntiDpiConfig(),
    this.autoDetectProxy = true,
    this.sidebarCollapsed = false,
    this.playerPanelEnabled = true,
    this.progressBarStyle = ProgressBarStyle.standard,
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

  /// Кроссфейд между треками в секундах. `0` — выключен.
  ///
  /// Значение хранится, но движок воспроизведения (вне этого модуля) пока
  /// не умеет накладывать треки — см. отчёт.
  final int crossfadeSeconds;

  final bool autoPlayNext;

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

  bool get isUiScaleAuto => uiScale <= 0;

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
    int? crossfadeSeconds,
    bool? autoPlayNext,
    SearchSource? searchSource,
    SwipeSensitivity? miniSwipeSensitivity,
    TrackSwipeAction? trackSwipeAction,
    String? streamingRegion,
    String? streamingLanguage,
    String? oauthClientId,
    String? oauthClientSecret,
    String? musixmatchApiKey,
    double? lastVolume,
    double? lastSpeed,
    double? uiScale,
    AntiDpiConfig? bypass,
    bool? autoDetectProxy,
    bool? sidebarCollapsed,
    bool? playerPanelEnabled,
    ProgressBarStyle? progressBarStyle,
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
      crossfadeSeconds: crossfadeSeconds ?? this.crossfadeSeconds,
      autoPlayNext: autoPlayNext ?? this.autoPlayNext,
      searchSource: searchSource ?? this.searchSource,
      miniSwipeSensitivity: miniSwipeSensitivity ?? this.miniSwipeSensitivity,
      trackSwipeAction: trackSwipeAction ?? this.trackSwipeAction,
      streamingRegion: streamingRegion ?? this.streamingRegion,
      streamingLanguage: streamingLanguage ?? this.streamingLanguage,
      oauthClientId: oauthClientId ?? this.oauthClientId,
      oauthClientSecret: oauthClientSecret ?? this.oauthClientSecret,
      musixmatchApiKey: musixmatchApiKey ?? this.musixmatchApiKey,
      lastVolume: lastVolume ?? this.lastVolume,
      lastSpeed: lastSpeed ?? this.lastSpeed,
      uiScale: uiScale ?? this.uiScale,
      bypass: bypass ?? this.bypass,
      autoDetectProxy: autoDetectProxy ?? this.autoDetectProxy,
      sidebarCollapsed: sidebarCollapsed ?? this.sidebarCollapsed,
      playerPanelEnabled: playerPanelEnabled ?? this.playerPanelEnabled,
      progressBarStyle: progressBarStyle ?? this.progressBarStyle,
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
        'crossfadeSeconds': crossfadeSeconds,
        'autoPlayNext': autoPlayNext,
        'searchSource': searchSource.name,
        'miniSwipeSensitivity': miniSwipeSensitivity.name,
        'trackSwipeAction': trackSwipeAction.name,
        'streamingRegion': streamingRegion,
        'streamingLanguage': streamingLanguage,
        'oauthClientId': oauthClientId,
        'oauthClientSecret': oauthClientSecret,
        'musixmatchApiKey': musixmatchApiKey,
        'lastVolume': lastVolume,
        'lastSpeed': lastSpeed,
        'uiScale': uiScale,
        'bypass': bypass.toJson(),
        'autoDetectProxy': autoDetectProxy,
        'sidebarCollapsed': sidebarCollapsed,
        'playerPanelEnabled': playerPanelEnabled,
        'progressBarStyle': progressBarStyle.name,
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
      crossfadeSeconds: (json['crossfadeSeconds'] as num?)?.toInt() ?? 0,
      autoPlayNext: json['autoPlayNext'] as bool? ?? true,
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
