import 'package:meta/meta.dart';

import '../../core/utils/artwork_urls.dart';

/// Обложка в конкретном размере.
@immutable
class Thumbnail {
  const Thumbnail({required this.url, this.width, this.height});

  final String url;
  final int? width;
  final int? height;

  @override
  bool operator ==(Object other) =>
      other is Thumbnail && other.url == url && other.width == width;

  @override
  int get hashCode => Object.hash(url, width);
}

/// Ссылка на исполнителя (может быть без id, если YouTube его не отдал).
@immutable
class ArtistRef {
  const ArtistRef({required this.name, this.id});

  final String name;
  final String? id;

  bool get isNavigable => id != null && id!.isNotEmpty;
}

/// Ссылка на альбом.
@immutable
class AlbumRef {
  const AlbumRef({required this.name, this.id});

  final String name;
  final String? id;

  bool get isNavigable => id != null && id!.isNotEmpty;
}

/// Утилиты выбора лучшей обложки.
extension ThumbnailListX on List<Thumbnail> {
  /// Обложка максимального размера (или последняя доступная).
  String? get best => _pick(_maxWidth);

  /// Обложка, подходящая под квадрат заданной стороны (для списков — меньше трафик).
  String? sized(int target) => _pick(target);

  /// Заведомо больше любой реальной обложки YouTube.
  static const int _maxWidth = 99999;

  String? _pick(int target) {
    if (isEmpty) return null;
    final List<Thumbnail> sorted = <Thumbnail>[...this]
      ..sort((Thumbnail a, Thumbnail b) =>
          (a.width ?? 0).compareTo(b.width ?? 0));
    for (final Thumbnail t in sorted) {
      if ((t.width ?? 0) >= target) return t.url;
    }
    return sorted.last.url;
  }
}

/// Трек (аудио, который можно воспроизвести).
@immutable
class Track {
  const Track({
    required this.id,
    required this.title,
    this.artists = const <ArtistRef>[],
    this.album,
    this.duration = Duration.zero,
    this.thumbnails = const <Thumbnail>[],
    this.isExplicit = false,
    this.playlistId,
    this.isVideo = false,
    this.played = false,
  });

  /// YouTube videoId — он же идентификатор потока.
  final String id;
  final String title;
  final List<ArtistRef> artists;
  final AlbumRef? album;
  final Duration duration;
  final List<Thumbnail> thumbnails;
  final bool isExplicit;

  /// Если трек получен из плейлиста — его id нужен для корректного queue/next.
  final String? playlistId;
  final bool isVideo;

  /// Отмечался ли трек как прослушанный (для отображения в плейлистах).
  final bool played;

  String get artistLine =>
      artists.isEmpty ? 'Неизвестный исполнитель' : artists.map((ArtistRef a) => a.name).join(', ');

  String? get artwork => thumbnails.best;

  /// Крупная обложка для открытого вида: размер переписывается в адресе,
  /// поэтому картинка не растягивается из мелкого превью.
  String? artworkLarge(int size) => artworkAt(size);

  /// Обложка запрошенного размера.
  String? artworkAt(int size) {
    final String? url = thumbnails.best;
    if (url == null) return null;
    return upgradeArtwork(url, size);
  }

  /// Запасные варианты — если максимального превью у видео нет.
  List<String> artworkFallbacks(int size) {
    final String? url = thumbnails.best;
    if (url == null) return const <String>[];
    return artworkVariants(url, size);
  }

  Track copyWith({
    bool? played,
    List<ArtistRef>? artists,
    List<Thumbnail>? thumbnails,
    AlbumRef? album,
  }) => Track(
        id: id,
        title: title,
        artists: artists ?? this.artists,
        album: album ?? this.album,
        duration: duration,
        thumbnails: thumbnails ?? this.thumbnails,
        isExplicit: isExplicit,
        playlistId: playlistId,
        isVideo: isVideo,
        played: played ?? this.played,
      );

  @override
  bool operator ==(Object other) =>
      other is Track && other.id == id && other.playlistId == playlistId;

  @override
  int get hashCode => Object.hash(id, playlistId);
}

/// Альбом.
@immutable
class Album {
  const Album({
    required this.id,
    required this.title,
    this.artists = const <ArtistRef>[],
    this.year,
    this.thumbnails = const <Thumbnail>[],
    this.tracks = const <Track>[],
    this.trackCount,
    this.duration,
    this.description,
    this.audioPlaylistId,
  });

  final String id;
  final String title;
  final List<ArtistRef> artists;
  final String? year;
  final List<Thumbnail> thumbnails;
  final List<Track> tracks;
  final int? trackCount;
  final Duration? duration;
  final String? description;

  /// Звуковой id плейлиста альбома (`OLAK5uy_…`).
  ///
  /// Нужен для сохранения альбома в библиотеку: YouTube принимает там
  /// `target.playlistId`, а не browse-идентификатор страницы (`MPREb_…`).
  /// `null`, если YouTube не вернул кнопку «слушать» — тогда сохранить нельзя.
  final String? audioPlaylistId;

  String get artistLine => artists.map((ArtistRef a) => a.name).join(', ');
  String? get artwork => thumbnails.best;
}

/// Исполнитель.
@immutable
class Artist {
  const Artist({
    required this.id,
    required this.name,
    this.thumbnails = const <Thumbnail>[],
    this.description,
    this.subscribers,
    this.topTracks = const <Track>[],
    this.albums = const <Album>[],
    this.singles = const <Album>[],
    this.related = const <Artist>[],
  });

