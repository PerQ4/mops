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
    this.skipped = 0,
    this.playlistId,
    this.error,
  });

  final String name;
  final int matched;
  final List<SpotifyTrack> missed;

  /// Записи Spotify, которые переносить нечем: эпизоды подкастов, локальные
  /// файлы и удалённые треки. Не путать с [missed] — там песни, которых не
  /// нашлось в YouTube Music.
  final int skipped;
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
    // Чтение плейлиста — единственный шаг, где сбой Spotify не должен валить
    // весь перенос: показываем понятную причину именно по этому плейлисту.
    final ({List<SpotifyTrack> tracks, int skipped}) fetched;
    try {
      fetched = await spotify.playlistTracks(playlist.id);
    } on SpotifyException catch (error) {
      return ImportResult(
        name: playlist.name,
        matched: 0,
        missed: const <SpotifyTrack>[],
        error: error.message,
      );
    }

    final List<SpotifyTrack> tracks = fetched.tracks;
    if (tracks.isEmpty) {
      return ImportResult(
        name: playlist.name,
        matched: 0,
        missed: const <SpotifyTrack>[],
        skipped: fetched.skipped,
        error: fetched.skipped > 0
            // Пустой ответ и «в плейлисте только подкасты/локальные файлы» —
            // разные вещи, и советы пользователю тоже разные.
            ? 'В плейлисте только подкасты и локальные файлы — переносить нечего.'
            : 'Spotify не отдал треки этого плейлиста.',
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
        skipped: fetched.skipped,
        error: 'Ни один трек не нашёлся в YouTube Music.',
      );
    }

    // Плейлист создаём сразу с треками: так меньше запросов, а приватность
    // оставляем приватной — пользователь сам решит, делать ли её общей.
    final String? playlistId;
    try {
      playlistId = await library.createPlaylist(
        title: playlist.name,
        videoIds: videoIds.take(100).toList(),
      );
    } on Object catch (error) {
      return ImportResult(
        name: playlist.name,
        matched: 0,
        missed: missed,
        skipped: fetched.skipped,
        error: 'Плейлист создать не удалось: $error',
      );
    }
    if (playlistId == null) {
      return ImportResult(
        name: playlist.name,
        matched: videoIds.length,
        missed: missed,
        skipped: fetched.skipped,
        error: 'Треки нашлись, но плейлист создать не удалось.',
      );
    }

    // YouTube принимает не больше сотни треков за раз: остальное докладываем
    // отдельными запросами. Сбой на середине не должен «терять» уже созданный
    // плейлист — сообщаем, что добавилось частично.
    for (int i = 100; i < videoIds.length; i += 100) {
      try {
        await library.addToPlaylist(
          playlistId,
          videoIds.sublist(i, math.min(i + 100, videoIds.length)),
        );
      } on Object catch (error) {
        return ImportResult(
          name: playlist.name,
          matched: i,
          missed: missed,
          skipped: fetched.skipped,
          playlistId: playlistId,
          error: 'Плейлист создан, но часть треков не добавилась: $error',
        );
      }
    }

    return ImportResult(
      name: playlist.name,
      matched: videoIds.length,
      missed: missed,
      skipped: fetched.skipped,
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
