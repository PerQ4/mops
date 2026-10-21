import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Готовые компоненты Material 3 Expressive. Берём их ради слайдера: в нём
// ползунок — вертикальная полоса 4x44 (а не круг), между ползунком и дорожкой
// зазор 6, а дорожка толщиной 16 — точные токены Compose Material 3.
import 'package:material_3_expressive/material_3_expressive.dart' as m3e;

import '../../core/audio/audio_engine.dart';
import '../../core/theme/motion.dart';
import '../../core/utils/format.dart';
import '../../data/local/app_settings.dart';
import '../../state/player_controller.dart';
import '../../state/providers.dart';
import 'equalizer.dart';

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

/// Границы и шаг темпа и питча — диалог `tempo_and_pitch` в ArchiveTune:
/// 0.5–2.0 с шагом 0.05 (30 делений ползунка).
const double kTempoPitchMin = 0.5;
const double kTempoPitchMax = 2.0;
const double kTempoPitchStep = 0.05;

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
    // «Живая» амплитуда волны. Движок уровень звука не отдаёт (см. пояснение
    // у `_liveWaveLevel`), поэтому уровень условный — но построен на реально
    // известных значениях: позиции (она идёт со скоростью воспроизведения, то
    // есть учитывает темп) и громкости плеера. На паузе волна плоская.
    final double waveLevel = playing
        ? _liveWaveLevel(
            position: player.playback.position,
            volume: player.playback.volume,
          )
        : 0.0;
    // Коэффициент амплитуды 0..1: в тихом месте волна почти ровная, в громком —
    // выраженная. Даже у нижней границы оставляем лёгкую волнистость, чтобы
    // дорожка не выглядела сломанной. На паузе волна полностью плоская — как
    // было раньше (`amplitude = 0`).
    final double waveAmplitude =
        playing ? 0.08 + 0.92 * waveLevel : 0.0;
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

    // Боковой отступ — как `PlayerHorizontalPadding` в ArchiveTune (32),
    // в панели вдвое уже (16). У «волнистого» он тоже нужен: внутренний
    // отступ под рычажок убирается в самом стиле, а не снаружи.
    final double sidePad = widget.compact ? 16 : _kPlayerHorizontalPadding;

    return Column(
      children: <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(horizontal: sidePad),
          child: style == ProgressBarStyle.standard ||
                  style == ProgressBarStyle.wavy ||
                  style == ProgressBarStyle.circular
              ? _M3ESeekBar(
                  style: style,
                  value: value.clamp(0.0, 1.0),
                  waveAmplitude: waveAmplitude,
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
                )
              : _StyledSeekBar(
                  progress: value.clamp(0.0, 1.0),
                  style: style,
                  // Обе части — цветом акцента; прозрачность каждой части
                  // задаёт сам painter по таблице `PlayerSliderColors.Config`.
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
        ),
        Padding(
          // Подписи времени стоят на 4 px глубже дорожки — как
          // `PlayerTimeLabel` в ArchiveTune (`PlayerHorizontalPadding + 4`).
          padding: EdgeInsets.symmetric(horizontal: sidePad + 4),
          child: Row(
            children: <Widget>[
              Text(formatDurationClock(shown), style: label),
              const Spacer(),
              Text(formatDurationClock(duration), style: label),
            ],
          ),
        ),
      ],
    );
  }
}

/// Предпросмотр стиля полосы — как карточка `SliderStyleOptionCard` в
/// ArchiveTune (`ui/screens/settings/AppearanceSettings.kt:1194`).
///
/// Это та же полоса, что и в плеере, но без подписей времени: в оригинале
/// карточка показывает её при значении 50 % и подписью снизу. Полоса живая —
/// по ней можно провести пальцем, чтобы почувствовать поведение стиля.
class SeekBarPreview extends StatefulWidget {
  const SeekBarPreview({super.key, required this.style});

  /// Какой стиль показывать.
  final ProgressBarStyle style;

  @override
  State<SeekBarPreview> createState() => _SeekBarPreviewState();
}

