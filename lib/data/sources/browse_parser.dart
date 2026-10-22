import '../models/models.dart';
import '../../core/innertube/renderer.dart';

/// Парсеры ответов InnerTube в доменные модели.
///
/// YouTube Music отдаёт контент через небольшой набор «рендереров».
/// Один и тот же `musicResponsiveListItemRenderer` используется и в поиске,
/// и в плейлистах, и в библиотеке — поэтому парсить их один раз выгодно:
/// анонимный и авторизованный контент разбираются одинаково.
///
/// Все обращения к полям идут через [traverse] / [textOf], поэтому небольшие
/// изменения схемы не приводят к исключениям — значение просто не находится.
class BrowseParser {
  const BrowseParser._();

  // ---------------------------------------------------------------- одиночные

  /// Разбирает `musicResponsiveListItemRenderer` — основную «строку» трека.
  ///
  /// [fallbackPlaylistId] нужен для плейлистов: без него YouTube не отдаст
  /// корректный `playlistId` и «следующий трек» уедет в радио.
  static Track? responsiveItem(dynamic renderer, {String? fallbackPlaylistId}) {
    if (renderer is! Map) return null;

    // Видео берём из endpoints: иногда videoId лежит не в корне.
    final String? videoId = _firstString(renderer, <List<String>>[
      <String>['videoId'],
      <String>['playlistItemData', 'videoId'],
      <String>['navigationEndpoint', 'watchEndpoint', 'videoId'],
      <String>['overlay', 'musicItemThumbnailOverlayRenderer', 'content',
          'musicPlayButtonRenderer', 'playNavigationEndpoint', 'watchEndpoint', 'videoId'],
    ]);
    if (videoId == null || videoId.isEmpty) return null;

    final String title = _firstString(renderer, <List<String>>[
          <String>['flexColumns', 'musicResponsiveListItemFlexColumnRenderer', 'text', 'runs', 'text'],
          <String>['title', 'runs', 'text'],
        ]) ??
        'Без названия';

    // Байлайн содержит исполнителей и (для плейлистов) альбом + длительность.
    final List<dynamic> bylineColumns =
        traverseList(renderer, <String>['flexColumns']).whereType<Map>().toList();

    final List<ArtistRef> artists = _artistsFromColumns(bylineColumns);
    final AlbumRef? album = _albumFromColumns(bylineColumns);

    final Duration duration = _firstDuration(bylineColumns) ??
        parseDurationText(
          textOf(traverse(renderer, <String>['lengthText'])),
        ) ??
        Duration.zero;

    final String? playlistId = _firstString(renderer, <List<String>>[
          <String>['navigationEndpoint', 'watchPlaylistEndpoint', 'playlistId'],
          <String>['overlay', 'musicItemThumbnailOverlayRenderer', 'content',
              'musicPlayButtonRenderer', 'playNavigationEndpoint',
              'watchPlaylistEndpoint', 'playlistId'],
        ]) ??
        fallbackPlaylistId;

    // `playlistSetVideoId` — идентификатор записи внутри плейлиста. Без него
    // сервер не удаляет трек (`ACTION_REMOVE_VIDEO` принимает и `videoId`, и
    // этот id). YouTube кладёт его только для правимых пользователем
    // плейлистов, поэтому `null` здесь означает «удалить эту запись нельзя».
    final String? setVideoId = _firstString(renderer, <List<String>>[
      <String>['playlistItemData', 'playlistSetVideoId'],
      <String>['navigationEndpoint', 'watchEndpoint', 'playlistSetVideoId'],
      <String>['overlay', 'musicItemThumbnailOverlayRenderer', 'content',
          'musicPlayButtonRenderer', 'playNavigationEndpoint', 'watchEndpoint',
          'playlistSetVideoId'],
    ]);

    return Track(
      id: videoId,
      title: title,
      artists: artists,
      album: album,
      duration: duration,
      thumbnails: _thumbnails(renderer),
      isExplicit: _hasBadge(renderer, 'MUSIC_EXPLICIT_BADGE'),
      playlistId: playlistId,
      setVideoId: setVideoId,
      isVideo: isVideo(renderer),
    );
  }

  /// Признак клипа: `musicVideoType` = `MUSIC_VIDEO_TYPE_OMV` (официальный
  /// клип) или `MUSIC_VIDEO_TYPE_UGC` (пользовательское видео). Обычная
  /// аудиодорожка — то, что в YouTube Music называется песней, — помечена
  /// `MUSIC_VIDEO_TYPE_ATV`.
  ///
  /// Путь одинаков у строки списка (`musicResponsiveListItemRenderer`) и у
  /// панели очереди (`playlistPanelVideoRenderer`, она же радио), поэтому
  /// разбор живёт здесь: признак нужен и настройке «Скрыть видео», и пункту
  /// «Смотреть клип» в меню трека.
  static bool isVideo(dynamic renderer) {
    final String? videoType = traverseString(renderer, <String>[
      'navigationEndpoint',
      'watchEndpoint',
      'watchEndpointMusicSupportedConfigs',
      'watchEndpointMusicConfig',
      'musicVideoType',
    ]);
    return videoType == 'MUSIC_VIDEO_TYPE_OMV' ||
        videoType == 'MUSIC_VIDEO_TYPE_UGC';
  }

  /// Разбирает строку `musicResponsiveListItemRenderer` любого вида.
  ///
  /// В одной и той же разметке строка может описывать трек, альбом, артиста
  /// или плейлист: у трека есть видео-идентификатор, у остальных — ссылка
  /// на страницу. Этот метод различает их сам.
  static BrowseItem? responsiveAny(dynamic renderer) {
    if (renderer is! Map) return null;

    final Track? track = responsiveItem(renderer);
    if (track != null) return TrackItem(track);

    final String? browseId = _firstString(renderer, <List<String>>[
      <String>['navigationEndpoint', 'browseEndpoint', 'browseId'],
    ]);
    if (browseId == null || browseId.isEmpty) return null;

    final String title = _firstString(renderer, <List<String>>[
          <String>['flexColumns', 'musicResponsiveListItemFlexColumnRenderer', 'text', 'runs', 'text'],
          <String>['title', 'runs', 'text'],
        ]) ??
        '';
    if (title.isEmpty) return null;

    final String pageType = _firstString(renderer, <List<String>>[
          <String>['navigationEndpoint', 'browseEndpoint',
              'browseEndpointContextSupportedConfigs',
              'browseEndpointContextMusicConfig', 'pageType'],
        ]) ??
        '';
    final String subtitle = _byline(renderer);
    final List<Thumbnail> thumbnails = _thumbnails(renderer);

    if (pageType.contains('ARTIST') || browseId.startsWith('UC')) {
      return ArtistItem(Artist(
        id: browseId,
        name: title,
        thumbnails: thumbnails,
        subscribers: subtitle.isEmpty ? null : subtitle,
      ));
    }
    if (pageType.contains('ALBUM') || browseId.startsWith('MPRE')) {
      return AlbumItem(Album(
        id: browseId,
        title: title,
        artists: _artistsFromByline(_bylineRuns(renderer), subtitle),
        year: _extractYear(subtitle),
        thumbnails: thumbnails,
      ));
    }
    return PlaylistItem(Playlist(
      id: browseId,
      title: title,
      author: subtitle.isEmpty ? null : subtitle,
      thumbnails: thumbnails,
    ));
  }

