import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../core/utils/format.dart';
import '../../data/models/models.dart';
import '../../data/sources/library_source.dart';
import '../../state/auth_controller.dart';
import '../../state/library_providers.dart';
import '../../widgets/app_progress.dart';
import '../../widgets/artwork.dart';

/// Диалог «Добавить в плейлист»: свои плейлисты и строка «Новый плейлист».
///
/// Список берём из библиотеки YouTube Music (`likedPlaylistsProvider`), а не
/// из локального хранилища: трек добавляется на сервер, и выбирать нужно
/// именно те плейлисты, куда сервер его примет.
///
/// [hostContext] — контекст экрана, откуда диалог открыли. Сообщение об
/// успехе или ошибке показываем уже после закрытия диалога, когда его
/// собственный контекст перестаёт быть действительным.
Future<void> showAddToPlaylistDialog(
  BuildContext hostContext,
  Track track,
) {
  return showDialog<void>(
    context: hostContext,
    builder: (BuildContext dialogContext) =>
        _AddToPlaylistDialog(track: track, hostContext: hostContext),
  );
}

/// Название нового плейлиста. `null` — отмена или пустая строка.
///
/// Один диалог на все точки входа: и «Новый плейлист» внутри «Добавить в
/// плейлист», и пункт «Создать плейлист» в библиотеке. Второй такой же диалог
/// разошёлся бы с первым по поведению (проверка пустого имени, Enter).
Future<String?> askPlaylistTitle(BuildContext context) async {
  final TextEditingController field = TextEditingController();
  final String? result = await showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('Новый плейлист'),
      content: TextField(
        controller: field,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Название'),
        onSubmitted: (String value) => Navigator.pop(dialogContext, value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, field.text),
          child: const Text('Создать'),
        ),
      ],
    ),
  );
  field.dispose();

  final String title = result?.trim() ?? '';
  return title.isEmpty ? null : title;
}

/// Создаёт пустой плейлист: спрашивает название, отправляет его на сервер и
/// сообщает результат.
///
/// Точка входа общая для плитки в библиотеке и кнопки в шапке боковой панели:
/// после создания список плейлистов сбрасывает [PlaylistEditor], поэтому
/// вызывающему не нужно помнить об инвалидации.
Future<void> createPlaylistWithDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  // Мессенджер берём до ожидания: после диалога контекст может уже не быть
  // смонтирован, а сообщение показать всё равно нужно.
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final String? title = await askPlaylistTitle(context);
  if (title == null || !context.mounted) return;

  try {
    await ref.read(playlistEditorProvider).create(title: title);
    messenger.showSnackBar(
      SnackBar(content: Text('Плейлист «$title» создан')),
    );
  } on Object catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text('Не удалось создать плейлист: $error')),
    );
  }
}

class _AddToPlaylistDialog extends ConsumerStatefulWidget {
  const _AddToPlaylistDialog({required this.track, required this.hostContext});

  final Track track;
  final BuildContext hostContext;

  @override
  ConsumerState<_AddToPlaylistDialog> createState() =>
      _AddToPlaylistDialogState();
}

class _AddToPlaylistDialogState extends ConsumerState<_AddToPlaylistDialog> {
  /// Идёт запрос: пока он не закончился, повторные нажатия не принимаем —
  /// иначе трек уехал бы в плейлист дважды.
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );
    final AsyncValue<LibraryPlaylists> playlists =
        ref.watch(likedPlaylistsProvider);

    // Высоту ограничиваем долей окна: на низком окне список иначе ушёл бы
    // под кнопки, а на высоком — растянулся бы на пол-экрана. Ширину тоже
    // подгоняем под окно — фиксированные 420 на узком окне вылезали бы за
    // края (у `AlertDialog` ещё по 48 с каждой стороны уходит на отступы).
    final Size window = MediaQuery.sizeOf(context);
    final double maxHeight = window.height * 0.6;
    final double contentWidth =
        math.min(420, math.max(240, window.width - 96));

    return AlertDialog(
      title: const Text('Добавить в плейлист'),
      contentPadding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
      content: SizedBox(
        width: contentWidth,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: !signedIn
              ? const _Hint(
                  'Войдите в аккаунт YouTube Music — плейлисты хранятся на '
                  'сервере, без входа их не видно.',
                )
              : playlists.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: AppProgress()),
                  ),
                  error: (Object error, StackTrace _) =>
                      _Hint('Не удалось загрузить плейлисты.\n$error'),
                  data: _buildList,
                ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }

  Widget _buildList(LibraryPlaylists data) {
    final List<Playlist> playlists = data.playlists;
    return ListView(
      // Список меряется по содержимому и прокручивается только если оно
      // переросло ограничение по высоте (см. `maxHeight` выше).
      shrinkWrap: true,
      children: <Widget>[
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        ListTile(
          enabled: !_busy,
          leading: const Icon(Icons.add),
          title: const Text('Новый плейлист'),
          onTap: _createPlaylist,
        ),
        const Divider(height: 1),
        if (playlists.isEmpty)
          const _Hint('Плейлистов пока нет — создайте первый.')
        else
          for (final Playlist playlist in playlists)
            _PlaylistRow(
              playlist: playlist,
              enabled: !_busy,
              onTap: () => _addTo(playlist),
            ),
      ],
    );
  }

  /// Спрашивает название и создаёт плейлист сразу с треком.
  Future<void> _createPlaylist() async {
    // Мессенджер берём до первого ожидания: после него `hostContext` может
    // уже не быть смонтированным, а `State.mounted` про чужой контекст
    // ничего не говорит.
    final ScaffoldMessengerState messenger =
        ScaffoldMessenger.of(widget.hostContext);
    final String? title = await _askTitle();
    if (title == null || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(playlistEditorProvider).createWithTrack(
            title: title,
            videoId: widget.track.id,
          );
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(content: Text('Плейлист «$title» создан, трек в нём')),
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text('Не удалось создать плейлист: $error')),
      );
    }
  }

  /// Добавляет трек в выбранный плейлист.
  Future<void> _addTo(Playlist playlist) async {
    final ScaffoldMessengerState messenger =
        ScaffoldMessenger.of(widget.hostContext);
    setState(() => _busy = true);
    try {
      await ref.read(playlistEditorProvider).addTrack(
            playlistId: playlist.id,
            videoId: widget.track.id,
          );
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(content: Text('Добавлено в «${playlist.title}»')),
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text('Не удалось добавить в плейлист: $error')),
      );
    }
  }

  /// Название нового плейлиста. `null` — отмена или пустая строка.
  Future<String?> _askTitle() => askPlaylistTitle(context);
}

/// Строка плейлиста: обложка, название и число треков.
class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({
    required this.playlist,
    required this.enabled,
    required this.onTap,
  });

  final Playlist playlist;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final int? count = playlist.trackCount;
    return ListTile(
      enabled: enabled,
      leading: Artwork(
        url: playlist.artwork,
        size: 44,
        radius: BorderRadius.circular(AppLayout.thumbnailRadius),
        icon: Icons.queue_music,
      ),
      title: Text(playlist.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: count == null ? null : Text(trackCountLabel(count)),
      onTap: onTap,
    );
  }
}

/// Пояснение вместо списка: пусто, нет входа или ошибка загрузки.
class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}
