import 'dart:math' as math;

import '../models/models.dart';
import 'catalog_source.dart';
import 'library_source.dart';
import 'spotify_client.dart';

/// Итог переноса одного плейлиста.
class ImportResult {
  const ImportResult({
    required this.name,
    required this.matched,
    required this.missed,
    this.playlistId,
    this.error,
  });

  final String name;
  final int matched;
  final List<SpotifyTrack> missed;
  final String? playlistId;
  final String? error;
}

/// Перенос библиотеки из Spotify в YouTube Music.
///
/// Как это работает: треки читаются из Spotify, затем каждый ищется в
/// YouTube Music по строке «исполнитель название». Найденные добавляются
/// в новый плейлист — с тем же названием, что и в Spotify. Что не нашлось,
/// показываем списком: обычно это редкие записи и региональные издания.
class SpotifyImporter {
  SpotifyImporter({
    required this.spotify,
    required this.catalog,
    required this.library,
  });

  final SpotifyClient spotify;
  final CatalogSource catalog;
  final LibrarySource library;

  /// Переносит плейлист. [onProgress] сообщает, сколько треков обработано.
  Future<ImportResult> importPlaylist(
    SpotifyPlaylist playlist, {
    void Function(int done, int total)? onProgress,
  }) async {
    final List<SpotifyTrack> tracks = await spotify.playlistTracks(playlist.id);
    if (tracks.isEmpty) {
      return ImportResult(
        name: playlist.name,
        matched: 0,
        missed: const <SpotifyTrack>[],
        error: 'В плейлисте нет треков или Spotify его не отдал.',
      );
    }

    final List<String> videoIds = <String>[];
    final List<SpotifyTrack> missed = <SpotifyTrack>[];

    for (int i = 0; i < tracks.length; i++) {
      final SpotifyTrack track = tracks[i];
      final String? videoId = await _findOnYoutube(track);
      if (videoId == null) {
        missed.add(track);
      } else if (!videoIds.contains(videoId)) {
        // Повторы пропускаем: в YouTube Music один и тот же трек может
        // встретиться в плейлисте дважды, и это выглядит как ошибка.
        videoIds.add(videoId);
      }
      onProgress?.call(i + 1, tracks.length);
    }

    if (videoIds.isEmpty) {
      return ImportResult(
        name: playlist.name,
        matched: 0,
        missed: missed,
        error: 'Ни один трек не нашёлся в YouTube Music.',
      );
    }

    // Плейлист создаём сразу с треками: так меньше запросов, а приватность
    // оставляем приватной — пользователь сам решит, делать ли её общей.
    final String? playlistId = await library.createPlaylist(
      title: playlist.name,
      videoIds: videoIds.take(100).toList(),
    );
    if (playlistId == null) {
      return ImportResult(
        name: playlist.name,
        matched: videoIds.length,
        missed: missed,
        error: 'Треки нашлись, но плейлист создать не удалось.',
      );
    }

    // YouTube принимает не больше сотни треков за раз: остальное докладываем
    // отдельными запросами.
    for (int i = 100; i < videoIds.length; i += 100) {
      await library.addToPlaylist(
        playlistId,
        videoIds.sublist(i, math.min(i + 100, videoIds.length)),
      );
    }

    return ImportResult(
      name: playlist.name,
      matched: videoIds.length,
      missed: missed,
      playlistId: playlistId,
    );
  }

  /// Ищет трек в YouTube Music и возвращает его идентификатор.
  Future<String?> _findOnYoutube(SpotifyTrack track) async {
    try {
      final List<BrowseSection> sections =
          await catalog.search(track.query);
      for (final BrowseSection section in sections) {
        for (final BrowseItem item in section.items) {
          if (item is TrackItem) return item.track.id;
        }
      }
    } on Object {
      // Не нашлось или поиск не ответил — трек попадёт в список ненайденных.
    }
    return null;
  }
}
