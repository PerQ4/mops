import '../models/models.dart';
import '../../core/innertube/innertube_client.dart';
import '../../core/innertube/renderer.dart';
import 'browse_parser.dart';

/// Что искать в YouTube Music.
enum SearchFilter {
  all('Всё', null),

  // Строки — protobuf-фильтры, которые понимает InnerTube.
  songs('Треки', 'Eg-KAQwIARAAGAAgACgAMABqChAEEAMQCRAFEAo='),
  albums('Альбомы', 'Eg-KAQwIABAAGAEgACgAMABqChAEEAMQCRAFEAo='),
  artists('Исполнители', 'Eg-KAQwIABAAGAAgASgAMABqChAEEAMQCRAFEAo='),
  playlists('Плейлисты', 'Eg-KAQwIABAAGAAgACgBMABqChAEEAMQCRAFEAo='),
  videos('Видео', 'Eg-KAQwIABABGAAgACgAMABqChAEEAMQCRAFEAo=');

  const SearchFilter(this.label, this.params);

  final String label;
  final String? params;
}

/// Публичные разделы YouTube Music.
enum ExploreSection {
  newReleases('Новые релизы', 'FEmusic_new_releases'),
  charts('Чарты', 'FEmusic_charts'),
  moods('Настроения', 'FEmusic_moods_and_genres'),
  podcasts('Подкасты', 'FEmusic_podcasts');

  const ExploreSection(this.label, this.browseId);

  final String label;
  final String browseId;
}

/// Источник контента YouTube Music.
///
/// Один код-путь и для гостевого режима, и для входа в аккаунт: на публичные
/// запросы `authenticated: false`, на персональные — `true`. Так парсеры
/// переиспользуются, а поведение остаётся предсказуемым.
class CatalogSource {
  CatalogSource(this._client);

  final InnerTubeClient _client;

  static const String _browseHome = 'FEmusic_home';
  static const String _browseExplore = 'FEmusic_explore';

  /// Главная страница (подборки, «для вас»).
  Future<List<BrowseSection>> home() async {
    final Map<String, dynamic> res = await _client.browse(
      _browseHome,
      // Если пользователь вошёл, главная становится персональной.
      authenticated: _client.hasAuth,
    );
    return BrowseParser.homeSections(res);
  }

  /// Раздел «Обзор» (новые релизы, чарты, настроения).
  Future<List<BrowseSection>> explore() async {
    final Map<String, dynamic> res = await _client.browse(_browseExplore);
    return BrowseParser.homeSections(res);
  }

  /// Произвольный публичный раздел.
  Future<List<BrowseSection>> browseSection(String browseId) async {
    final Map<String, dynamic> res = await _client.browse(browseId);
    return BrowseParser.homeSections(res);
  }

  // ----------------------------------------------------------------- поиск

  /// Общий поиск. Возвращает секции: «Треки», «Альбомы», «Исполнители»…
  Future<List<BrowseSection>> search(
    String query, {
    SearchFilter filter = SearchFilter.all,
  }) async {
    final Map<String, dynamic> res = await _client.search(
      query,
      params: filter.params,
    );
    return BrowseParser.sectionsFrom(res);
  }

  /// Подсказки по мере ввода.
  Future<List<String>> searchSuggestions(String query) async {
    if (query.trim().isEmpty) return const <String>[];
    final Map<String, dynamic> res = await _client.post(
      'music/get_search_suggestions',
      body: <String, dynamic>{'input': query},
    );
    return traverseStrings(res, <String>['query'])
        .where((String s) => s.isNotEmpty)
        .take(10)
        .toList();
  }

  // -------------------------------------------------------------- страницы

  /// Страница альбома.
  Future<Album> album(String albumId) async {
    final Map<String, dynamic> res = await _client.browse(albumId);
    final List<Track> tracks = _tracksFrom(res, fallbackPlaylistId: null);

    return Album(
      id: albumId,
      title: BrowseParser.pageTitle(res) ?? 'Альбом',
      artists: _artistsFromSubtitle(BrowseParser.pageSubtitle(res)),
      year: _yearFrom(BrowseParser.pageSubtitle(res)),
      thumbnails: BrowseParser.pageThumbnails(res),
      tracks: tracks,
      trackCount: tracks.isEmpty ? null : tracks.length,
      duration: _totalDuration(tracks),
      description: BrowseParser.pageDescription(res),
    );
  }

