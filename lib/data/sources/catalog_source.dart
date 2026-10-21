import 'dart:convert';
import 'dart:io';

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

/// Что прятать в выдаче каталога и поиска и какой длины отдавать топы.
///
/// Живёт в источнике каталога, а не в `AppSettings`: `catalog_source.dart`
/// импортируют консольные инструменты (`dart run tool/...`), а `app_settings`
/// тянет за собой Flutter. Значение одно на класс, и его ставит слой состояния
/// (`SettingsController`): источник каталога создаётся без настроек
/// (`catalogSourceProvider`), поэтому передать их в конструктор нечем.
class ContentFilter {
  const ContentFilter({
    this.hideExplicit = false,
    this.hideVideo = false,
    this.topSize = 50,
  });

  /// Прятать explicit-треки (мат).
  final bool hideExplicit;

  /// Прятать клипы (видео).
  final bool hideVideo;

  /// Сколько элементов оставлять в полке топа или чарта.
  final int topSize;

  /// Есть ли что прятать: если нет, полки остаются нетронутыми.
  bool get hidesAnything => hideExplicit || hideVideo;
}

/// Профиль клиента, которым запрашиваются субтитры.
///
/// Субтитры отдаёт только «плеер» мобильного/очкового клиента; веб-клиент
/// (`WEB_REMIX`) отвечает `UNPLAYABLE` и дорожек не присылает. Значения взяты
/// из `youtube_clients.dart`, но продублированы здесь намеренно: тот файл
/// тянет за собой настройки и Flutter, а `catalog_source.dart` импортируют
/// консольные инструменты, которые запускаются обычным `dart run`.
const String _captionClientName = 'ANDROID_VR';
const String _captionClientVersion = '1.65.10';
const String _captionClientNumericId = '28';
const String _captionUserAgent =
    'com.google.android.apps.youtube.vr.oculus/1.65.10 '
    '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';

/// Источник контента YouTube Music.
///
/// Один код-путь и для гостевого режима, и для входа в аккаунт: на публичные
/// запросы `authenticated: false`, на персональные — `true`. Так парсеры
/// переиспользуются, а поведение остаётся предсказуемым.
class CatalogSource {
  CatalogSource(this._client);

  final InnerTubeClient _client;

  /// Фильтр содержимого, общий для всех источников каталога. Ставит его слой
  /// состояния при чтении и изменении настроек — см. [ContentFilter].
  static ContentFilter contentFilter = const ContentFilter();

  /// Id исполнителей, которых пользователь заблокировал.
  ///
  /// Как и [contentFilter], живёт статикой: источник каталога создаётся без
  /// настроек, а `catalog_source.dart` импортируют консольные инструменты и не
  /// должны тянуть Flutter. Слой состояния публикует список до первого запроса
  /// каталога, поэтому фильтр работает уже на стартовом экране.
  ///
  /// Сравнение только по id: одно и то же имя YouTube отдаёт с разными
  /// написаниями, а у разных исполнителей имена совпадают — блокировка по
  /// строке промахивалась бы в обе стороны.
  static Set<String> blockedArtistIds = const <String>{};

  /// Готовность списка блокировок: пока файл не прочитан, каталог не
  /// запрашивается.
  ///
  /// Без ожидания первый ответ (главная, «Мне нравится») приходил бы
  /// нефильтрованным и на мгновение показывал заблокированных исполнителей,
  /// после чего список дёргался бы. Ошибку чтения глотаем: нет списка —
  /// значит, нечего скрывать, и это не повод не показать каталог.
  static Future<void>? blockedArtistsReady;

  /// Заблокирован ли исполнитель с этим id. `null` и пустая строка — нет.
  static bool isArtistBlocked(String? artistId) {
    if (artistId == null || artistId.isEmpty) return false;
    return blockedArtistIds.contains(artistId);
  }

  static const String _browseHome = 'FEmusic_home';
  static const String _browseExplore = 'FEmusic_explore';

