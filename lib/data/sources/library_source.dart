import 'dart:typed_data';

import '../../core/innertube/innertube_client.dart';
import '../../core/innertube/renderer.dart';
import '../models/models.dart';
import 'browse_parser.dart';

/// Информация об аккаунте, в который выполнен вход.
class AccountInfo {
  const AccountInfo({
    this.name,
    this.channelId,
    this.handle,
    this.avatarUrl,
  });

  final String? name;
  final String? channelId;
  final String? handle;
  final String? avatarUrl;
}

/// Отказ при смене обложки с текстом, понятным пользователю.
///
/// Отдельный тип, потому что причины разные, а `describeError` сводит все
/// ответы 401/403 к «нужен вход»: для чужого плейлиста это неправда.
class PlaylistImageException implements Exception {
  const PlaylistImageException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Операции, доступные только после входа в аккаунт.
///
/// Все вызовы идут через [InnerTubeClient] с `authenticated: true`.
/// Ошибки авторизации пробрасываются как [InnerTubeException] с
/// `isUnauthorized == true` — слой выше по этому признаку разлогинивает.
class LibrarySource {
  LibrarySource(this._client);

  final InnerTubeClient _client;

  // BrowseId разделов библиотеки YouTube Music.
  static const String _browseLikedPlaylists = 'FEmusic_liked_playlists';
  static const String _browseLikedAlbums = 'FEmusic_liked_albums';
  static const String _browseLikedSongs = 'VLLM';
  static const String _browseLibrarySongs = 'FEmusic_liked_videos';
  static const String _browseLibraryArtists =
      'FEmusic_library_corpus_track_artists';
  static const String _browseSubscriptions = 'FEmusic_library_corpus_artists';

  /// Имя аккаунта, аватар и id канала.
  Future<AccountInfo> accountInfo() async {
    final Map<String, dynamic> res = await _client.post(
      'account/account_menu',
      body: <String, dynamic>{},
      authenticated: true,
    );

    final dynamic header = traverse(res, <String>[
      'actions',
      'openPopupAction',
      'popup',
      'multiPageMenuRenderer',
      'header',
      'activeAccountHeaderRenderer',
    ]);

    if (header is! Map) return const AccountInfo();

    final String? name = traverseString(header, <String>['accountName', 'runs', 'text']);
    final String? handle =
        traverseString(header, <String>['channelHandle', 'runs', 'text']);

    String? avatar;
    for (final dynamic thumb in traverseList(header, <String>['accountPhoto', 'thumbnails'])) {
      if (thumb is Map && thumb['url'] is String) {
        avatar = thumb['url'] as String; // берём последний — самый крупный
      }
    }

    return AccountInfo(
      name: name,
      handle: handle,
      avatarUrl: avatar,
      channelId: traverseString(header, <String>[
        'accountByline',
        'runs',
        'navigationEndpoint',
        'browseEndpoint',
        'browseId',
      ]),
    );
  }

  /// Плейлисты пользователя.
  Future<List<Playlist>> likedPlaylists() async {
    final Map<String, dynamic> res = await _client.browse(
      _browseLikedPlaylists,
      authenticated: true,
    );
    return _playlistsFromResponse(res);
  }

  /// Альбомы, сохранённые в библиотеке.
  ///
  /// Отдельный раздел: YouTube хранит альбомы не вместе с плейлистами, и без
  /// него кнопка «В библиотеке» не находила бы подтверждения сервера после
  /// сохранения альбома. Отдаём именно страницы альбомов (`MPREb_…`) — по
  /// этому id кнопка на странице альбома и сверяется со списком.
  Future<List<Album>> likedAlbums() async {
    final Map<String, dynamic> res = await _client.browse(
      _browseLikedAlbums,
      authenticated: true,
    );
    return _albumsFromResponse(res);
  }

  /// `browseId` плейлиста «Мне нравится».
  ///
  /// Именно он приходит в списке плейлистов библиотеки (`likedPlaylists`),
  /// поэтому плитка открывает экран плейлиста с этим id.
  static const String likedPlaylistBrowseId = 'VLLM';

