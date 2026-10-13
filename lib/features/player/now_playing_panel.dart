import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/catalog_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import 'lyrics_view.dart';
import 'player_controls.dart';
import 'queue_list.dart';

/// Постоянная панель плеера на широких экранах.
///
/// Занимает правую колонку и не перекрывает содержимое: на десктопе
/// отдельный полноэкранный плеер не нужен, поэтому и дублирующего маршрута
/// нет. Сверху — обложка на размытом фоне, ниже — управление и
/// переключатель между очередью и текстом песни.
class NowPlayingPanel extends ConsumerStatefulWidget {
  const NowPlayingPanel({super.key});

  @override
  ConsumerState<NowPlayingPanel> createState() => _NowPlayingPanelState();
}

class _NowPlayingPanelState extends ConsumerState<NowPlayingPanel> {
  /// Что показано под управлением: очередь или текст.
  bool _showLyrics = false;

  @override
  Widget build(BuildContext context) {
    final PlayerUiState player = ref.watch(playerControllerProvider);
    final Track? track = player.current;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    if (track == null) {
      return ColoredBox(
        color: scheme.surfaceContainerLowest,
        child: const EmptyState(
          icon: Icons.headphones_outlined,
          title: 'Ничего не играет',
          subtitle: 'Выберите трек — он появится здесь.',
        ),
      );
    }

    return ColoredBox(
      color: scheme.surfaceContainerLowest,
      child: Column(
        children: <Widget>[
          _ArtworkHeader(track: track),
          _TrackInfo(track: track, player: player),
          const SizedBox(height: 4),
          PlayerSeekBar(player: player, compact: true),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
            child: PlayerTransportBar(player: player, dense: true),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: PlayerVolumeBar(player: player),
          ),
          const Divider(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppLayout.gutter),
            child: SegmentedButton<bool>(
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(
                  value: false,
                  label: Text('Очередь'),
                  icon: Icon(Icons.queue_music, size: 18),
                ),
                ButtonSegment<bool>(
                  value: true,
                  label: Text('Текст'),
                  icon: Icon(Icons.lyrics_outlined, size: 18),
                ),
              ],
              selected: <bool>{_showLyrics},
              showSelectedIcon: false,
              onSelectionChanged: (Set<bool> value) =>
                  setState(() => _showLyrics = value.first),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _showLyrics
                ? LyricsView(
                    key: ValueKey<String>('panel-lyrics-${track.id}'),
                    videoId: track.id,
                  )
                : const QueueList(),
          ),
        ],
      ),
    );
  }
}

/// Обложка во всю ширину панели на размытой копии самой себя.
class _ArtworkHeader extends StatelessWidget {
  const _ArtworkHeader({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Панель фиксированной ширины, поэтому высота обложки — константа.
    const double side = AppLayout.playerPanelWidth;

    return SizedBox(
      height: side,
      width: side,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
            child: Artwork(
              url: track.thumbnails.sized(512) ?? track.artwork,
              fit: BoxFit.cover,
              radius: BorderRadius.zero,
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  scheme.surface.withValues(alpha: 0.25),
                  scheme.surface.withValues(alpha: 0.6),
                  scheme.surfaceContainerLowest,
                ],
                stops: const <double>[0.35, 0.8, 1],
              ),
            ),
          ),
          Center(
            child: SizedBox(
              width: side * 0.62,
              height: side * 0.62,
              child: Artwork(
                url: track.thumbnails.sized(1024) ?? track.artwork,
                radius: BorderRadius.circular(AppLayout.radiusL),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Название, исполнитель и кнопка «нравится».
class _TrackInfo extends ConsumerWidget {
  const _TrackInfo({required this.track, required this.player});

  final Track track;
  final PlayerUiState player;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppLayout.gutter, 10, 8, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  track.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  player.error ?? track.artistLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(
                    color: player.error != null
                        ? scheme.error
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: signedIn ? 'Нравится' : 'Войдите, чтобы ставить лайки',
            icon: const Icon(Icons.favorite_border, size: 20),
            onPressed: signedIn
                ? () => _like(context, ref)
                : null,
          ),
        ],
      ),
    );
  }

  Future<void> _like(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(librarySourceProvider).setLiked(track.id, liked: true);
      messenger.showSnackBar(
        const SnackBar(content: Text('Добавлено в «Мне нравится»')),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Не удалось поставить лайк. Проверьте вход в аккаунт.'),
        ),
      );
    }
  }
}