  /// Главная страница: порция секций и токен следующей порции.
  ///
  /// `continuation == null` — первый запрос. Если ответ содержит токен, его
  /// нужно передать сюда же, чтобы получить ещё секции: YouTube Music отдаёт
  /// главную порциями, как ленту. Проверено на живом ответе — первая порция
  /// содержит 2 секции и токен, каждая следующая ещё по несколько секций,
  /// пока токен не пропадёт.
  ///
  /// Возвращается записью, а не парой позиционных значений: у вызывающего
  /// кода имена полей читаются лучше, и не нужно помнить порядок.
  Future<({List<BrowseSection> sections, String? continuation})> homePage({
    String? continuation,
  }) async {
    await _waitForBlocked();
    final Map<String, dynamic> res = await _client.browse(
      _browseHome,
      continuation: continuation,
      // Если пользователь вошёл, главная становится персональной. Для порций
      // продолжения авторизация должна быть той же, что и у первого запроса.
      authenticated: _client.hasAuth,
    );
    return (
      sections: _applyContentFilter(BrowseParser.homeSections(res)),
      continuation: BrowseParser.continuationToken(res),
    );
  }

  /// Главная страница (подборки, «для вас»).
  ///
  /// Оставлен для мест, которым нужны только секции: это первая порция
  /// [homePage]. Кто хочет докручивать ленту, должен брать [homePage].
  Future<List<BrowseSection>> home() async {
    return (await homePage()).sections;
  }

  /// Раздел «Обзор» (новые релизы, чарты, настроения).
  Future<List<BrowseSection>> explore() async {
    await _waitForBlocked();
    final Map<String, dynamic> res = await _client.browse(_browseExplore);
    return _applyContentFilter(BrowseParser.homeSections(res), limitTop: true);
  }

  /// Произвольный публичный раздел.
  ///
  /// Чарты и топы обрезаются до длины из настроек: серверу длину не передать,
  /// поэтому полку укорачиваем уже после разбора.
  Future<List<BrowseSection>> browseSection(String browseId) async {
    await _waitForBlocked();
    final Map<String, dynamic> res = await _client.browse(browseId);
    return _applyContentFilter(BrowseParser.homeSections(res), limitTop: true);
  }

  /// Настроения и жанры — подписи категорий для чипов главной.
  ///
  /// Отдельный разбор: на этой странице YouTube отдаёт не полки, а сетку
  /// кнопок `musicNavigationButtonRenderer`, которых общий разбор секций не
  /// знает. Берём из кнопки только подпись: конкретную категорию YouTube
  /// открывает по `params` из той же кнопки, а перехода на произвольный раздел
  /// с параметрами в приложении нет — чип открывает поиск по названию, как и
  /// прежний ряд настроений. Порядок и повторы — как их вернул YouTube.
  Future<List<String>> moodCategories() async {
    final Map<String, dynamic> res =
        await _client.browse(ExploreSection.moods.browseId);

    final List<String> titles = <String>[];
    final Set<String> seen = <String>{};
    for (final dynamic button
        in traverseList(res, <String>['musicNavigationButtonRenderer'])) {
      if (button is! Map) continue;
      final String title =
          (textOf(button['buttonText']) ?? textOf(button['text']) ?? '').trim();
      if (title.isEmpty) continue;
      if (seen.add(title)) titles.add(title);
    }
    return titles;
  }

  // ----------------------------------------------------------------- поиск

