import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/format.dart';
import '../../data/local/app_settings.dart';
import '../../state/player_controller.dart';
import '../../state/providers.dart';

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
    final bool playing = player.isPlaying;
    // Стиль полосы перемотки — как пять `SliderStyle` в ArchiveTune.
    final ProgressBarStyle style = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => s.progressBarStyle,
      ),
    );
    final TextStyle? label = Theme.of(context).textTheme.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        );

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.compact ? 16 : 24),
      child: Column(
        children: <Widget>[
          if (style == ProgressBarStyle.standard)
            SliderTheme(
              // Оформление как в ArchiveTune: активная часть — цветом акцента,
              // неактивная — приглушённая дорожка; пока играет, ползунок
              // крупнее и с обводкой фона, поэтому заметен с первого взгляда.
              // Пока тянем, над ползунком показывается время.
              data: SliderTheme.of(context).copyWith(
                trackHeight: 12,
                trackShape: const RoundedRectSliderTrackShape(),
                activeTrackColor: scheme.primary,
                inactiveTrackColor:
                    scheme.onSurfaceVariant.withValues(alpha: 0.18),
                disabledActiveTrackColor:
                    scheme.primary.withValues(alpha: 0.38),
                disabledInactiveTrackColor:
                    scheme.onSurfaceVariant.withValues(alpha: 0.12),
                thumbColor: scheme.primary,
                thumbShape: _SeekThumbShape(
                  playing: playing,
                  hueColor: scheme.surface,
                ),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
                activeTickMarkColor: Colors.transparent,
                inactiveTickMarkColor: Colors.transparent,
                // Подсказка со временем при перетаскивании.
                showValueIndicator: ShowValueIndicator.onlyForContinuous,
                valueIndicatorShape:
                    const RectangularSliderValueIndicatorShape(),
                valueIndicatorColor: scheme.inverseSurface,
                valueIndicatorTextStyle: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: scheme.onInverseSurface),
              ),
              child: Slider(
                label: formatDurationClock(shown),
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
            )
          else
            _StyledSeekBar(
              progress: value.clamp(0.0, 1.0),
              style: style,
              activeColor: scheme.primary,
              inactiveColor: scheme.onSurfaceVariant.withValues(alpha: 0.18),
              playing: playing,
              enabled: seekable,
              onSeek: (double fraction) =>
                  setState(() => _dragValue = fraction),
              onSeekEnd: (double fraction) {
                ref
                    .read(playerControllerProvider.notifier)
                    .seek(duration * fraction);
                setState(() => _dragValue = null);
              },
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: <Widget>[
                Text(formatDurationClock(shown), style: label),
                const Spacer(),
                Text(formatDurationClock(duration), style: label),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Ползунок полосы перемотки.
///
/// Отличается от стандартного тем, что при воспроизведении он крупнее и
/// обведён цветом фона: «ручка» не сливается с дорожкой и сразу видно, что
/// трек играет. В паузе — компактнее и без обводки.
class _SeekThumbShape extends SliderComponentShape {
  const _SeekThumbShape({required this.playing, required this.hueColor});

  /// Играет ли трек прямо сейчас.
  final bool playing;

  /// Цвет обводки — фон поверхности под ползунком.
  final Color hueColor;

  double get _radius => playing ? 9 : 7;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      Size.fromRadius(_radius + 3);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final Canvas canvas = context.canvas;
    final Color fill = sliderTheme.thumbColor ?? hueColor;
    if (playing) {
      canvas.drawCircle(center, _radius + 2, Paint()..color = hueColor);
    }
    canvas.drawCircle(center, _radius, Paint()..color = fill);
  }
}

/// Отметка качества потока — как у ArchiveTune (OPUS и битрейт).
///
/// Стоит рядом с названием трека, а не по центру шкалы перемотки: там она
/// спорила со временем и мешала тянуть ползунок.
class QualityBadge extends StatelessWidget {
  const QualityBadge({super.key, required this.player});

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

/// Кнопки транспорта: назад, играть/пауза, вперёд.
///
/// Перемешивание и повтор сюда не входят: они переехали в строку с названием
/// (рядом с лайком и «…»), поэтому строка транспорта остаётся крупной и чистой.
class PlayerTransportBar extends ConsumerWidget {
  const PlayerTransportBar({
    super.key,
    required this.player,
    this.dense = false,
    this.showModes = false,
  });

  final PlayerUiState player;

  /// Плотный вариант для боковой панели — меньше отступы.
  final bool dense;

  /// Показывать перемешивание и повтор прямо в транспорте. В боковой панели
  /// они живут здесь (сверху их убрали, чтобы строка с названием не пухла),
  /// а на полном экране — в строке с названием, поэтому там флаг выключен.
  final bool showModes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    final double mainSize = dense ? 48 : 60;
    final double skipSize = dense ? 32 : 40;
    final double modeSize = dense ? 20 : 24;
    final double gap = dense ? 6 : 14;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        if (showModes)
          IconButton(
            tooltip: player.shuffle ? 'Перемешивание включено' : 'Перемешать',
            isSelected: player.shuffle,
            iconSize: modeSize,
            icon: const Icon(Icons.shuffle),
            selectedIcon:
                Icon(Icons.shuffle, size: modeSize, color: scheme.primary),
            onPressed: controller.toggleShuffle,
          ),
        if (showModes) SizedBox(width: gap),
        IconButton(
          tooltip: 'Предыдущий',
          iconSize: skipSize,
          icon: const Icon(Icons.skip_previous_rounded),
          onPressed: player.queue.isEmpty ? null : controller.previous,
        ),
        SizedBox(width: gap),
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
        SizedBox(width: gap),
        IconButton(
          tooltip: 'Следующий',
          iconSize: skipSize,
          icon: const Icon(Icons.skip_next_rounded),
          onPressed: player.queue.isEmpty ? null : controller.next,
        ),
        if (showModes) SizedBox(width: gap),
        if (showModes)
          IconButton(
            tooltip: player.repeat.label,
            isSelected: player.repeat != PlayerRepeatMode.off,
            iconSize: modeSize,
            icon: Icon(
              player.repeat == PlayerRepeatMode.one
                  ? Icons.repeat_one
                  : Icons.repeat,
            ),
            selectedIcon: Icon(
              player.repeat == PlayerRepeatMode.one
                  ? Icons.repeat_one
                  : Icons.repeat,
              size: modeSize,
              color: scheme.primary,
            ),
            onPressed: controller.cycleRepeat,
          ),
      ],
    );
  }
}

/// Громкость — компактно: одна иконка и выезжающая полоса.
///
/// Раньше полоса стояла всегда, а рядом была вторая иконка динамика — дубль.
/// Теперь полоса появляется по наведению (на десктопе) и всегда видна на
/// тач-экранах, где наведения нет.
class PlayerVolumeControl extends ConsumerStatefulWidget {
  const PlayerVolumeControl({super.key, this.iconSize = 20});

  final double iconSize;

  @override
  ConsumerState<PlayerVolumeControl> createState() =>
      _PlayerVolumeControlState();
}

class _PlayerVolumeControlState extends ConsumerState<PlayerVolumeControl> {
  bool _hovered = false;

  /// Есть ли наведение. На телефонах его нет — там полоса видна всегда.
  bool get _hasHover => switch (Theme.of(context).platform) {
        TargetPlatform.windows ||
        TargetPlatform.macOS ||
        TargetPlatform.linux =>
          true,
        _ => false,
      };

  @override
  Widget build(BuildContext context) {
    final double volume = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.playback.volume),
    );
    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool expanded = !_hasHover || _hovered;

    return Align(
      alignment: Alignment.centerLeft,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              tooltip: volume > 0 ? 'Выключить звук' : 'Включить звук',
              iconSize: widget.iconSize,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
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
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.centerLeft,
              child: expanded
                  ? SizedBox(
                      width: 170,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6),
                          overlayShape:
                              const RoundSliderOverlayShape(overlayRadius: 14),
                        ),
                        child: Slider(
                          value: volume.clamp(0.0, 1.0),
                          onChanged: controller.setVolume,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Громкость: иконка «выключить» и слайдер.
class PlayerVolumeBar extends ConsumerWidget {
  const PlayerVolumeBar({super.key, required this.player});

  final PlayerUiState player;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const PlayerVolumeControl();
  }
}

/// Полоса перемотки нестандартного стиля — как `SliderStyle` в ArchiveTune.
///
/// Рисуется вручную: Material-овский `Slider` не умеет ни «сегменты без
/// ползунка», ни волну. Перетаскивание обрабатывается здесь же, поэтому
/// внешний `Slider` для этих стилей не используется.
class _StyledSeekBar extends StatefulWidget {
  const _StyledSeekBar({
    required this.progress,
    required this.style,
    required this.activeColor,
    required this.inactiveColor,
    required this.playing,
    required this.enabled,
    required this.onSeek,
    required this.onSeekEnd,
  });

  final double progress;
  final ProgressBarStyle style;
  final Color activeColor;
  final Color inactiveColor;
  final bool playing;
  final bool enabled;
  final ValueChanged<double> onSeek;
  final ValueChanged<double> onSeekEnd;

  @override
  State<_StyledSeekBar> createState() => _StyledSeekBarState();
}

class _StyledSeekBarState extends State<_StyledSeekBar>
    with SingleTickerProviderStateMixin {
  /// Фаза волны: гоняем бесконечно, чтобы «волнистый» стиль жил.
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  double _lastFraction = 0;

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  double get _height => switch (widget.style) {
        ProgressBarStyle.thick => 16,
        ProgressBarStyle.simple => 8,
        ProgressBarStyle.wavy => 20,
        ProgressBarStyle.circular => 22,
        ProgressBarStyle.standard => 24,
      };

  void _apply(Offset local, double width, {required bool commit}) {
    if (!widget.enabled) return;
    _lastFraction = (local.dx / width).clamp(0.0, 1.0);
    if (commit) {
      widget.onSeekEnd(_lastFraction);
    } else {
      widget.onSeek(_lastFraction);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (TapDownDetails d) =>
              _apply(d.localPosition, width, commit: false),
          onTapUp: (TapUpDetails d) =>
              _apply(d.localPosition, width, commit: true),
          onHorizontalDragUpdate: (DragUpdateDetails d) =>
              _apply(d.localPosition, width, commit: false),
          onHorizontalDragEnd: (DragEndDetails _) =>
              widget.onSeekEnd(_lastFraction),
          child: SizedBox(
            width: width,
            height: _height,
            child: AnimatedBuilder(
              animation: _wave,
              builder: (BuildContext context, Widget? child) => CustomPaint(
                painter: _SeekBarPainter(
                  progress: widget.progress,
                  style: widget.style,
                  activeColor: widget.activeColor,
                  inactiveColor: widget.inactiveColor,
                  wave: _wave.value,
                  amplitude: widget.playing ? 1.0 : 0.0,
                  enabled: widget.enabled,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Рисует дорожку выбранного стиля: толстую/тонкую линию или волну.
class _SeekBarPainter extends CustomPainter {
  _SeekBarPainter({
    required this.progress,
    required this.style,
    required this.activeColor,
    required this.inactiveColor,
    required this.wave,
    required this.amplitude,
    required this.enabled,
  });

  final double progress;
  final ProgressBarStyle style;
  final Color activeColor;
  final Color inactiveColor;

  /// Фаза волны, 0..1.
  final double wave;

  /// Насколько выражена волна: 1 — играет, 0 — пауза.
  final double amplitude;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final double mid = size.height / 2;
    final double p = progress.clamp(0.0, 1.0);
    final Color active =
        enabled ? activeColor : activeColor.withValues(alpha: 0.4);

    switch (style) {
      case ProgressBarStyle.thick:
      case ProgressBarStyle.simple:
        final double thickness = style == ProgressBarStyle.thick ? 12 : 3;
        canvas.drawLine(
          Offset(0, mid),
          Offset(size.width, mid),
          _linePaint(inactiveColor, thickness),
        );
        canvas.drawLine(
          Offset(0, mid),
          Offset(size.width * p, mid),
          _linePaint(active, thickness),
        );

      case ProgressBarStyle.wavy:
      case ProgressBarStyle.circular:
        _paintWave(canvas, size, mid, p, inactiveColor, false);
        _paintWave(canvas, size, mid, p, active, true);
        if (style == ProgressBarStyle.circular) {
          canvas.drawCircle(Offset(size.width * p, mid), 7, Paint()..color = active);
        }

      case ProgressBarStyle.standard:
        // Этим стилем управляет обычный Slider — сюда не попадаем.
        break;
    }
  }

  Paint _linePaint(Color color, double width) => Paint()
    ..color = color
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round;

  void _paintWave(
    Canvas canvas,
    Size size,
    double mid,
    double p,
    Color color,
    bool active,
  ) {
    final double start = active ? 0 : size.width * p;
    final double end = active ? size.width * p : size.width;
    if (end - start <= 0.5) return;

    // В паузе волна выпрямляется — как в ArchiveTune.
    final double amp = 1.0 + amplitude * 3.0;
    const double wavelength = 26;
    final Path path = Path()..moveTo(start, mid);
    for (double x = start; x <= end; x += 2) {
      final double y = mid +
          amp *
              math.sin((x / wavelength) * 2 * math.pi + wave * 2 * math.pi);
      path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _SeekBarPainter old) =>
      old.progress != progress ||
      old.wave != wave ||
      old.amplitude != amplitude ||
      old.style != style ||
      old.activeColor != activeColor ||
      old.enabled != enabled;
}