class _SeekBarPreviewState extends State<SeekBarPreview> {
  /// В оригинале предпросмотр стоит на середине шкалы.
  double _value = 0.5;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (widget.style == ProgressBarStyle.standard ||
        widget.style == ProgressBarStyle.wavy ||
        widget.style == ProgressBarStyle.circular) {
      return _M3ESeekBar(
        style: widget.style,
        value: _value,
        // В предпросмотре показываем волну на полной амплитуде — как раньше
        // (живой уровень тут взять неоткуда: трек не играет).
        waveAmplitude: 1.0,
        onChanged: (double v) => setState(() => _value = v),
      );
    }
    return _StyledSeekBar(
      progress: _value,
      style: widget.style,
      activeColor: scheme.primary,
      inactiveColor: scheme.primary,
      // В карточке показываем «играющее» состояние — как в оригинале.
      playing: true,
      enabled: true,
      onSeek: (double v) => setState(() => _value = v),
      onSeekEnd: (double v) => setState(() => _value = v),
    );
  }
}

/// Условный «уровень звука» для волны — от 0 до 1.
///
/// Движок (media_kit/libmpv) уровень громкости и спектр в Dart не отдаёт:
/// `Player.stream.audioParams` (`AudioParams`) содержит только формат, частоту
/// дискретизации и каналы, а `audio-bitrate` — постоянный для потока битрейт,
/// а не мгновенная громкость; готовой «визуализации» у media_kit нет вовсе.
/// Поэтому данные не выдумываются: уровень строится из того, что действительно
/// известно интерфейсу, — позиции воспроизведения и громкости плеера.
///
/// Позиция идёт в реальном времени со скоростью воспроизведения, поэтому темп
/// учитывается сам собой. Значение намеренно гладкое — сумма нескольких
/// медленных синусов от позиции (периоды ~24, 11 и 6.5 с): волна «дышит», но
/// не дёргается, и на кадр не приходится никаких тяжёлых пересчётов — функция
/// вызывается только при обычном обновлении позиции (несколько раз в секунду).
/// Множитель громкости — реальный параметр: тише значит ровнее.
double _liveWaveLevel({
  required Duration position,
  required double volume,
}) {
  final double t = position.inMilliseconds / 1000.0;
  final double a = math.sin(t * 0.26 + 0.7);
  final double b = math.sin(t * 0.57 + 2.1) * 0.6;
  final double c = math.sin(t * 0.97 + 4.4) * 0.35;
  final double raw = (a + b + c) / 1.95; // примерно -1..1
  final double breath = ((raw + 1) / 2).clamp(0.0, 1.0); // 0..1
  final double volumeFactor = 0.35 + 0.65 * volume.clamp(0.0, 1.0);
  return (breath * volumeFactor).clamp(0.0, 1.0);
}

/// Полоса перемотки на компоненте Material 3 Expressive.
///
/// В ArchiveTune (`StyledPlaybackSlider`, ветка `main`) «обычный» стиль — это
/// штатный `Slider` Material 3, а «волнистый» и «с кружком» — волнистая
/// дорожка из библиотеки `me.saket.squiggles`. Ползунок там не круг, а
/// вертикальная полоса: токены `handleWidth = 4`, `handleHeight = 44`
/// (`material_3_expressive`, `res/m3e_slider_tokens.dart`).
///
/// У «волнистого» ползунка нет вовсе: в ArchiveTune его цвет прозрачный
/// (`PlayerSliderColors.wavySliderColors`), поэтому здесь он не рисуется.
class _M3ESeekBar extends StatelessWidget {
  const _M3ESeekBar({
    required this.style,
    required this.value,
    required this.waveAmplitude,
    this.onChanged,
    this.onChangeEnd,
  });

  final ProgressBarStyle style;
  final double value;

