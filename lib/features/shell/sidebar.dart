import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../core/utils/format.dart';
import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/catalog_providers.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/artwork.dart';
import '../common/navigation.dart';

/// Постоянная левая панель широкой раскладки.
///
/// Форма взята у Spotify Desktop: сверху навигация, ниже библиотека со списком
/// плейлистов пользователя. Панель не сворачивается — ширина фиксирована
/// константой, иначе содержимое «дёргалось» бы при каждом изменении окна.
class LibrarySidebar extends StatelessWidget {
  const LibrarySidebar({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: AppLayout.sidebarWidth,
      // Material одновременно даёт фон панели и подложку для InkWell.
      child: Material(
        color: scheme.surfaceContainer,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SizedBox(height: 8),
            const _SectionLabel('Библиотека'),
            const Expanded(child: _PlaylistList()),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 16, 6),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _PlaylistList extends ConsumerWidget {
  const _PlaylistList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Playlist>> playlists = ref.watch(
      likedPlaylistsProvider,
    );
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );

    return playlists.when(
      data: (List<Playlist> data) {
        if (data.isEmpty) {
          return _Hint(
            icon: signedIn ? Icons.queue_music : Icons.login_outlined,
            text: signedIn
                ? 'Плейлистов пока нет'
                : 'Войдите, чтобы видеть свои плейлисты',
            actionLabel: signedIn ? null : 'Войти',
            onAction: signedIn ? null : () => AppRoutes.account(context),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 12),
          itemCount: data.length,
          itemBuilder: (BuildContext context, int index) =>
              _PlaylistRow(playlist: data[index]),
        );
      },
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      ),
      error: (Object error, StackTrace _) => _Hint(
        icon: Icons.error_outline,
        text: 'Не удалось загрузить плейлисты',
        actionLabel: 'Повторить',
        onAction: () => ref.invalidate(likedPlaylistsProvider),
      ),
    );
  }
}

/// Одна строка плейлиста: обложка 48, высота 64, обложка с радиусом 4 —
/// как в ArchiveTune. Кнопки появляются при наведении, активная строка
/// подсвечена фоном.
class _PlaylistRow extends ConsumerStatefulWidget {
  const _PlaylistRow({required this.playlist});

  final Playlist playlist;

  @override
  ConsumerState<_PlaylistRow> createState() => _PlaylistRowState();
}

class _PlaylistRowState extends ConsumerState<_PlaylistRow> {
  bool _hovered = false;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    // Активной считаем строку плейлиста, из которого играет текущий трек.
    final bool active = ref.watch(
      playerControllerProvider.select(
        (PlayerUiState s) => s.current?.playlistId == widget.playlist.id,
      ),
    );
    final bool showActions = _hovered || active;

    return SizedBox(
      height: 64,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: InkWell(
          onTap: () => AppRoutes.playlist(context, widget.playlist.id),
          child: Container(
            decoration: active
                ? BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(AppLayout.radiusS),
                  )
                : null,
            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: <Widget>[
                Artwork(
                  url: widget.playlist.thumbnails.sized(96),
                  size: 48,
                  radius: BorderRadius.circular(4),
                  icon: Icons.queue_music,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        widget.playlist.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: active
                              ? scheme.onSecondaryContainer
                              : scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _subtitle(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: active
                              ? scheme.onSecondaryContainer.withValues(
                                  alpha: 0.7,
                                )
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                // Кнопки не убираем из дерева, а гасим прозрачностью: иначе
                // название «прыгало» бы по ширине при каждом наведении.
                IgnorePointer(
                  ignoring: !showActions,
                  child: AnimatedOpacity(
                    opacity: showActions ? 1 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _busy
                            ? const SizedBox(
                                width: 36,
                                height: 36,
                                child: Padding(
                                  padding: EdgeInsets.all(8),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : IconButton(
                                tooltip: 'Играть',
                                iconSize: 20,
                                icon: const Icon(Icons.play_arrow_rounded),
                                onPressed: _play,
                              ),
                        PopupMenuButton<_RowAction>(
                          tooltip: 'Действия',
                          iconSize: 20,
                          icon: const Icon(Icons.more_vert),
                          onSelected: _onAction,
                          itemBuilder: (BuildContext context) =>
                              const <PopupMenuEntry<_RowAction>>[
                                PopupMenuItem<_RowAction>(
                                  value: _RowAction.open,
                                  child: Text('Открыть'),
                                ),
                                PopupMenuItem<_RowAction>(
                                  value: _RowAction.play,
                                  child: Text('Играть'),
                                ),
                              ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _subtitle() {
    final String? author = widget.playlist.author;
    if (author != null && author.isNotEmpty) return author;
    final String count = trackCountLabel(widget.playlist.trackCount);
    return count.isEmpty ? 'Плейлист' : count;
  }

  void _onAction(_RowAction action) {
    switch (action) {
      case _RowAction.open:
        AppRoutes.playlist(context, widget.playlist.id);
      case _RowAction.play:
        _play();
    }
  }

  /// Запускает плейлист.
  ///
  /// В списке библиотеки треки обычно не приходят — догружаем страницу
  /// плейлиста по id, иначе играть было бы нечего.
  Future<void> _play() async {
    if (_busy) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final Playlist full = widget.playlist.tracks.isNotEmpty
          ? widget.playlist
          : await ref.read(catalogSourceProvider).playlist(widget.playlist.id);
      if (full.tracks.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('В плейлисте нет треков')),
        );
        return;
      }
      await ref.read(playerControllerProvider.notifier).playQueue(full.tracks);
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Не удалось запустить плейлист')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

enum _RowAction { open, play }

/// Короткая подсказка вместо пустого списка или ошибки.
class _Hint extends StatelessWidget {
  const _Hint({
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 22, color: scheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (actionLabel != null && onAction != null) ...<Widget>[
            const SizedBox(height: 4),
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}
