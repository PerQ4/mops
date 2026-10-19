import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../core/utils/format.dart';
import '../../data/models/models.dart';
import '../../data/sources/library_source.dart';
import '../../state/auth_controller.dart';
import '../../state/catalog_providers.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/async_views.dart';
import '../../widgets/track_menu.dart';
import '../../widgets/track_tile.dart';
import '../album/media_hero.dart';
import 'm3u_export.dart';

/// Страница плейлиста.
class PlaylistScreen extends ConsumerWidget {
  const PlaylistScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // «Понравившаяся музыка» в библиотеке открывается с id `VLLM` (а из
    // очереди — с `LM`). Общий `playlistProvider` запрашивает раздел без
    // авторизации, и гостю YouTube отдаёт пустой плейлист, поэтому для
    // «Мне нравится» берём отдельный авторизованный источник.
    final bool liked = LibrarySource.isLikedPlaylist(playlistId);
    final AsyncValue<Playlist> playlist = liked
        ? ref.watch(likedSongsPlaylistProvider)
        : ref.watch(playlistProvider(playlistId));

    return Scaffold(
      body: playlist.when(
        data: (Playlist data) => _PlaylistBody(playlist: data),
        loading: () => const MediaDetailSkeleton(),
        error: (Object error, StackTrace _) => Scaffold(
          appBar: AppBar(),
          body: MediaDetailStatePanel(
            icon: Icons.cloud_off_outlined,
            title: 'Не удалось загрузить',
            description: describeError(error),
            actionLabel: 'Повторить',
            onAction: () => ref.invalidate(
              liked ? likedSongsPlaylistProvider : playlistProvider(playlistId),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaylistBody extends ConsumerWidget {
  const _PlaylistBody({required this.playlist});

  final Playlist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? current = ref.watch(currentTrackProvider);
    final bool playing = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.isPlaying),
    );
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );

    final bool liked = LibrarySource.isLikedPlaylist(playlist.id);
    // Правку плейлиста сервер принимает только от владельца. Признак владения
    // — `setVideoId` у записей: YouTube выдаёт его лишь для тех плейлистов,
    // которые пользователь может править. Пустой плейлист записей не имеет,
    // поэтому его тоже считаем правимым: его мог только что создать сам
    // пользователь, и отказывать ему в переименовании было бы неправильно.
    final bool canEdit = !liked &&
        (playlist.tracks.isEmpty ||
            playlist.tracks.any((Track t) => t.setVideoId != null));

    final bool isCurrentPlaylist =
        current != null && playlist.tracks.any((Track t) => t.id == current.id);
    final bool hasTracks = playlist.tracks.isNotEmpty;

    return CustomScrollView(
      slivers: <Widget>[
        SliverAppBar(
          pinned: true,
          expandedHeight: AppLayout.appBarHeight,
          title: Text(
            playlist.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: <Widget>[
            // Действия над плейлистом — только после входа: без него сервер
            // правку не примет. У гостя кнопки нет, а не «мертвая» кнопка.
            if (signedIn)
              IconButton(
                tooltip: 'Действия с плейлистом',
                icon: const Icon(Icons.more_vert),
                onPressed: () => _openActions(context, canEdit: canEdit),
              ),
            const SizedBox(width: 4),
          ],
        ),
        SliverToBoxAdapter(
          child: MediaHero(
            title: playlist.title,
            subtitle: playlist.author,
            meta: _metaLine(),
            description: playlist.description,
            imageUrl: playlist.thumbnails.sized(600),
            fallbackIcon: Icons.queue_music,
            // Порядок действий как в ArchiveTune: перемешать, слушать, добавить.
            actions: <Widget>[
              HeroCircleButton(
                icon: Icons.shuffle,
                tooltip: 'Перемешать',
                size: 52,
                onPressed: hasTracks
                    ? () => ref
                        .read(playerControllerProvider.notifier)
                        .playQueue(playlist.tracks, shuffle: true)
                    : null,
              ),
              HeroPlayButton(
                label: isCurrentPlaylist && playing ? 'Пауза' : 'Слушать',
                icon: isCurrentPlaylist && playing
                    ? Icons.pause
                    : Icons.play_arrow,
                onPressed: !hasTracks
                    ? null
                    : () {
                        final PlayerController controller =
                            ref.read(playerControllerProvider.notifier);
                        // Иконка «пауза» должна действительно ставить на
                        // паузу, а не перезапускать плейлист с начала.
                        if (isCurrentPlaylist && playing) {
                          controller.togglePlayPause();
                        } else {
                          controller.playQueue(playlist.tracks);
                        }
                      },
              ),
              HeroCircleButton(
                icon: Icons.playlist_add,
                tooltip: 'В очередь',
                size: 52,
                onPressed: hasTracks ? () => _enqueueAll(ref) : null,
              ),
              // Сохранение в библиотеку. У плейлиста ключ состояния и id для
              // мутации совпадают; «Мне нравится» сохранять нечего — это уже
              // библиотека, поэтому кнопка неактивна.
              HeroSaveButton(
                stateId: playlist.id,
                playlistId:
                    LibrarySource.isLikedPlaylist(playlist.id) ? null : playlist.id,
              ),
            ],
          ),
        ),
        if (playlist.tracks.isEmpty)
          // Пустой плейлист — как `MediaDetailStatePanel` в `OnlinePlaylistScreen.kt`
          // (`fillMaxWidth().padding(horizontal = 24.dp, vertical = 32.dp)`).
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: MediaDetailStatePanel(
                icon: Icons.queue_music,
                title: 'Плейлист пуст',
                description: 'В нём пока нет доступных треков.',
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: playlist.tracks.length,
            itemBuilder: (BuildContext context, int index) {
              final Track track = playlist.tracks[index];
              final bool isCurrent = current?.id == track.id;
              // Удалять можно только запись правимого плейлиста — у неё есть
              // `setVideoId`. У «Мне нравится» удаление не показываем: это
              // снятие лайка, и живёт оно в меню трека.
              final bool removable = !liked && track.setVideoId != null;
              // Подменить запись можно там же, где её вообще разрешено
              // править: в своём плейлисте или в «Мне нравится» (там замена —
              // это снять лайк со старого и поставить новому).
              final bool canReplace = liked || track.setVideoId != null;
              void openMenu() => showTrackMenu(
                    context,
                    track,
                    replaceInPlaylist: canReplace
                        ? (Track replacement) =>
                            _replaceInPlaylist(ref, track, replacement)
                        : null,
                  );
              return TrackTile(
                track: track,
                isCurrent: isCurrent,
                isPlaying: isCurrent && playing,
                onMenu: openMenu,
                onTap: () => ref
                    .read(playerControllerProvider.notifier)
                    .playTrack(track, context: playlist.tracks),
                trailing: removable
                    ? _TrackActions(
                        onRemove: () => _removeTrack(context, ref, track),
                        onMenu: openMenu,
                      )
                    : null,
              );
            },
          ),
        const SliverToBoxAdapter(
          // Отступ снизу под плавающий островок плеера.
          child: SizedBox(height: AppLayout.floatingDockClearance),
        ),
      ],
    );
  }

  /// «N треков • длительность» — формат метаданных из спецификации.
  /// Автор вынесен в подпись героя.
  String? _metaLine() {
    final List<String> parts = <String>[];
    if (playlist.trackCount != null) {
      parts.add(trackCountLabel(playlist.trackCount));
    }
    if (playlist.duration != null) {
      final String total = formatTotalDuration(playlist.duration!);
      if (total.isNotEmpty) parts.add(total);
    }
    return parts.isEmpty ? null : parts.join(mediaDetailMetadataSeparator);
  }

  /// Кладёт весь плейлист в конец очереди.
  void _enqueueAll(WidgetRef ref) {
    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);
    for (final Track track in playlist.tracks) {
      controller.enqueue(track);
    }
  }

  /// Меню действий над плейлистом. После удаления страница показывает то,
  /// чего уже нет, — закрываем её.
  Future<void> _openActions(
    BuildContext context, {
    required bool canEdit,
  }) async {
    final PlaylistActionResult? result = await showPlaylistActionsSheet(
      context,
      playlist,
      canEdit: canEdit,
    );
    if (result == PlaylistActionResult.deleted && context.mounted) {
      Navigator.of(context).maybePop();
    }
  }

  /// Удаляет трек из плейлиста — после подтверждения.
  Future<void> _removeTrack(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) async {
    // Мессенджер берём до ожиданий: после них контекст может уже не быть
    // смонтированным, а сообщение показать всё равно нужно.
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool confirmed =
        await confirmRemoveTrackDialog(context, track) ?? false;
    if (!confirmed) return;

    try {
      await ref.read(librarySourceProvider).removeFromPlaylist(
            playlist.id,
            track.id,
            setVideoId: track.setVideoId!,
          );
      invalidatePlaylistCaches(ref, playlist.id);
      messenger.showSnackBar(
        SnackBar(content: Text('«${track.title}» удалён из плейлиста')),
      );
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }

  /// Подменяет запись плейлиста найденной заменой.
  ///
  /// У YouTube нет мутации «заменить трек»: в своём плейлисте это удаление
  /// старой записи плюс добавление новой (в ArchiveTune `replace` работает так
  /// же), а в «Мне нравится» — снять лайк со старого и поставить новому.
  /// Если добавление не прошло, старую запись возвращаем: иначе плейлист
  /// потерял бы трек вместо его замены.
  Future<void> _replaceInPlaylist(
    WidgetRef ref,
    Track oldTrack,
    Track replacement,
  ) async {
    if (replacement.id == oldTrack.id) return;
    final LibrarySource library = ref.read(librarySourceProvider);

    if (LibrarySource.isLikedPlaylist(playlist.id)) {
      await library.setLiked(oldTrack.id, liked: false);
      try {
        await library.setLiked(replacement.id, liked: true);
      } on Object {
        // Возвращаем лайк старому треку, иначе подмена теряла бы запись.
        await library.setLiked(oldTrack.id, liked: true);
        rethrow;
      }
      ref.invalidate(likedSongsProvider);
      ref.invalidate(likedSongsPlaylistProvider);
      return;
    }

    final String? setVideoId = oldTrack.setVideoId;
    // Чужую запись сервер удалять откажется — подмены не будет.
    if (setVideoId == null) return;

    // Замена уже лежит в плейлисте: повторное добавление создало бы дубль,
    // достаточно убрать старую запись.
    final bool alreadyPresent =
        playlist.tracks.any((Track t) => t.id == replacement.id);
    await library.removeFromPlaylist(
      playlist.id,
      oldTrack.id,
      setVideoId: setVideoId,
    );
    if (!alreadyPresent) {
      try {
        await library.addToPlaylist(playlist.id, <String>[replacement.id]);
      } on Object {
        // Добавление не прошло — возвращаем старую запись, чтобы плейлист не
        // потерял трек. Если и это не вышло, пробрасываем исходную ошибку:
        // она объясняет, что именно сломалось.
        try {
          await library.addToPlaylist(playlist.id, <String>[oldTrack.id]);
        } on Object {
          // нет
        }
        rethrow;
      }
    }
    invalidatePlaylistCaches(ref, playlist.id);
  }
}

/// Кнопки строки плейлиста: удаление записи и обычное меню трека.
///
/// Меню трека оставляем рядом с удалением: убрать запись — не единственное,
/// что нужно от строки, а терять ради этого лайк и «в очередь» нельзя.
class _TrackActions extends StatelessWidget {
  const _TrackActions({required this.onRemove, required this.onMenu});

  final VoidCallback onRemove;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final Color color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          tooltip: 'Удалить из плейлиста',
          iconSize: 20,
          color: color,
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: onRemove,
        ),
        IconButton(
          tooltip: 'Действия',
          iconSize: 20,
          color: color,
          icon: const Icon(Icons.more_vert),
          onPressed: onMenu,
        ),
      ],
    );
  }
}

