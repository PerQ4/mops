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

    return Track(
      id: videoId,
      title: title,
      artists: artists,
      album: album,
      duration: duration,
      thumbnails: _thumbnails(renderer),
      isExplicit: _hasBadge(renderer, 'MUSIC_EXPLICIT_BADGE'),
      playlistId: playlistId,
    );
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
        artists: _artistsFromSubtitle(subtitle),
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

  /// Собирает текст второго столбца строки (исполнители, год, число треков).
  static String _byline(dynamic renderer) {
    final List<dynamic> columns =
        traverseList(renderer, <String>['flexColumns']).whereType<Map>().toList();
    if (columns.length < 2) return '';
    final List<dynamic> runs = _runsOfColumn(columns, 1);
    if (runs.isEmpty) return '';
    return runs
        .whereType<Map>()
        .map(textOf)
        .whereType<String>()
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty && s != '•')
        .join(' • ');
  }

  /// Разбирает `musicTwoRowItemRenderer` — плитку альбома/плейлиста/артиста.
  static BrowseItem? twoRowItem(dynamic renderer) {
    if (renderer is! Map) return null;

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
    final String? subtitle = _firstString(renderer, <List<String>>[
      <String>['subtitle', 'runs', 'text'],
    ]);

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
        artists: _artistsFromSubtitle(subtitle),
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
        artists: _artistsFromSubtitle(subtitle),
        thumbnails: thumbnails,
        duration: _durationFromSubtitle(subtitle) ?? Duration.zero,
      ));
    }

    return PlaylistItem(Playlist(
      id: browseId,
      title: title,
      author: subtitle,
      thumbnails: thumbnails,
    ));
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

    // Трек: у элемента есть watchEndpoint с videoId.
    final String? videoId = _firstString(renderer, <List<String>>[
      <String>['onTap', 'watchEndpoint', 'videoId'],
    ]);
    if (videoId != null && videoId.isNotEmpty) {
      final List<dynamic> runs =
          traverseList(renderer, <String>['subtitle', 'runs']);
      return TrackItem(Track(
        id: videoId,
        title: title,
        artists: _artistsFromRuns(runs),
        thumbnails: _thumbnails(renderer),
        duration: _durationFromRuns(runs) ?? Duration.zero,
      ));
    }

    // Иначе это страница: определяем тип по префиксу идентификатора.
    final String browseId = _firstString(renderer, <List<String>>[
          <String>['onTap', 'browseEndpoint', 'browseId'],
          <String>['navigationEndpoint', 'browseEndpoint', 'browseId'],
        ]) ??
        '';
    final String subtitle = _firstString(renderer, <List<String>>[
          <String>['subtitle', 'runs', 'text'],
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
        artists: _artistsFromSubtitle(subtitle),
        year: _extractYear(subtitle),
        thumbnails: _thumbnails(renderer),
      ));
    }
    return PlaylistItem(Playlist(
      id: browseId,
      title: title,
      author: subtitle,
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

  static List<ArtistRef> _artistsFromRuns(List<dynamic> runs) {
    final List<ArtistRef> artists = <ArtistRef>[];
    for (final dynamic run in runs) {
      if (run is! Map) continue;
      final String? name = textOf(run);
      if (name == null || name.trim() == '•' || name.trim().isEmpty) continue;
      final String? id = traverseString(run, <String>[
        'navigationEndpoint',
        'browseEndpoint',
        'browseId',
      ]);
      if (id == null) continue;
      artists.add(ArtistRef(name: name.trim(), id: id));
    }
    return artists;
  }

  /// Достаёт длительность из подписи вида «Исполнитель • 3:20».
  ///
  /// У клипов YouTube Music длительность приходит только в подписи, отдельного
  /// поля с ней нет.
  static Duration? _durationFromSubtitle(String? subtitle) {
    if (subtitle == null) return null;
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
    return _firstString(response, <List<String>>[
      <String>['header', 'musicDetailHeaderRenderer', 'title', 'runs', 'text'],
      <String>['header', 'musicImmersiveHeaderRenderer', 'title', 'runs', 'text'],
      <String>['header', 'musicVisualHeaderRenderer', 'title', 'runs', 'text'],
      <String>['header', 'musicEditablePlaylistDetailHeaderRenderer', 'header',
          'musicDetailHeaderRenderer', 'title', 'runs', 'text'],
    ]);
  }

  /// Подзаголовок страницы (исполнители, год, число треков).
  static String? pageSubtitle(dynamic response) {
    return _firstString(response, <List<String>>[
      <String>['header', 'musicDetailHeaderRenderer', 'subtitle', 'runs', 'text'],
      <String>['header', 'musicImmersiveHeaderRenderer', 'subtitle', 'runs', 'text'],
      <String>['header', 'musicVisualHeaderRenderer', 'subtitle', 'runs', 'text'],
    ]);
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

    final List<String> subtitleRuns = traverseStrings(
      response,
      <String>['header', 'musicDetailHeaderRenderer', 'subtitle', 'runs', 'text'],
    );

    return Album(
      id: albumId,
      title: title,
      artists: _artistsFromSubtitle(subtitleRuns.join(' ')),
      year: _extractYear(subtitleRuns.join(' ')),
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

    final List<ArtistRef> artists = <ArtistRef>[];
    for (final dynamic run in runs) {
      if (run is! Map) continue;
      final String? text = textOf(run);
      if (text == null) continue;

      final String trimmed = text.trim();
      if (trimmed.isEmpty) continue;
      // Разделители между сущностями — «•».
      if (trimmed == '•') continue;
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

  static AlbumRef? _albumFromColumns(List<dynamic> columns) {
    final List<dynamic> runs = _runsOfColumn(columns, 1);
    if (runs.isEmpty) return null;

    for (final dynamic run in runs) {
      if (run is! Map) continue;
      final String? browseId = traverseString(run, <String>[
        'navigationEndpoint',
        'browseEndpoint',
        'browseId',
      ]);
      if (browseId == null) continue;
      if (!browseId.startsWith('MPRE')) continue; // альбомы имеют префикс MPRE
      final String? name = textOf(run);
      if (name == null) continue;
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

  static List<ArtistRef> _artistsFromSubtitle(String? subtitle) {
    if (subtitle == null || subtitle.isEmpty) return const <ArtistRef>[];
    return subtitle
        .split('•')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty && !_looksLikeYear(s))
        .map((String s) => ArtistRef(name: s))
        .toList();
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
