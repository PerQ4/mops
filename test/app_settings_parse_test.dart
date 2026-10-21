import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mops/core/audio/audio_equalizer.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/fronting.dart';
import 'package:mops/core/theme/seed_colors.dart';
import 'package:mops/data/local/app_settings.dart';
import 'package:mops/data/sources/sponsorblock.dart';

/// Значения всех полей, отличные от дефолтных: так round-trip проверяет каждое
/// поле, а не только те, что случайно попали в пример.
AppSettings _allNonDefault() => const AppSettings().copyWith(
  themeMode: ThemeModePreference.dark,
  colorSource: ColorSource.artwork,
  seedColorIndex: 3,
  useMaterialExpressive: false,
  pureBlack: true,
  paletteStyle: PaletteStylePreference.monochrome,
  fontPreference: FontPreference.custom,
  customFontPath: r'C:\fonts\my.ttf',
  disableAnimations: true,
  forceHighRefreshRate: true,
  playerPanelWidth: 320,
  playerPanelMode: RightPanelMode.player,
  sidebarWidth: 240,
  lyricsSource: LyricsSource.lrclib,
  audioQuality: AudioQuality.low,
  lowDataMode: true,
  streamClient: StreamSource.ios,
  showLyricsInPlayer: false,
  lyricsTextScale: 1.2,
  lyricsLineSpacing: 1.6,
  lyricsLineBlur: false,
  lyricsMode: LyricsMode.enhanced,
  lyricsAnimationStyle: LyricsAnimationStyle.spring,
  lyricsProviderOrder: <LyricsSource>[LyricsSource.kugou, LyricsSource.unison],
  lyricsDisabledProviders: <LyricsSource>[LyricsSource.music],
  paxsenixAppleMusic: false,
  paxsenixSpotify: false,
  paxsenixMusixmatch: false,
  romanizeJapanese: false,
  romanizeKorean: false,
  romanizeChinese: false,
  romanizeHindi: false,
  romanizeOther: false,
  autoPlayNext: false,
  restoreQueue: false,
  preloadNextTrack: false,
  localMediaFolder: r'C:\music',
  searchSource: SearchSource.libraryOnly,
  hideExplicit: true,
  hideVideo: true,
  topSize: TopSize.hundred,
  miniSwipeSensitivity: SwipeSensitivity.high,
  trackSwipeAction: TrackSwipeAction.playNext,
  streamingRegion: 'US',
  streamingLanguage: 'en',
  oauthClientId: 'client-id',
  oauthClientSecret: 'client-secret',
  musixmatchApiKey: 'mxm-key',
  discordRichPresence: true,
  discordApplicationId: '12345',
  lastVolume: 0.3,
  lastSpeed: 1.75,
  uiScale: 1.25,
  compactRows: true,
  bypass: const AntiDpiConfig(
    fronting: FrontingConfig(enabled: true, frontHost: 'example.com'),
    fragmentation: FragmentationLevel.medium,
    fragmentDelayMs: 5,
    proxyKind: ProxyKind.socks5,
    proxyHost: '127.0.0.1',
    proxyPort: 1081,
    proxyUsername: 'proxy-user',
    proxyPassword: 'proxy-pass',
  ),
  autoDetectProxy: false,
  sidebarCollapsed: true,
  sidebarNavigation: true,
  playerPanelEnabled: false,
  progressBarStyle: ProgressBarStyle.thick,
  playerBackgroundStyle: PlayerBackgroundStyle.liquid,
  liquidSpeed: 1.5,
  liquidScale: 0.75,
  liquidSaturation: 0.5,
  liquidColorSource: LiquidColorSource.theme,
  disableBlur: true,
  blurRadius: 12,
  visualizerEnabled: true,
  visualizerStyle: VisualizerStyle.bars,
  liveCoverEnabled: true,
  listeningStatsEnabled: false,
  equalizerEnabled: true,
  equalizerBands: const <double>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
  equalizerPresetId: 'custom',
  skipSilence: true,
  audioNormalization: true,
  pauseOnDeviceMute: false,
  volumeSliderStyle: ProgressBarStyle.simple,
  miniPlayerBackgroundStyle: MiniPlayerBackgroundStyle.glow,
  titleBarCentered: false,
  titleBarMatchesBackground: true,
  sponsorBlockEnabled: true,
  sponsorBlockCategories: const <SponsorBlockCategory>[
    SponsorBlockCategory.sponsor,
    SponsorBlockCategory.outro,
  ],
);