/// Что сделал пользователь в меню плейлиста.
enum PlaylistActionResult { renamed, deleted, exported }

/// Меню действий над плейлистом: переименовать, выгрузить в M3U, удалить.
///
/// Одно на страницу плейлиста и на плитку в библиотеке: держать две копии —
/// значит гарантированно получить расхождение в доступных действиях.
///
/// [canEdit] — можно ли править плейлист. Если не задан, считаем правимым
/// всё, кроме «Мне нравится»: у плитки библиотеки данных о владении нет, а
/// сервер честно откажет, если плейлист чужой.
Future<PlaylistActionResult?> showPlaylistActionsSheet(
  BuildContext context,
  Playlist playlist, {
  bool? canEdit,
}) {
  final bool editable = canEdit ?? !LibrarySource.isLikedPlaylist(playlist.id);
  return showModalBottomSheet<PlaylistActionResult>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => _PlaylistActionsSheet(
      playlist: playlist,
      hostContext: context,
      canEdit: editable,
    ),
  );
}

class _PlaylistActionsSheet extends ConsumerWidget {
  const _PlaylistActionsSheet({
    required this.playlist,
    required this.hostContext,
    required this.canEdit,
  });

  final Playlist playlist;

  /// Контекст, из которого открыли лист: сообщения показываем уже после его
  /// закрытия, когда контекст листа недействителен.
  final BuildContext hostContext;

  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.queue_music),
            title: Text(
              playlist.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Divider(height: 1),
          _PlaylistSheetAction(
            icon: Icons.download_outlined,
            title: 'Экспорт в M3U',
            onTap: () => _export(context, ref),
          ),
          if (canEdit)
            _PlaylistSheetAction(
              icon: Icons.edit_outlined,
              title: 'Переименовать',
              onTap: signedIn ? () => _rename(context, ref) : null,
            ),
          if (canEdit)
            _PlaylistSheetAction(
              icon: Icons.delete_outline,
              title: 'Удалить плейлист',
              destructive: true,
              onTap: signedIn ? () => _delete(context, ref) : null,
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// Переименование: спросить название, отправить и сбросить кэш.
  Future<void> _rename(BuildContext sheetContext, WidgetRef ref) async {
    final String? title =
        await showRenamePlaylistDialog(sheetContext, playlist.title);
    if (title == null || !sheetContext.mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(hostContext);
    try {
      await ref.read(librarySourceProvider).renamePlaylist(playlist.id, title);
      invalidatePlaylistCaches(ref, playlist.id);
      if (sheetContext.mounted) {
        Navigator.pop(sheetContext, PlaylistActionResult.renamed);
      }
      messenger.showSnackBar(
        SnackBar(content: Text('Плейлист переименован в «$title»')),
      );
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }

  /// Удаление плейлиста — только после подтверждения.
  Future<void> _delete(BuildContext sheetContext, WidgetRef ref) async {
    final bool confirmed =
        await confirmDeletePlaylistDialog(sheetContext, playlist.title) ?? false;
    if (!confirmed || !sheetContext.mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(hostContext);
    try {
      await ref.read(librarySourceProvider).deletePlaylist(playlist.id);
      invalidatePlaylistCaches(ref, playlist.id);
      if (sheetContext.mounted) {
        Navigator.pop(sheetContext, PlaylistActionResult.deleted);
      }
      messenger.showSnackBar(
        SnackBar(content: Text('Плейлист «${playlist.title}» удалён')),
      );
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }

  /// Экспорт: спросить путь и записать файл.
  Future<void> _export(BuildContext sheetContext, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(hostContext);
    // У плитки библиотеки треков нет — догружаем их, иначе экспорт был бы
    // пустым файлом.
    final Playlist full = await _withTracks(ref, playlist);
    if (full.tracks.isEmpty) {
      if (sheetContext.mounted) Navigator.pop(sheetContext);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('В плейлисте нет треков — экспортировать нечего.'),
        ),
      );
      return;
    }
    if (!sheetContext.mounted) return;

    final String? path = await _showM3uPathDialog(sheetContext, full.title);
    if (path == null) return;

    try {
      await writeM3uFile(full, path);
      if (sheetContext.mounted) {
        Navigator.pop(sheetContext, PlaylistActionResult.exported);
      }
      messenger.showSnackBar(
        SnackBar(content: Text('Плейлист сохранён: $path')),
      );
    } on FileSystemException catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Не удалось записать файл: ${error.message}')),
      );
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Не удалось сохранить плейлист: $error')),
      );
    }
  }

  /// Догружает треки, если плейлист пришёл из списка библиотеки без них.
  Future<Playlist> _withTracks(WidgetRef ref, Playlist playlist) async {
    if (playlist.tracks.isNotEmpty) return playlist;
    if (LibrarySource.isLikedPlaylist(playlist.id)) {
      return ref.read(likedSongsPlaylistProvider.future);
    }
    return ref.read(playlistProvider(playlist.id).future);
  }
}

