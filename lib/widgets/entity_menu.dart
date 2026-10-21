import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/blocked_artists.dart';
import '../data/models/models.dart';
import '../data/sources/library_source.dart';
import '../features/common/navigation.dart';
import '../state/auth_controller.dart';
import '../state/catalog_providers.dart';
import '../state/library_providers.dart';
import '../state/player_controller.dart';
import 'async_views.dart';

/// Контекстные меню альбома, исполнителя и плейлиста.
///
/// Меню открывается у курсора: карточка в ленте не имеет «шапки», к которой
/// можно было бы привязать шторку, а `showMenu` даёт привычное десктопное
/// поведение. Пункты повторяют кнопки шапок страниц: своих запросов здесь нет,
/// все действия идут через те же провайдеры.

enum _AlbumAction { play, shuffle, enqueue, save, open }

enum _ArtistAction { play, shuffle, enqueue, subscribe, block, open }

enum _PlaylistAction { play, shuffle, enqueue, open }

/// Ширина меню. Умолчание Material 3 (280) тесно для подписей с иконкой:
/// «Сохранить в библиотеку» и «Заблокировать исполнителя» в него не влезают.
const BoxConstraints _menuConstraints = BoxConstraints(
  minWidth: 200,
  maxWidth: 320,
);

/// Меню альбома: воспроизведение, сохранение в библиотеку и переход.
Future<void> showAlbumMenu(
  BuildContext context,
  WidgetRef ref,
  Album album, {
  required Offset position,
}) async {
  final bool signedIn = ref.read(authControllerProvider).isSignedIn;
  final bool saved = ref.read(savedIdsProvider).contains(album.id);
  final String? playlistId = album.audioPlaylistId;
  // Как и кнопка в шапке: без входа сохранять некуда, а без звукового id
  // сервер не поймёт, что именно сохранять.
  final bool canSave = signedIn && playlistId != null && playlistId.isNotEmpty;

  final _AlbumAction? action = await showMenu<_AlbumAction>(
    context: context,
    position: _menuPosition(context, position),
    constraints: _menuConstraints,
    items: <PopupMenuEntry<_AlbumAction>>[
      _entry(_AlbumAction.play, Icons.play_arrow, 'Играть'),
      _entry(_AlbumAction.shuffle, Icons.shuffle, 'Перемешать'),
      _entry(_AlbumAction.enqueue, Icons.playlist_add, 'В очередь'),
      const PopupMenuDivider(),
      _entry(
        _AlbumAction.save,
        saved ? Icons.library_add_check : Icons.library_add,
        saved ? 'Убрать из библиотеки' : 'Сохранить в библиотеку',
        enabled: canSave,
      ),
      const PopupMenuDivider(),
      _entry(
        _AlbumAction.open,
        Icons.album_outlined,
        'Открыть страницу',
        enabled: album.id.isNotEmpty,
      ),
    ],
  );
  if (action == null || !context.mounted) return;

  switch (action) {
    case _AlbumAction.play:
      await _play(context, ref, () => _albumTracks(ref, album));
    case _AlbumAction.shuffle:
      await _play(
        context,
        ref,
        () => _albumTracks(ref, album),
        shuffle: true,
      );
    case _AlbumAction.enqueue:
      await _enqueue(context, ref, () => _albumTracks(ref, album));
    case _AlbumAction.save:
      await _toggleSaved(
        context,
        ref,
        album,
        playlistId: playlistId!,
        saved: saved,
      );
    case _AlbumAction.open:
      unawaited(AppRoutes.album(context, album.id));
  }
}