/// Порядок ключей в файле настроек: его видят глазами и диффят, поэтому он
/// часть контракта, а не деталь реализации.
const List<String> _expectedKeyOrder = <String>[
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
];

void main() {
  group('decode: неверный тип поля', () {
    test('портит только своё поле, остальные значения сохраняются', () {
      final Map<String, dynamic> json =
          jsonDecode(const AppSettings().encode()) as Map<String, dynamic>;

      // Неверные типы — по одному из разных доменов.
      json['themeMode'] = 123;
      json['pureBlack'] = 'yes';
      json['lyricsTextScale'] = 'большой';
      json['equalizerBands'] = 5;
      json['bypass'] = 'нет';
      json['sponsorBlockCategories'] = 42;
      json['localMediaFolder'] = <String>['не папка'];

      // Верные значения в том же JSON должны дожить до результата.
      json['seedColorIndex'] = 7;
      json['customFontPath'] = r'D:\fonts\x.ttf';
      json['lyricsMode'] = 'v2';
      json['equalizerPresetId'] = 'rock';
      json['streamClient'] = 'visionOs';
      json['sponsorBlockEnabled'] = true;

      final AppSettings settings = AppSettings.decode(jsonEncode(json));

      expect(settings.themeMode, ThemeModePreference.system);
      expect(settings.pureBlack, isFalse);
      expect(settings.lyricsTextScale, 1.0);
      expect(settings.equalizerBands, kEqualizerFlatBands);
      expect(settings.bypass.toJson(), const AntiDpiConfig().toJson());
      expect(settings.sponsorBlockCategories, kDefaultSponsorBlockCategories);
      expect(settings.localMediaFolder, '');

      expect(settings.seedColorIndex, 7);
      expect(settings.customFontPath, r'D:\fonts\x.ttf');
      expect(settings.lyricsMode, LyricsMode.v2);
      expect(settings.equalizerPresetId, 'rock');
      expect(settings.streamClient, StreamSource.visionOs);
      expect(settings.sponsorBlockEnabled, isTrue);
    });

    test('испорченный вложенный bypass не стоит всех настроек', () {
      final Map<String, dynamic> json =
          jsonDecode(const AppSettings().encode()) as Map<String, dynamic>;
      json['bypass'] = <String, dynamic>{'frontingEnabled': 'да'};
      json['pureBlack'] = true;

      final AppSettings settings = AppSettings.decode(jsonEncode(json));

      expect(settings.bypass.toJson(), const AntiDpiConfig().toJson());
      expect(settings.pureBlack, isTrue);
    });

    test('список имён вместо строки через запятую тоже читается', () {
      final Map<String, dynamic> json =
          jsonDecode(const AppSettings().encode()) as Map<String, dynamic>;
      json['lyricsProviderOrder'] = <String>['kugou', 'unison'];
      json['lyricsDisabledProviders'] = <String>['music'];
      json['equalizerBands'] = <String>[
        '1',
        '1',
        '1',
        '1',
        '1',
        '1',
        '1',
        '1',
        '1',
        '1',
      ];

      final AppSettings settings = AppSettings.decode(jsonEncode(json));

      expect(settings.lyricsProviderOrder, <LyricsSource>[
        LyricsSource.kugou,
        LyricsSource.unison,
      ]);
      expect(settings.lyricsDisabledProviders, <LyricsSource>[
        LyricsSource.music,
      ]);
      expect(settings.equalizerBands, <double>[1, 1, 1, 1, 1, 1, 1, 1, 1, 1]);
    });
  });

  group('decode: не настройки', () {
    test('пустая строка и null — дефолты', () {
      expect(AppSettings.decode(null).toJson(), const AppSettings().toJson());
      expect(AppSettings.decode('').toJson(), const AppSettings().toJson());
    });

    test('не JSON, не объект и литерал null — дефолты без исключения', () {
      for (final String raw in <String>['не json', '[]', 'null', '"строка"']) {
        expect(
          AppSettings.decode(raw).toJson(),
          const AppSettings().toJson(),
          reason: 'вход: $raw',
        );
      }
    });
  });

  group('round-trip', () {
    test('дефолт: fromJson(toJson()) даёт те же значения', () {
      const AppSettings original = AppSettings();
      final AppSettings restored = AppSettings.decode(original.encode());

      expect(restored.toJson(), original.toJson());
      expect(restored.encode(), original.encode());
    });

    test('все поля не по умолчанию: значения не теряются', () {
      final AppSettings original = _allNonDefault();
      final AppSettings restored = AppSettings.decode(original.encode());

      expect(restored.toJson(), original.toJson());
      expect(restored.encode(), original.encode());
    });
  });

  group('toJson: состав и порядок', () {
    test('83 ключа в прежнем порядке', () {
      final Map<String, dynamic> json = const AppSettings().toJson();

      expect(json.length, _expectedKeyOrder.length);
      expect(json.length, 83);
      expect(json.keys.toList(), _expectedKeyOrder);
    });

    test('дефолтный JSON совпадает с эталоном байт в байт', () {
      expect(const AppSettings().encode(), kDefaultSettingsJson);
    });
  });
}