  /// id, под которым лайкнутый плейлист известен внутри API и в очереди.
  static const String likedPlaylistQueueId = 'LM';

  /// Относится ли id к плейлисту «Мне нравится».
  ///
  /// Проверяем оба варианта: страница библиотеки использует `browseId` (`VLLM`),
  /// а ссылки из очереди и старой разметки — `playlistId` (`LM`).
  static bool isLikedPlaylist(String id) =>
      id == likedPlaylistBrowseId || id == likedPlaylistQueueId;

  /// Треки, которым поставлен лайк.
  Future<List<Track>> likedSongs() async {
    final ({Map<String, dynamic> first, List<Track> tracks}) page =
        await _allShelfTracks(_browseLikedSongs, likedPlaylistQueueId);
    return page.tracks;
  }

  /// Полная полка треков: первая страница плюс все продолжения.
  ///
  /// YouTube отдаёт за раз лишь часть списка (для «Мне нравится» и длинных
  /// плейлистов — первую страницу), остальное докручивается токеном
  /// продолжения. Без этого списки обрывались, и треков было «не все».
  Future<({Map<String, dynamic> first, List<Track> tracks})> _allShelfTracks(
    String browseId,
    String playlistId,
  ) async {
    final Map<String, dynamic> first =
        await _client.browse(browseId, authenticated: true);

    final List<Track> tracks = <Track>[
      ...BrowseParser.playlistShelf(first, playlistId: playlistId),
      ..._responsiveItems(first, playlistId: playlistId),
    ];

    String? token = BrowseParser.continuationToken(first);
    int guard = 0;
    while (token != null && guard++ < 80) {
      final Map<String, dynamic> page = await _client.browse(
        browseId,
        continuation: token,
        authenticated: true,
      );
      final List<Track> more = <Track>[
        ...BrowseParser.playlistShelf(page, playlistId: playlistId),
        ...BrowseParser.playlistShelfContinuation(page, playlistId: playlistId),
        // Страницы продолжения приходят не «полкой», а просто списком
        // элементов. Без этого разбора цикл обрывался на первой странице, и
        // «Мне нравится» показывал ровно 100 треков вместо всех — а вместе с
        // ним и множество лайков, из-за чего уже лайкнутый трек выглядел
        // нелайкнутым. Так же собирает треки `CatalogSource._tracksFrom`.
        ..._responsiveItems(page, playlistId: playlistId),
      ];
      if (more.isEmpty) break;
      tracks.addAll(more);
      token = BrowseParser.continuationToken(page);
    }

    return (first: first, tracks: _dedupe(tracks));
  }

  /// Все элементы списка на странице, независимо от того, обёрнуты ли они
  /// в «полку»: на страницах продолжения обёртки нет.
  List<Track> _responsiveItems(dynamic response, {required String playlistId}) {
    final List<Track> tracks = <Track>[];
    for (final dynamic renderer
        in traverseList(response, <String>['musicResponsiveListItemRenderer'])) {
      final Track? track = BrowseParser.responsiveItem(
        renderer,
        fallbackPlaylistId: playlistId,
      );
      if (track != null) tracks.add(track);
    }
    return tracks;
  }

  /// Убирает дубликаты по id, сохраняя порядок.
  List<Track> _dedupe(List<Track> tracks) {
    final Set<String> seen = <String>{};
    final List<Track> result = <Track>[];
    for (final Track track in tracks) {
      if (seen.add(track.id)) result.add(track);
    }
    return result;
  }