  /// Амплитуда волны как множитель 0..1 (у «волнистого» стиля).
  ///
  /// В пакете `material_3_expressive` `amplitude` — это именно множитель к
  /// `waveAmplitude` темы (3 dp), а не размер в пикселях: значение обрезается
  /// до 0..1. Поэтому 0 — плоская дорожка, 1 — максимальная волна. Живой
  /// уровень приходит от `_liveWaveLevel` в `_PlayerSeekBarState`.
  final double waveAmplitude;

  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    // Как в ArchiveTune (`PlayerComponents.kt`, ветки `SliderStyle`): у всех
    // стилей, кроме «Обычного», дорожка идёт выразительным слайдером M3E —
    // только у «Волнистого» ползунка нет, а у «С кружком» он есть. Ползунки
    // берём готовые из пакета: свои формы рисовать не нужно.
    final bool wavy = style != ProgressBarStyle.standard;
    // Параметры волны — из `WavySliderExpressive` (ArchiveTune): штрих 6,
    // длина волны 36 (`strokeWidth * 6`), а волна заметна, только пока идёт
    // воспроизведение (`waveAmplitudeWhenPlaying`). Живая амплитуда приходит
    // параметром и меняется вместе с громкостью/позицией.
    final Widget slider = wavy
        ? m3e.M3ESlider.wavy(
            value: value,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
            amplitude: waveAmplitude.clamp(0.0, 1.0),
            wavelength: 36,
            // Толщина волны — не как у обычной дорожки: у `SquigglySlider`
            // штрих 6 (`strokeWidth = 6.dp`), иначе волна выходит втрое
            // жирнее оригинала.
            trackThickness: 6,
            // Ползунок «с кружком» — прямоугольник 6x24 из `SquigglySlider`
            // (`height = strokeWidth * 4`), а не высокая ручка Material 3.
            // У «волнистого» рычажка нет, поэтому и места под него не
            // резервируем (иначе дорожка уходила в отступ по краям).
            thumbLength: style == ProgressBarStyle.wavy ? 0 : 24,
            // Ползунок есть только у «с кружком»; у «волнистого» его нет.
            thumbBuilder: style == ProgressBarStyle.wavy ? _noThumb : null,
          )
        : m3e.M3ESlider(
            value: value,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          );

    // Пакет — отдельная тема. Собираем её из цвета акцента приложения:
    // иначе дорожка и ползунок будут стандартными лиловыми. Тему берём из
    // кэша: полоса перестраивается на каждом тике позиции, а построение схемы
    // из seed-цвета — не бесплатное.
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final m3e.M3EThemeData data = _m3eThemeFor(
      Theme.of(context).brightness,
      scheme.primary,
    );
    return m3e.M3ETheme(data: data, child: slider);
  }

  /// Пустой ползунок — для «волнистого» стиля.
  static Widget _noThumb({
    required BuildContext context,
    required m3e.M3ESliderColors colors,
    required bool pressed,
  }) =>
      const SizedBox.shrink();
}

/// Кэш тем `material_3_expressive` по яркости и цвету акцента.
///
/// `M3EThemeData.dark/light` строит полную цветовую схему из seed-цвета
/// (`M3EColorScheme.fromSeed`) — это заметная работа, а `_M3ESeekBar`
/// перестраивается на каждом обновлении позиции. Цвет акцента меняется редко
/// (при смене трека/темы), поэтому тему достаточно построить один раз.
final Map<(Brightness, int), m3e.M3EThemeData> _m3eThemeCache =
    <(Brightness, int), m3e.M3EThemeData>{};

