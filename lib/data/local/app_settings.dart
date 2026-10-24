import 'dart:convert';

import '../../core/net/anti_dpi.dart';
import '../../core/theme/seed_colors.dart';
import '../sources/sponsorblock.dart';
import 'settings/appearance_settings.dart';
import 'settings/general_settings.dart';
import 'settings/integrations_settings.dart';
import 'settings/layout_settings.dart';
import 'settings/lyrics_settings.dart';
import 'settings/network_settings.dart';
import 'settings/playback_settings.dart';

// Публичные типы доменов (перечисления, порядок источников, `PaxsenixOptions`)
// остаются доступны там же, где и раньше — через этот файл.
export 'settings/appearance_settings.dart';
export 'settings/general_settings.dart';
export 'settings/integrations_settings.dart';
export 'settings/layout_settings.dart';
export 'settings/lyrics_settings.dart';
export 'settings/network_settings.dart';
export 'settings/playback_settings.dart';

/// Все настройки приложения. Сериализуется в JSON и хранится в
/// shared_preferences одной строкой — так меньше кода и атомарная запись.
///
/// Состояние разложено по доменам (`settings/*.dart`), а наружу отдаётся
/// прежними плоскими геттерами: экраны, провайдеры и движки о перегруппировке
/// не знают. Новая настройка добавляется в свой домен, а здесь появляются
/// только однострочные делегаты.
class AppSettings {
  const AppSettings({
    this.appearance = const AppearanceSettings(),
    this.layout = const LayoutSettings(),
    this.lyrics = const LyricsSettings(),
    this.playback = const PlaybackSettings(),
    this.network = const NetworkSettings(),
    this.integrations = const IntegrationsSettings(),
    this.general = const GeneralSettings(),
  });

  /// Тема, палитра, шрифт, масштаб и оформление плеера.
  final AppearanceSettings appearance;

  /// Панели, их ширины и жесты по спискам.
  final LayoutSettings layout;

  /// Источник, вид и анимация текста, романизация.
  final LyricsSettings lyrics;

  /// Качество потока, очередь, эквалайзер и обработка звука.
  final PlaybackSettings playback;

  /// Экономия трафика и обход блокировок.
  final NetworkSettings network;

  /// Discord, SponsorBlock, вход в аккаунт и ключ Paxsenix.
  final IntegrationsSettings integrations;

  /// Поиск, локальные файлы, регион и статистика.
  final GeneralSettings general;

  // ---------------------------------------------------------------------------
  // Внешний вид
  // ---------------------------------------------------------------------------

  ThemeModePreference get themeMode => appearance.themeMode;
  ColorSource get colorSource => appearance.colorSource;
  int get seedColorIndex => appearance.seedColorIndex;
  bool get useMaterialExpressive => appearance.useMaterialExpressive;
  bool get pureBlack => appearance.pureBlack;
  PaletteStylePreference get paletteStyle => appearance.paletteStyle;
  FontPreference get fontPreference => appearance.fontPreference;
  String get customFontPath => appearance.customFontPath;
  bool get disableAnimations => appearance.disableAnimations;
  bool get forceHighRefreshRate => appearance.forceHighRefreshRate;
  double get uiScale => appearance.uiScale;
  bool get compactRows => appearance.compactRows;
  ProgressBarStyle get progressBarStyle => appearance.progressBarStyle;
  ProgressBarStyle get volumeSliderStyle => appearance.volumeSliderStyle;
  PlayerInfoAlignment get playerInfoAlignment => appearance.playerInfoAlignment;
  MiniPlayerBackgroundStyle get miniPlayerBackgroundStyle =>
      appearance.miniPlayerBackgroundStyle;
  PlayerBackgroundStyle get playerBackgroundStyle =>
      appearance.playerBackgroundStyle;
  double get liquidSpeed => appearance.liquidSpeed;
  double get liquidScale => appearance.liquidScale;
  double get liquidSaturation => appearance.liquidSaturation;
  LiquidColorSource get liquidColorSource => appearance.liquidColorSource;
  bool get disableBlur => appearance.disableBlur;
  double get blurRadius => appearance.blurRadius;
  bool get visualizerEnabled => appearance.visualizerEnabled;
  VisualizerStyle get visualizerStyle => appearance.visualizerStyle;
  bool get liveCoverEnabled => appearance.liveCoverEnabled;
  bool get titleBarCentered => appearance.titleBarCentered;
  bool get titleBarMatchesBackground => appearance.titleBarMatchesBackground;