  /// Страница исполнителя.
  Future<Artist> artist(String artistId) async {
    final Map<String, dynamic> res = await _client.browse(artistId);
    final List<BrowseSection> sections = BrowseParser.sectionsFrom(res);

    final List<Track> topTracks = <Track>[];
    final List<Album> albums = <Album>[];
    final List<Album> singles = <Album>[];
    final List<Artist> related = <Artist>[];

    for (final BrowseSection section in sections) {
      final String title = section.title.toLowerCase();
      for (final BrowseItem item in section.items) {
        switch (item) {
          case TrackItem(:final Track track):
            if (title.contains('песн') ||
                title.contains('song') ||
                title.contains('трек')) {
              topTracks.add(track);
            }
          case AlbumItem(:final Album album):
            if (title.contains('сингл') || title.contains('single')) {
              singles.add(album);
            } else if (title.contains('альбом') || title.contains('album')) {
              albums.add(album);
            }
          case ArtistItem(:final Artist a):
            if (title.contains('похож') ||
                title.contains('related') ||
                title.contains('fan')) {
              related.add(a);
            }
          case PlaylistItem():
            break;
        }
      }
    }

    // «Популярные треки» часто лежат в musicShelfRenderer, который без заголовка
    // не попал в секции — добираем напрямую.
    if (topTracks.isEmpty) {
      topTracks.addAll(_tracksFrom(res, fallbackPlaylistId: null));
    }

    return Artist(
      id: artistId,
      name: BrowseParser.pageTitle(res) ?? 'Исполнитель',
      thumbnails: BrowseParser.pageThumbnails(res),
      description: BrowseParser.pageDescription(res),
      subscribers: BrowseParser.pageSubtitle(res),
      topTracks: topTracks,
      albums: albums,
      singles: singles,
      related: related,
    );
  }

  /// Страница плейлиста (в том числе чужого).
  Future<Playlist> playlist(String playlistId) async {
    final String browseId =
        playlistId.startsWith('VL') ? playlistId : 'VL$playlistId';

    final Map<String, dynamic> res = await _client.browse(browseId);
    final List<Track> tracks =
        _tracksFrom(res, fallbackPlaylistId: playlistId);

    return Playlist(
      id: playlistId,
      title: BrowseParser.pageTitle(res) ?? 'Плейлист',
      author: BrowseParser.pageSubtitle(res),
      description: BrowseParser.pageDescription(res),
      thumbnails: BrowseParser.pageThumbnails(res),
      tracks: tracks,
      trackCount: tracks.isEmpty ? null : tracks.length,
      duration: _totalDuration(tracks),
    );
  }

  // -------------------------------------------------------------- очередь

  /// Треки, которые YouTube предлагает после указанного.
  ///
  /// Используется, когда очередь закончилась: включаем «радио по треку»,
  /// как это делает YouTube Music.
  Future<List<Track>> autoplayQueue(String videoId) async {
    final Map<String, dynamic> res = await _client.next(videoId);

    final List<Track> tracks = <Track>[];
    for (final dynamic renderer in traverseList(
      res,
      <String>['playlistPanelVideoRenderer'],
    )) {
      final Track? track = _panelTrack(renderer);
      if (track != null && track.id != videoId) tracks.add(track);
    }
    return tracks;
  }

  Track? _panelTrack(dynamic renderer) {
    if (renderer is! Map) return null;
    final String? videoId = traverseString(renderer, <String>['videoId']);
    if (videoId == null || videoId.isEmpty) return null;

    final String title = traverseString(renderer, <String>['title', 'runs', 'text']) ??
        traverseString(renderer, <String>['title', 'simpleText']) ??
        'Без названия';

    final List<dynamic> byline = traverseList(renderer, <String>['longBylineText', 'runs'])
        .isNotEmpty
        ? traverseList(renderer, <String>['longBylineText', 'runs'])
        : traverseList(renderer, <String>['shortBylineText', 'runs']);

    final List<ArtistRef> artists = <ArtistRef>[];
    for (final dynamic run in byline) {
      if (run is! Map) continue;
      final String? name = textOf(run);
      if (name == null || name.trim() == '•' || name.trim().isEmpty) continue;
      final String? artistId = traverseString(run, <String>[
        'navigationEndpoint',
        'browseEndpoint',
        'browseId',
      ]);
      if (artistId == null) continue;
      artists.add(ArtistRef(name: name.trim(), id: artistId));
    }

    final List<Thumbnail> thumbs = <Thumbnail>[];
    for (final dynamic t in traverseList(renderer, <String>['thumbnail', 'thumbnails'])) {
      if (t is Map && t['url'] is String) {
        thumbs.add(Thumbnail(url: t['url'] as String));
      }
    }

    return Track(
      id: videoId,
      title: title,
      artists: artists,
      duration: parseDurationText(
            traverseString(renderer, <String>['lengthText', 'runs', 'text']),
          ) ??
          Duration.zero,
      thumbnails: thumbs,
    );
  }

