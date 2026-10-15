import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/format.dart';
import '../../data/local/app_settings.dart';
import '../../state/player_controller.dart';
import '../../state/providers.dart';

/// Альфы дорожки слайдера — из ArchiveTune
/// (`ui/theme/PlayerSliderColors.kt`, `object Config`).
///
/// Активная часть всюду рисуется цветом акцента без прозрачности, а вот
/// неактивная — той же ролью, но приглушённой. Значения перенесены точно:
/// `INACTIVE_TRACK_ALPHA = 0.22`, `THICK_INACTIVE_TRACK_ALPHA = 0.28`,
/// `SIMPLE_ACTIVE_TRACK_ALPHA = 0.85`, `SIMPLE_INACTIVE_TRACK_ALPHA = 0.15`,
/// `INACTIVE_TICK_ALPHA = 0.25`.
const double _kInactiveTrackAlpha = 0.22;
const double _kThickInactiveTrackAlpha = 0.28;
const double _kSimpleActiveTrackAlpha = 0.85;
const double _kSimpleInactiveTrackAlpha = 0.15;

/// Горизонтальный отступ содержимого плеера — `PlayerHorizontalPadding`
/// (`constants/Dimensions.kt:45`). Используется полосой перемотки и её
/// подписями времени.
const double _kPlayerHorizontalPadding = 32;

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
      // Отступ как `PlayerHorizontalPadding` в ArchiveTune (32), в панели —
      // вдвое уже (16): там колонка узкая.
      padding: EdgeInsets.symmetric(
        horizontal: widget.compact ? 16 : _kPlayerHorizontalPadding,
      ),
      child: Column(
        children: <Widget>[
          if (style == ProgressBarStyle.standard)
            SliderTheme(
              // Оформление как в ArchiveTune: активная часть — цветом акцента,
              // неактивная — приглушённая дорожка; пока играет, ползунок
              // крупнее и с обводкой фона, поэтому заметен с первого взгляда.
              // Пока тянем, над ползунком показывается время.
              data: SliderTheme.of(context).copyWith(
                // ArchiveTune для стиля Standard не задаёт толщину — это
                // штатный Material 3 Slider (`TrackHeight = 16`), поэтому и
                // здесь берём 16, а не произвольные 12.
                trackHeight: 16,
                trackShape: const RoundedRectSliderTrackShape(),
                activeTrackColor: scheme.primary,
                // Неактивная часть — той же ролью акцента с альфой 0.22
                // (`PlayerSliderColors.Config.INACTIVE_TRACK_ALPHA`), а не
                // приглушённым `onSurfaceVariant`.
                inactiveTrackColor:
                    scheme.primary.withValues(alpha: _kInactiveTrackAlpha),
                disabledActiveTrackColor:
                    scheme.primary.withValues(alpha: 0.38),
                disabledInactiveTrackColor:
                    scheme.primary.withValues(alpha: 0.12),
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
              // Обе части — цветом акцента; прозрачность каждой части задаёт
              // сам painter по таблице `PlayerSliderColors.Config`.
              activeColor: scheme.primary,
              inactiveColor: scheme.primary,
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
            // Подписи времени стоят на 4 px глубже дорожки — как
            // `PlayerTimeLabel` в ArchiveTune (`PlayerHorizontalPadding + 4`).
            padding: const EdgeInsets.symmetric(horizontal: 4),
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

  /// Радиусы из ArchiveTune: у штатного Material 3 Slider ползунок 20 dp в
  /// диаметре (радиус 10), у «волнистого» — `thumbRadius = 8`. В паузе берём
  /// меньший, чтобы ручка не спорила с дорожкой.
  double get _radius => playing ? 10 : 8;

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

    // Размеры и отступы — из ArchiveTune, стиль плеера V4
    // (`ui/player/PlayerComponents.kt`, `PlayerPlaybackControls`):
    // центр 88, боковые 56/46, зазор 12, иконки 44/28/22, радиусы 18/16.
    const double baseLarge = 56;
    const double baseSmall = 46;
    const double baseGap = 12;
    const double baseLargeIcon = 28;
    const double baseSmallIcon = 22;
    const double baseLargeRadius = 18;
    const double baseSmallRadius = 16;
    const double centerSize = 88;
    const double centerPadding = 40;

    final bool canPrevious = player.queue.isNotEmpty;
    final bool canNext = player.queue.isNotEmpty;
    final bool repeatOn = player.repeat != PlayerRepeatMode.off;

    // Цвет «текста на фоне» и заливки кнопок — ролями схемы.
    final Color onBackground = scheme.onSurface;
    final Color buttonFill = scheme.primary;
    final Color onButtonFill = scheme.onPrimary;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Масштаб как в ArchiveTune: боковые группы должны поместиться рядом
        // с центральной кнопкой. В узкой панели плеера прижимаем сильнее.
        final double sideTotal =
            (constraints.maxWidth - centerSize - centerPadding) / 2;
        final double cap = dense ? 0.8 : 1.0;
        final double scale = ((sideTotal - baseGap) / (baseLarge + baseSmall))
            .clamp(0.6, cap);

        final double large = baseLarge * scale;
        final double small = baseSmall * scale;
        final double gap = baseGap * scale;
        final double largeIcon = baseLargeIcon * scale;
        final double smallIcon = baseSmallIcon * scale;
        final double largeRadius = baseLargeRadius * scale;
        final double smallRadius = baseSmallRadius * scale;

        Widget modeButton({
          required String tooltip,
          required IconData icon,
          required bool selected,
          required VoidCallback onPressed,
        }) {
          return _TransportButton(
            tooltip: tooltip,
            icon: icon,
            size: small,
            radius: smallRadius,
            iconSize: smallIcon,
            // Заливка приглушённая: 0.08 в покое, 0.2 во включённом виде.
            background: onBackground.withValues(alpha: selected ? 0.2 : 0.08),
            foreground: onBackground.withValues(alpha: selected ? 1 : 0.6),
            onPressed: onPressed,
          );
        }

        Widget skipButton({
          required String tooltip,
          required IconData icon,
          required bool enabled,
          required VoidCallback onPressed,
        }) {
          return _TransportButton(
            tooltip: tooltip,
            icon: icon,
            size: large,
            radius: largeRadius,
            iconSize: largeIcon,
            background: onBackground.withValues(alpha: 0.15),
            foreground: onBackground.withValues(alpha: enabled ? 1 : 0.4),
            onPressed: enabled ? onPressed : null,
          );
        }

        return Row(
          children: <Widget>[
            Expanded(
              // FittedBox: когда масштаб упирается в нижнюю границу, группа
              // кнопок перестаёт влезать и RenderFlex даёт переполнение.
              // Здесь она просто чуть ужимается — без полосы переполнения.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (showModes) ...<Widget>[
                      modeButton(
                        tooltip: player.shuffle
                            ? 'Перемешивание включено'
                            : 'Перемешать',
                        icon: Icons.shuffle,
                        selected: player.shuffle,
                        onPressed: controller.toggleShuffle,
                      ),
                      SizedBox(width: gap),
                    ],
                    skipButton(
                      tooltip: 'Предыдущий',
                      icon: Icons.skip_previous_rounded,
                      enabled: canPrevious,
                      onPressed: controller.previous,
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              // Центральная кнопка не масштабируется и отделена отступом 20.
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _TransportPlayButton(
                playing: player.isPlaying,
                loading: player.isLoading,
                size: centerSize,
                fill: buttonFill,
                onFill: onButtonFill,
                onPressed: controller.togglePlayPause,
              ),
            ),
            Expanded(
              // То же и для правой группы — см. пояснение слева.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    skipButton(
                      tooltip: 'Следующий',
                      icon: Icons.skip_next_rounded,
                      enabled: canNext,
                      onPressed: controller.next,
                    ),
                    if (showModes) ...<Widget>[
                      SizedBox(width: gap),
                      modeButton(
                        tooltip: player.repeat.label,
                        icon: player.repeat == PlayerRepeatMode.one
                            ? Icons.repeat_one
                            : Icons.repeat,
                        selected: repeatOn,
                        onPressed: controller.cycleRepeat,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Квадратная кнопка транспорта — как `Surface` со скруглением в ArchiveTune.
///
/// Одинаково рисует и крупные «назад/вперёд», и мелкие «перемешать/повтор»:
/// отличается только заливка и прозрачность иконки.
class _TransportButton extends StatelessWidget {
  const _TransportButton({
    required this.tooltip,
    required this.icon,
    required this.size,
    required this.radius,
    required this.iconSize,
    required this.background,
    required this.foreground,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final double size;
  final double radius;
  final double iconSize;
  final Color background;
  final Color foreground;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final BorderRadius shape = BorderRadius.circular(radius);
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: size,
        height: size,
        child: Material(
          color: background,
          borderRadius: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            borderRadius: shape,
            onTap: onPressed,
            child: Center(
              child: Icon(icon, size: iconSize, color: foreground),
            ),
          ),
        ),
      ),
    );
  }
}

/// Центральная кнопка «играть/пауза» — 88 dp, со скруглением, которое
/// меняется в зависимости от состояния (28 в воспроизведении, 44 в паузе) —
/// `cinematicPlayPauseCorner` в ArchiveTune.
class _TransportPlayButton extends StatelessWidget {
  const _TransportPlayButton({
    required this.playing,
    required this.loading,
    required this.size,
    required this.fill,
    required this.onFill,
    required this.onPressed,
  });

  final bool playing;
  final bool loading;
  final double size;
  final Color fill;
  final Color onFill;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final double radius = playing ? 28 : 44;
    final BorderRadius shape = BorderRadius.circular(radius);
    return Tooltip(
      message: playing ? 'Пауза' : 'Играть',
      child: SizedBox(
        width: size,
        height: size,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          curve: Curves.linear,
          decoration: BoxDecoration(color: fill, borderRadius: shape),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: shape,
              onTap: onPressed,
              child: Center(
                child: loading
                    ? SizedBox(
                        width: 40,
                        height: 40,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: onFill,
                        ),
                      )
                    : Icon(
                        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        // Иконка центральной кнопки — 44 dp.
                        size: 44,
                        color: onFill,
                      ),
              ),
            ),
          ),
        ),
      ),
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
                        // Громкость как в ArchiveTune (`AppleMusicControls`):
                        // дорожка 8 dp, активная часть — акцент с альфой 0.88,
                        // неактивная — с 0.24, ползунок радиусом 6.
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 8,
                          activeTrackColor:
                              scheme.primary.withValues(alpha: 0.88),
                          inactiveTrackColor:
                              scheme.primary.withValues(alpha: 0.24),
                          thumbColor: scheme.primary,
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
    // Пока полоса недоступна (нет длительности) — приглушаем активную часть.
    final Color activeBase =
        enabled ? activeColor : activeColor.withValues(alpha: 0.4);

    // Прозрачности — из `PlayerSliderColors.Config` (ArchiveTune).
    final Color inactive = switch (style) {
      ProgressBarStyle.thick =>
        inactiveColor.withValues(alpha: _kThickInactiveTrackAlpha),
      ProgressBarStyle.simple =>
        inactiveColor.withValues(alpha: _kSimpleInactiveTrackAlpha),
      _ => inactiveColor.withValues(alpha: _kInactiveTrackAlpha),
    };

    switch (style) {
      case ProgressBarStyle.thick:
      case ProgressBarStyle.simple:
        // Толщина сегментов: толстый — 12 dp, простой — 3 dp
        // (`StyledPlaybackSlider` в ArchiveTune).
        final double thickness = style == ProgressBarStyle.thick ? 12 : 3;
        // Простой стиль ещё и активную часть делает полупрозрачной (0.85).
        final Color active = style == ProgressBarStyle.simple
            ? activeBase.withValues(alpha: _kSimpleActiveTrackAlpha)
            : activeBase;
        canvas.drawLine(
          Offset(0, mid),
          Offset(size.width, mid),
          _linePaint(inactive, thickness),
        );
        canvas.drawLine(
          Offset(0, mid),
          Offset(size.width * p, mid),
          _linePaint(active, thickness),
        );

      case ProgressBarStyle.wavy:
      case ProgressBarStyle.circular:
        // Волна толще, пока играет: 6 dp против 3 dp в паузе
        // (`trackHeight = if (isPlaying) 6.dp else 3.dp`).
        final double stroke = amplitude > 0 ? 6 : 3;
        _paintWave(canvas, size, mid, p, inactive, false, stroke);
        _paintWave(canvas, size, mid, p, activeBase, true, stroke);
        if (style == ProgressBarStyle.circular) {
          // Ползунок волны — `thumbRadius = 8` (`WavySliderExpressive`).
          canvas.drawCircle(
            Offset(size.width * p, mid),
            8,
            Paint()..color = activeBase,
          );
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
    double strokeWidth,
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
        ..strokeWidth = strokeWidth
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
