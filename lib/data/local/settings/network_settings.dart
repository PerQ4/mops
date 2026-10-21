import '../../../core/net/anti_dpi.dart';

/// Сеть: режим экономии трафика и обход блокировок.
class NetworkSettings {
  const NetworkSettings({
    this.lowDataMode = false,
    this.bypass = const AntiDpiConfig(),
    this.autoDetectProxy = true,
  });

  /// Режим низкого расхода трафика.
  ///
  /// Как `LowDataModeKey` в ArchiveTune, только без слежения за типом сети:
  /// решение всегда за пользователем (на десктопе лимитный интернет бывает и
  /// по Wi-Fi). Включённый режим понижает запрашиваемый размер обложек и
  /// крупные превью видео (`i.ytimg.com`) не запрашивает вовсе — см.
  /// `core/utils/artwork_urls.dart`.
  final bool lowDataMode;

  /// Обход блокировок провайдера (подмена хоста, прокси).
  final AntiDpiConfig bypass;

  /// Искать ли локальный прокси автоматически, чтобы заработал звук.
  ///
  /// Провайдер блокирует медиахосты отдельно, и подмена хоста их не обходит.
  /// Локальный прокси (v2rayA, v2rayN, Clash…) решает задачу целиком,
  /// поэтому приложение пробует найти его само.
  final bool autoDetectProxy;

  NetworkSettings copyWith({
    bool? lowDataMode,
    AntiDpiConfig? bypass,
    bool? autoDetectProxy,
  }) {
    return NetworkSettings(
      lowDataMode: lowDataMode ?? this.lowDataMode,
      bypass: bypass ?? this.bypass,
      autoDetectProxy: autoDetectProxy ?? this.autoDetectProxy,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'lowDataMode': lowDataMode,
    'bypass': bypass.toJson(),
    'autoDetectProxy': autoDetectProxy,
  };

  factory NetworkSettings.fromJson(Map<String, dynamic> json) {
    return NetworkSettings(
      lowDataMode: json['lowDataMode'] as bool? ?? false,
      bypass: json['bypass'] is Map<String, dynamic>
          ? AntiDpiConfig.fromJson(json['bypass'] as Map<String, dynamic>)
          : const AntiDpiConfig(),
      autoDetectProxy: json['autoDetectProxy'] as bool? ?? true,
    );
  }
}