  bool get isUiScaleAuto => appearance.isUiScaleAuto;

  int get safeSeedIndex => appearance.safeSeedIndex;

  // ---------------------------------------------------------------------------
  // Раскладка
  // ---------------------------------------------------------------------------

  double get playerPanelWidth => layout.playerPanelWidth;
  RightPanelMode get playerPanelMode => layout.playerPanelMode;
  double get sidebarWidth => layout.sidebarWidth;
  SwipeSensitivity get miniSwipeSensitivity => layout.miniSwipeSensitivity;
  TrackSwipeAction get trackSwipeAction => layout.trackSwipeAction;
  bool get sidebarCollapsed => layout.sidebarCollapsed;
  bool get sidebarNavigation => layout.sidebarNavigation;
  bool get playerPanelEnabled => layout.playerPanelEnabled;

  // ---------------------------------------------------------------------------
  // Тексты
  // ---------------------------------------------------------------------------

  LyricsSource get lyricsSource => lyrics.lyricsSource;
  bool get showLyricsInPlayer => lyrics.showLyricsInPlayer;
  double get lyricsTextScale => lyrics.lyricsTextScale;
  double get lyricsLineSpacing => lyrics.lyricsLineSpacing;
  bool get lyricsLineBlur => lyrics.lyricsLineBlur;
  LyricsMode get lyricsMode => lyrics.lyricsMode;
  LyricsAnimationStyle get lyricsAnimationStyle => lyrics.lyricsAnimationStyle;
  double get lyricsActiveLineScale => lyrics.lyricsActiveLineScale;
  double get effectiveLyricsActiveLineScale => lyrics.effectiveActiveLineScale;
  double get modeLyricsActiveLineScale => lyrics.modeActiveLineScale;
  bool get hasCustomLyricsActiveLineScale => lyrics.hasCustomActiveLineScale;
  double get lyricsInactiveOpacity => lyrics.lyricsInactiveOpacity;
  LyricsTextAlign get lyricsTextAlign => lyrics.lyricsTextAlign;
  LyricsColumnWidth get lyricsColumnWidth => lyrics.lyricsColumnWidth;
  bool get lyricsAutoScroll => lyrics.lyricsAutoScroll;
  List<LyricsSource> get lyricsProviderOrder => lyrics.lyricsProviderOrder;
  List<LyricsSource> get lyricsDisabledProviders =>
      lyrics.lyricsDisabledProviders;
  bool get paxsenixAppleMusic => lyrics.paxsenixAppleMusic;
  bool get paxsenixSpotify => lyrics.paxsenixSpotify;
  bool get paxsenixMusixmatch => lyrics.paxsenixMusixmatch;
  bool get romanizeJapanese => lyrics.romanizeJapanese;
  bool get romanizeKorean => lyrics.romanizeKorean;
  bool get romanizeChinese => lyrics.romanizeChinese;
  bool get romanizeHindi => lyrics.romanizeHindi;
  bool get romanizeOther => lyrics.romanizeOther;

  bool isLyricsSourceEnabled(LyricsSource source) =>
      lyrics.isSourceEnabled(source);

  /// Источники, которые можно включать и выключать, — всё, кроме «Авто».
  static List<LyricsSource> get toggleableLyricsSources =>
      LyricsSettings.toggleableSources;

  /// Каталоги Paxsenix одним значением — так источник получает их одним
  /// параметром, а не тремя.
  PaxsenixOptions get paxsenixOptions => lyrics.paxsenixOptions;

  // ---------------------------------------------------------------------------
  // Воспроизведение
  // ---------------------------------------------------------------------------