  /// Runs второго столбца строки — байлайн с исполнителями и годом.
  static List<dynamic> _bylineRuns(dynamic renderer) {
    final List<dynamic> columns =
        traverseList(renderer, <String>['flexColumns']).whereType<Map>().toList();
    return _runsOfColumn(columns, 1);
  }

  /// Собирает текст второго столбца строки (исполнители, год, число треков).
  static String _byline(dynamic renderer) {
    final List<dynamic> runs = _bylineRuns(renderer);
    if (runs.isEmpty) return '';
    return runs
        .whereType<Map>()
        .map(textOf)
        .whereType<String>()
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty && s != '•')
        .join(' • ');
  }

  /// Плитка «создать плейлист» из раздела библиотеки.
  ///
  /// Это не плейлист, а кнопка: у неё нет `browseEndpoint`, зато есть
  /// `createPlaylistEndpoint` (сервер дублирует его и в корне плитки, и в run
  /// заголовка). Название локализовано («Новый плейлист», «New playlist»),
  /// поэтому по тексту плитку не ищем — только по структуре ответа.
  ///
  /// Без этой проверки плитка превращалась в [PlaylistItem] с пустым id:
  /// в списке висел «пустой плейлист», а открыть его и что-то сделать с ним
  /// было нельзя.
  static bool isCreatePlaylistTile(dynamic renderer) {
    if (renderer is! Map) return false;
    return traverse(renderer, <String>[
          'navigationEndpoint',
          'createPlaylistEndpoint',
        ]) !=
        null;
  }

  /// Обложка плитки «создать плейлист»: YouTube рисует для неё отдельную
  /// картинку, и она приходит тем же `musicThumbnailRenderer`.
  static String? createPlaylistTileArtwork(dynamic renderer) {
    if (!isCreatePlaylistTile(renderer)) return null;
    return _thumbnails(renderer).best;
  }

  /// Разбирает `musicTwoRowItemRenderer` — плитку альбома/плейлиста/артиста.
  static BrowseItem? twoRowItem(dynamic renderer) {
    if (renderer is! Map) return null;

    // Кнопка создания плейлиста — не элемент библиотеки (см.
    // [isCreatePlaylistTile]). Пропускаем её до разбора названия и ссылок.
    if (isCreatePlaylistTile(renderer)) return null;

    final String title = _firstString(renderer, <List<String>>[
          <String>['title', 'runs', 'text'],
          <String>['title', 'simpleText'],
        ]) ??
        '';
    if (title.isEmpty) return null;

    final String browseId = _firstString(renderer, <List<String>>[
          <String>['navigationEndpoint', 'browseEndpoint', 'browseId'],
        ]) ??
        '';
    final String pageType = _firstString(renderer, <List<String>>[
          <String>['navigationEndpoint', 'browseEndpoint', 'browseEndpointContextSupportedConfigs',
              'browseEndpointContextMusicConfig', 'pageType'],
        ]) ??
        '';

    final List<Thumbnail> thumbnails = _thumbnails(renderer);
    // Подпись разбираем целиком, а не первым run. У одиночного трека первый
    // run — служебная подпись («Композиция»), а исполнитель со ссылкой идёт
    // следующим; из-за чтения только первого run имя подменялось типом записи,
    // а идентификатор исполнителя терялся.
    final List<dynamic> subtitleRuns = _subtitleRuns(renderer);
    final String subtitle = _subtitleText(renderer);

    // Тип определяем по pageType, а если его нет — по префиксу browseId.
    final bool isArtist = pageType.contains('ARTIST') ||
        (!pageType.contains('ALBUM') && browseId.startsWith('UC'));
    final bool isAlbum = pageType.contains('ALBUM') ||
        (!isArtist && browseId.startsWith('MPRE'));

    if (isArtist) {
      return ArtistItem(Artist(
        id: browseId,
        name: title,
        thumbnails: thumbnails,
        subscribers: subtitle,
      ));
    }

    if (isAlbum) {
      return AlbumItem(Album(
        id: browseId,
        title: title,
        artists: _artistsFromByline(subtitleRuns, subtitle),
        year: _extractYear(subtitle),
        thumbnails: thumbnails,
      ));
    }

    // Клип YouTube Music: у него нет browseId, зато есть watchEndpoint с
    // videoId. Без этой ветки такие элементы попадали в плейлисты с пустым
    // идентификатором, и нажатие открывало пустую страницу плейлиста вместо
    // воспроизведения.
    final String videoId = _firstString(renderer, <List<String>>[
          <String>['navigationEndpoint', 'watchEndpoint', 'videoId'],
        ]) ??
        '';
    if (videoId.isNotEmpty) {
      return TrackItem(Track(
        id: videoId,
        title: title,
        artists: _artistsFromByline(subtitleRuns, subtitle),
        // Альбом берём из подписи, только если там есть настоящая ссылка на
        // альбом (`_albumFromRuns`). Обычно в подписи карточки — исполнители,
        // и тогда альбом разрешается позже, по ответу `next` (см.
        // `CatalogSource.trackAlbum` и `openBrowseItem`).
        album: _albumFromRuns(subtitleRuns),
        thumbnails: thumbnails,
        duration: _durationFromSubtitle(subtitle) ?? Duration.zero,
      ));
    }

    // Плитка без ссылки на страницу — не плейлист: пустой id давал элемент,
    // который никуда не ведёт и над которым не работают действия.
    if (browseId.isEmpty) return null;

    return PlaylistItem(Playlist(
      id: browseId,
      title: title,
      author: subtitle.isEmpty ? null : subtitle,
      thumbnails: thumbnails,
    ));
  }

  /// Альбом трека из ответа `next`.
  ///
  /// У карточки трека в подписи стоят исполнители, а не альбом, поэтому из
  /// разметки карточки альбом узнать нельзя. Зато в ответе `next` у элемента
  /// очереди (`playlistPanelVideoRenderer`) рядом с байлайном лежит ссылка на
  /// альбом (`MPRE…`, `pageType = MUSIC_PAGE_TYPE_ALBUM`) — её и берём.
  ///
  /// Панель выбираем именно запрошенного трека: у соседей по очереди альбомы
  /// свои, и первый элемент не всегда совпадает с запрошенным.
  static AlbumRef? trackAlbum(dynamic response, {required String videoId}) {
    final List<dynamic> panels =
        traverseList(response, <String>['playlistPanelVideoRenderer']);
    dynamic panel;
    for (final dynamic candidate in panels) {
      if (candidate is! Map) continue;
      if ('${candidate['videoId']}' == videoId) {
        panel = candidate;
        break;
      }
    }
    panel ??= panels.isEmpty ? null : panels.first;
    if (panel is! Map) return null;

    // Байлайн: `longBylineText` — полный, `shortBylineText` — запасной.
    final List<dynamic> runs = <dynamic>[
      ...traverseList(panel, <String>['longBylineText', 'runs']),
      ...traverseList(panel, <String>['shortBylineText', 'runs']),
    ];
    return _albumFromRuns(runs);
  }

  /// Трек из элемента панели очереди (`playlistPanelVideoRenderer`).
  ///
  /// Байлайн панели размечен так: «Исполнители • Альбом • Год», причём у
  /// исполнителей ссылка ведёт на страницу исполнителя
  /// (`MUSIC_PAGE_TYPE_ARTIST`), а у альбома — на его страницу (`MPRE…`,
  /// `MUSIC_PAGE_TYPE_ALBUM`). Раньше автором считался любой run со ссылкой,
  /// поэтому альбом печатался вторым исполнителем: в очереди выходило
  /// «Пошлая Молли, Контракт • 3:25». Здесь граница проводится по типу
  /// страницы; текст остаётся только запасным путём.
  static Track? panelTrack(dynamic renderer) {
    if (renderer is! Map) return null;
    final String? videoId = traverseString(renderer, <String>['videoId']);
    if (videoId == null || videoId.isEmpty) return null;

    final String title =
        traverseString(renderer, <String>['title', 'runs', 'text']) ??
            traverseString(renderer, <String>['title', 'simpleText']) ??
            'Без названия';

    final List<dynamic> longRuns =
        traverseList(renderer, <String>['longBylineText', 'runs']);
    final List<dynamic> shortRuns =
        traverseList(renderer, <String>['shortBylineText', 'runs']);
    final (List<ArtistRef>, AlbumRef?) byline =
        _panelByline(longRuns, shortRuns);

    // Панель очереди — та же разметка, что и строки каталога, поэтому
    // признак клипа берём общим разбором; без него у клипа из радио
    // не появлялся пункт «Смотреть клип».
    final List<Thumbnail> thumbs = <Thumbnail>[];
    for (final dynamic t
        in traverseList(renderer, <String>['thumbnail', 'thumbnails'])) {
      if (t is Map && t['url'] is String) {
        thumbs.add(Thumbnail(url: t['url'] as String));
      }
    }

    return Track(
      id: videoId,
      title: title,
      artists: byline.$1,
      album: byline.$2,
      duration: parseDurationText(
            traverseString(renderer, <String>['lengthText', 'runs', 'text']),
          ) ??
          Duration.zero,
      thumbnails: thumbs,
      isVideo: isVideo(renderer),
    );
  }

  /// Исполнители и альбом из байлайна панели очереди.
  ///
  /// Ссылки решают: run со страницей исполнителя — автор, run со страницей
  /// альбома — альбом. Если ссылок нет, `shortBylineText` панели содержит
  /// только исполнителей (альбома там не бывает) — берём его. Совсем без
  /// подсказок остаётся текст: тогда «Исполнитель, Альбом» неотличим от
  /// «Исполнитель1, Исполнитель2», и мы показываем одного исполнителя —
  /// выдуманный соавтор хуже потерянного второго.
  static (List<ArtistRef>, AlbumRef?) _panelByline(
    List<dynamic> longRuns,
    List<dynamic> shortRuns,
  ) {
    final List<dynamic> runs = longRuns.isNotEmpty ? longRuns : shortRuns;

    List<ArtistRef> artists = _linkedArtists(runs);
    AlbumRef? album = _albumFromRuns(runs);

    if (artists.isEmpty) {
      final String shortText = _runsText(shortRuns);
      if (shortText.isNotEmpty) {
        artists = _artistsFromNames(_splitNames(shortText));
      } else {
        final List<String> names =
            _splitNames(_firstBylineSegment(longRuns));
        final List<ArtistRef> candidates = _artistsFromNames(names);
        if (names.length > 1) {
          artists = candidates.isEmpty
              ? const <ArtistRef>[]
              : <ArtistRef>[candidates.first];
          album ??= AlbumRef(name: names.skip(1).join(', '));
        } else {
          artists = candidates;
        }
      }
    }

    album ??= _albumFromPanelText(longRuns, artists);

    // Альбом не может быть исполнителем: даже если разбор положил его
    // в авторы (например, у run не оказалось ссылки), убираем по названию.
    return (_withoutAlbum(artists, album), album);
  }

  /// Альбом из текста байлайна — когда ссылки на альбом нет.
  ///
  /// «… • Альбом • 2021» — берём первый неслужебный сегмент после
  /// исполнителей. «Исполнитель, Альбом» без разделителя распознаём по
  /// разнице с уже известными исполнителями.
  static AlbumRef? _albumFromPanelText(
    List<dynamic> runs,
    List<ArtistRef> artists,
  ) {
    final String text = _runsText(runs);
    if (text.isEmpty) return null;

    final List<String> segments = text
        .split('•')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    for (final String segment in segments.skip(1)) {
      if (_isBylineField(segment)) continue;
      return AlbumRef(name: segment);
    }

    if (segments.isEmpty) return null;
    final List<String> names = _splitNames(segments.first);
    if (names.length < 2) return null;
    final Set<String> known =
        artists.map((ArtistRef a) => a.name.trim().toLowerCase()).toSet();
    final List<String> rest = names
        .where((String name) => !known.contains(name.toLowerCase()))
        .toList();
    return rest.length == 1 ? AlbumRef(name: rest.single) : null;
  }

  /// Год, длительность и счётчик — не название альбома.
  ///
  /// Служебные подписи вроде «Альбом» здесь намеренно не отбрасываются:
  /// это позиция названия, и альбом с таким именем существует.
  static bool _isBylineField(String value) {
    final String text = value.trim();
    if (text.isEmpty || text == '•') return true;
    if (_looksLikeYear(text)) return true;
    if (parseDurationText(text) != null) return true;
    return _looksLikeCount(text);
  }

  static String _runsText(List<dynamic> runs) {
    final StringBuffer buffer = StringBuffer();
    for (final dynamic run in runs) {
      if (run is Map && run['text'] is String) buffer.write(run['text']);
    }
    return buffer.toString().trim();
  }

  static String _firstBylineSegment(List<dynamic> runs) =>
      _runsText(runs).split('•').first.trim();

  /// Разделители имён в одной текстовой строке: «A, B», «A и B», «A & B».
  static final RegExp _artistSeparator = RegExp(
    r'\s*,\s*|\s+и\s+|\s*&\s*|\s+feat\.?\s+|\s+ft\.?\s+',
    caseSensitive: false,
    unicode: true,
  );

  static List<String> _splitNames(String text) {
    return text
        .split(_artistSeparator)
        .map((String part) => part.trim())
        .where((String part) => part.isNotEmpty && part != '•')
        .toList();
  }

  static List<ArtistRef> _artistsFromNames(List<String> names) => names
      .where((String name) => !_isBylineField(name))
      .where((String name) => !_artistStopWords.contains(name.toLowerCase()))
      .map((String name) => ArtistRef(name: name))
      .toList(growable: false);

  /// Убирает из авторов элемент, совпавший с названием альбома.
  static List<ArtistRef> _withoutAlbum(
    List<ArtistRef> artists,
    AlbumRef? album,
  ) {
    if (album == null) return artists;
    final String albumName = album.name.trim().toLowerCase();
    if (albumName.isEmpty) return artists;
    return artists
        .where((ArtistRef a) => a.name.trim().toLowerCase() != albumName)
        .toList(growable: false);
  }

  /// Разбирает `musicShelfRenderer` / `musicCarouselShelfRenderer` в секцию.
  static BrowseSection? shelf(dynamic renderer) {
    if (renderer is! Map) return null;

    final String title = _firstString(renderer, <List<String>>[
          <String>['title', 'runs', 'text'],
          <String>['title', 'simpleText'],
        ]) ??
        '';

    final List<BrowseItem> items = <BrowseItem>[];

    for (final dynamic item in traverseList(renderer, <String>['contents'])) {
      if (item is! Map) continue;
      final dynamic responsive = item['musicResponsiveListItemRenderer'];
      if (responsive != null) {
        final BrowseItem? parsed = responsiveAny(responsive);
        if (parsed != null) items.add(parsed);
        continue;
      }
      final dynamic twoRow = item['musicTwoRowItemRenderer'];
      if (twoRow != null) {
        final BrowseItem? parsed = twoRowItem(twoRow);
        if (parsed != null) items.add(parsed);
      }
    }

    if (items.isEmpty) return null;
    return BrowseSection(title: title, items: items);
  }

  /// Разбирает `musicPlaylistShelfRenderer` в список треков.
  ///
  /// [playlistId] обязателен: он проставляется каждому треку.
  static List<Track> playlistShelf(dynamic node, {required String playlistId}) {
    final List<Track> tracks = <Track>[];
    for (final dynamic renderer in traverseList(
      node,
      <String>['musicPlaylistShelfRenderer', 'contents'],
    )) {
      if (renderer is! Map) continue;
      final Track? track = responsiveItem(
        renderer['musicResponsiveListItemRenderer'],
        fallbackPlaylistId: playlistId,
      );
      if (track != null) tracks.add(track);
    }
    return tracks;
  }

  /// Треки из ответа на continuation полки/плейлиста.
  ///
  /// В ответе на `continuation` контейнер другой —
  /// `musicPlaylistShelfContinuation.contents`, а не `musicPlaylistShelfRenderer`:
  /// без этого «Мне нравится» и длинные плейлисты обрывались на первой странице.
  static List<Track> playlistShelfContinuation(
    dynamic node, {
    required String playlistId,
  }) {
    final List<Track> tracks = <Track>[];
    for (final dynamic renderer in traverseList(
      node,
      <String>['musicPlaylistShelfContinuation', 'contents'],
    )) {
      if (renderer is! Map) continue;
      final Track? track = responsiveItem(
        renderer['musicResponsiveListItemRenderer'],
        fallbackPlaylistId: playlistId,
      );
      if (track != null) tracks.add(track);
    }
    return tracks;
  }

  /// Токен продолжения — им докручивается лента («ещё»).
  ///
  /// YouTube Music кладёт его двумя разными способами, встречаются оба:
  ///  * в плейлистах и старой разметке —
  ///    `continuations[0].nextContinuationData.continuation`;
  ///  * в новых ответах (в том числе на главной) —
  ///    `continuationItemRenderer.continuationEndpoint.continuationCommand.token`.
  ///
  /// Здесь именно `traverseList`, а не `traverse`: обход ответов «разворачивает»
  /// список на последнем шаге, поэтому `traverse` вернул бы первый элемент
  /// списка `continuations`, и токен бы не нашёлся (прежде так и было — главная
  /// не докручивалась). `traverseList` отдаёт все элементы списка.
  static String? continuationToken(dynamic node) {
    for (final dynamic c in traverseList(node, <String>['continuations'])) {
      final String? token =
          traverseString(c, <String>['nextContinuationData', 'continuation']);
      if (token != null && token.isNotEmpty) return token;
    }
    for (final dynamic token in traverseList(node, <String>[
      'continuationItemRenderer',
      'continuationEndpoint',
      'continuationCommand',
      'token',
    ])) {
      if (token is String && token.isNotEmpty) return token;
    }
    return null;
  }

  /// Универсальный разбор секций.
  ///
  /// YouTube Music заворачивает списки по-разному: главная отдаёт карусели
  /// и полки с заголовками, поиск — плоский список `itemSectionRenderer`
  /// без заголовков, страница исполнителя смешивает оба вида. Здесь все
  /// варианты приводятся к одному типу [BrowseSection].
  static List<BrowseSection> sectionsFrom(dynamic response) {
    List<dynamic> entries = traverseList(
      response,
      <String>['sectionListRenderer', 'contents'],
    );
    if (entries.isEmpty) {
      entries = traverseList(
        response,
        <String>['sectionListContinuation', 'contents'],
      );
    }

    // Ответ поиска: заголовков у секций нет, элементы идут подряд.
    final bool isSearch =
        traverseList(response, <String>['tabbedSearchResultsRenderer'])
            .isNotEmpty;

    final List<BrowseSection> sections = <BrowseSection>[];
    final List<BrowseItem> loose = <BrowseItem>[];

    for (final dynamic entry in entries) {
      if (entry is! Map) continue;

      final dynamic carousel = entry['musicCarouselShelfRenderer'];
      if (carousel != null) {
        final BrowseSection? section = shelf(carousel);
        if (section != null) sections.add(section);
        continue;
      }

      final dynamic shelfRenderer = entry['musicShelfRenderer'];
      if (shelfRenderer != null) {
        final BrowseSection? section = shelf(shelfRenderer);
        if (section != null) sections.add(section);
        continue;
      }

      final dynamic card = entry['musicCardShelfRenderer'];
      if (card != null) {
        final BrowseItem? item = cardShelf(card);
        if (item != null) {
          sections.add(BrowseSection(
            title: isSearch ? 'Лучший результат' : 'Выделено',
            items: <BrowseItem>[item],
          ));
        }
        continue;
      }

      final dynamic itemSection = entry['itemSectionRenderer'];
      if (itemSection != null) {
        final List<BrowseItem> items = itemsOf(itemSection['contents']);
        if (items.isEmpty) continue;

        final String? title = _itemSectionTitle(itemSection);
        if (title == null || title.isEmpty) {
          // Без заголовка: у поиска такие элементы образуют один общий список.
          loose.addAll(items);
        } else {
          sections.add(BrowseSection(title: title, items: items));
        }
      }
    }

    if (loose.isNotEmpty) {
      sections.add(BrowseSection(title: 'Результаты', items: loose));
    }

    // Если разметка незнакома — откатываемся на поиск полок где угодно.
    if (sections.isEmpty) {
      for (final dynamic carousel
          in traverseList(response, <String>['musicCarouselShelfRenderer'])) {
        final BrowseSection? section = shelf(carousel);
        if (section != null) sections.add(section);
      }
      for (final dynamic shelfRenderer
          in traverseList(response, <String>['musicShelfRenderer'])) {
        final BrowseSection? section = shelf(shelfRenderer);
        if (section != null) sections.add(section);
      }
    }

    return sections;
  }

  /// Заголовок `itemSectionRenderer` — в разных ответах лежит по-разному.
  static String? _itemSectionTitle(dynamic itemSection) {
    return _firstString(itemSection, <List<String>>[
          <String>['header', 'musicHeaderRenderer', 'title', 'runs', 'text'],
          <String>['header', 'itemSectionHeaderRenderer', 'title', 'runs', 'text'],
          <String>['header', 'title', 'runs', 'text'],
          <String>['header', 'title', 'simpleText'],
        ]) ??
        textOf(traverse(itemSection, <String>['header', 'title']));
  }

  /// «Лучший результат» поиска: может быть треком, альбомом, артистом.
  static BrowseItem? cardShelf(dynamic renderer) {
    if (renderer is! Map) return null;

    final String title = _firstString(renderer, <List<String>>[
          <String>['title', 'runs', 'text'],
          <String>['title', 'simpleText'],
        ]) ??
        '';
    if (title.isEmpty) return null;

    // Подпись целиком: первый run — тип записи («Видео»/«Композиция»), а
    // исполнитель со ссылкой идёт дальше. Раньше брался только первый run.
    final List<dynamic> subtitleRuns = _subtitleRuns(renderer);
    final String subtitle = _subtitleText(renderer);

    // Трек: у элемента есть watchEndpoint с videoId.
    final String? videoId = _firstString(renderer, <List<String>>[
      <String>['onTap', 'watchEndpoint', 'videoId'],
    ]);
    if (videoId != null && videoId.isNotEmpty) {
      return TrackItem(Track(
        id: videoId,
        title: title,
        artists: _artistsFromByline(subtitleRuns, subtitle),
        thumbnails: _thumbnails(renderer),
        duration: _durationFromRuns(subtitleRuns) ?? Duration.zero,
      ));
    }

    // Иначе это страница: определяем тип по префиксу идентификатора.
    final String browseId = _firstString(renderer, <List<String>>[
          <String>['onTap', 'browseEndpoint', 'browseId'],
          <String>['navigationEndpoint', 'browseEndpoint', 'browseId'],
        ]) ??
        '';

    if (browseId.startsWith('UC')) {
      return ArtistItem(Artist(
        id: browseId,
        name: title,
        thumbnails: _thumbnails(renderer),
      ));
    }
    if (browseId.startsWith('MPRE')) {
      return AlbumItem(Album(
        id: browseId,
        title: title,
        artists: _artistsFromByline(subtitleRuns, subtitle),
        year: _extractYear(subtitle),
        thumbnails: _thumbnails(renderer),
      ));
    }
    // Без ссылки на страницу это не плейлист (например, кнопка создания):
    // пустой id вёл бы на пустую страницу.
    if (browseId.isEmpty) return null;
    return PlaylistItem(Playlist(
      id: browseId,
      title: title,
      author: subtitle.isEmpty ? null : subtitle,
      thumbnails: _thumbnails(renderer),
    ));
  }

  /// Разбирает список элементов любого вида (треки и «плитки» вперемешку).
  static List<BrowseItem> itemsOf(dynamic contents) {
    final List<BrowseItem> items = <BrowseItem>[];
    if (contents is! List) return items;

    for (final dynamic item in contents) {
      if (item is! Map) continue;

      final dynamic responsive = item['musicResponsiveListItemRenderer'];
      if (responsive != null) {
        final BrowseItem? parsed = responsiveAny(responsive);
        if (parsed != null) items.add(parsed);
        continue;
      }
      final dynamic twoRow = item['musicTwoRowItemRenderer'];
      if (twoRow != null) {
        final BrowseItem? parsed = twoRowItem(twoRow);
        if (parsed != null) items.add(parsed);
      }
    }
    return items;
  }

  /// Runs подписи элемента (`subtitle.runs`) — у плиток исполнитель лежит там.
  static List<dynamic> _subtitleRuns(dynamic renderer) =>
      traverseList(renderer, <String>['subtitle', 'runs']);

  /// Текст подписи целиком, а не только первый run.
  ///
  /// `traverse(...,'text')` отдаёт первый найденный run, поэтому подпись
  /// «Композиция • Валентин Стрыкало» превращалась в «Композиция»: тип записи
  /// подставлялся на место автора. Собираем все runs подряд — разделитель
  /// «•» остаётся в тексте, и старый разбор по нему работает как раньше.
  static String _subtitleText(dynamic renderer) {
    final StringBuffer buffer = StringBuffer();
    for (final dynamic run in _subtitleRuns(renderer)) {
      if (run is Map && run['text'] is String) buffer.write(run['text']);
    }
    return buffer.toString().trim();
  }

  /// Исполнители, у которых есть ссылка на страницу.
  ///
  /// Именно такие runs дают и настоящее имя, и `browseId`: без идентификатора
  /// из меню трека нельзя открыть исполнителя. Служебные подписи
  /// («Композиция», «Song», «Видео») в имя не попадают, а страницы альбомов и
  /// плейлистов отбрасываются — это не исполнители.
  static List<ArtistRef> _linkedArtists(List<dynamic> runs) {
    final List<ArtistRef> artists = <ArtistRef>[];
    for (final dynamic run in runs) {
      if (run is! Map) continue;
      final String? text = textOf(run);
      if (text == null) continue;
      final String name = text.trim();
      if (name.isEmpty || name == '•') continue;
      if (_artistStopWords.contains(name.toLowerCase())) continue;

      final String? browseId = traverseString(run, <String>[
        'navigationEndpoint',
        'browseEndpoint',
        'browseId',
      ]);
      if (browseId == null || browseId.isEmpty) continue;

      final String pageType = traverseString(run, <String>[
            'navigationEndpoint',
            'browseEndpoint',
            'browseEndpointContextSupportedConfigs',
            'browseEndpointContextMusicConfig',
            'pageType',
          ]) ??
          '';
      if (_isNonArtistPage(browseId, pageType)) continue;

      artists.add(ArtistRef(name: name, id: browseId));
    }
    return artists;
  }

  /// Исполнители байлайна/подписи: сначала со ссылкой, иначе — из текста.
  ///
  /// Если у элемента нет ни одной ссылки на страницу (бывает у гостевых и
  /// урезанных ответов), сохраняем прежнее поведение — имя из текста подписи,
  /// чтобы автор не терялся вовсе.
  static List<ArtistRef> _artistsFromByline(
    List<dynamic> runs,
    String fallbackText,
  ) {
    final List<ArtistRef> linked = _linkedArtists(runs);
    if (linked.isNotEmpty) return linked;
    // Байлайн трека устроен так: «Исполнители • Альбом • 3:45». Исполнители —
    // всегда первый сегмент, всё после первого разделителя — альбом, год и
    // время. Раньше в фолбэк уходил весь текст, и альбом попадал в авторы:
    // в плеере под названием трека он печатался вторым исполнителем.
    return _artistsFromSubtitle(fallbackText.split('•').first);
  }

  /// Достаёт длительность из подписи вида «Исполнитель • 3:20».
  ///
  /// У клипов YouTube Music длительность приходит только в подписи, отдельного
  /// поля с ней нет. Сначала пробуем формат с часами (`1:02:33`): без него
  /// от часового клипа осталось бы только «1:02», то есть 1 минута 2 секунды.
  static Duration? _durationFromSubtitle(String? subtitle) {
    if (subtitle == null) return null;

    final RegExpMatch? long =
        RegExp(r'(?:^|\D)(\d{1,2}):(\d{2}):(\d{2})(?:\D|$)').firstMatch(subtitle);
    if (long != null) {
      return Duration(
        hours: int.parse(long.group(1)!),
        minutes: int.parse(long.group(2)!),
        seconds: int.parse(long.group(3)!),
      );
    }

    final RegExpMatch? match =
        RegExp(r'(?:^|\D)(\d{1,2}):(\d{2})(?:\D|$)').firstMatch(subtitle);
    if (match == null) return null;
    return Duration(
      minutes: int.parse(match.group(1)!),
      seconds: int.parse(match.group(2)!),
    );
  }

  static Duration? _durationFromRuns(List<dynamic> runs) {
    for (final dynamic run in runs) {
      final Duration? parsed = parseDurationText(textOf(run));
      if (parsed != null) return parsed;
    }
    return null;
  }

  /// Секции главной страницы / раздела (в порядке отображения).
  ///
  /// Разметка главной и поиска отличается только обёртками, поэтому разбор
  /// идёт общим кодом.
  static List<BrowseSection> homeSections(dynamic response) =>
      sectionsFrom(response);

  /// Текст заголовка страницы (для альбома, плейлиста, исполнителя).
  static String? pageTitle(dynamic response) {
    return _responsiveHeaderText(response, 'title') ??
        _firstString(response, <List<String>>[
      <String>['header', 'musicDetailHeaderRenderer', 'title', 'runs', 'text'],
      <String>['header', 'musicImmersiveHeaderRenderer', 'title', 'runs', 'text'],
      <String>['header', 'musicVisualHeaderRenderer', 'title', 'runs', 'text'],
      <String>['header', 'musicEditablePlaylistDetailHeaderRenderer', 'header',
          'musicDetailHeaderRenderer', 'title', 'runs', 'text'],
    ]);
  }

  /// Подзаголовок страницы (исполнители, год, число треков).
  static String? pageSubtitle(dynamic response) {
    return _responsiveHeaderText(response, 'subtitle') ??
        _firstString(response, <List<String>>[
      <String>['header', 'musicDetailHeaderRenderer', 'subtitle', 'runs', 'text'],
      <String>['header', 'musicImmersiveHeaderRenderer', 'subtitle', 'runs', 'text'],
      <String>['header', 'musicVisualHeaderRenderer', 'subtitle', 'runs', 'text'],
    ]);
  }

  /// Новая шапка страницы — `musicResponsiveHeaderRenderer`.
  ///
  /// Лежит она не по фиксированному пути: в разных ответах обёртки разные,
  /// поэтому ищем её по всему дереву. Если искать по пути вида
  /// `header → musicResponsiveHeaderRenderer`, шапка не находится, и страница
  /// остаётся без названия и без исполнителей.
  static Map<dynamic, dynamic>? _responsiveHeader(dynamic response) {
    for (final dynamic header
        in traverseList(response, <String>['musicResponsiveHeaderRenderer'])) {
      if (header is Map) return header;
    }
    return null;
  }

  /// Текст поля новой шапки (`title`, `subtitle`) одной строкой.
  static String? _responsiveHeaderText(dynamic response, String field) {
    final Map<dynamic, dynamic>? header = _responsiveHeader(response);
    if (header == null) return null;
    final String text = traverseList(header, <String>[field, 'runs', 'text'])
        .whereType<String>()
        .join()
        .trim();
    return text.isEmpty ? null : text;
  }

  /// Исполнители из шапки страницы.
  ///
  /// У новой шапки (`musicResponsiveHeaderRenderer`) исполнитель лежит не в
  /// подзаголовке, а в `straplineTextOne`: в подзаголовке там «Сингл • 2026»,
  /// то есть тип и год, а вовсе не автор. Из-за этого у альбомов список
  /// исполнителей шапки выходил пустым, подставлять трекам было нечего — и
  /// каждый трек показывался как «Неизвестный исполнитель».
  static List<ArtistRef> pageArtists(dynamic response) {
    final Map<dynamic, dynamic>? header = _responsiveHeader(response);
    final List<dynamic> runs = header == null
        ? <dynamic>[]
        : traverseList(header, <String>['straplineTextOne', 'runs']);
    if (runs.isNotEmpty) {
      final List<ArtistRef> linked = _linkedArtists(runs);
      if (linked.isNotEmpty) return linked;
      // Ссылки может не быть (урезанный или гостевой ответ) — берём хотя бы
      // имя из текста, иначе подпись исполнителя пропадёт вовсе.
      final String plain = runs
          .map(textOf)
          .whereType<String>()
          .join()
          .trim();
      if (plain.isNotEmpty) {
        return <ArtistRef>[ArtistRef(name: plain)];
      }
    }
    // Старая шапка: исполнитель в подзаголовке.
    return _artistsFromSubtitle(pageSubtitle(response));
  }

  /// Описание страницы.
  static String? pageDescription(dynamic response) {
    return _firstString(response, <List<String>>[
      <String>['header', 'musicDetailHeaderRenderer', 'description', 'runs', 'text'],
      <String>['header', 'musicImmersiveHeaderRenderer', 'description', 'runs', 'text'],
    ]);
  }

  /// Крупная обложка страницы (из шапки), а не мелкие превью из списков.
  static List<Thumbnail> pageThumbnails(dynamic response) {
    final List<Thumbnail> fromHeader =
        _thumbnails(traverse(response, <String>['header']));
    return fromHeader.isEmpty ? _thumbnails(response) : fromHeader;
  }

  /// Звуковой id плейлиста альбома (`OLAK5uy_…`) со страницы альбома.
  ///
  /// Под этим id альбом сохраняется в библиотеку и собирается в очередь:
  /// browse-идентификатор страницы (`MPREb_…`) сервер в мутации не понимает.
  /// YouTube кладёт его в кнопку «слушать» шапки, и у двух разметок она
  /// лежит в разных местах: у новой (`musicResponsiveHeaderRenderer`) —
  /// в `buttons[].musicPlayButtonRenderer`, у старой
  /// (`musicDetailHeaderRenderer`) — в `menu.topLevelButtons[].buttonRenderer`.
  /// Внутри самой кнопки id тоже бывает двух видов — `watchPlaylistEndpoint`
  /// и `watchEndpoint` (A/B-тест YouTube), поэтому пробуем оба.
  static String? albumAudioPlaylistId(dynamic response) {
    final Map<dynamic, dynamic>? header = _responsiveHeader(response);
    if (header != null) {
      final String? id = _audioPlaylistIdFromButtons(header['buttons']);
      if (id != null) return id;
    }

    final dynamic detail =
        traverse(response, <String>['header', 'musicDetailHeaderRenderer']);
    if (detail is Map) {
      return _audioPlaylistIdFromButtons(
        traverse(detail, <String>['menu', 'topLevelButtons']),
      );
    }
    return null;
  }

  /// Ищет id плейлиста в списке кнопок шапки: подходит и `musicPlayButtonRenderer`,
  /// и старый `buttonRenderer`.
  static String? _audioPlaylistIdFromButtons(dynamic buttons) {
    if (buttons is! List) return null;
    for (final dynamic entry in buttons) {
      if (entry is! Map) continue;
      final dynamic play =
          entry['musicPlayButtonRenderer'] ?? entry['buttonRenderer'];
      if (play is! Map) continue;
      final String? id = _firstString(play, <List<String>>[
        <String>['playNavigationEndpoint', 'watchPlaylistEndpoint', 'playlistId'],
        <String>['playNavigationEndpoint', 'watchEndpoint', 'playlistId'],
        <String>['navigationEndpoint', 'watchPlaylistEndpoint', 'playlistId'],
        <String>['navigationEndpoint', 'watchEndpoint', 'playlistId'],
      ]);
      if (id != null) return id;
    }
    return null;
  }

  /// Разбирает страницу плейлиста: заголовок, автор, обложки и треки.
  static Playlist parsePlaylistPage(dynamic response, {required String playlistId}) {
    final String title = _firstString(response, <List<String>>[
          <String>['header', 'musicDetailHeaderRenderer', 'title', 'runs', 'text'],
          <String>['header', 'musicEditablePlaylistDetailHeaderRenderer', 'header',
              'musicDetailHeaderRenderer', 'title', 'runs', 'text'],
        ]) ??
        'Плейлист';

    final String? author = _firstString(response, <List<String>>[
      <String>['header', 'musicDetailHeaderRenderer', 'subtitle', 'runs', 'text'],
    ]);

    final String? description = _firstString(response, <List<String>>[
      <String>['header', 'musicDetailHeaderRenderer', 'description', 'runs', 'text'],
    ]);

    return Playlist(
      id: playlistId,
      title: title,
      author: author,
      description: description,
      thumbnails: _thumbnails(response),
      tracks: playlistShelf(response, playlistId: playlistId),
    );
  }

  /// Разбирает страницу альбома.
  static Album parseAlbumPage(dynamic response, {required String albumId}) {
    final List<Track> tracks = <Track>[];
    for (final dynamic renderer
        in traverseList(response, <String>['musicShelfRenderer', 'contents'])) {
      if (renderer is! Map) continue;
      final Track? track = responsiveItem(renderer['musicResponsiveListItemRenderer']);
      if (track != null) tracks.add(track);
    }

    final String title = _firstString(response, <List<String>>[
          <String>['header', 'musicDetailHeaderRenderer', 'title', 'runs', 'text'],
        ]) ??
        'Альбом';

    final List<dynamic> subtitleRuns = traverseList(
      response,
      <String>['header', 'musicDetailHeaderRenderer', 'subtitle', 'runs'],
    );
    final String subtitleText = subtitleRuns
        .whereType<Map>()
        .map((Map run) => run['text']?.toString() ?? '')
        .join();

    return Album(
      id: albumId,
      title: title,
      artists: _artistsFromByline(subtitleRuns, subtitleText),
      year: _extractYear(subtitleText),
      thumbnails: _thumbnails(response),
      tracks: tracks,
      trackCount: tracks.isEmpty ? null : tracks.length,
    );
  }

  // ------------------------------------------------------------------ helpers

  static List<ArtistRef> _artistsFromColumns(List<dynamic> columns) {
    // Столбец №1 (индекс 1) — байлайн: «Исполнитель • Альбом • 3:45».
    final List<dynamic> runs = _runsOfColumn(columns, 1);
    if (runs.isEmpty) return const <ArtistRef>[];

    // Сначала — только исполнители со ссылкой: у них настоящее имя и browseId,
    // а связки («и») и служебные подписи без ссылки в список не попадают.
    final List<ArtistRef> linked = _linkedArtists(runs);
    if (linked.isNotEmpty) return linked;

    // Ссылок нет вовсе (урезанный/гостевой ответ) — прежнее поведение:
    // исполнителем считается любой осмысленный текст байлайна.
    return _artistsFromTextRuns(runs);
  }

  /// Разбор байлайна по тексту — фолбэк, когда ссылок на страницы нет.
  static List<ArtistRef> _artistsFromTextRuns(List<dynamic> runs) {
    final List<ArtistRef> artists = <ArtistRef>[];
    for (final dynamic run in runs) {
      if (run is! Map) continue;
      final String? text = textOf(run);
      if (text == null) continue;

      final String trimmed = text.trim();
      if (trimmed.isEmpty) continue;
      // Разделитель полей байлайна. Всё после первого — уже не исполнители:
      // там альбом, год, длительность и счётчики. Поэтому не «пропускаем», а
      // останавливаемся: иначе альбом попадал в список авторов.
      if (trimmed == '•') break;
      // Длительность и год исполнителями не являются.
      if (parseDurationText(trimmed) != null) continue;
      if (RegExp(r'^(19|20)\d{2}$').hasMatch(trimmed)) continue;
      // Служебные подписи YouTube.
      if (_artistStopWords.contains(trimmed.toLowerCase())) continue;

      // Ссылка на исполнителя есть не всегда: часто это просто текст.
      // Тогда тоже считаем его исполнителем — иначе имя теряется.
      final String? browseId = traverseString(run, <String>[
        'navigationEndpoint',
        'browseEndpoint',
        'browseId',
      ]);
      final String pageType = traverseString(run, <String>[
            'navigationEndpoint',
            'browseEndpoint',
            'browseEndpointContextSupportedConfigs',
            'browseEndpointContextMusicConfig',
            'pageType',
          ]) ??
          '';

      // Альбомы, плейлисты и прочие страницы — не исполнители.
      if (_isNonArtistPage(browseId, pageType)) continue;

      artists.add(ArtistRef(name: trimmed, id: browseId));
    }
    return artists;
  }

  /// Отличает страницу исполнителя от альбома, плейлиста и прочих сущностей.
  static bool _isNonArtistPage(String? browseId, String pageType) {
    if (pageType.contains('ALBUM') ||
        pageType.contains('PLAYLIST') ||
        pageType.contains('PODCAST') ||
        pageType.contains('TRACK')) {
      return true;
    }
    if (browseId == null || browseId.isEmpty) return false;
    // Альбомы YouTube Music начинаются с MPRE, плейлисты — с VL/PL/RD.
    return browseId.startsWith('MPRE') ||
        browseId.startsWith('VL') ||
        browseId.startsWith('PL') ||
        browseId.startsWith('RD');
  }

  /// Достаёт список «runs» из столбца строки.
  ///
  /// Важно: берём именно `traverseList`, а не `traverse`. Обход ответов
  /// «разворачивает» список на последнем шаге, поэтому `traverse` вернул бы
  /// один элемент, а не весь список, и разбор молча терял бы данные.
  static List<dynamic> _runsOfColumn(List<dynamic> columns, int index) {
    if (columns.length <= index) return const <dynamic>[];
    return traverseList(columns[index], <String>[
      'musicResponsiveListItemFlexColumnRenderer',
      'text',
      'runs',
    ]);
  }

  /// Слова, которые YouTube ставит на место исполнителя.
  static const Set<String> _artistStopWords = <String>{
    'композиция',
    'видео',
    'песня',
    'трек',
    'альбом',
    'сингл',
    'мини-альбом',
    'сборник',
    'подкаст',
    'song',
    'video',
    'album',
    'single',
    'ep',
  };

  static AlbumRef? _albumFromColumns(List<dynamic> columns) =>
      _albumFromRuns(_runsOfColumn(columns, 1));

  /// Альбом из набора runs: только настоящий альбом.
  ///
  /// Признак альбома — префикс идентификатора `MPRE…` либо тип страницы
  /// `ALBUM`. Ссылка на исполнителя (`UC…`, `MUSIC_PAGE_TYPE_ARTIST`) альбомом
  /// не считается: у карточки трека подпись — это исполнители, и раньше в
  /// «альбом» мог попасть кто угодно из подписи.
  static AlbumRef? _albumFromRuns(List<dynamic> runs) {
    for (final dynamic run in runs) {
      if (run is! Map) continue;
      final String? browseId = traverseString(run, <String>[
        'navigationEndpoint',
        'browseEndpoint',
        'browseId',
      ]);
      if (browseId == null || browseId.isEmpty) continue;

      final String pageType = traverseString(run, <String>[
            'navigationEndpoint',
            'browseEndpoint',
            'browseEndpointContextSupportedConfigs',
            'browseEndpointContextMusicConfig',
            'pageType',
          ]) ??
          '';
      // Если тип страницы известен — он решает; иначе смотрим на префикс.
      final bool isAlbum = pageType.isEmpty
          ? browseId.startsWith('MPRE')
          : pageType.contains('ALBUM');
      if (!isAlbum) continue;

      final String? name = textOf(run);
      if (name == null || name.trim().isEmpty) continue;
      return AlbumRef(name: name.trim(), id: browseId);
    }
    return null;
  }

  static Duration? _firstDuration(List<dynamic> columns) {
    for (int index = 0; index < columns.length; index++) {
      final List<dynamic> runs = _runsOfColumn(columns, index);
      for (final dynamic run in runs) {
        final String? text = textOf(run);
        final Duration? parsed = parseDurationText(text);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  /// Фолбэк: исполнители из текста подписи, когда ссылок на страницы нет.
  ///
  /// Служебные подписи («Композиция», «Song»), год, длительность и счётчики
  /// просмотров отбрасываются — иначе они попадали бы в имя автора.
  static List<ArtistRef> _artistsFromSubtitle(String? subtitle) {
    if (subtitle == null || subtitle.isEmpty) return const <ArtistRef>[];
    return subtitle
        .split('•')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .where((String s) => !_looksLikeYear(s))
        .where((String s) => parseDurationText(s) == null)
        .where((String s) => !_artistStopWords.contains(s.toLowerCase()))
        .where((String s) => !_looksLikeCount(s))
        .map((String s) => ArtistRef(name: s))
        .toList();
  }

  /// Счётчик («40 тыс. просмотров», «1.2M views») — не исполнитель.
  static bool _looksLikeCount(String value) {
    final String lower = value.toLowerCase();
    return lower.contains('просмотр') ||
        lower.contains('view') ||
        lower.contains('подписчик') ||
        lower.contains('subscriber') ||
        RegExp(r'^\d[\d\s.,]*\s*(тыс|млн|млрд|k|m|b)\.?$').hasMatch(lower);
  }

  static bool _looksLikeYear(String value) =>
      RegExp(r'^(19|20)\d{2}$').hasMatch(value.trim());

  static String? _extractYear(String? text) {
    if (text == null) return null;
    final RegExpMatch? match = RegExp(r'(19|20)\d{2}').firstMatch(text);
    return match?.group(0);
  }

  static List<Thumbnail> _thumbnails(dynamic node) {
    final List<Thumbnail> result = <Thumbnail>[];
    for (final dynamic thumb in traverseList(node, <String>['thumbnails'])) {
      if (thumb is! Map) continue;
      final dynamic url = thumb['url'];
      if (url is! String || url.isEmpty) continue;
      result.add(Thumbnail(
        url: url,
        width: (thumb['width'] as num?)?.toInt(),
        height: (thumb['height'] as num?)?.toInt(),
      ));
    }
    return result;
  }

  static bool _hasBadge(dynamic node, String badgeStyle) {
    for (final dynamic style in traverseList(node, <String>['badges', 'musicInlineBadgeRenderer', 'icon', 'iconType'])) {
      if (style == badgeStyle) return true;
    }
    return false;
  }

  static String? _firstString(dynamic node, List<List<String>> candidates) {
    for (final List<String> path in candidates) {
      final dynamic value = traverse(node, path);
      if (value is String && value.isNotEmpty) return value;
    }
    return null;
  }
}
