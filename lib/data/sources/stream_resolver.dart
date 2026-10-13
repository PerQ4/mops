import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../local/app_settings.dart';

/// Готовая к воспроизведению ссылка на аудиопоток.
@immutable
class ResolvedStream {
  const ResolvedStream({
    required this.url,
    required this.expiresAt,
    this.bitrateKbps,
    this.container,
    this.isLive = false,
  });

  final Uri url;
  final int? bitrateKbps;
  final String? container;
  final bool isLive;

  /// Ссылки googlevideo живут несколько часов; после этого нужен перезапрос.
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(
        expiresAt.subtract(const Duration(minutes: 5)),
      );
}

/// Контракт получения потока. Реализации можно менять независимо от UI.
abstract class StreamResolver {
  Future<ResolvedStream> resolve(String videoId, {required AudioQuality quality});
  void dispose();
}

/// Ошибка получения потока с понятным текстом.
class StreamResolutionException implements Exception {
  StreamResolutionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Реализация поверх `youtube_explode_dart`.
///
/// Библиотека сама разбирает `signatureCipher` (подпись ссылки), поэтому
/// приложение не зависит от внешних бинарников вроде `yt-dlp` — важно для
/// кроссплатформенности.
class YoutubeExplodeResolver implements StreamResolver {
  YoutubeExplodeResolver({YoutubeExplode? client})
      : _client = client ?? YoutubeExplode();

  final YoutubeExplode _client;

  /// Кэш: видео-ссылки живут часами, а `getManifest` — довольно дорогая операция.
  final Map<String, ResolvedStream> _cache = <String, ResolvedStream>{};

  @override
  Future<ResolvedStream> resolve(
    String videoId, {
    required AudioQuality quality,
  }) async {
    final String key = '$videoId:${quality.name}';
    final ResolvedStream? cached = _cache[key];
    if (cached != null && !cached.isExpired) return cached;

    try {
      final StreamManifest manifest =
          await _client.videos.streamsClient.getManifest(videoId);

      final List<AudioOnlyStreamInfo> audio = manifest.audioOnly.toList();
      if (audio.isEmpty) {
        throw StreamResolutionException(
          'У этого трека нет аудиодорожки — возможно, это видео без звука.',
        );
      }

      // Выбираем поток, ближайший к желаемому битрейту снизу вверх.
      audio.sort((AudioOnlyStreamInfo a, AudioOnlyStreamInfo b) =>
          a.bitrate.kiloBitsPerSecond.compareTo(b.bitrate.kiloBitsPerSecond));

      final int target = quality.targetKbps;
      AudioOnlyStreamInfo chosen = audio.first;
      for (final AudioOnlyStreamInfo stream in audio) {
        if (stream.bitrate.kiloBitsPerSecond <= target) {
          chosen = stream;
        } else {
          break;
        }
      }
      if (quality == AudioQuality.high) {
        // Для «максимума» всегда берём лучший доступный.
        chosen = audio.last;
      }

      final ResolvedStream resolved = ResolvedStream(
        url: chosen.url,
        bitrateKbps: chosen.bitrate.kiloBitsPerSecond.round(),
        container: chosen.container.name,
        expiresAt: DateTime.now().add(const Duration(hours: 5)),
      );
      _cache[key] = resolved;
      return resolved;
    } on StreamResolutionException {
      rethrow;
    } on Exception catch (error) {
      debugPrint('Не удалось получить поток для $videoId: $error');
      throw StreamResolutionException(
        'Не удалось получить аудиопоток. Проверьте соединение и попробуйте снова.',
      );
    }
  }

  @override
  void dispose() {
    _cache.clear();
    _client.close();
  }
}