m3e.M3EThemeData _m3eThemeFor(Brightness brightness, Color primary) {
  final (Brightness, int) key = (brightness, primary.toARGB32());
  final m3e.M3EThemeData? cached = _m3eThemeCache[key];
  if (cached != null) return cached;

  final m3e.M3EThemeData data = brightness == Brightness.dark
      ? m3e.M3EThemeData.dark(seedColor: primary)
      : m3e.M3EThemeData.light(seedColor: primary);
  // Кэш ограничен: при палитре из обложки акцент меняется с каждым треком.
  if (_m3eThemeCache.length >= 16) {
    _m3eThemeCache.remove(_m3eThemeCache.keys.first);
  }
  _m3eThemeCache[key] = data;
  return data;
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

/// Открывает диалог «Темп и питч».
///
/// Значения применяются сразу: темп слышно на играющем треке, и отдельная
/// кнопка «применить» только мешала бы. «Сбросить» возвращает 1.0 обоим.
///
/// Питч — не универсальная возможность бэкенда (см. [AudioEngine.supportsPitch]):
/// если движок его не умеет, ползунок отключён, а причина подписана текстом —
/// вместо молча неработающего сдвига.
Future<void> showTempoPitchDialog(BuildContext context, WidgetRef ref) async {
  final PlayerController controller =
      ref.read(playerControllerProvider.notifier);
  final PlaybackState playback = ref.read(playerControllerProvider).playback;
  final bool pitchSupported = ref.read(audioEngineProvider).supportsPitch;

  // Локальные значения — для плавного движения ползунка: состояние движка
  // приходит через поток, и без своей копии ползунок отставал бы от пальца.
  double speed = playback.speed;
  double pitch = playback.pitch;
  final int divisions =
      ((kTempoPitchMax - kTempoPitchMin) / kTempoPitchStep).round();

  await showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => StatefulBuilder(
      builder: (BuildContext context, StateSetter setState) {
        final ColorScheme scheme = Theme.of(context).colorScheme;
        final TextTheme text = Theme.of(context).textTheme;

        Widget block({
          required String title,
          required String note,
          required double value,
          required bool enabled,
          required ValueChanged<double> onChanged,
        }) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(title, style: text.titleSmall),
                  const Spacer(),
                  Text(
                    '${value.toStringAsFixed(2)}×',
                    style: text.labelLarge?.copyWith(
                      color: enabled ? scheme.primary : scheme.onSurfaceVariant,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ],
              ),
              Slider(
                value: value.clamp(kTempoPitchMin, kTempoPitchMax),
                min: kTempoPitchMin,
                max: kTempoPitchMax,
                divisions: divisions,
                label: '${value.toStringAsFixed(2)}×',
                onChanged: enabled ? onChanged : null,
              ),
              Text(
                note,
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          );
        }

        return AlertDialog(
          title: const Text('Темп и питч'),
          content: ConstrainedBox(
            // Ширина ограничена, но не задана жёстко: на узком экране диалог
            // должен ужиматься, а не вылезать за край.
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                block(
                  title: 'Темп',
                  note: 'Скорость без изменения высоты тона.',
                  value: speed,
                  enabled: true,
                  onChanged: (double v) {
                    setState(() => speed = v);
                    controller.setSpeed(v);
                  },
                ),
                const SizedBox(height: 12),
                block(
                  title: 'Питч',
                  note: pitchSupported
                      ? 'Высота тона без изменения темпа. Сдвиг делает libmpv '
                          'через scaletempo — на крайних значениях возможен '
                          'лёгкий призвук.'
                      : 'Недоступно: этот движок не умеет менять высоту тона '
                          'отдельно от темпа.',
                  value: pitch,
                  enabled: pitchSupported,
                  onChanged: (double v) {
                    setState(() => pitch = v);
                    controller.setPitch(v);
                  },
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                setState(() {
                  speed = 1.0;
                  pitch = 1.0;
                });
                controller.setSpeed(1.0);
                if (pitchSupported) controller.setPitch(1.0);
              },
              child: const Text('Сбросить'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Готово'),
            ),
          ],
        );
      },
    ),
  );
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
                    // Темп и питч — всегда в блоке управления: это настройка
                    // воспроизведения, а не режим очереди, поэтому она не
                    // прячется за `showModes`.
                    SizedBox(width: gap),
                    _TempoButton(
                      speed: player.playback.speed,
                      pitch: player.playback.pitch,
                      size: small,
                      radius: smallRadius,
                      iconSize: smallIcon,
                      onPressed: () => showTempoPitchDialog(context, ref),
                    ),
                    // Эквалайзер — рядом с темпом: это тоже настройка
                    // воспроизведения, а не конкретного трека.
                    SizedBox(width: gap),
                    _EqualizerButton(
                      size: small,
                      radius: smallRadius,
                      iconSize: smallIcon,
                    ),
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