  /// Плейлист «Мне нравится» целиком — для экрана плейлиста.
  ///
  /// Отдельный метод, а не `CatalogSource.playlist`: тот запрашивает раздел
  /// без `authenticated: true`, а гостю YouTube не отдаёт лайкнутые треки —
  /// страница открывалась пустой. Здесь запрос всегда авторизованный.
  Future<Playlist> likedSongsPlaylist() async {
    final ({Map<String, dynamic> first, List<Track> tracks}) page =
        await _allShelfTracks(likedPlaylistBrowseId, likedPlaylistQueueId);
    final Map<String, dynamic> res = page.first;
    final List<Track> tracks = page.tracks;

    // Обложки в шапке у лайкнутого плейлиста обычно нет — тогда берём её
    // у первого трека, иначе герой страницы остался бы серой заглушкой.
    final List<Thumbnail> headerThumbs = BrowseParser.pageThumbnails(res);
    final List<Thumbnail> thumbs = headerThumbs.isNotEmpty
        ? headerThumbs
        : (tracks.isEmpty ? const <Thumbnail>[] : tracks.first.thumbnails);

    return Playlist(
      id: likedPlaylistBrowseId,
      title: 'Мне нравится',
      thumbnails: thumbs,
      tracks: tracks,
      trackCount: tracks.isEmpty ? null : tracks.length,
      duration: _totalDuration(tracks),
    );
  }

  /// Суммарная длительность — для подписи «N треков • 1 ч 20 мин».
  Duration? _totalDuration(List<Track> tracks) {
    Duration total = Duration.zero;
    for (final Track track in tracks) {
      total += track.duration;
    }
    return total == Duration.zero ? null : total;
  }

  /// Все сохранённые треки (включая добавленные вручную).
  Future<List<Track>> librarySongs() async {
    final ({Map<String, dynamic> first, List<Track> tracks}) page =
        await _allShelfTracks(_browseLibrarySongs, 'LM');
    if (page.tracks.isNotEmpty) return page.tracks;

    // Раздел может прийти как обычная секция.
    final List<Track> tracks = <Track>[];
    for (final dynamic renderer
        in traverseList(page.first, <String>['musicResponsiveListItemRenderer'])) {
      final Track? track = BrowseParser.responsiveItem(renderer);
      if (track != null) tracks.add(track);
    }
    return tracks;
  }

  /// Исполнители, чьи треки сохранены в библиотеке.
  Future<List<Artist>> libraryArtists() =>
      _artistsFromBrowse(_browseLibraryArtists);

  /// Каналы, на которые оформлена подписка.
  Future<List<Artist>> subscriptions() => _artistsFromBrowse(_browseSubscriptions);

  Future<List<Artist>> _artistsFromBrowse(String browseId) async {
    final Map<String, dynamic> res =
        await _client.browse(browseId, authenticated: true);

    final List<Artist> artists = <Artist>[];
    for (final dynamic renderer
        in traverseList(res, <String>['musicResponsiveListItemRenderer'])) {
      final Artist? artist = _artistFromResponsive(renderer);
      if (artist != null) artists.add(artist);
    }
    for (final dynamic renderer
        in traverseList(res, <String>['musicTwoRowItemRenderer'])) {
      final BrowseItem? item = BrowseParser.twoRowItem(renderer);
      if (item is ArtistItem) artists.add(item.artist);
    }
    return artists;
  }

  Artist? _artistFromResponsive(dynamic renderer) {
    if (renderer is! Map) return null;
    final String? channelId = traverseString(renderer, <String>[
      'navigationEndpoint',
      'browseEndpoint',
      'browseId',
    ]);
    if (channelId == null || !channelId.startsWith('UC')) return null;

    final String name =
        traverseString(renderer, <String>[
              'flexColumns',
              'musicResponsiveListItemFlexColumnRenderer',
              'text',
              'runs',
              'text',
            ]) ??
        '';

    final List<Thumbnail> thumbs = <Thumbnail>[];
    for (final dynamic t in traverseList(renderer, <String>['thumbnails'])) {
      if (t is Map && t['url'] is String) {
        thumbs.add(Thumbnail(
          url: t['url'] as String,
          width: (t['width'] as num?)?.toInt(),
        ));
      }
    }

    return Artist(id: channelId, name: name, thumbnails: thumbs);
  }

  List<Playlist> _playlistsFromResponse(Map<String, dynamic> res) {
    final List<Playlist> playlists = <Playlist>[];
    for (final dynamic renderer
        in traverseList(res, <String>['musicTwoRowItemRenderer'])) {
      final BrowseItem? item = BrowseParser.twoRowItem(renderer);
      if (item is PlaylistItem) playlists.add(item.playlist);
    }
    return playlists;
  }