  final String id;
  final String name;
  final List<Thumbnail> thumbnails;
  final String? description;
  final String? subscribers;
  final List<Track> topTracks;
  final List<Album> albums;
  final List<Album> singles;
  final List<Artist> related;

  String? get artwork => thumbnails.best;
}

/// Плейлист.
@immutable
class Playlist {
  const Playlist({
    required this.id,
    required this.title,
    this.author,
    this.description,
    this.thumbnails = const <Thumbnail>[],
    this.tracks = const <Track>[],
    this.trackCount,
    this.duration,
  });

  final String id;
  final String title;
  final String? author;
  final String? description;
  final List<Thumbnail> thumbnails;
  final List<Track> tracks;
  final int? trackCount;
  final Duration? duration;

  String? get artwork => thumbnails.best;
}

/// Элемент карусели на главной: может быть треком, альбомом, плейлистом и т.д.
sealed class BrowseItem {
  const BrowseItem();

  String get title;
  List<Thumbnail> get thumbnails;
  String? get image => thumbnails.best;
}

class TrackItem extends BrowseItem {
  const TrackItem(this.track);

  final Track track;

  @override
  String get title => track.title;

  @override
  List<Thumbnail> get thumbnails => track.thumbnails;
}

class AlbumItem extends BrowseItem {
  const AlbumItem(this.album);

  final Album album;

  @override
  String get title => album.title;

  @override
  List<Thumbnail> get thumbnails => album.thumbnails;
}

class ArtistItem extends BrowseItem {
  const ArtistItem(this.artist);

  final Artist artist;

  @override
  String get title => artist.name;

  @override
  List<Thumbnail> get thumbnails => artist.thumbnails;
}

class PlaylistItem extends BrowseItem {
  const PlaylistItem(this.playlist);

  final Playlist playlist;

  @override
  String get title => playlist.title;

  @override
  List<Thumbnail> get thumbnails => playlist.thumbnails;
}

/// Секция главного экрана / раздела.
@immutable
class BrowseSection {
  const BrowseSection({
    required this.title,
    this.items = const <BrowseItem>[],
    this.subtitle,
    this.browseId,
    this.params,
  });

  final String title;
  final String? subtitle;
  final List<BrowseItem> items;
  final String? browseId;
  final String? params;
}

/// Слово синхронизированного текста — для «караоке»-подсветки.
@immutable
class TimedWord {
  const TimedWord({required this.time, required this.text, this.end});

  /// Начало слова. Есть всегда — по нему включается подсветка.
  final Duration time;
  final String text;

  /// Конец слова из TTML (`end`). Не все источники его отдают, поэтому null —
  /// это норма: конец тогда выводится из начала следующего слова или из конца
  /// строки (см. `lyrics_view.dart`). Ничего не выдумываем сверх данных.
  final Duration? end;
}

/// Строка синхронизированного текста.
@immutable
class TimedLyric {
  const TimedLyric({required this.time, required this.text, this.words});

  final Duration time;
  final String text;

  /// Пословная разметка (TTML Apple Music) — по ней строка подсвечивается
  /// слово за словом, как в ArchiveTune.
  final List<TimedWord>? words;

  bool get hasWords => words != null && words!.isNotEmpty;
}

/// Необязательные метаданные найденного текста — по ним считается
/// совместимость с играющим треком.
///
/// Базы отдают их не всегда: LRCLIB и KuGou присылают длительность и имена,
/// TTML — пометку перевода. Где данных нет, поле остаётся `null`, и оценка
/// просто не получает эти баллы (это не штраф: неизвестное — не значит неверное).
@immutable
class LyricsMatch {
  const LyricsMatch({
    this.title,
    this.artist,
    this.duration,
    this.hasTranslation = false,
  });

  /// Название, как его вернула база (может отличаться от нашего).
  final String? title;

  /// Исполнитель, как его вернула база.
  final String? artist;

  /// Длительность по данным базы.
  final Duration? duration;

  /// Есть ли в тексте отдельный перевод (в TTML — блок `x-translation`).
  final bool hasTranslation;
}

/// Текст песни: обычный, синхронизированный или отсутствует.
@immutable
class Lyrics {
  const Lyrics({this.plain, this.timed, this.source, this.match});

  final String? plain;
  final List<TimedLyric>? timed;
  final String? source;

  /// Метаданные для оценки совместимости; `null` — база их не дала.
  final LyricsMatch? match;

  bool get isEmpty => (plain == null || plain!.isEmpty) && (timed?.isEmpty ?? true);

  /// Годится ли текст для подсветки и автопрокрутки.
  ///
  /// Мало того, чтобы времена были: нужны хотя бы два **разных** и хотя бы
  /// одно ненулевое. Если все метки нулевые (так приходят субтитры без
  /// стартовых времён или битый синхротекст), подсветка «залипала» бы на
  /// последней строке, а прокрутка не сдвинулась бы ни на пиксель. В таком
  /// случае честнее показать обычный текст без выделения.
  bool get isSynced {
    final List<TimedLyric>? lines = timed;
    if (lines == null || lines.length < 2) return false;

    bool hasPositive = false;
    int distinct = 0;
    int? previous;
    for (final TimedLyric line in lines) {
      final int ms = line.time.inMilliseconds;
      if (ms > 0) hasPositive = true;
      if (ms != previous) distinct++;
      previous = ms;
    }
    return hasPositive && distinct >= 2;
  }

  static const Lyrics none = Lyrics();
}
