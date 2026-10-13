import 'dart:convert';

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

/// Полноэкранный вид плеера.
enum PlayerLayout {
  /// Классика: обложка сверху, управление снизу.
  classic('Классика'),

  /// Обложка на весь экран, управление поверх.
  immersive('Полноэкранная обложка'),

  /// Обложка слева, управление и очередь справа (для широких экранов).
  split('Разделённый');

  const PlayerLayout(this.label);

  final String label;

  static PlayerLayout fromName(String? name) => PlayerLayout.values.firstWhere(
        (PlayerLayout l) => l.name == name,
        orElse: () => PlayerLayout.classic,
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
    this.playerLayout = PlayerLayout.classic,
    this.showLyricsInPlayer = true,
    this.autoPlayNext = true,
    this.streamingRegion = 'RU',
    this.streamingLanguage = 'ru',
    this.oauthClientId = '',
    this.oauthClientSecret = '',
    this.lastVolume = 1.0,
    this.lastSpeed = 1.0,
    this.uiScale = 0.0,
  });

  final ThemeModePreference themeMode;
  final ColorSource colorSource;
  final int seedColorIndex;
  final bool useMaterialExpressive;
  final AudioQuality audioQuality;
  final PlayerLayout playerLayout;
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

  bool get isUiScaleAuto => uiScale <= 0;

  int get safeSeedIndex =>
      (seedColorIndex >= 0 && seedColorIndex < kSeedColors.length) ? seedColorIndex : 0;

  AppSettings copyWith({
    ThemeModePreference? themeMode,
    ColorSource? colorSource,
    int? seedColorIndex,
    bool? useMaterialExpressive,
    AudioQuality? audioQuality,
    PlayerLayout? playerLayout,
    bool? showLyricsInPlayer,
    bool? autoPlayNext,
    String? streamingRegion,
    String? streamingLanguage,
    String? oauthClientId,
    String? oauthClientSecret,
    double? lastVolume,
    double? lastSpeed,
    double? uiScale,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      colorSource: colorSource ?? this.colorSource,
      seedColorIndex: seedColorIndex ?? this.seedColorIndex,
      useMaterialExpressive: useMaterialExpressive ?? this.useMaterialExpressive,
      audioQuality: audioQuality ?? this.audioQuality,
      playerLayout: playerLayout ?? this.playerLayout,
      showLyricsInPlayer: showLyricsInPlayer ?? this.showLyricsInPlayer,
      autoPlayNext: autoPlayNext ?? this.autoPlayNext,
      streamingRegion: streamingRegion ?? this.streamingRegion,
      streamingLanguage: streamingLanguage ?? this.streamingLanguage,
      oauthClientId: oauthClientId ?? this.oauthClientId,
      oauthClientSecret: oauthClientSecret ?? this.oauthClientSecret,
      lastVolume: lastVolume ?? this.lastVolume,
      lastSpeed: lastSpeed ?? this.lastSpeed,
      uiScale: uiScale ?? this.uiScale,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'themeMode': themeMode.name,
        'colorSource': colorSource.name,
        'seedColorIndex': seedColorIndex,
        'useMaterialExpressive': useMaterialExpressive,
        'audioQuality': audioQuality.name,
        'playerLayout': playerLayout.name,
        'showLyricsInPlayer': showLyricsInPlayer,
        'autoPlayNext': autoPlayNext,
        'streamingRegion': streamingRegion,
        'streamingLanguage': streamingLanguage,
        'oauthClientId': oauthClientId,
        'oauthClientSecret': oauthClientSecret,
        'lastVolume': lastVolume,
        'lastSpeed': lastSpeed,
        'uiScale': uiScale,
      };

  String encode() => jsonEncode(toJson());

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      themeMode: ThemeModePreference.fromName(json['themeMode'] as String?),
      colorSource: ColorSource.fromName(json['colorSource'] as String?),
      seedColorIndex: (json['seedColorIndex'] as num?)?.toInt() ?? 0,
      useMaterialExpressive: json['useMaterialExpressive'] as bool? ?? true,
      audioQuality: AudioQuality.fromName(json['audioQuality'] as String?),
      playerLayout: PlayerLayout.fromName(json['playerLayout'] as String?),
      showLyricsInPlayer: json['showLyricsInPlayer'] as bool? ?? true,
      autoPlayNext: json['autoPlayNext'] as bool? ?? true,
      streamingRegion: json['streamingRegion'] as String? ?? 'RU',
      streamingLanguage: json['streamingLanguage'] as String? ?? 'ru',
      oauthClientId: json['oauthClientId'] as String? ?? '',
      oauthClientSecret: json['oauthClientSecret'] as String? ?? '',
      lastVolume: (json['lastVolume'] as num?)?.toDouble() ?? 1.0,
      lastSpeed: (json['lastSpeed'] as num?)?.toDouble() ?? 1.0,
      uiScale: (json['uiScale'] as num?)?.toDouble() ?? 0.0,
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
