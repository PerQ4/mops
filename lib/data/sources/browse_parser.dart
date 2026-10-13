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
        final Track? track = responsiveItem(responsive);
        if (track != null) items.add(TrackItem(track));
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

  /// Продолжение списка (для подгрузки «ещё») — токен и позиция.
  static String? continuationToken(dynamic node) {
    final dynamic value = traverse(node, <String>[
      'continuations',
    ]);
    if (value is List) {
      for (final dynamic c in value) {
        if (c is Map) {
          final dynamic token =
              traverse(c, <String>['nextContinuationData', 'continuation']);
          if (token is String) return token;
        }
      }
    }
    return traverseString(node, <String>[
      'continuationContents',
      'sectionListContinuation',
    ]);
  }

  /// Универсальный разбор секций: находит в ответе все полки и карусели.
  ///
  /// Подходит и для главной, и для поиска, и для страницы исполнителя:
  /// структура везде одна — `sectionListRenderer.contents`, внутри которого
  /// лежат `musicShelfRenderer` и `musicCarouselShelfRenderer`
  /// (иногда завёрнутые в `itemSectionRenderer.content`).
  static List<BrowseSection> sectionsFrom(dynamic response) {
    final List<BrowseSection> sections = <BrowseSection>[];

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

    return sections;
  }

  /// Секции главной страницы / раздела (в порядке отображения).
  static List<BrowseSection> homeSections(dynamic response) {
    final List<BrowseSection> sections = <BrowseSection>[];

    for (final dynamic renderer
        in traverseList(response, <String>['sectionListRenderer', 'contents'])) {
      if (renderer is! Map) continue;

      final dynamic carousel = renderer['musicCarouselShelfRenderer'];
      if (carousel != null) {
        final BrowseSection? section = shelf(carousel);
        if (section != null) sections.add(section);
        continue;
      }

      final dynamic shelfRenderer = renderer['musicShelfRenderer'];
      if (shelfRenderer != null) {
        final BrowseSection? section = shelf(shelfRenderer);
        if (section != null) sections.add(section);
      }
    }

    // Если разметка изменилась — откатываемся на универсальный разбор.
    return sections.isEmpty ? sectionsFrom(response) : sections;
  }

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
    if (columns.length < 2) return const <ArtistRef>[];
    final Map? column = columns[1] as Map?;
    final dynamic runs = traverse(column, <String>[
      'musicResponsiveListItemFlexColumnRenderer',
      'text',
      'runs',
    ]);
    if (runs is! List) return const <ArtistRef>[];

    final List<ArtistRef> artists = <ArtistRef>[];
    for (final dynamic run in runs) {
      if (run is! Map) continue;
      final String? text = textOf(run);
      if (text == null || text.trim().isEmpty) continue;
      // Разделители между сущностями — «•».
      if (text.trim() == '•') continue;
      final String? artistId = traverseString(run, <String>[
        'navigationEndpoint',
        'browseEndpoint',
        'browseId',
      ]);
      if (artistId == null) continue; // не ссылка — значит это альбом или длительность
      artists.add(ArtistRef(name: text.trim(), id: artistId));
    }
    return artists;
  }

  static AlbumRef? _albumFromColumns(List<dynamic> columns) {
    if (columns.length < 2) return null;
    final Map? column = columns[1] as Map?;
    final dynamic runs = traverse(column, <String>[
      'musicResponsiveListItemFlexColumnRenderer',
      'text',
      'runs',
    ]);
    if (runs is! List) return null;

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
    for (final dynamic column in columns) {
      final dynamic runs = traverse(column, <String>[
        'musicResponsiveListItemFlexColumnRenderer',
        'text',
        'runs',
      ]);
      if (runs is! List) continue;
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