/// Меню исполнителя: воспроизведение, подписка, локальная блокировка.
Future<void> showArtistMenu(
  BuildContext context,
  WidgetRef ref,
  Artist artist, {
  required Offset position,
}) async {
  final bool signedIn = ref.read(authControllerProvider).isSignedIn;
  final bool subscribed = ref.read(subscribedIdsProvider).contains(artist.id);
  final bool blocked = ref
      .read(blockedArtistsProvider)
      .any((BlockedArtist item) => item.id == artist.id);

  final _ArtistAction? action = await showMenu<_ArtistAction>(
    context: context,
    position: _menuPosition(context, position),
    constraints: _menuConstraints,
    items: <PopupMenuEntry<_ArtistAction>>[
      _entry(_ArtistAction.play, Icons.play_arrow, 'Играть'),
      _entry(_ArtistAction.shuffle, Icons.shuffle, 'Перемешать'),
      _entry(_ArtistAction.enqueue, Icons.playlist_add, 'В очередь'),
      const PopupMenuDivider(),
      _entry(
        _ArtistAction.subscribe,
        subscribed ? Icons.notifications_active : Icons.notifications_none,
        subscribed ? 'Отписаться' : 'Подписаться',
        // Без входа подписываться некуда — как у кнопки в шапке.
        enabled: signedIn && artist.id.isNotEmpty,
      ),
      _entry(
        _ArtistAction.block,
        blocked
            ? Icons.person_add_alt_1_outlined
            : Icons.person_off_outlined,
        blocked ? 'Разблокировать исполнителя' : 'Заблокировать исполнителя',
        // Блокировка живёт по id: без него запись нельзя ни поставить, ни снять.
        enabled: artist.id.isNotEmpty,
      ),
      const PopupMenuDivider(),
      _entry(
        _ArtistAction.open,
        Icons.person_outline,
        'Открыть страницу',
        enabled: artist.id.isNotEmpty,
      ),
    ],
  );
  if (action == null || !context.mounted) return;

  switch (action) {
    case _ArtistAction.play:
      await _play(context, ref, () => _artistTracks(ref, artist));
    case _ArtistAction.shuffle:
      await _play(
        context,
        ref,
        () => _artistTracks(ref, artist),
        shuffle: true,
      );
    case _ArtistAction.enqueue:
      await _enqueue(context, ref, () => _artistTracks(ref, artist));
    case _ArtistAction.subscribe:
      await _toggleSubscribed(context, ref, artist, subscribed: subscribed);
    case _ArtistAction.block:
      await _toggleBlocked(context, ref, artist, blocked: blocked);
    case _ArtistAction.open:
      unawaited(AppRoutes.artist(context, artist.id));
  }
}

/// Меню плейлиста: воспроизведение и переход на страницу.
///
/// Правка плейлиста (переименование, обложка, удаление) сюда не входит: у
/// карточки нет признака владения, который есть у страницы, — сервер откажет
/// на чужом плейлисте уже после подтверждения в диалоге.
Future<void> showPlaylistMenu(
  BuildContext context,
  WidgetRef ref,
  Playlist playlist, {
  required Offset position,
}) async {
  final _PlaylistAction? action = await showMenu<_PlaylistAction>(
    context: context,
    position: _menuPosition(context, position),
    constraints: _menuConstraints,
    items: <PopupMenuEntry<_PlaylistAction>>[
      _entry(_PlaylistAction.play, Icons.play_arrow, 'Играть'),
      _entry(_PlaylistAction.shuffle, Icons.shuffle, 'Перемешать'),
      _entry(_PlaylistAction.enqueue, Icons.playlist_add, 'В очередь'),
      const PopupMenuDivider(),
      _entry(
        _PlaylistAction.open,
        Icons.queue_music,
        'Открыть страницу',
        enabled: playlist.id.isNotEmpty,
      ),
    ],
  );
  if (action == null || !context.mounted) return;

  switch (action) {
    case _PlaylistAction.play:
      await _play(context, ref, () => _playlistTracks(ref, playlist));
    case _PlaylistAction.shuffle:
      await _play(
        context,
        ref,
        () => _playlistTracks(ref, playlist),
        shuffle: true,
      );
    case _PlaylistAction.enqueue:
      await _enqueue(context, ref, () => _playlistTracks(ref, playlist));
    case _PlaylistAction.open:
      unawaited(AppRoutes.playlist(context, playlist.id));
  }
}

/// Треки альбома: у карточки из библиотеки своего списка нет, поэтому
/// догружаем её страницу тем же провайдером, что и экран.
Future<List<Track>> _albumTracks(WidgetRef ref, Album album) async {
  if (album.tracks.isNotEmpty) return album.tracks;
  return (await ref.read(albumProvider(album.id).future)).tracks;
}

/// Верхние треки исполнителя — то же, что играет кнопка на его странице.
Future<List<Track>> _artistTracks(WidgetRef ref, Artist artist) async {
  if (artist.topTracks.isNotEmpty) return artist.topTracks;
  return (await ref.read(artistProvider(artist.id).future)).topTracks;
}

/// Треки плейлиста. «Мне нравится» запрашивается отдельным провайдером: общий
/// `playlistProvider` ходит в каталог без авторизации и вернул бы пустоту.
Future<List<Track>> _playlistTracks(
  WidgetRef ref,
  Playlist playlist,
) async {
  if (playlist.tracks.isNotEmpty) return playlist.tracks;
  final Playlist full = LibrarySource.isLikedPlaylist(playlist.id)
      ? await ref.read(likedSongsPlaylistProvider.future)
      : await ref.read(playlistProvider(playlist.id).future);
  return full.tracks;
}