/// JSON, который приложение писало до правки разбора (снят с кода до неё).
/// Это эталон байт в байт: состав, порядок и формат значений не должны меняться.
const String kDefaultSettingsJson =
    r'{"themeMode":"system","colorSource":"seed","seedColorIndex":0,"useMaterialExpressive":true,"pureBlack":false,"paletteStyle":"tonal","fontPreference":"poppins","customFontPath":"","disableAnimations":false,"forceHighRefreshRate":false,"playerPanelWidth":280.0,"playerPanelMode":"queue","sidebarWidth":280.0,"lyricsSource":"auto","audioQuality":"high","lowDataMode":false,"streamClient":"auto","showLyricsInPlayer":true,"lyricsTextScale":1.0,"lyricsLineSpacing":1.35,"lyricsLineBlur":true,"lyricsMode":"classic","lyricsAnimationStyle":"fade","lyricsProviderOrder":"youlyPlus,betterLyrics,musixmatch,kugou,lrclib,unison","lyricsDisabledProviders":"","paxsenixAppleMusic":true,"paxsenixSpotify":true,"paxsenixMusixmatch":true,"romanizeJapanese":true,"romanizeKorean":true,"romanizeChinese":true,"romanizeHindi":true,"romanizeOther":true,"autoPlayNext":true,"restoreQueue":true,"preloadNextTrack":true,"localMediaFolder":"","searchSource":"online","hideExplicit":false,"hideVideo":false,"topSize":"fifty","miniSwipeSensitivity":"normal","trackSwipeAction":"off","streamingRegion":"RU","streamingLanguage":"ru","oauthClientId":"","oauthClientSecret":"","musixmatchApiKey":"","discordRichPresence":false,"discordApplicationId":"","lastVolume":1.0,"lastSpeed":1.0,"uiScale":0.0,"compactRows":false,"bypass":{"frontingEnabled":true,"frontHost":"www.google.com","fragmentation":"off","fragmentDelayMs":1,"proxyKind":"none","proxyHost":"","proxyPort":1080,"proxyUsername":"","proxyPassword":""},"autoDetectProxy":true,"sidebarCollapsed":false,"sidebarNavigation":false,"playerPanelEnabled":true,"progressBarStyle":"standard","playerBackgroundStyle":"gradient","liquidSpeed":1.0,"liquidScale":1.0,"liquidSaturation":1.0,"liquidColorSource":"artwork","disableBlur":false,"blurRadius":48.0,"visualizerEnabled":false,"visualizerStyle":"halo","liveCoverEnabled":false,"listeningStatsEnabled":true,"equalizerEnabled":false,"equalizerBands":"0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0","equalizerPresetId":"flat","skipSilence":false,"audioNormalization":false,"pauseOnDeviceMute":true,"volumeSliderStyle":"standard","miniPlayerBackgroundStyle":"theme","titleBarCentered":true,"titleBarMatchesBackground":false,"sponsorBlockEnabled":false,"sponsorBlockCategories":"sponsor,selfpromo,intro,outro,music_offtopic"}';
