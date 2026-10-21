import 'package:meta/meta.dart';

import '../../data/models/models.dart';

/// Подкаст-шоу: шапка страницы и (если уже загружены) эпизоды.
///
/// Модели живут в фиче, а не в общем `data/models/models.dart`: там только
/// музыкальные сущности, а подкаст — отдельный вид контента со своей
/// страницей, подпиской и локальным прогрессом. Источник каталога импортирует
/// этот файл, поэтому моделям нельзя зависеть от Flutter — только от `models`.
@immutable
class PodcastShow {
  const PodcastShow({
    required this.browseId,
    this.playlistId,
    required this.title,
    this.author,
    this.authorId,
    this.description,
    this.thumbnails = const <Thumbnail>[],
    this.episodes = const <PodcastEpisode>[],
  });

  /// Идентификатор страницы (`MPSP…`): по нему запрашивается шоу.
  final String browseId;

  /// Звуковой id плейлиста шоу (`PL…`) — то, что принимает сервер при
  /// подписке (`like/like` с `target.playlistId`). YouTube отдаёт его не
  /// всегда; тогда [canSubscribe] ложно.
  final String? playlistId;

  final String title;
  final String? author;
  final String? authorId;
  final String? description;
  final List<Thumbnail> thumbnails;
  final List<PodcastEpisode> episodes;

  /// Ключ шоу в провайдерах и локальном хранилище.
  ///
  /// Предпочитаем звуковой id: он же нужен для подписки, поэтому состояние
  /// подписки и прогресс не зависят от того, пришло ли шоу из каталога
  /// (там бывает только browse-id) или из библиотеки.
  String get key =>
      (playlistId != null && playlistId!.isNotEmpty) ? playlistId! : browseId;

  String? get artwork => thumbnails.best;

  bool get canSubscribe => playlistId != null && playlistId!.isNotEmpty;

  PodcastShow copyWith({
    String? browseId,
    String? playlistId,
    String? title,
    String? author,
    String? authorId,
    String? description,
    List<Thumbnail>? thumbnails,
    List<PodcastEpisode>? episodes,
  }) {
    return PodcastShow(
      browseId: browseId ?? this.browseId,
      playlistId: playlistId ?? this.playlistId,
      title: title ?? this.title,
      author: author ?? this.author,
      authorId: authorId ?? this.authorId,
      description: description ?? this.description,
      thumbnails: thumbnails ?? this.thumbnails,
      episodes: episodes ?? this.episodes,
    );
  }
}

/// Один эпизод подкаста.
///
/// Внутри — обычный [Track]: плеер умеет играть эпизод тем же путём, что и
/// песню. Дата выхода и описание лежат рядом, а не в треке: они нужны только
/// списку эпизодов.
@immutable
class PodcastEpisode {
  const PodcastEpisode({
    required this.track,
    this.date,
    this.browseId,
    this.description,
  });

  final Track track;

  /// Дата выпуска, как её показывает YouTube («15 сент. 2026 г.»).
  final String? date;

  /// Страница эпизода (`MPED…`). Для воспроизведения не нужна, но пригодится
  /// для перехода к полному описанию.
  final String? browseId;

  final String? description;

  String get id => track.id;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'track': _trackToJson(track),
        if (date != null) 'date': date,
        if (browseId != null) 'browseId': browseId,
        if (description != null) 'description': description,
      };

  factory PodcastEpisode.fromJson(Map<String, dynamic> json) {
    final dynamic rawTrack = json['track'];
    if (rawTrack is! Map<String, dynamic>) {
      throw const FormatException('В записи эпизода нет трека');
    }
    return PodcastEpisode(
      track: _trackFromJson(rawTrack),
      date: json['date'] is String ? json['date'] as String : null,
      browseId: json['browseId'] is String ? json['browseId'] as String : null,
      description:
          json['description'] is String ? json['description'] as String : null,
    );
  }
}

/// Раздел обзора подкастов: карусель или полка с шоу.
@immutable
class PodcastSection {
  const PodcastSection({
    required this.title,
    this.shows = const <PodcastShow>[],
  });

  final String title;
  final List<PodcastShow> shows;
}

