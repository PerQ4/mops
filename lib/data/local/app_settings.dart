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

/// Все настройки приложения. Сериализуется в JSON и хранится в
/// shared_preferences одной строкой — так меньше кода и атомарная запись.
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeModePreference.system,
    this.colorSource = ColorSource.seed,
    this.seedColorIndex = 0,
    this.useMaterialExpressive = true,
    this.audioQuality = AudioQuality.high,
    this.streamClient = StreamSource.auto,
    this.showLyricsInPlayer = true,
    this.autoPlayNext = true,
    this.streamingRegion = 'RU',
    this.streamingLanguage = 'ru',
    this.oauthClientId = '',
    this.oauthClientSecret = '',
    this.lastVolume = 1.0,
    this.lastSpeed = 1.0,
    this.uiScale = 0.0,
    this.bypass = const AntiDpiConfig(),
    this.autoDetectProxy = true,
    this.sidebarCollapsed = false,
  });

  final ThemeModePreference themeMode;
  final ColorSource colorSource;
  final int seedColorIndex;
  final bool useMaterialExpressive;
  final AudioQuality audioQuality;

  /// Клиент YouTube, у которого запрашивается ссылка на поток.
  final StreamSource streamClient;

  final bool showLyricsInPlayer;
  final bool autoPlayNext;
  final String streamingRegion;
  final String streamingLanguage;
  final String oauthClientId;
  final String oauthClientSecret;
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

  bool get isUiScaleAuto => uiScale <= 0;

  int get safeSeedIndex =>
      (seedColorIndex >= 0 && seedColorIndex < kSeedColors.length) ? seedColorIndex : 0;

  AppSettings copyWith({
    ThemeModePreference? themeMode,
    ColorSource? colorSource,
    int? seedColorIndex,
    bool? useMaterialExpressive,
    AudioQuality? audioQuality,
    StreamSource? streamClient,
    bool? showLyricsInPlayer,
    bool? autoPlayNext,
    String? streamingRegion,
    String? streamingLanguage,
    String? oauthClientId,
    String? oauthClientSecret,
    double? lastVolume,
    double? lastSpeed,
    double? uiScale,
    AntiDpiConfig? bypass,
    bool? autoDetectProxy,
    bool? sidebarCollapsed,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      colorSource: colorSource ?? this.colorSource,
      seedColorIndex: seedColorIndex ?? this.seedColorIndex,
      useMaterialExpressive: useMaterialExpressive ?? this.useMaterialExpressive,
      audioQuality: audioQuality ?? this.audioQuality,
      streamClient: streamClient ?? this.streamClient,
      showLyricsInPlayer: showLyricsInPlayer ?? this.showLyricsInPlayer,
      autoPlayNext: autoPlayNext ?? this.autoPlayNext,
      streamingRegion: streamingRegion ?? this.streamingRegion,
      streamingLanguage: streamingLanguage ?? this.streamingLanguage,
      oauthClientId: oauthClientId ?? this.oauthClientId,
      oauthClientSecret: oauthClientSecret ?? this.oauthClientSecret,
      lastVolume: lastVolume ?? this.lastVolume,
      lastSpeed: lastSpeed ?? this.lastSpeed,
      uiScale: uiScale ?? this.uiScale,
      bypass: bypass ?? this.bypass,
      autoDetectProxy: autoDetectProxy ?? this.autoDetectProxy,
      sidebarCollapsed: sidebarCollapsed ?? this.sidebarCollapsed,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'themeMode': themeMode.name,
        'colorSource': colorSource.name,
        'seedColorIndex': seedColorIndex,
        'useMaterialExpressive': useMaterialExpressive,
        'audioQuality': audioQuality.name,
        'streamClient': streamClient.name,
        'showLyricsInPlayer': showLyricsInPlayer,
        'autoPlayNext': autoPlayNext,
        'streamingRegion': streamingRegion,
        'streamingLanguage': streamingLanguage,
        'oauthClientId': oauthClientId,
        'oauthClientSecret': oauthClientSecret,
        'lastVolume': lastVolume,
        'lastSpeed': lastSpeed,
        'uiScale': uiScale,
        'bypass': bypass.toJson(),
        'autoDetectProxy': autoDetectProxy,
        'sidebarCollapsed': sidebarCollapsed,
      };

  String encode() => jsonEncode(toJson());

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      themeMode: ThemeModePreference.fromName(json['themeMode'] as String?),
      colorSource: ColorSource.fromName(json['colorSource'] as String?),
      seedColorIndex: (json['seedColorIndex'] as num?)?.toInt() ?? 0,
      useMaterialExpressive: json['useMaterialExpressive'] as bool? ?? true,
      audioQuality: AudioQuality.fromName(json['audioQuality'] as String?),
      streamClient: StreamSource.fromName(json['streamClient'] as String?),
      showLyricsInPlayer: json['showLyricsInPlayer'] as bool? ?? true,
      autoPlayNext: json['autoPlayNext'] as bool? ?? true,
      streamingRegion: json['streamingRegion'] as String? ?? 'RU',
      streamingLanguage: json['streamingLanguage'] as String? ?? 'ru',
      oauthClientId: json['oauthClientId'] as String? ?? '',
      oauthClientSecret: json['oauthClientSecret'] as String? ?? '',
      lastVolume: (json['lastVolume'] as num?)?.toDouble() ?? 1.0,
      lastSpeed: (json['lastSpeed'] as num?)?.toDouble() ?? 1.0,
      uiScale: (json['uiScale'] as num?)?.toDouble() ?? 0.0,
      bypass: json['bypass'] is Map<String, dynamic>
          ? AntiDpiConfig.fromJson(json['bypass'] as Map<String, dynamic>)
          : const AntiDpiConfig(),
      autoDetectProxy: json['autoDetectProxy'] as bool? ?? true,
      sidebarCollapsed: json['sidebarCollapsed'] as bool? ?? false,
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
