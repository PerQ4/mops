import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/format.dart';
import '../../state/player_controller.dart';

/// Полоса перемотки со временем по краям и отметкой качества в центре.
///
/// Используется и в панели плеера на десктопе, и в полноэкранном плеере на
/// телефоне — поэтому живёт в одном месте.
class PlayerSeekBar extends ConsumerStatefulWidget {
  const PlayerSeekBar({super.key, required this.player, this.compact = false});

  final PlayerUiState player;

  /// Компактный вид: подписи времени меньше, без отметки качества.
  final bool compact;

  @override
  ConsumerState<PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends ConsumerState<PlayerSeekBar> {
  /// Пока тянем ползунок, показываем его значение, а не позицию из плеера.
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final PlayerUiState player = widget.player;
    // Длительность берём из трека, если движок её не сообщил: для потока
    // через посредника он может её не отдать, а без длительности полоса
    // перемотки отключалась целиком.
    final Duration engineDuration = player.playback.duration;
    final Duration duration = engineDuration > Duration.zero
        ? engineDuration
        : (player.current?.duration ?? Duration.zero);
    final bool seekable = duration > Duration.zero;

    // Прогресс считаем от выбранной длительности: у потока через посредника
    // движок может не знать длительность, и его progress всегда ноль —
    // ползунок тогда не двигался бы даже после перемотки.
    final double progress = duration > Duration.zero
        ? (player.playback.position.inMilliseconds / duration.inMilliseconds)
            .clamp(0.0, 1.0)
        : 0.0;
    final double value = _dragValue ?? progress;
    final Duration shown = _dragValue == null
        ? player.playback.position
        : duration * _dragValue!;

    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle? label = Theme.of(context).textTheme.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        );

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.compact ? 16 : 24),
      child: Column(
        children: <Widget>[
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              // «Толстая» дорожка из ArchiveTune: 12 против прежних 4 —
              // по ней заметно, где идёт воспроизведение, и легче попасть
              // курсором.
              trackHeight: 12,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
              trackShape: const RoundedRectSliderTrackShape(),
            ),
            child: Slider(
              value: value.clamp(0.0, 1.0),
              onChanged: seekable
                  ? (double v) => setState(() => _dragValue = v)
                  : null,
              onChangeEnd: seekable
                  ? (double v) {
                      // Позицию считаем сами: у движка длительность может
                      // быть нулевой, тогда seekFraction дал бы ноль.
                      ref
                          .read(playerControllerProvider.notifier)
                          .seek(duration * v);
                      setState(() => _dragValue = null);
                    }
                  : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: <Widget>[
                Text(formatDurationClock(shown), style: label),
                const Spacer(),
                // Отметку качества показываем, если есть место по ширине:
                // на узком экране она мешала бы времени.
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final bool roomy = MediaQuery.sizeOf(context).width >= 320;
                    if (!roomy) return const SizedBox.shrink();
                    return _QualityBadge(player: player);
                  },
                ),
                if (!widget.compact) const Spacer(),
                if (widget.compact) const Spacer(),
                Text(formatDurationClock(duration), style: label),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Отметка качества потока — как у ArchiveTune (OPUS и битрейт).
class _QualityBadge extends StatelessWidget {
  const _QualityBadge({required this.player});

  final PlayerUiState player;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? note = player.streamNote;
    if (note == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.graphic_eq, size: 13, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            note,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 0.6,
                ),
          ),
        ],
      ),
    );
  }
}

/// Кнопки управления: перемешать, назад, играть/пауза, вперёд, повтор.
class PlayerTransportBar extends ConsumerWidget {
  const PlayerTransportBar({
    super.key,
    required this.player,
    this.dense = false,
  });

  final PlayerUiState player;

  /// Плотный вариант для боковой панели — меньше отступы.
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    final double mainSize = dense ? 44 : 52;
    final double skipSize = dense ? 30 : 36;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        IconButton(
          tooltip: player.shuffle ? 'Перемешивание включено' : 'Перемешать',
          isSelected: player.shuffle,
          icon: Icon(Icons.shuffle, size: dense ? 20 : 24),
          selectedIcon: Icon(Icons.shuffle,
              size: dense ? 20 : 24, color: scheme.primary),
          onPressed: controller.toggleShuffle,
        ),
        IconButton(
          tooltip: 'Предыдущий',
          iconSize: skipSize,
          icon: const Icon(Icons.skip_previous_rounded),
          onPressed: player.queue.isEmpty ? null : controller.previous,
        ),
        SizedBox(
          width: mainSize + 8,
          height: mainSize + 8,
          child: player.isLoading
              ? const Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                )
              : IconButton.filled(
                  tooltip: player.isPlaying ? 'Пауза' : 'Играть',
                  iconSize: mainSize * 0.62,
                  icon: Icon(player.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded),
                  onPressed: controller.togglePlayPause,
                ),
        ),
        IconButton(
          tooltip: 'Следующий',
          iconSize: skipSize,
          icon: const Icon(Icons.skip_next_rounded),
          onPressed: player.queue.isEmpty ? null : controller.next,
        ),
        IconButton(
          tooltip: player.repeat.label,
          isSelected: player.repeat != PlayerRepeatMode.off,
          icon: Icon(
            player.repeat == PlayerRepeatMode.one
                ? Icons.repeat_one
                : Icons.repeat,
            size: dense ? 20 : 24,
          ),
          selectedIcon: Icon(
            player.repeat == PlayerRepeatMode.one
                ? Icons.repeat_one
                : Icons.repeat,
            size: dense ? 20 : 24,
            color: scheme.primary,
          ),
          onPressed: controller.cycleRepeat,
        ),
      ],
    );
  }
}

/// Только слайдер громкости с одной иконкой — для широкой полосы плеера,
/// где места мало и кнопки «выключить звук» было бы слишком много.
class PlayerVolumeBarSliderOnly extends ConsumerWidget {
  const PlayerVolumeBarSliderOnly({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final double volume = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.playback.volume),
    );
    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Row(
      children: <Widget>[
        IconButton(
          tooltip: volume > 0 ? 'Выключить звук' : 'Включить звук',
          iconSize: 18,
          icon: Icon(
            volume == 0
                ? Icons.volume_off_rounded
                : volume < 0.5
                    ? Icons.volume_down_rounded
                    : Icons.volume_up_rounded,
          ),
          color: scheme.onSurfaceVariant,
          onPressed: () => controller.setVolume(volume == 0 ? 1.0 : 0.0),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: volume.clamp(0.0, 1.0),
              onChanged: controller.setVolume,
            ),
          ),
        ),
      ],
    );
  }
}

/// Громкость: иконка «выключить» и слайдер.
class PlayerVolumeBar extends ConsumerWidget {
  const PlayerVolumeBar({super.key, required this.player});

  final PlayerUiState player;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);
    final double volume = player.playback.volume;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Row(
      children: <Widget>[
        IconButton(
          tooltip: volume > 0 ? 'Выключить звук' : 'Включить звук',
          iconSize: 20,
          icon: Icon(
            volume == 0
                ? Icons.volume_off_rounded
                : volume < 0.5
                    ? Icons.volume_down_rounded
                    : Icons.volume_up_rounded,
          ),
          color: scheme.onSurfaceVariant,
          onPressed: () => controller.setVolume(volume == 0 ? 1.0 : 0.0),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: volume.clamp(0.0, 1.0),
              onChanged: controller.setVolume,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Icon(
            Icons.speaker_rounded,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
