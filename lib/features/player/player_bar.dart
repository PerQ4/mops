import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/models/models.dart';
import '../../state/player_controller.dart';
import '../../widgets/artwork.dart';
import '../common/navigation.dart';

/// Компактная панель плеера над нижней навигацией.
///
/// Форма как у ArchiveTune: плавающая скруглённая карточка с отступами,
/// а не полоса во всю ширину. Кнопок ровно три — назад, играть, вперёд;
/// всё остальное живёт в полноэкранном плеере, чтобы не дублировать
/// управление в двух местах.
class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.current),
    );
    if (track == null) return const SizedBox.shrink();

    final PlayerUiState player = ref.watch(playerControllerProvider);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppLayout.radiusL),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => AppRoutes.nowPlaying(context),
          child: SizedBox(
            height: AppLayout.miniPlayerHeight,
            child: Row(
              children: <Widget>[
                const SizedBox(width: 8),
                _MiniArtwork(track: track, player: player),
                const SizedBox(width: 12),
                Expanded(child: _MiniTitles(track: track, player: player)),
                const _MiniControls(),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniArtwork extends StatelessWidget {
  const _MiniArtwork({required this.track, required this.player});

  final Track track;
  final PlayerUiState player;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        children: <Widget>[
          Artwork(
            url: track.thumbnails.sized(128) ?? track.artwork,
            size: 48,
            radius: BorderRadius.circular(AppLayout.radiusS),
          ),
          // Полоска загрузки поверх обложки: не двигает раскладку.
          if (player.isLoading)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(AppLayout.radiusS),
                ),
                child: const Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MiniTitles extends StatelessWidget {
  const _MiniTitles({required this.track, required this.player});

  final Track track;
  final PlayerUiState player;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool downloading = player.downloading;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          downloading
              ? 'Загрузка ${(player.downloadProgress * 100).round()}%'
              : player.error ?? track.artistLine,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.bodySmall?.copyWith(
            color: player.error != null ? scheme.error : scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _MiniControls extends ConsumerWidget {
  const _MiniControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerUiState player = ref.watch(playerControllerProvider);
    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          tooltip: 'Предыдущий',
          iconSize: 26,
          icon: const Icon(Icons.skip_previous_rounded),
          onPressed: player.queue.isEmpty ? null : controller.previous,
        ),
        IconButton.filled(
          tooltip: player.isPlaying ? 'Пауза' : 'Играть',
          iconSize: 26,
          icon: Icon(
            player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          ),
          onPressed: controller.togglePlayPause,
        ),
        IconButton(
          tooltip: 'Следующий',
          iconSize: 26,
          icon: const Icon(Icons.skip_next_rounded),
          onPressed: player.queue.isEmpty ? null : controller.next,
        ),
      ],
    );
  }
}