/// Кнопка «Темп и питч» в блоке управления.
///
/// Подсвечена, когда темп или питч отличаются от 1.0: иначе сдвинутое
/// воспроизведение выглядело бы как обычное, и причину пришлось бы искать.
/// Текущие значения — в подсказке и в самом диалоге.
class _TempoButton extends StatelessWidget {
  const _TempoButton({
    required this.speed,
    required this.pitch,
    required this.size,
    required this.radius,
    required this.iconSize,
    required this.onPressed,
  });

  final double speed;
  final double pitch;
  final double size;
  final double radius;
  final double iconSize;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final Color onBackground = Theme.of(context).colorScheme.onSurface;
    final bool active = speed != 1.0 || pitch != 1.0;
    final String value = active
        ? 'темп ${speed.toStringAsFixed(2)}×, питч ${pitch.toStringAsFixed(2)}×'
        : 'темп и питч обычные';
    return _TransportButton(
      tooltip: 'Темп и питч ($value)',
      icon: Icons.speed,
      size: size,
      radius: radius,
      iconSize: iconSize,
      background: onBackground.withValues(alpha: active ? 0.2 : 0.08),
      foreground: onBackground.withValues(alpha: active ? 1 : 0.6),
      onPressed: onPressed,
    );
  }
}

/// Кнопка «Эквалайзер» в блоке управления.
///
/// Подсвечена, когда эквалайзер включён: сам он звук не подписывает, и без
/// подсветки причину «почему звук не такой» пришлось бы искать в настройках.
class _EqualizerButton extends ConsumerWidget {
  const _EqualizerButton({
    required this.size,
    required this.radius,
    required this.iconSize,
  });

  final double size;
  final double radius;
  final double iconSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool enabled = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => s.equalizerEnabled,
      ),
    );
    final Color onBackground = Theme.of(context).colorScheme.onSurface;
    return _TransportButton(
      tooltip: enabled ? 'Эквалайзер (включён)' : 'Эквалайзер',
      icon: Icons.graphic_eq,
      size: size,
      radius: radius,
      iconSize: iconSize,
      background: onBackground.withValues(alpha: enabled ? 0.2 : 0.08),
      foreground: onBackground.withValues(alpha: enabled ? 1 : 0.6),
      onPressed: () => showEqualizerDialog(context, ref),
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
          duration: AppMotion.controlMorph.duration,
          curve: AppMotion.controlMorph.curve,
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
/// Громкость и устройство вывода: одна строка во всю ширину блока.
class PlayerVolumeControl extends ConsumerWidget {
  const PlayerVolumeControl({super.key, this.iconSize = 20});

  final double iconSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerUiState player = ref.watch(playerControllerProvider);
    final double volume = player.playback.volume;
    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ProgressBarStyle style = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.volumeSliderStyle),
    );

    return Row(
      children: <Widget>[
        IconButton(
          tooltip: volume > 0 ? 'Выключить звук' : 'Включить звук',
          iconSize: iconSize,
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
        // Полоса громкости — во всю ширину блока; стиль тот же, что у полосы
        // перемотки (тот же компонент), поэтому вид совпадает.
        Expanded(
          child: style == ProgressBarStyle.standard ||
                  style == ProgressBarStyle.wavy ||
                  style == ProgressBarStyle.circular
              ? _M3ESeekBar(
                  style: style,
                  value: volume.clamp(0.0, 1.0),
                  // Волны у громкости нет: она показывает уровень, а не ход
                  // воспроизведения, и «живой» амплитуды у неё взяться неоткуда
                  // (у движка нет уровня сигнала). Нулевая амплитуда оставляет
                  // ровную дорожку той же толщины, что и выбранный стиль.
                  waveAmplitude: 0,
                  onChanged: controller.setVolume,
                  onChangeEnd: (_) {},
                )
              : _StyledSeekBar(
                  progress: volume.clamp(0.0, 1.0),
                  style: style,
                  activeColor: scheme.primary,
                  inactiveColor: scheme.primary,
                  playing: false,
                  enabled: true,
                  onSeek: controller.setVolume,
                  onSeekEnd: (_) {},
                ),
        ),
        // С другой стороны — выбор устройства вывода.
        IconButton(
          tooltip: 'Устройство вывода',
          iconSize: iconSize,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 36, height: 36),
          icon: const Icon(Icons.speaker),
          color: scheme.onSurfaceVariant,
          onPressed: () => _pickOutputDevice(context, ref, player),
        ),
      ],
    );
  }

  Future<void> _pickOutputDevice(
    BuildContext context,
    WidgetRef ref,
    PlayerUiState player,
  ) async {
    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);
    final List<AudioOutputDevice> devices = player.audioDevices;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Устройство вывода'),
            ),
            for (final AudioOutputDevice device in devices)
              ListTile(
                title: Text(device.isAuto ? 'Системное' : device.description),
                selected: device.name == player.audioDeviceName,
                trailing: device.name == player.audioDeviceName
                    ? const Icon(Icons.check)
                    : null,
                onTap: () {
                  controller.setAudioDevice(device.name);
                  Navigator.of(sheetContext).pop();
                },
              ),
          ],
        ),
      ),
    );
  }
}

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

