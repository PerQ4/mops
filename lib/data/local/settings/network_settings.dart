import '../../../core/net/anti_dpi.dart';
import 'json_read.dart';

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
      lowDataMode: readBool(json['lowDataMode'], false),
      bypass: _parseBypass(json['bypass']),
      autoDetectProxy: readBool(json['autoDetectProxy'], true),
    );
  }

  /// Разбор обхода DPI без падения.
  ///
  /// Внутри `AntiDpiConfig.fromJson` остались `as bool?`, поэтому неверный тип
  /// во вложенном объекте ловим здесь: один испорченный `bypass` не должен
  /// стоить всех настроек.
  static AntiDpiConfig _parseBypass(Object? value) {
    if (value is! Map) return const AntiDpiConfig();
    try {
      return AntiDpiConfig.fromJson(Map<String, dynamic>.from(value));
    } on Object {
      return const AntiDpiConfig();
    }
  }
}