/// Пункт меню плейлиста: иконка и подпись, оформление одно на все действия.
class _PlaylistSheetAction extends StatelessWidget {
  const _PlaylistSheetAction({
    required this.icon,
    required this.title,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color? color = destructive ? scheme.error : null;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title, style: color == null ? null : TextStyle(color: color)),
      enabled: onTap != null,
      onTap: onTap,
    );
  }
}

/// Спрашивает новое название плейлиста. `null` — отмена или пустая строка.
Future<String?> showRenamePlaylistDialog(
  BuildContext context,
  String currentTitle,
) async {
  final TextEditingController field =
      TextEditingController(text: currentTitle);
  final String? result = await showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('Переименовать плейлист'),
      content: TextField(
        controller: field,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Название'),
        onSubmitted: (String value) => Navigator.pop(dialogContext, value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, field.text),
          child: const Text('Сохранить'),
        ),
      ],
    ),
  );
  field.dispose();

  final String title = result?.trim() ?? '';
  return title.isEmpty ? null : title;
}

/// Подтверждение удаления плейлиста — действие необратимое.
Future<bool?> confirmDeletePlaylistDialog(BuildContext context, String title) {
  return showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('Удалить плейлист?'),
      content: Text(
        'Плейлист «$title» будет удалён из аккаунта YouTube Music. '
        'Вернуть его будет нельзя.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(dialogContext).colorScheme.error,
            foregroundColor: Theme.of(dialogContext).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Удалить'),
        ),
      ],
    ),
  );
}