class _StyledSeekBarState extends State<_StyledSeekBar> {
  double _lastFraction = 0;

  /// Высота области попадания. Сама дорожка рисуется по центру и тоньше —
  /// запас нужен, чтобы по полосе было удобно попадать пальцем.
  double get _height => switch (widget.style) {
        ProgressBarStyle.thick => 16,
        ProgressBarStyle.simple => 8,
        ProgressBarStyle.wavy => 16,
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
            child: CustomPaint(
              painter: _SeekBarPainter(
                progress: widget.progress,
                style: widget.style,
                activeColor: widget.activeColor,
                inactiveColor: widget.inactiveColor,
                playing: widget.playing,
                enabled: widget.enabled,
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
    required this.playing,
    required this.enabled,
  });

  final double progress;
  final ProgressBarStyle style;
  final Color activeColor;
  final Color inactiveColor;

  /// Играет ли трек: у «волнистого» стиля от этого зависит толщина линии.
  final bool playing;
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

    // Толщина дорожки — как в `StyledPlaybackSlider` (ArchiveTune): толстый
    // 12 dp, простой 3 dp, «волнистый» 6 dp в игре и 3 dp в паузе.
    //
    // Волну не рисуем: в ArchiveTune ни один из этих стилей не рисует синус —
    // дорожка у них прямая, а «волнистость» выражается только толщиной
    // (`PlayerComponents.kt:803-828`, `ui/component/PlayerSlider.kt`).
    final double thickness = switch (style) {
      ProgressBarStyle.thick => 12,
      ProgressBarStyle.simple => 3,
      ProgressBarStyle.wavy => playing ? 6 : 3,
      _ => 3,
    };
    // Простой стиль ещё и активную часть делает полупрозрачной (0.85).
    final Color active = style == ProgressBarStyle.simple
        ? activeBase.withValues(alpha: _kSimpleActiveTrackAlpha)
        : activeBase;

    canvas.drawLine(
      Offset(0, mid),
      Offset(size.width, mid),
      _linePaint(inactive, thickness),
    );
    if (size.width * p > 0.5) {
      canvas.drawLine(
        Offset(0, mid),
        Offset(size.width * p, mid),
        _linePaint(active, thickness),
      );
    }
  }

  Paint _linePaint(Color color, double width) => Paint()
    ..color = color
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round;

  @override
  bool shouldRepaint(covariant _SeekBarPainter old) =>
      old.progress != progress ||
      old.style != style ||
      old.playing != playing ||
      old.activeColor != activeColor ||
      old.inactiveColor != inactiveColor ||
      old.enabled != enabled;
}