  /// Альбомы из раздела библиотеки: плитки `musicTwoRowItemRenderer`.
  ///
  /// Разбор общий с каталогом ([BrowseParser.twoRowItem]): у альбома
  /// browse-идентификатор начинается с `MPRE`, по нему тип и определяется.
  List<Album> _albumsFromResponse(Map<String, dynamic> res) {
    final List<Album> albums = <Album>[];
    for (final dynamic renderer
        in traverseList(res, <String>['musicTwoRowItemRenderer'])) {
      final BrowseItem? item = BrowseParser.twoRowItem(renderer);
      if (item is AlbumItem) albums.add(item.album);
    }
    return albums;
  }

  // --------------------------------------------------------------- мутации

  /// Ставит или снимает лайк.
  Future<void> setLiked(String videoId, {required bool liked}) {
    return _client.mutate(
      liked ? 'like/like' : 'like/removelike',
      <String, dynamic>{
        'target': <String, dynamic>{'videoId': videoId},
      },
    );
  }

  /// Ставит или снимает дизлайк.
  Future<void> setDisliked(String videoId, {required bool disliked}) {
    return _client.mutate(
      disliked ? 'like/dislike' : 'like/removelike',
      <String, dynamic>{
        'target': <String, dynamic>{'videoId': videoId},
      },
    );
  }

  /// Оформляет или отменяет подписку на канал.
  Future<void> setSubscribed(String channelId, {required bool subscribed}) {
    return _client.mutate(
      subscribed ? 'subscription/subscribe' : 'subscription/unsubscribe',
      <String, dynamic>{
        'channelIds': <String>[channelId],
      },
    );
  }

  /// Сохраняет плейлист или альбом в библиотеку (или убирает из неё).
  ///
  /// YouTube Music не различает эти случаи: «добавить в библиотеку» — та же
  /// мутация, что и лайк, только `target` не `videoId`, а `playlistId`.
  /// [playlistId] — то, что принимает сервер: у плейлиста его собственный id,
  /// у альбома звуковой id плейлиста (`OLAK5uy_…`), а не browse-идентификатор
  /// страницы (`MPREb_…`) — последний сервер не понимает.
  Future<void> setSaved({required String playlistId, required bool saved}) {
    // У плейлистов `Playlist.id` — это browse-идентификатор страницы с
    // префиксом `VL` (`VLPL…`, `VLLM`), а мутация принимает «сырой» id, как и
    // очередь (ср. `likedPlaylistQueueId`). Снимаем префикс — так же, как это
    // делает `_editPlaylist` ниже.
    return _client.mutate(
      saved ? 'like/like' : 'like/removelike',
      <String, dynamic>{
        'target': <String, dynamic>{'playlistId': _rawPlaylistId(playlistId)},
      },
    );
  }

  /// Создаёт плейлист и возвращает его id.
  ///
  /// [privacyStatus]: `PRIVATE`, `PUBLIC` или `UNLISTED`.
  Future<String?> createPlaylist({
    required String title,
    String description = '',
    String privacyStatus = 'PRIVATE',
    List<String> videoIds = const <String>[],
  }) async {
    final Map<String, dynamic> res = await _client.mutate(
      'playlist/create',
      <String, dynamic>{
        'title': title,
        'description': description,
        'privacyStatus': privacyStatus,
        if (videoIds.isNotEmpty) 'videoIds': videoIds,
      },
    );
    return traverseString(res, <String>['playlistId']);
  }

  /// Добавляет треки в плейлист.
  ///
  /// Ограничение YouTube: не больше сотни треков за запрос — вызывающий сам
  /// режет длинные списки (см. `SpotifyImporter`).
  Future<void> addToPlaylist(String playlistId, List<String> videoIds) {
    return _editPlaylist(
      playlistId,
      videoIds
          .map((String id) => <String, dynamic>{
                // Именно `ACTION_ADD_VIDEO`, а не короткое `ADD_VIDEO`:
                // так делает и эталон ArchiveTune, и текущий ytmusicapi.
                'action': 'ACTION_ADD_VIDEO',
                'addedVideoId': id,
              })
          .toList(),
    );
  }