/// Включает сущность целиком — как кнопка «Слушать» в её шапке.
///
/// Контроллер и мессенджер берём до возможного ожидания: карточка может
/// исчезнуть из ленты вместе с меню, а сообщение всё равно нужно показать.
Future<void> _play(
  BuildContext context,
  WidgetRef ref,
  Future<List<Track>> Function() load, {
  bool shuffle = false,
}) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final PlayerController player = ref.read(playerControllerProvider.notifier);
  try {
    final List<Track> tracks = await load();
    if (tracks.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Треков нет — играть нечего.')),
      );
      return;
    }
    await player.playQueue(tracks, shuffle: shuffle);
  } on Object catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
  }
}

/// Добавляет все треки в конец очереди — как кнопка «В очередь».
Future<void> _enqueue(
  BuildContext context,
  WidgetRef ref,
  Future<List<Track>> Function() load,
) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final PlayerController player = ref.read(playerControllerProvider.notifier);
  try {
    final List<Track> tracks = await load();
    if (tracks.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Треков нет — в очередь нечего добавить.')),
      );
      return;
    }
    player.enqueueAll(tracks);
  } on Object catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
  }
}

/// Сохраняет альбом в библиотеку или убирает его оттуда.
Future<void> _toggleSaved(
  BuildContext context,
  WidgetRef ref,
  Album album, {
  required String playlistId,
  required bool saved,
}) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  try {
    await ref
        .read(savedIdsProvider.notifier)
        .toggle(id: album.id, playlistId: playlistId);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          saved
              ? '«${album.title}» убран из библиотеки'
              : '«${album.title}» сохранён в библиотеку',
        ),
      ),
    );
  } on Object catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
  }
}

/// Подписывает на канал или отписывает от него.
Future<void> _toggleSubscribed(
  BuildContext context,
  WidgetRef ref,
  Artist artist, {
  required bool subscribed,
}) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  try {
    await ref.read(subscribedIdsProvider.notifier).toggle(artist.id);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          subscribed
              ? 'Подписка отменена: ${artist.name}'
              : 'Вы подписались: ${artist.name}',
        ),
      ),
    );
  } on Object catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
  }
}

/// Меняет локальную блокировку исполнителя.
Future<void> _toggleBlocked(
  BuildContext context,
  WidgetRef ref,
  Artist artist, {
  required bool blocked,
}) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final BlockedArtists notifier = ref.read(blockedArtistsProvider.notifier);
  try {
    if (blocked) {
      await notifier.unblock(artist.id);
    } else {
      await notifier.block(id: artist.id, name: artist.name);
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          blocked
              ? 'Блокировка снята: ${artist.name}'
              : 'Исполнитель заблокирован: ${artist.name}',
        ),
      ),
    );
  } on Object {
    messenger.showSnackBar(
      const SnackBar(content: Text('Не удалось изменить блокировку.')),
    );
  }
}

/// Положение меню у курсора.
///
/// `showMenu` ждёт координаты в системе наложения того навигатора, в котором
/// открывается меню, а нажатие приходит в глобальных. Без пересчёта меню
/// уезжало бы на ширину боковой панели — подэкраны живут во вложенном
/// навигаторе.
RelativeRect _menuPosition(BuildContext context, Offset globalPosition) {
  final RenderObject? overlay =
      Navigator.of(context).overlay?.context.findRenderObject();
  if (overlay is RenderBox && overlay.hasSize) {
    final Offset local = overlay.globalToLocal(globalPosition);
    return RelativeRect.fromLTRB(
      local.dx,
      local.dy,
      overlay.size.width - local.dx,
      overlay.size.height - local.dy,
    );
  }
  final Size size = MediaQuery.sizeOf(context);
  return RelativeRect.fromLTRB(
    globalPosition.dx,
    globalPosition.dy,
    size.width - globalPosition.dx,
    size.height - globalPosition.dy,
  );
}

/// Пункт меню: иконка и подпись, одинаково во всех трёх меню.
///
/// Подпись обрезается, а не вылезает за меню: в Material 3 ширина поповера
/// ограничена, и длинная строка вроде «Заблокировать исполнителя» иначе
/// ломала бы раскладку.
PopupMenuItem<T> _entry<T>(
  T value,
  IconData icon,
  String title, {
  bool enabled = true,
}) {
  return PopupMenuItem<T>(
    value: value,
    enabled: enabled,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Flexible(
          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
  );
}