  // --------------------------------------------------------------- тексты

  /// Текст песни: сначала пробуем синхронизированный, затем обычный.
  Future<Lyrics> lyrics(String videoId) async {
    try {
      final Map<String, dynamic> nextRes = await _client.next(videoId);

      // В watch-next есть вкладка «Текст»; её browseId ведёт на страницу текста.
      final List<dynamic> tabs =
          traverseList(nextRes, <String>['tabs', 'tabRenderer']);
      String? lyricsBrowseId;
      for (final dynamic tab in tabs) {
        final String? pageType = traverseString(tab, <String>[
          'endpoint',
          'browseEndpoint',
          'browseEndpointContextSupportedConfigs',
          'browseEndpointContextMusicConfig',
          'pageType',
        ]);
        if (pageType == 'MUSIC_PAGE_TYPE_TRACK_LYRICS') {
          lyricsBrowseId = traverseString(tab, <String>['browseId']);
          break;
        }
      }
      // Фолбэк: как в ytmusicapi — вторая вкладка.
      lyricsBrowseId ??= tabs.length > 1
          ? traverseString(tabs[1], <String>['browseId'])
          : null;

      if (lyricsBrowseId == null) return Lyrics.none;

      final Map<String, dynamic> lyricsRes =
          await _client.browse(lyricsBrowseId);

      final List<TimedLyric> timed = _parseTimedLyrics(lyricsRes);
      if (timed.isNotEmpty) {
        return Lyrics(timed: timed, plain: timed.map((TimedLyric l) => l.text).join('\n'));
      }

      final List<String> lines =
          traverseStrings(lyricsRes, <String>['description', 'runs', 'text']);
      final String plain = lines
          .where((String line) => line.trim().isNotEmpty)
          .join('\n')
          .trim();

      if (plain.isEmpty) return Lyrics.none;
      return Lyrics(plain: plain);
    } on Exception {
      // Текста может не быть — это не ошибка приложения.
      return Lyrics.none;
    }
  }

  List<TimedLyric> _parseTimedLyrics(Map<String, dynamic> response) {
    final dynamic data = traverse(response, <String>[
      'contents',
      'type',
      'lyricsData',
    ]);
    if (data is! Map) return const <TimedLyric>[];

    final List<TimedLyric> result = <TimedLyric>[];
    for (final dynamic line in traverseList(data, <String>['timedLyricsData'])) {
      if (line is! Map) continue;
      final String? text = textOf(line);
      final dynamic startMs = line['lyricLineStartTimeMs'];
      if (text == null || startMs is! num) continue;
      result.add(TimedLyric(
        time: Duration(milliseconds: startMs.toInt()),
        text: text.trim(),
      ));
    }
    return result;
  }

  // --------------------------------------------------------------- helpers

  List<Track> _tracksFrom(dynamic response, {String? fallbackPlaylistId}) {
    final List<Track> tracks = <Track>[];
    for (final dynamic renderer
        in traverseList(response, <String>['musicResponsiveListItemRenderer'])) {
      final Track? track =
          BrowseParser.responsiveItem(renderer, fallbackPlaylistId: fallbackPlaylistId);
      if (track != null) tracks.add(track);
    }
    return tracks;
  }

  List<ArtistRef> _artistsFromSubtitle(String? subtitle) {
    if (subtitle == null || subtitle.isEmpty) return const <ArtistRef>[];
    return subtitle
        .split('•')
        .map((String s) => s.trim())
        .where((String s) =>
            s.isNotEmpty && !RegExp(r'^(19|20)\d{2}$').hasMatch(s) && !s.contains('трек'))
        .map((String s) => ArtistRef(name: s))
        .toList();
  }

  String? _yearFrom(String? subtitle) {
    if (subtitle == null) return null;
    return RegExp(r'(19|20)\d{2}').firstMatch(subtitle)?.group(0);
  }

  Duration? _totalDuration(List<Track> tracks) {
    if (tracks.isEmpty) return null;
    Duration total = Duration.zero;
    for (final Track track in tracks) {
      total += track.duration;
    }
    return total == Duration.zero ? null : total;
  }
}