  /// Удаляет трек из плейлиста.
  ///
  /// Серверу мало одного `removedVideoId`: нужен ещё `setVideoId` записи —
  /// YouTube отдаёт его вместе с треком на странице плейлиста
  /// (`Track.setVideoId`), и только для плейлистов, которые пользователь
  /// может править. Без него удаление отклоняется, поэтому он обязателен.
  Future<void> removeFromPlaylist(
    String playlistId,
    String videoId, {
    required String setVideoId,
  }) {
    return _editPlaylist(
      playlistId,
      <Map<String, dynamic>>[
        <String, dynamic>{
          'action': 'ACTION_REMOVE_VIDEO',
          'setVideoId': setVideoId,
          'removedVideoId': videoId,
        },
      ],
    );
  }

  /// Переименовывает плейлист.
  ///
  /// Действие `ACTION_SET_PLAYLIST_NAME` с полем `playlistName` — как в
  /// ArchiveTune (`EditPlaylistBody.RenamePlaylistAction`) и ytmusicapi.
  Future<void> renamePlaylist(String playlistId, String title) {
    return _editPlaylist(
      playlistId,
      <Map<String, dynamic>>[
        <String, dynamic>{
          'action': 'ACTION_SET_PLAYLIST_NAME',
          'playlistName': title,
        },
      ],
    );
  }

  /// Удаляет плейлист целиком.
  ///
  /// Отдельный эндпоинт `playlist/delete`, а не действие правки: так же
  /// удаляет и ArchiveTune, и ytmusicapi.
  Future<void> deletePlaylist(String playlistId) async {
    final Map<String, dynamic> response = await _client.mutate(
      'playlist/delete',
      <String, dynamic>{'playlistId': _rawPlaylistId(playlistId)},
    );
    _requireSucceeded(response, 'удалить плейлист');
  }

  /// Предел размера обложки плейлиста — 2 МиБ.
  static const int maxPlaylistImageBytes = 2 * 1024 * 1024;

  /// Ставит свою обложку плейлиста.
  ///
  /// Обложка меняется в два этапа, и это не прихоть клиента: файл уходит на
  /// отдельный `playlist_image_upload` по ресайзбл-протоколу и возвращает
  /// зашифрованный blob-id, а к плейлисту он привязывается обычной мутацией
  /// `browse/edit_playlist` с действием `ACTION_SET_CUSTOM_THUMBNAIL`.
  /// Формат обоих запросов восстановлен по живому трафику веб-клиента
  /// (ytmusicapi, issue #711 и PR #866); официально он не описан.
  ///
  /// [imageBytes] — уже квадратный PNG (его готовит кроппер). Размер
  /// проверяется здесь, а не только в интерфейсе: сервер тоже откажет, но
  /// его ответ не объясняет, что именно не так.
  Future<void> setPlaylistImage(String playlistId, Uint8List imageBytes) async {
    if (isLikedPlaylist(playlistId)) {
      throw const PlaylistImageException(
        'У плейлиста «Мне нравится» своей обложки нет: YouTube собирает её '
        'из обложек треков.',
      );
    }
    if (imageBytes.isEmpty) {
      throw const PlaylistImageException('Файл обложки пуст.');
    }
    if (imageBytes.length > maxPlaylistImageBytes) {
      throw PlaylistImageException(
        'Обложка весит ${(imageBytes.length / (1024 * 1024)).toStringAsFixed(1)} МБ '
        'при пределе 2 МБ. Уменьшите картинку.',
      );
    }

    // Конфигурацию получаем до загрузки: если страница YouTube Music не
    // открылась (регион, сеть), это не «нет прав на плейлист», и выдавать
    // ошибку за отказ сервера нельзя.
    await _client.bootstrap();

    try {
      final Map<String, dynamic> uploaded = await _client.uploadResumable(
        '/playlist_image_upload/playlist_custom_thumbnail',
        bytes: imageBytes,
        contentType: 'image/png',
      );

      final dynamic rawBlob = uploaded['encryptedBlobId'] ??
          uploaded['playlistScottyEncryptedBlobId'];
      final String? blob =
          rawBlob is String && rawBlob.isNotEmpty ? rawBlob : null;
      if (blob == null) {
        // Файл мог уехать, но без id его не к чему привязать. Молча
        // «успехом» это считать нельзя.
        throw const PlaylistImageException(
          'YouTube принял файл, но не вернул идентификатор обложки. '
          'Обложка не изменена.',
        );
      }

      // Последний шаг — обычная правка плейлиста, но статус проверяем строго:
      // если сервер его не прислал, подтвердить смену нельзя, и молчать об
      // этом (как `_requireSucceeded`) значит показать ложный успех.
      final Map<String, dynamic> response = await _client.mutate(
        'browse/edit_playlist',
        <String, dynamic>{
          'playlistId': _rawPlaylistId(playlistId),
          'actions': <Map<String, dynamic>>[
            <String, dynamic>{
              'action': 'ACTION_SET_CUSTOM_THUMBNAIL',
              'addedCustomThumbnail': <String, dynamic>{
                'imageKey': <String, dynamic>{
                  'type': 'PLAYLIST_IMAGE_TYPE_CUSTOM_THUMBNAIL',
                  'name': 'studio_square_thumbnail',
                },
                'playlistScottyEncryptedBlobId': blob,
              },
            },
          ],
        },
      );
      final dynamic status = response['status'];
      if (status is! String || status != 'STATUS_SUCCEEDED') {
        throw PlaylistImageException(
          status is String && status.isNotEmpty
              ? 'YouTube не сменил обложку: сервер ответил «$status».'
              : 'YouTube не подтвердил смену обложки. Откройте плейлист '
                  'и проверьте: возможно, изменение не применилось.',
        );
      }
    } on InnerTubeException catch (error) {
      throw PlaylistImageException(_imageErrorMessage(error));
    }
  }