/// Подтверждение удаления трека из плейлиста.
Future<bool?> confirmRemoveTrackDialog(BuildContext context, Track track) {
  return showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('Удалить из плейлиста?'),
      content: Text('Трек «${track.title}» будет убран из этого плейлиста.'),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Удалить'),
        ),
      ],
    ),
  );
}

/// Спрашивает путь, куда сохранить M3U. `null` — отмена или пустой путь.
///
/// Поле заполняется путём по умолчанию, но его можно изменить: сохранять
/// список для другого плеера чаще всего нужно в конкретную папку.
Future<String?> _showM3uPathDialog(BuildContext context, String title) async {
  // Путь по умолчанию узнаём до открытия диалога: подставлять его позже,
  // когда окно уже открыто, — значит гонять поле туда-сюда и рискнуть
  // обратиться к нему после закрытия.
  final String defaultPath = await defaultM3uPath(title);
  if (!context.mounted) return null;

  final TextEditingController field =
      TextEditingController(text: defaultPath);
  final String? result = await showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('Экспорт в M3U'),
      content: TextField(
        controller: field,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Путь к файлу',
          helperText: 'Существующий файл будет перезаписан',
        ),
        onSubmitted: (String value) => Navigator.pop(dialogContext, value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, field.text),
          child: const Text('Сохранить'),
        ),
      ],
    ),
  );
  field.dispose();

  final String path = result?.trim() ?? '';
  return path.isEmpty ? null : path;
}

/// Сбрасывает кэш страниц и списков, которых коснулась правка плейлиста.
void invalidatePlaylistCaches(WidgetRef ref, String playlistId) {
  ref.invalidate(playlistProvider(playlistId));
  ref.invalidate(likedPlaylistsProvider);
  if (LibrarySource.isLikedPlaylist(playlistId)) {
    ref.invalidate(likedSongsPlaylistProvider);
    ref.invalidate(likedSongsProvider);
  }
}
