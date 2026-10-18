import 'dart:convert';

import 'package:meta/meta.dart';

import '../models/models.dart';

/// Ключ, под которым снимок очереди лежит в `shared_preferences`.
///
/// Отдельно от строки настроек: снимок переписывается по таймеру, пока идёт
/// воспроизведение, а строку настроек читают и пишут на каждое изменение
/// любой настройки. Вместе они гоняли бы очередь по диску лишний раз.
const String kQueueSnapshotKey = 'mops.queue.v1';

/// Компактный снимок очереди плеера для восстановления между запусками.
///
/// Хранит только то, что нужно нарисовать очередь и подсветить текущий трек:
/// идентификатор, название, исполнителя, длительность, обложку, `playlistId` и
/// признак видео. Остальные метаданные подтянутся из источника, когда трек
/// понадобится, — для восстановления они не нужны, а полный трек в разы тяжелее.
///
/// `isVideo` здесь не ради отрисовки, а ради действий над треком: у
/// восстановленного клипа без него пропадал бы пункт «Смотреть клип».
@immutable
class QueueSnapshot {
  const QueueSnapshot({
    required this.tracks,
    required this.index,
    this.position = Duration.zero,
  });

  final List<Track> tracks;

  /// Индекс текущего трека в [tracks]; -1 — ничего не выбрано.
  final int index;

  /// Позиция текущего трека на момент снимка.
  final Duration position;

  bool get isEmpty => tracks.isEmpty;

  Track? get current =>
      (index >= 0 && index < tracks.length) ? tracks[index] : null;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': 1,
        'index': index,
        'position': position.inMilliseconds,
        'tracks': tracks.map(_trackToJson).toList(growable: false),
      };

  String encode() => jsonEncode(toJson());

  /// Разбирает снимок; при битом JSON или мусоре возвращает `null`.
  ///
  /// Ошибки наружу не пробрасываются: испорченный снимок — это отсутствие
  /// снимка, а не повод не запустить приложение. Одна битая запись трека тоже
  /// не обнуляет снимок — она просто пропускается.
  static QueueSnapshot? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return _fromJson(decoded);
    } on FormatException {
      return null;
    } on Object {
      return null;
    }
  }

  static QueueSnapshot? _fromJson(Map<String, dynamic> json) {
    final dynamic rawTracks = json['tracks'];
    if (rawTracks is! List) return null;

    final List<Track> tracks = <Track>[];
    for (final dynamic item in rawTracks) {
      if (item is! Map<String, dynamic>) continue;
      final Track? track = _trackFromJson(item);
      if (track != null) tracks.add(track);
    }
    if (tracks.isEmpty) return null;

    final dynamic rawIndex = json['index'];
    final int index = rawIndex is num ? rawIndex.toInt() : -1;
    final dynamic rawPosition = json['position'];
    final Duration position = rawPosition is num
        ? Duration(milliseconds: rawPosition.toInt())
        : Duration.zero;

    return QueueSnapshot(
      tracks: tracks,
      // Индекс вне очереди (снимок битый) — сбрасываем на «ничего не выбрано»,
      // а не подсвечиваем случайный трек.
      index: (index >= 0 && index < tracks.length) ? index : -1,
      position: position < Duration.zero ? Duration.zero : position,
    );
  }
}

/// Сериализация трека для снимка. Живёт здесь, а не в `models.dart`: этот
/// формат нужен только очереди, и менять ради него модели незачем.
Map<String, dynamic> _trackToJson(Track track) => <String, dynamic>{
      'id': track.id,
      'title': track.title,
      if (track.artists.isNotEmpty)
        'artist': track.artists.map((ArtistRef a) => a.name).join(', '),
      if (track.duration > Duration.zero)
        'duration': track.duration.inMilliseconds,
      if (track.artwork != null) 'artwork': track.artwork,
      if (track.playlistId != null) 'playlistId': track.playlistId,
      // Пишем только когда видео: у обычной песни поле отсутствует, как и
      // раньше, — снимок для них не растёт.
      if (track.isVideo) 'video': true,
    };

Track? _trackFromJson(Map<String, dynamic> json) {
  final dynamic id = json['id'];
  if (id is! String || id.isEmpty) return null;

  final dynamic title = json['title'];
  final dynamic artist = json['artist'];
  final dynamic rawDuration = json['duration'];
  final dynamic artwork = json['artwork'];
  final dynamic playlistId = json['playlistId'];
  final dynamic video = json['video'];

  return Track(
    id: id,
    title: title is String ? title : '',
    artists: (artist is String && artist.isNotEmpty)
        ? <ArtistRef>[ArtistRef(name: artist)]
        : const <ArtistRef>[],
    duration: rawDuration is num
        ? Duration(milliseconds: rawDuration.toInt())
        : Duration.zero,
    thumbnails: (artwork is String && artwork.isNotEmpty)
        ? <Thumbnail>[Thumbnail(url: artwork)]
        : const <Thumbnail>[],
    playlistId:
        (playlistId is String && playlistId.isNotEmpty) ? playlistId : null,
    isVideo: video == true,
  );
}