  AudioQuality get audioQuality => playback.audioQuality;
  StreamSource get streamClient => playback.streamClient;
  bool get autoPlayNext => playback.autoPlayNext;
  bool get restoreQueue => playback.restoreQueue;
  bool get preloadNextTrack => playback.preloadNextTrack;
  double get lastVolume => playback.lastVolume;
  double get lastSpeed => playback.lastSpeed;
  bool get equalizerEnabled => playback.equalizerEnabled;
  List<double> get equalizerBands => playback.equalizerBands;
  String get equalizerPresetId => playback.equalizerPresetId;
  bool get skipSilence => playback.skipSilence;
  bool get audioNormalization => playback.audioNormalization;
  bool get pauseOnDeviceMute => playback.pauseOnDeviceMute;

  // ---------------------------------------------------------------------------
  // Сеть
  // ---------------------------------------------------------------------------

  bool get lowDataMode => network.lowDataMode;
  AntiDpiConfig get bypass => network.bypass;
  bool get autoDetectProxy => network.autoDetectProxy;

  // ---------------------------------------------------------------------------
  // Интеграции
  // ---------------------------------------------------------------------------

  String get oauthClientId => integrations.oauthClientId;
  String get oauthClientSecret => integrations.oauthClientSecret;
  String get musixmatchApiKey => integrations.musixmatchApiKey;
  bool get discordRichPresence => integrations.discordRichPresence;
  String get discordApplicationId => integrations.discordApplicationId;
  bool get sponsorBlockEnabled => integrations.sponsorBlockEnabled;
  List<SponsorBlockCategory> get sponsorBlockCategories =>
      integrations.sponsorBlockCategories;

  // ---------------------------------------------------------------------------
  // Прочее
  // ---------------------------------------------------------------------------

