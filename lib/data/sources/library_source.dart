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

  /// Треки, которым поставлен лайк.
  Future<List<Track>> likedSongs() async {
    final Map<String, dynamic> res = await _client.browse(
      _browseLikedSongs,
      authenticated: true,
    );
    return BrowseParser.playlistShelf(res, playlistId: 'LM');
  }

  /// Все сохранённые треки (включая добавленные вручную).
  Future<List<Track>> librarySongs() async {
    final Map<String, dynamic> res = await _client.browse(
      _browseLibrarySongs,
      authenticated: true,
    );
    final List<Track> fromShelf =
        BrowseParser.playlistShelf(res, playlistId: 'LM');
    if (fromShelf.isNotEmpty) return fromShelf;

    // Раздел может прийти как обычная секция.
    final List<Track> tracks = <Track>[];
    for (final dynamic renderer
        in traverseList(res, <String>['musicResponsiveListItemRenderer'])) {
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
  Future<void> addToPlaylist(String playlistId, List<String> videoIds) {
    return _editPlaylist(
      playlistId,
      videoIds
          .map((String id) => <String, dynamic>{
                'action': 'ADD_VIDEO',
                'addedVideoId': id,
              })
          .toList(),
    );
  }

  /// Удаляет трек из плейлиста (по индексу в плейлисте).
  Future<void> removeFromPlaylist(String playlistId, String videoId) {
    return _editPlaylist(
      playlistId,
      <Map<String, dynamic>>[
        <String, dynamic>{
          'action': 'REMOVE_VIDEO',
          'removedVideoId': videoId,
        },
      ],
    );
  }

  Future<void> _editPlaylist(String playlistId, List<Map<String, dynamic>> actions) {
    return _client.mutate(
      'browse/edit_playlist',
      <String, dynamic>{
        // Внутренний id плейлиста обязан иметь префикс VL.
        'playlistId': playlistId.startsWith('VL') ? playlistId : 'VL$playlistId',
        'actions': actions,
      },
    );
  }
}
