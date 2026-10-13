import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/audio_engine.dart';
import '../../core/utils/format.dart';
import '../../data/models/models.dart';
import '../../state/player_controller.dart';
import '../../widgets/artwork.dart';
import '../common/navigation.dart';
import 'queue_sheet.dart';

/// Постоянная панель плеера внизу окна.
///
/// Скрыта, пока ничего не выбрано. Нажатие на левую часть открывает
/// полноэкранный плеер, кнопки справа управляют воспроизведением.
class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerUiState player = ref.watch(playerControllerProvider);
    final Track? track = player.current;

    if (track == null) return const SizedBox.shrink();

    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool wide = MediaQuery.sizeOf(context).width >= 1000;

    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // Полоса прогресса: видна всегда, тонкая.
            LinearProgressIndicator(
              value: player.playback.duration > Duration.zero
                  ? player.playback.progress
                  : null,
              minHeight: 2,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
            InkWell(
              onTap: () => AppRoutes.nowPlaying(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: <Widget>[
                    TrackArtwork(track: track, size: 48, radius: 10),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _Titles(track: track, player: player),
                    ),
                    const SizedBox(width: 8),
                    _Controls(player: player, compact: !wide),
                    if (wide) ...<Widget>[
                      const SizedBox(width: 8),
                      const _VolumeControl(),
                    ],
                    IconButton(
                      tooltip: 'Очередь',
                      icon: const Icon(Icons.queue_music),
                      onPressed: () => QueueSheet.show(context),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Titles extends StatelessWidget {
  const _Titles({required this.track, required this.player});

  final Track track;
  final PlayerUiState player;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          player.error ?? track.artistLine,
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

/// Кнопки «предыдущий / играть / следующий».
class _Controls extends ConsumerWidget {
  const _Controls({required this.player, this.compact = false});

  final PlayerUiState player;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerController controller = ref.read(playerControllerProvider.notifier);
    final bool isLoading = player.isLoading;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (!compact)
          IconButton(
            tooltip: 'Предыдущий',
            icon: const Icon(Icons.skip_previous),
            onPressed: player.queue.isEmpty ? null : controller.previous,
          ),
        SizedBox(
          width: 48,
          height: 48,
          child: isLoading
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : IconButton.filled(
                  tooltip: player.isPlaying ? 'Пауза' : 'Играть',
                  icon: Icon(
                    player.isPlaying ? Icons.pause : Icons.play_arrow,
                    size: 28,
                  ),
                  onPressed: controller.togglePlayPause,
                ),
        ),
        if (!compact)
          IconButton(
            tooltip: 'Следующий',
            icon: const Icon(Icons.skip_next),
            onPressed: player.queue.isEmpty ? null : controller.next,
          ),
      ],
    );
  }
}

/// Громкость: иконка-переключатель «вкл/выкл» + слайдер.
class _VolumeControl extends ConsumerWidget {
  const _VolumeControl();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final double volume = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.playback.volume),
    );
    final PlayerController controller = ref.read(playerControllerProvider.notifier);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          tooltip: volume > 0 ? 'Выключить звук' : 'Включить звук',
          icon: Icon(
            volume == 0
                ? Icons.volume_off
                : volume < 0.5
                    ? Icons.volume_down
                    : Icons.volume_up,
          ),
          onPressed: () => controller.setVolume(volume == 0 ? 1.0 : 0.0),
        ),
        SizedBox(
          width: 110,
          child: Slider(
            value: volume.clamp(0.0, 1.0),
            onChanged: controller.setVolume,
          ),
        ),
      ],
    );
  }
}

/// Небольшая подпись с состояниями для отладки/индикации.
String playbackStatusLabel(PlaybackStatus status) => switch (status) {
      PlaybackStatus.idle => 'Готово',
      PlaybackStatus.loading => 'Загрузка…',
      PlaybackStatus.buffering => 'Буферизация…',
      PlaybackStatus.playing => 'Играет',
      PlaybackStatus.paused => 'Пауза',
      PlaybackStatus.completed => 'Завершено',
      PlaybackStatus.error => 'Ошибка',
    };

/// Форматирование длительности для панели.
String formatProgress(PlaybackState playback) =>
    '${formatDuration(playback.position)} / ${formatDuration(playback.duration)}';