  String get localMediaFolder => general.localMediaFolder;
  SearchSource get searchSource => general.searchSource;
  bool get hideExplicit => general.hideExplicit;
  bool get hideVideo => general.hideVideo;
  TopSize get topSize => general.topSize;
  String get streamingRegion => general.streamingRegion;
  String get streamingLanguage => general.streamingLanguage;
  bool get listeningStatsEnabled => general.listeningStatsEnabled;

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
    double? lyricsActiveLineScale,
    double? lyricsInactiveOpacity,
    LyricsTextAlign? lyricsTextAlign,
    LyricsColumnWidth? lyricsColumnWidth,
    bool? lyricsAutoScroll,
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
    bool? preloadNextTrack,
    String? localMediaFolder,
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
    bool? compactRows,
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
    VisualizerStyle? visualizerStyle,
    bool? liveCoverEnabled,
    bool? listeningStatsEnabled,
    bool? equalizerEnabled,
    List<double>? equalizerBands,
    String? equalizerPresetId,
    bool? skipSilence,
    bool? audioNormalization,
    bool? pauseOnDeviceMute,
    ProgressBarStyle? volumeSliderStyle,
    PlayerInfoAlignment? playerInfoAlignment,
    MiniPlayerBackgroundStyle? miniPlayerBackgroundStyle,
    bool? titleBarCentered,
    bool? titleBarMatchesBackground,
    bool? sponsorBlockEnabled,
    List<SponsorBlockCategory>? sponsorBlockCategories,
  }) {
    return AppSettings(
      appearance: appearance.copyWith(
        themeMode: themeMode,
        colorSource: colorSource,
        seedColorIndex: seedColorIndex,
        useMaterialExpressive: useMaterialExpressive,
        pureBlack: pureBlack,
        paletteStyle: paletteStyle,
        fontPreference: fontPreference,
        customFontPath: customFontPath,
        disableAnimations: disableAnimations,
        forceHighRefreshRate: forceHighRefreshRate,
        uiScale: uiScale,
        compactRows: compactRows,
        progressBarStyle: progressBarStyle,
        volumeSliderStyle: volumeSliderStyle,
        playerInfoAlignment: playerInfoAlignment,
        miniPlayerBackgroundStyle: miniPlayerBackgroundStyle,
        playerBackgroundStyle: playerBackgroundStyle,
        liquidSpeed: liquidSpeed,
        liquidScale: liquidScale,
        liquidSaturation: liquidSaturation,
        liquidColorSource: liquidColorSource,
        disableBlur: disableBlur,
        blurRadius: blurRadius,
        visualizerEnabled: visualizerEnabled,
        visualizerStyle: visualizerStyle,
        liveCoverEnabled: liveCoverEnabled,
        titleBarCentered: titleBarCentered,
        titleBarMatchesBackground: titleBarMatchesBackground,
      ),
      layout: layout.copyWith(
        playerPanelWidth: playerPanelWidth,
        playerPanelMode: playerPanelMode,
        sidebarWidth: sidebarWidth,
        miniSwipeSensitivity: miniSwipeSensitivity,
        trackSwipeAction: trackSwipeAction,
        sidebarCollapsed: sidebarCollapsed,
        sidebarNavigation: sidebarNavigation,
        playerPanelEnabled: playerPanelEnabled,
      ),
      lyrics: lyrics.copyWith(
        lyricsSource: lyricsSource,
        showLyricsInPlayer: showLyricsInPlayer,
        lyricsTextScale: lyricsTextScale,
        lyricsLineSpacing: lyricsLineSpacing,
        lyricsLineBlur: lyricsLineBlur,
        lyricsMode: lyricsMode,
        lyricsAnimationStyle: lyricsAnimationStyle,
        lyricsActiveLineScale: lyricsActiveLineScale,
        lyricsInactiveOpacity: lyricsInactiveOpacity,
        lyricsTextAlign: lyricsTextAlign,
        lyricsColumnWidth: lyricsColumnWidth,
        lyricsAutoScroll: lyricsAutoScroll,
        lyricsProviderOrder: lyricsProviderOrder,
        lyricsDisabledProviders: lyricsDisabledProviders,
        paxsenixAppleMusic: paxsenixAppleMusic,
        paxsenixSpotify: paxsenixSpotify,
        paxsenixMusixmatch: paxsenixMusixmatch,
        romanizeJapanese: romanizeJapanese,
        romanizeKorean: romanizeKorean,
        romanizeChinese: romanizeChinese,
        romanizeHindi: romanizeHindi,
        romanizeOther: romanizeOther,
      ),
      playback: playback.copyWith(
        audioQuality: audioQuality,
        streamClient: streamClient,
        autoPlayNext: autoPlayNext,
        restoreQueue: restoreQueue,
        preloadNextTrack: preloadNextTrack,
        lastVolume: lastVolume,
        lastSpeed: lastSpeed,
        equalizerEnabled: equalizerEnabled,
        equalizerBands: equalizerBands,
        equalizerPresetId: equalizerPresetId,
        skipSilence: skipSilence,
        audioNormalization: audioNormalization,
        pauseOnDeviceMute: pauseOnDeviceMute,
      ),
      network: network.copyWith(
        lowDataMode: lowDataMode,
        bypass: bypass,
        autoDetectProxy: autoDetectProxy,
      ),
      integrations: integrations.copyWith(
        oauthClientId: oauthClientId,
        oauthClientSecret: oauthClientSecret,
        musixmatchApiKey: musixmatchApiKey,
        discordRichPresence: discordRichPresence,
        discordApplicationId: discordApplicationId,
        sponsorBlockEnabled: sponsorBlockEnabled,
        sponsorBlockCategories: sponsorBlockCategories,
      ),
      general: general.copyWith(
        localMediaFolder: localMediaFolder,
        searchSource: searchSource,
        hideExplicit: hideExplicit,
        hideVideo: hideVideo,
        topSize: topSize,
        streamingRegion: streamingRegion,
        streamingLanguage: streamingLanguage,
        listeningStatsEnabled: listeningStatsEnabled,
      ),
    );
  }

  /// Порядок ключей сохранён прежним: файл настроек не должен меняться от
  /// одной лишь перегруппировки кода (его сравнивают глазами и диффят).
  static const List<String> _jsonKeyOrder = <String>[
    'themeMode',
    'colorSource',
    'seedColorIndex',
    'useMaterialExpressive',
    'pureBlack',
    'paletteStyle',
    'fontPreference',
    'customFontPath',
    'disableAnimations',
    'forceHighRefreshRate',
    'playerPanelWidth',
    'playerPanelMode',
    'sidebarWidth',
    'lyricsSource',
    'audioQuality',
    'lowDataMode',
    'streamClient',
    'showLyricsInPlayer',
    'lyricsTextScale',
    'lyricsLineSpacing',
    'lyricsLineBlur',
    'lyricsMode',
    'lyricsAnimationStyle',
    'lyricsActiveLineScale',
    'lyricsInactiveOpacity',
    'lyricsTextAlign',
    'lyricsColumnWidth',
    'lyricsAutoScroll',
    'lyricsProviderOrder',
    'lyricsDisabledProviders',
    'paxsenixAppleMusic',
    'paxsenixSpotify',
    'paxsenixMusixmatch',
    'romanizeJapanese',
    'romanizeKorean',
    'romanizeChinese',
    'romanizeHindi',
    'romanizeOther',
    'autoPlayNext',
    'restoreQueue',
    'preloadNextTrack',
    'localMediaFolder',
    'searchSource',
    'hideExplicit',
    'hideVideo',
    'topSize',
    'miniSwipeSensitivity',
    'trackSwipeAction',
    'streamingRegion',
    'streamingLanguage',
    'oauthClientId',
    'oauthClientSecret',
    'musixmatchApiKey',
    'discordRichPresence',
    'discordApplicationId',
    'lastVolume',
    'lastSpeed',
    'uiScale',
    'compactRows',
    'bypass',
    'autoDetectProxy',
    'sidebarCollapsed',
    'sidebarNavigation',
    'playerPanelEnabled',
    'progressBarStyle',
    'playerBackgroundStyle',
    'liquidSpeed',
    'liquidScale',
    'liquidSaturation',
    'liquidColorSource',
    'disableBlur',
    'blurRadius',
    'visualizerEnabled',
    'visualizerStyle',
    'liveCoverEnabled',
    'listeningStatsEnabled',
    'equalizerEnabled',
    'equalizerBands',
    'equalizerPresetId',
    'skipSilence',
    'audioNormalization',
    'pauseOnDeviceMute',
    'volumeSliderStyle',
    'miniPlayerBackgroundStyle',
    'titleBarCentered',
    'titleBarMatchesBackground',
    'sponsorBlockEnabled',
    'sponsorBlockCategories',
    // Новое поле — в конец: прежние ключи и их порядок остаются как были.
    'playerInfoAlignment',
  ];

  /// Плоский JSON: домены пишут свои ключи, здесь они только упорядочиваются.
  Map<String, dynamic> toJson() {
    final Map<String, dynamic> parts = <String, dynamic>{
      ...appearance.toJson(),
      ...layout.toJson(),
      ...lyrics.toJson(),
      ...playback.toJson(),
      ...network.toJson(),
      ...integrations.toJson(),
      ...general.toJson(),
    };
    assert(
      parts.length == _jsonKeyOrder.length,
      'Домен потерял или продублировал ключ: ${parts.length} против '
      '${_jsonKeyOrder.length}',
    );
    // Список нужен только ради прежнего порядка ключей. Если домен завёл
    // новое поле, а список не обновили, отдаём всё как есть: порядок в файле
    // менее важен, чем сохранность значения.
    if (parts.length != _jsonKeyOrder.length ||
        !parts.keys.every(_jsonKeyOrder.contains)) {
      return parts;
    }
    return <String, dynamic>{
      for (final String key in _jsonKeyOrder) key: parts[key],
    };
  }

  String encode() => jsonEncode(toJson());

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      appearance: AppearanceSettings.fromJson(json),
      layout: LayoutSettings.fromJson(json),
      lyrics: LyricsSettings.fromJson(json),
      playback: PlaybackSettings.fromJson(json),
      network: NetworkSettings.fromJson(json),
      integrations: IntegrationsSettings.fromJson(json),
      general: GeneralSettings.fromJson(json),
    );
  }

  factory AppSettings.decode(String? raw) {
    // Пустая строка и `null` — это «настроек ещё нет», а не ошибка: дефолты
    // здесь и есть норма.
    if (raw == null || raw.isEmpty) return const AppSettings();
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return AppSettings.fromJson(decoded);
    } on Object {
      // Настройки не должны мешать запуску: не JSON, не объект, любое
      // исключение при разборе полей — откат на дефолты, а не падение
      // из `main()` до `runApp`.
    }
    return const AppSettings();
  }
}