/// Запись локальной истории: «недавно игравшие» и прогресс эпизода.
///
/// Хранится полный снимок шоу и эпизода, а не одна ссылка: список недавних
/// должен показываться сразу после запуска, не дожидаясь ни сети, ни ответа
/// на запрос страницы шоу. Снимок трека достаточен, чтобы возобновить
/// воспроизведение, даже если шоу уже пропало из каталога.
@immutable
class PodcastEntry {
  const PodcastEntry({
    required this.showId,
    required this.showTitle,
    this.showPlaylistId,
    this.showArtwork,
    required this.episode,
    this.position = Duration.zero,
    required this.duration,
    required this.at,
  });

  /// Ключ шоу (см. [PodcastShow.key]).
  final String showId;
  final String showTitle;
  final String? showPlaylistId;
  final String? showArtwork;
  final PodcastEpisode episode;

  /// Докуда дослушан эпизод.
  final Duration position;

  /// Длительность на момент записи: у разбора страницы она бывает округлена
  /// до минут, а плеер знает точную — поэтому храним отдельно.
  final Duration duration;

  /// Время последнего прослушивания (мс от эпохи): по нему сортируются
  /// недавние и вытесняются старые записи.
  final int at;

  String get episodeId => episode.id;

  String? get artwork => episode.track.artwork ?? showArtwork;

  /// Доля прослушанного от 0 до 1.
  double get fraction {
    final int total = duration.inMilliseconds;
    if (total <= 0) return 0;
    return (position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  PodcastEntry copyWith({
    Duration? position,
    Duration? duration,
    int? at,
  }) {
    return PodcastEntry(
      showId: showId,
      showTitle: showTitle,
      showPlaylistId: showPlaylistId,
      showArtwork: showArtwork,
      episode: episode,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      at: at ?? this.at,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'showId': showId,
        'showTitle': showTitle,
        if (showPlaylistId != null) 'showPlaylistId': showPlaylistId,
        if (showArtwork != null) 'showArtwork': showArtwork,
        'episode': episode.toJson(),
        'positionMs': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'at': at,
      };

  factory PodcastEntry.fromJson(Map<String, dynamic> json) {
    final dynamic rawEpisode = json['episode'];
    final dynamic showId = json['showId'];
    final dynamic showTitle = json['showTitle'];
    if (rawEpisode is! Map<String, dynamic> ||
        showId is! String ||
        showId.isEmpty ||
        showTitle is! String) {
      throw const FormatException('Битая запись подкаста');
    }
    final dynamic position = json['positionMs'];
    final dynamic duration = json['durationMs'];
    return PodcastEntry(
      showId: showId,
      showTitle: showTitle,
      showPlaylistId: json['showPlaylistId'] is String
          ? json['showPlaylistId'] as String
          : null,
      showArtwork:
          json['showArtwork'] is String ? json['showArtwork'] as String : null,
      episode: PodcastEpisode.fromJson(rawEpisode),
      position: Duration(
        milliseconds: position is num ? position.toInt() : 0,
      ),
      duration: Duration(
        milliseconds: duration is num ? duration.toInt() : 0,
      ),
      at: json['at'] is num ? (json['at'] as num).toInt() : 0,
    );
  }
}

// ------------------------------------------------------------ снимок трека

/// Снимок трека для файла истории.
///
/// Храним только то, что нужно строке и плееру: id, название, длительность,
/// обложку и подпись автора. Полный `Track` сериализовать незачем — ссылки на
/// исполнителя и альбом в истории подкастов всё равно не используются.
Map<String, dynamic> _trackToJson(Track track) => <String, dynamic>{
      'id': track.id,
      'title': track.title,
      'durationMs': track.duration.inMilliseconds,
      if (track.artwork != null) 'artwork': track.artwork,
      if (track.artists.isNotEmpty)
        'artists': track.artists.map((ArtistRef a) => a.name).toList(),
    };

Track _trackFromJson(Map<String, dynamic> json) {
  final dynamic id = json['id'];
  final dynamic title = json['title'];
  if (id is! String || id.isEmpty || title is! String) {
    throw const FormatException('Битый снимок трека');
  }
  final dynamic duration = json['durationMs'];
  final dynamic artwork = json['artwork'];
  final dynamic artists = json['artists'];
  return Track(
    id: id,
    title: title,
    duration: Duration(
      milliseconds: duration is num ? duration.toInt() : 0,
    ),
    thumbnails: artwork is String && artwork.isNotEmpty
        ? <Thumbnail>[Thumbnail(url: artwork)]
        : const <Thumbnail>[],
    artists: artists is List
        ? artists
            .whereType<String>()
            .map((String name) => ArtistRef(name: name))
            .toList(growable: false)
        : const <ArtistRef>[],
  );
}