  /// Общий поиск. Возвращает секции: «Треки», «Альбомы», «Исполнители»…
  Future<List<BrowseSection>> search(
    String query, {
    SearchFilter filter = SearchFilter.all,
  }) async {
    await _waitForBlocked();
    final Map<String, dynamic> res = await _client.search(
      query,
      params: filter.params,
    );
    return _applyContentFilter(BrowseParser.sectionsFrom(res));
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
    await _waitForBlocked();
    final Map<String, dynamic> res = await _client.browse(albumId);
    // Исполнители шапки: у новой разметки они в `straplineTextOne`, а не
    // в подзаголовке (см. `BrowseParser.pageArtists`). Если шапка старого
    // вида, остаётся прежний путь — разбор подзаголовка.
    List<ArtistRef> albumArtists = BrowseParser.pageArtists(res);
    if (albumArtists.isEmpty) {
      albumArtists = _artistsFromSubtitle(BrowseParser.pageSubtitle(res));
    }
    final List<Thumbnail> albumThumbs = BrowseParser.pageThumbnails(res);
    // В списке треков альбома у строк часто нет ни исполнителя, ни обложки —
    // они известны из шапки. Подставляем их, иначе в списке стоит
    // «Неизвестный исполнитель» и пустая картинка.
    final List<Track> tracks = _withHeaderFallback(
      _tracksFrom(res, fallbackPlaylistId: null),
      artists: albumArtists,
      thumbnails: albumThumbs,
    ).where((Track track) => !_trackBlocked(track)).toList(growable: false);

    return Album(
      id: albumId,
      title: BrowseParser.pageTitle(res) ?? 'Альбом',
      artists: albumArtists,
      year: _yearFrom(BrowseParser.pageSubtitle(res)),
      thumbnails: albumThumbs,
      tracks: tracks,
      trackCount: tracks.isEmpty ? null : tracks.length,
      duration: _totalDuration(tracks),
      description: BrowseParser.pageDescription(res),
      // Звуковой id плейлиста альбома — по нему альбом сохраняется
      // в библиотеку (см. `LibrarySource.setSaved`).
      audioPlaylistId: _audioPlaylistId(res, tracks),
    );
  }

  /// Звуковой id плейлиста альбома (`OLAK5uy_…`).
  ///
  /// Основной источник — кнопка «слушать» в шапке страницы. Запасной — строки
  /// треков: у них тот же id лежит в кнопке воспроизведения. Запасной берём
  /// только с ожидаемым префиксом: иначе туда мог бы попасть чужой id
  /// (например, радио), и мутация «сохранить» ушла бы не туда.
  String? _audioPlaylistId(Map<String, dynamic> res, List<Track> tracks) {
    final String? fromHeader = BrowseParser.albumAudioPlaylistId(res);
    if (fromHeader != null && fromHeader.isNotEmpty) return fromHeader;

    for (final Track track in tracks) {
      final String? id = track.playlistId;
      if (id != null && id.startsWith('OLAK5')) return id;
    }
    return null;
  }

  /// Подставляет трекам исполнителя и обложку из шапки страницы, если у самих
  /// строк их нет: в альбомах и «популярных треках» YouTube их часто опускает.
  List<Track> _withHeaderFallback(
    List<Track> tracks, {
    required List<ArtistRef> artists,
    required List<Thumbnail> thumbnails,
  }) {
    if (tracks.isEmpty) return tracks;
    return tracks.map((Track track) {
      final bool needArtists = track.artists.isEmpty && artists.isNotEmpty;
      final bool needThumbs = track.thumbnails.isEmpty && thumbnails.isNotEmpty;
      if (!needArtists && !needThumbs) return track;
      return track.copyWith(
        artists: needArtists ? artists : null,
        thumbnails: needThumbs ? thumbnails : null,
      );
    }).toList(growable: false);
  }