  /// Переводит сетевую ошибку загрузки обложки в объяснение.
  static String _imageErrorMessage(InnerTubeException error) {
    switch (error.statusCode) {
      case 401:
        return 'Сессия истекла — войдите в аккаунт заново и повторите.';
      case 403:
        return 'YouTube не разрешил сменить обложку. Это можно делать только '
            'в своём плейлисте и только под своим аккаунтом.';
      case 413:
        return 'Файл слишком большой для YouTube. Уменьшите картинку '
            'и попробуйте снова.';
      default:
        if (error.statusCode == null) return error.message;
        return '${error.message}. YouTube не принял обложку.';
    }
  }

  /// Правка плейлиста одним запросом (`browse/edit_playlist`).
  ///
  /// Сервер ждёт «сырой» id без префикса `VL` (`ytmusicapi.validate_playlist_id`
  /// и ArchiveTune снимают его) — с префиксом запрос завершается статусом
  /// ошибки, хотя для `browse` тот же id с `VL` и нужен.
  Future<void> _editPlaylist(
    String playlistId,
    List<Map<String, dynamic>> actions,
  ) async {
    final Map<String, dynamic> response = await _client.mutate(
      'browse/edit_playlist',
      <String, dynamic>{
        'playlistId': _rawPlaylistId(playlistId),
        'actions': actions,
      },
    );
    _requireSucceeded(response, 'изменить плейлист');
  }

  /// «Сырой» id плейлиста — то, что принимают мутации (`browse` просит `VL`).
  static String _rawPlaylistId(String playlistId) =>
      playlistId.startsWith('VL') ? playlistId.substring(2) : playlistId;

  /// Проверяет статус ответа мутации плейлиста.
  ///
  /// `browse/edit_playlist` и `playlist/delete` возвращают поле `status`; при
  /// отказе (например, правка чужого плейлиста) там не `STATUS_SUCCEEDED`.
  /// Раньше это молча считалось успехом — интерфейс сообщал об изменении,
  /// которого не произошло. Если поля нет вовсе, запрос считаем успешным:
  /// его содержат не все ответы.
  static void _requireSucceeded(Map<String, dynamic> response, String action) {
    final dynamic status = response['status'];
    if (status is! String || status == 'STATUS_SUCCEEDED') return;
    throw InnerTubeException('Не удалось $action: сервер ответил «$status».');
  }
}