  /// Страница исполнителя.
  Future<Artist> artist(String artistId) async {
    await _waitForBlocked();
    // Страницу самого заблокированного исполнителя не прячем: на ней стоит
    // плашка «исполнитель заблокирован» с кнопкой разблокировки. Если бы мы
    // отфильтровали всё содержимое, разблокировать было бы неоткуда.
    final bool pageBlocked = isArtistBlocked(artistId);
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
            if ((title.contains('песн') ||
                    title.contains('song') ||
                    title.contains('трек')) &&
                _keepTrack(track)) {
              topTracks.add(track);
            }
          case AlbumItem(album: final Album album):
            if (title.contains('сингл') || title.contains('single')) {
              singles.add(album);
            } else if (title.contains('альбом') || title.contains('album')) {
              albums.add(album);
            }
          case ArtistItem(artist: final Artist relatedArtist):
            if ((title.contains('похож') ||
                    title.contains('related') ||
                    title.contains('fan')) &&
                !isArtistBlocked(relatedArtist.id)) {
              related.add(relatedArtist);
            }
          case PlaylistItem():
            break;
        }
      }
    }

    // «Популярные треки» часто лежат в musicShelfRenderer, который без заголовка
    // не попал в секции — добираем напрямую.
    if (topTracks.isEmpty) {
      topTracks.addAll(
        _tracksFrom(res, fallbackPlaylistId: null).where(_keepTrack),
      );
    }

    final String artistName = BrowseParser.pageTitle(res) ?? 'Исполнитель';
    final List<Thumbnail> artistThumbs = BrowseParser.pageThumbnails(res);

    return Artist(
      id: artistId,
      name: artistName,
      thumbnails: artistThumbs,
      description: BrowseParser.pageDescription(res),
      subscribers: BrowseParser.pageSubtitle(res),
      topTracks: _limitTop(_withHeaderFallback(
        pageBlocked
            ? topTracks
            : topTracks
                .where((Track track) => !_trackBlocked(track))
                .toList(growable: false),
        artists: <ArtistRef>[ArtistRef(name: artistName, id: artistId)],
        thumbnails: artistThumbs,
      )),
      albums: albums,
      singles: singles,
      related: related,
    );
  }

  /// Страница плейлиста (в том числе чужого).
  Future<Playlist> playlist(String playlistId) async {
    await _waitForBlocked();
    final String browseId =
        playlistId.startsWith('VL') ? playlistId : 'VL$playlistId';

    // Авторизация обязательна: без неё YouTube не отдаёт приватные плейлисты —
    // например «Мне нравится» (id VLLM) приходит пустым, хотя вход выполнен.
    final Map<String, dynamic> res = await _client.browse(
      browseId,
      authenticated: _client.hasAuth,
    );
    final List<Track> tracks =
        _tracksFrom(res, fallbackPlaylistId: playlistId);

    // Длинные плейлисты YouTube отдаёт постранично — докручиваем продолжения,
    // иначе список обрывался на первой странице.
    String? token = BrowseParser.continuationToken(res);
    final Set<String> seen = tracks.map((Track t) => t.id).toSet();
    int guard = 0;
    while (token != null && guard++ < 80) {
      final Map<String, dynamic> page = await _client.browse(
        browseId,
        continuation: token,
        authenticated: _client.hasAuth,
      );
      final List<Track> more = <Track>[
        ..._tracksFrom(page, fallbackPlaylistId: playlistId),
        ...BrowseParser.playlistShelfContinuation(page, playlistId: playlistId),
      ];
      if (more.isEmpty) break;
      for (final Track track in more) {
        if (seen.add(track.id)) tracks.add(track);
      }
      token = BrowseParser.continuationToken(page);
    }

    // Фильтруем уже после продолжений: заблокированный исполнитель может
    // встретиться только на второй странице, и обрывать докрутку нельзя —
    // иначе вместе с ним пропали бы все следующие треки.
    final List<Track> visible = tracks
        .where((Track track) => !_trackBlocked(track))
        .toList(growable: false);

    return Playlist(
      id: playlistId,
      title: BrowseParser.pageTitle(res) ?? 'Плейлист',
      author: BrowseParser.pageSubtitle(res),
      description: BrowseParser.pageDescription(res),
      thumbnails: BrowseParser.pageThumbnails(res),
      tracks: visible,
      trackCount: visible.isEmpty ? null : visible.length,
      duration: _totalDuration(visible),
    );
  }

  // -------------------------------------------------------------- очередь

  /// Треки, которые YouTube предлагает после указанного.
  ///
  /// Используется, когда очередь закончилась: включаем «радио по треку»,
  /// как это делает YouTube Music.
  Future<List<Track>> autoplayQueue(String videoId) async {
    await _waitForBlocked();
    // Радио запрашиваем явно. Без `playlistId` YouTube отдаёт «дальше» для
    // одиночного видео — то есть сам же трек, и после фильтра ниже список
    // оставался пустым: ни ручной запуск радио, ни автопродление не работали.
    // `RDAMVM<videoId>` — идентификатор радио в YouTube Music.
    final Map<String, dynamic> res = await _client.next(
      videoId,
      playlistId: 'RDAMVM$videoId',
    );

    final List<Track> tracks = <Track>[];
    for (final dynamic renderer in traverseList(
      res,
      <String>['playlistPanelVideoRenderer'],
    )) {
      final Track? track = _panelTrack(renderer);
      // Радио — тоже каталог: заблокированный исполнитель не должен
      // подхватываться автопродлением в обход фильтрации остальных экранов.
      if (track != null &&
          track.id != videoId &&
          !_trackBlocked(track)) {
        tracks.add(track);
      }
    }
    return tracks;
  }

  /// Альбом, к которому относится трек (для клика по его названию).
  ///
  /// В карточках главной у трека нет данных об альбоме — подпись это
  /// исполнители. Альбом лежит в ответе `next` рядом с байлайном трека,
  /// поэтому спрашиваем его отдельно. `null` — YouTube альбом не сообщил
  /// (клип, редкая запись): вызывающий тогда запускает трек.
  Future<AlbumRef?> trackAlbum(String videoId) async {
    final Map<String, dynamic> res = await _client.next(videoId);
    return BrowseParser.trackAlbum(res, videoId: videoId);
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
      // Панель очереди — та же разметка, что и строки каталога, поэтому
      // признак клипа берём общим разбором; без него у клипа из радио
      // не появлялся пункт «Смотреть клип».
      isVideo: BrowseParser.isVideo(renderer),
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
        return Lyrics(
          timed: timed,
          plain: timed.map((TimedLyric l) => l.text).join('\n'),
          source: 'YouTube Music',
        );
      }

      final List<String> lines =
          traverseStrings(lyricsRes, <String>['description', 'runs', 'text']);
      final String plain = lines
          .where((String line) => line.trim().isNotEmpty)
          .join('\n')
          .trim();

      if (plain.isEmpty) return Lyrics.none;
      return Lyrics(plain: plain, source: 'YouTube Music');
    } on Exception {
      // Текста может не быть — это не ошибка приложения.
      return Lyrics.none;
    }
  }

  /// Текст из субтитров видео — второй источник, как в ArchiveTune.
  ///
  /// У клипов и редких записей вкладки «Текст» нет, а субтитры есть. Разметка
  /// приходит по адресу дорожки субтитров в формате json3: события со временем
  /// и кусками текста.
  ///
  /// Важная деталь: субтитры отдаёт только «плеер» мобильного/очкового
  /// клиента. Веб-клиент (`WEB_REMIX`), которым ходят остальные запросы
  /// каталога, на `player` отвечает `UNPLAYABLE`, и дорожек нет вовсе —
  /// поэтому здесь подставляется профиль Android VR с его заголовками.
  Future<Lyrics> subtitleLyrics(String videoId) async {
    try {
      final Map<String, dynamic> player = await _client.post(
        'player',
        body: <String, dynamic>{
          'context': <String, dynamic>{
            'client': <String, dynamic>{
              'clientName': _captionClientName,
              'clientVersion': _captionClientVersion,
              'hl': _client.locale,
              'gl': _client.region,
              'utcOffsetMinutes': 0,
              'userAgent': _captionUserAgent,
              'osName': 'Android',
              'osVersion': '12L',
              'deviceMake': 'Oculus',
              'deviceModel': 'Quest 3',
              'androidSdkVersion': 32,
            },
          },
          'videoId': videoId,
          'contentCheckOk': true,
          'racyCheckOk': true,
        },
        extraHeaders: <String, String>{
          'X-Youtube-Client-Name': _captionClientNumericId,
          'X-Youtube-Client-Version': _captionClientVersion,
          'User-Agent': _captionUserAgent,
        },
        // Со входом VR-профили получают ошибку 400 (как и при запросе потока).
        authenticated: false,
      );

      final List<dynamic> tracks = traverseList(player, <String>[
        'captions',
        'playerCaptionsTracklistRenderer',
        'captionTracks',
      ]);
      if (tracks.isEmpty) return Lyrics.none;

      // Берём дорожку на языке интерфейса, иначе — первую доступную.
      final Map<dynamic, dynamic> track = _pickCaptionTrack(tracks);
      final String? base = track['baseUrl'] as String?;
      if (base == null || base.isEmpty) return Lyrics.none;

      final HttpClient http = HttpClient();
      try {
        final HttpClientRequest request =
            await http.getUrl(Uri.parse(_withJsonFormat(base)));
        final HttpClientResponse response = await request.close();
        final String body = await response.transform(utf8.decoder).join();
        final dynamic decoded = jsonDecode(body);
        if (decoded is! Map) return Lyrics.none;

        final List<TimedLyric> timed = <TimedLyric>[];
        for (final dynamic event
            in decoded['events'] as List<dynamic>? ?? <dynamic>[]) {
          if (event is! Map) continue;
          final String text = (event['segs'] as List<dynamic>? ?? <dynamic>[])
              .whereType<Map<dynamic, dynamic>>()
              .map((Map<dynamic, dynamic> seg) => '${seg['utf8'] ?? ''}')
              .join()
              .trim();
          if (text.isEmpty) continue;
          timed.add(TimedLyric(
            time: Duration(
              milliseconds: (event['tStartMs'] as num?)?.toInt() ?? 0,
            ),
            text: text,
          ));
        }
        // Без единого времени синхронизации нет: подсветка «залипнет».
        if (timed.isEmpty || !timed.any((TimedLyric l) => l.time > Duration.zero)) {
          return Lyrics.none;
        }
        return Lyrics(
          timed: timed,
          plain: timed.map((TimedLyric l) => l.text).join('\n'),
          source: 'Субтитры',
        );
      } finally {
        http.close(force: true);
      }
    } on Exception {
      return Lyrics.none;
    }
  }

  /// Выбирает дорожку субтитров: сначала на языке интерфейса и без `asr`
  /// (ручную), затем — любую на этом языке, затем первую доступную.
  Map<dynamic, dynamic> _pickCaptionTrack(List<dynamic> tracks) {
    final List<Map<dynamic, dynamic>> maps =
        tracks.whereType<Map<dynamic, dynamic>>().toList();
    if (maps.isEmpty) return <dynamic, dynamic>{};

    final String locale = _client.locale.split('-').first.toLowerCase();
    Map<dynamic, dynamic>? manual;
    Map<dynamic, dynamic>? auto;
    for (final Map<dynamic, dynamic> track in maps) {
      final String lang =
          '${track['languageCode'] ?? ''}'.split('-').first.toLowerCase();
      final bool asr = '${track['kind'] ?? ''}' == 'asr';
      if (lang == locale) {
        if (asr && auto == null) auto = track;
        if (!asr && manual == null) manual = track;
      }
    }
    return manual ?? auto ?? maps.first;
  }

  /// Добавляет к адресу субтитров `fmt=json3`, убирая прежний формат.
  ///
  /// Параметр `fmt` у разных клиентов уже может стоять (`srv3`); просто
  /// дописать второй нельзя — сработает не всегда, поэтому старый убираем.
  String _withJsonFormat(String base) {
    final String stripped =
        base.replaceAll(RegExp(r'[&?]fmt=[^&]*'), '');
    final String separator = stripped.contains('?') ? '&' : '?';
    return '$stripped${separator}fmt=json3';
  }

  List<TimedLyric> _parseTimedLyrics(Map<String, dynamic> response) {
    // Путь к синхронному тексту у YouTube менялся: раньше был
    // `contents.type.lyricsData`, сейчас встречается обёртка
    // `...timedLyricsModel.lyricsData`. `traverseList` ищет ключ на любой
    // глубине, поэтому цепляемся сразу за `timedLyricsData` — разбор не
    // отвалится при очередной смене обёртки.
    final List<dynamic> raw =
        traverseList(response, <String>['timedLyricsData']);

    final List<TimedLyric> result = <TimedLyric>[];
    for (final dynamic line in raw) {
      if (line is! Map) continue;
      final Object? start = line['lyricLineStartTimeMs'] ??
          line['startTimeMs'] ??
          line['startTime'] ??
          line['time'];
      if (start is! num) continue;
      // Текст строки лежит то как `runs`/`simpleText`/`text`, то отдельным
      // полем `lyricLineText` — раньше второе имя не читалось, и строки
      // молча пропускались.
      final String? text = textOf(line) ?? _lyricLineText(line);
      if (text == null || text.trim().isEmpty) continue;
      result.add(TimedLyric(
        time: Duration(milliseconds: start.toInt()),
        text: text.trim(),
      ));
    }

    result.sort((TimedLyric a, TimedLyric b) => a.time.compareTo(b.time));
    return result;
  }

  String? _lyricLineText(dynamic line) {
    if (line is! Map) return null;
    for (final String key in <String>[
      'lyricLineText',
      'lyricsLineText',
      'lyricText',
    ]) {
      final dynamic value = line[key];
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return null;
  }

  // --------------------------------------------------------------- helpers

  /// Оставляет только то, что пользователь не просил прятать.
  ///
  /// Признак explicit/видео приходит из разбора. Если разбор его не отдал
  /// (`isVideo` не разобран), трек остаётся: настройка не должна прятать
  /// всё подряд.
  bool _keepTrack(Track track) {
    final ContentFilter filter = CatalogSource.contentFilter;
    if (filter.hideExplicit && track.isExplicit) return false;
    if (filter.hideVideo && track.isVideo) return false;
    return true;
  }

  /// Укорачивает список до длины топа из настроек.
  List<Track> _limitTop(List<Track> tracks) {
    final int size = CatalogSource.contentFilter.topSize;
    if (size <= 0 || tracks.length <= size) return tracks;
    return tracks.take(size).toList(growable: false);
  }

  /// Ждёт публикации списка блокировок (см. [blockedArtistsReady]).
  ///
  /// Ждём именно `Future`, а не флаг: запрос каталога стартует раньше, чем
  /// файл дочитан, и без ожидания первый ответ был бы нефильтрованным.
  Future<void> _waitForBlocked() async {
    final Future<void>? ready = CatalogSource.blockedArtistsReady;
    if (ready == null) return;
    try {
      await ready;
    } on Object {
      // Список не прочитан — скрывать нечего, это не ошибка каталога.
    }
  }

  /// Лежит ли трек хотя бы у одного заблокированного исполнителя.
  ///
  /// Достаточно одного: если в треке участвует заблокированный артист, трек
  /// скрывается целиком — как в ArchiveTune. Дробить трек по участникам
  /// было бы странно: пользователь просил не видеть исполнителя, а не
  /// вычёркивать его имя из чужих песен.
  bool _trackBlocked(Track track) {
    if (blockedArtistIds.isEmpty) return false;
    return track.artists.any(
      (ArtistRef artist) => isArtistBlocked(artist.id),
    );
  }

  /// Среди исполнителей альбома есть заблокированный.
  bool _artistsBlocked(List<ArtistRef> artists) {
    if (blockedArtistIds.isEmpty) return false;
    return artists.any(
      (ArtistRef artist) => isArtistBlocked(artist.id),
    );
  }

  /// Оставляет ли полка элемент с учётом настроек содержимого и блокировок.
  bool _keepItem(BrowseItem item) {
    switch (item) {
      case TrackItem(:final Track track):
        return _keepTrack(track) && !_trackBlocked(track);
      case AlbumItem(album: final Album album):
        return !_artistsBlocked(album.artists);
      case ArtistItem(artist: final Artist artist):
        return !isArtistBlocked(artist.id);
      case PlaylistItem():
        return true;
    }
  }

  /// Применяет настройки содержимого к полкам: прячет explicit и видео, а у
  /// топов и чартов ([limitTop]) обрезает длину.
  ///
  /// Полка, целиком состоявшая из скрытого, убирается совсем: пустой ряд на
  /// экране только мешает.
  List<BrowseSection> _applyContentFilter(
    List<BrowseSection> sections, {
    bool limitTop = false,
  }) {
    final ContentFilter filter = CatalogSource.contentFilter;
    // Блокировка — такая же причина прятать элементы, как и настройки, но
    // живёт отдельно от [ContentFilter]: список приходит с диска, а не из
    // настроек.
    final bool hideItems =
        filter.hidesAnything || blockedArtistIds.isNotEmpty;
    if (!hideItems && !limitTop) return sections;

    final List<BrowseSection> result = <BrowseSection>[];
    for (final BrowseSection section in sections) {
      List<BrowseItem> items = section.items;
      if (hideItems) {
        items = items
            .where(_keepItem)
            .toList(growable: false);
      }
      if (limitTop && items.length > filter.topSize) {
        items = items.take(filter.topSize).toList(growable: false);
      }
      if (items.isEmpty && section.items.isNotEmpty && hideItems) {
        continue;
      }
      if (identical(items, section.items)) {
        result.add(section);
      } else {
        result.add(BrowseSection(
          title: section.title,
          subtitle: section.subtitle,
          items: items,
          browseId: section.browseId,
          params: section.params,
        ));
      }
    }
    return result;
  }

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
