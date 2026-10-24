import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/audio_level_monitor.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/layout.dart';
import '../common/navigation.dart';
import '../../core/utils/artwork_urls.dart';
import '../../core/utils/format.dart';
import '../../data/local/app_settings.dart';
import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
import '../../state/providers.dart';
import '../../widgets/artist_line.dart';
import '../../widgets/artwork.dart';
import '../../widgets/blurred_artwork_background.dart';
import '../../widgets/liquid_backdrop.dart';
import '../../widgets/live_cover.dart';
import '../../widgets/spectrum_visualizer.dart';
import '../../widgets/track_menu.dart';
import 'equalizer.dart';
import 'lyrics_view.dart';
import 'media_info.dart';
import 'queue_list.dart';
import 'player_controls.dart';
import 'sleep_timer.dart';

/// Полноэкранный плеер для узких экранов.
///
/// На широких экранах он не нужен: там плеер всегда виден в правой панели,
/// поэтому дублирующего маршрута нет. Оформление — как у ArchiveTune:
/// размытая обложка сверху, тёмная панель с управлением снизу, крупный
/// транспорт и тонкая полоса перемотки.
class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  @override
  Widget build(BuildContext context) {
    final PlayerUiState player = ref.watch(playerControllerProvider);
    // Показ текста — ОБЩАЯ настройка для всех экранов, а не своё состояние
    // этого экрана: переключил здесь — текст показан и в панели, и в островке.
    final bool showLyrics = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => s.showLyricsInPlayer,
      ),
    );
    final Track? track = player.current;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Стиль фона полноэкранного плеера — из настроек (как PlayerBackgroundStyle
    // в ArchiveTune).
    final PlayerBackgroundStyle backgroundStyle = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => s.playerBackgroundStyle,
      ),
    );
    final bool disableBlur = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.disableBlur),
    );
    final double blurRadius = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.blurRadius),
    );

    return Scaffold(
      backgroundColor: scheme.surface,
      body: track == null
          ? _Empty(onClose: () => Navigator.maybePop(context))
          : Stack(
              children: <Widget>[
                // Фон: стиль из настроек (градиент, обложка, свечение,
                // окрашивание или «жидкость»).
                Positioned.fill(
                  child: _ArtworkBackdrop(
                    track: track,
                    style: backgroundStyle,
                    blurSigma: disableBlur ? 0 : blurRadius,
                    // «Жидкость» идёт только по звуку: на паузе анимация
                    // останавливается и перерисовок нет.
                    animate: player.isPlaying,
                  ),
                ),
                SafeArea(
                  child: Column(
                    children: <Widget>[
                      _TopBar(
                        showLyrics: showLyrics,
                        onToggleLyrics: () => ref
                            .read(settingsControllerProvider.notifier)
                            .setShowLyrics(!showLyrics),
                      ),
                      // На широком экране раскладка двухколоночная: обложка
                      // слева, управление справа. Вертикальная «телефонная»
                      // колонка на десктопе растягивала обложку на пол-экрана
                      // и оставляла пустоту по бокам.
                      Expanded(
                        child: context.isExpandedLayout
                            ? Row(
                                children: <Widget>[
                                  Expanded(
                                    flex: 5,
                                    child: _Stage(
                                      showLyrics: showLyrics,
                                      track: track,
                                      animate: player.isPlaying,
                                    ),
                                  ),
                                  Expanded(
                                    flex: 4,
                                    // Очередь сверху — своя прокручиваемая
                                    // область; шапку скрываем, название и
                                    // действия уже есть в блоке управления.
                                    // Боковые отступы задаёт сам блок
                                    // управления (`playerInset`), поэтому
                                    // внешнего отступа здесь нет: иначе
                                    // справа он удвоился бы.
                                    child: _StackedControls(
                                      reserve: _kQueueMinHeight,
                                      track: track,
                                      player: player,
                                      flexible: const QueueList(
                                        showHeader: false,
                                        showCurrent: false,
                                        showCarousel: false,
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : _StackedControls(
                                reserve: _kStageMinHeight,
                                track: track,
                                player: player,
                                flexible: _Stage(
                                  showLyrics: showLyrics,
                                  track: track,
                                  animate: player.isPlaying,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

/// Минимальная высота очереди в широкой раскладке.
///
/// Текущий трек (72) + подпись «Далее — N» (~40) + хотя бы одна строка
/// «далее» (72): меньше — и очередь вырождается в обрезанную полоску под
/// блоком управления (именно это и было на снимке).
const double _kQueueMinHeight = 184;

/// Минимальная высота верхней части в телефонной раскладке (обложка или
/// текст). Ниже неё управление начинает прокручиваться, но колонка не
/// переполняется на коротком окне (например, повёрнутый телефон).
const double _kStageMinHeight = 160;

/// Обложка или текст песни — то, что занимает основную площадь.
class _Stage extends StatelessWidget {
  const _Stage({
    required this.showLyrics,
    required this.track,
    required this.animate,
  });

  final bool showLyrics;
  final Track track;

  /// Идёт воспроизведение: нужно «живой обложке» — на паузе она замирает.
  final bool animate;

  @override
  Widget build(BuildContext context) {
    return AppMotion.stageSwitch.switcher(
      child: showLyrics
          ? LyricsView(
              key: ValueKey<String>('lyr-${track.id}'),
              videoId: track.id,
            )
          : _ArtworkStage(track: track, animate: animate),
    );
  }
}

/// Прокручиваемая область сверху и блок управления снизу.
///
/// Раньше обе части были прямыми детьми [Column]: очередь стояла в
/// `Expanded`, а управление — негибким соседом. Блок управления имеет
/// собственную высоту (название + полоса перемотки + транспорт 88 +
/// громкость) и на коротком окне занимал почти всю колонку: `Expanded`
/// сжимал очередь до нескольких пикселей, её строки резались по краю
/// блока, а при ещё меньшей высоте колонка просто переполнялась снизу.
///
/// Здесь верхней части ([flexible]) гарантируется [reserve], управление
/// получает остаток высоты и при нехватке места прокручивается. Так очередь
/// сохраняет собственную прокрутку и не перекрывается управлением при любой
/// высоте окна; на телефонной раскладке так же защищена обложка/текст.
class _StackedControls extends StatelessWidget {
  const _StackedControls({
    required this.flexible,
    required this.reserve,
    required this.track,
    required this.player,
  });

  /// Верхняя часть: очередь (широкий экран) либо обложка/текст (телефон).
  final Widget flexible;

  /// Сколько высоты оставляем [flexible] в любом случае.
  final double reserve;

  final Track track;
  final PlayerUiState player;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Управлению — всё, что осталось после минимума верхней части.
        // На сверхнизком окне лимит доходит до нуля, но колонка не выходит
        // за границы: очередь всё равно получает свой минимум.
        final double controlsMax =
            (constraints.maxHeight - reserve).clamp(0.0, double.infinity);
        return Column(
          children: <Widget>[
            Expanded(child: flexible),
            // Управление остаётся отдельным блоком внизу и не наезжает на
            // очередь; если места мало — прокручивается, а не выдавливает
            // соседа и не переполняет колонку.
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: controlsMax),
              child: SingleChildScrollView(
                // `primary: false` — иначе на телефоне это прокручивание
                // делило бы `PrimaryScrollController` с очередью.
                primary: false,
                child: _Controls(track: track, player: player),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Блок управления: название, шкала, транспорт и громкость.
class _Controls extends StatelessWidget {
  const _Controls({required this.track, required this.player});

  final Track track;
  final PlayerUiState player;

  @override
  Widget build(BuildContext context) {
    // Один и тот же боковой отступ у всех блоков (`playerInset`), а между
    // блоками — один вертикальный шаг. Раньше название шло с 32 и 6, шкала с
    // 32, транспорт с 32, а низ — с 30: края не совпадали ни между блоками,
    // ни с правой панелью.
    const EdgeInsets side = EdgeInsets.symmetric(
      horizontal: AppLayout.playerInset,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _InfoRow(track: track, player: player),
        const SizedBox(height: AppLayout.playerGroupGap),
        PlayerSeekBar(player: player),
        const SizedBox(height: AppLayout.playerItemGap),
        Padding(
          padding: side,
          // Перемешивание и повтор — по краям транспорта: отдельной строки
          // режимов больше нет, и блок управления стал ниже на её высоту.
          child: PlayerTransportBar(
            player: player,
            leading: const ShuffleButton(),
            trailing: const RepeatButton(),
          ),
        ),
        // Громкость — такой же блок, как шкала и транспорт, но своей группой:
        // зазор между ней и транспортом — общий межгрупповой шаг, а не шаг
        // внутри группы: иначе полоса громкости прилипает к кнопкам.
        const SizedBox(height: AppLayout.playerGroupGap),
        const Padding(
          padding: side,
          child: PlayerVolumeControl(),
        ),
        const SizedBox(height: AppLayout.playerItemGap),
      ],
    );
  }
}

/// Фон: мягкий градиент, собранный из палитры обложки.
///
/// Палитру извлекаем из картинки тем же способом, что и общую тему
/// (`AppTheme.schemeFromArtwork` → `ColorScheme.fromImageProvider`): это уже
/// есть в проекте, поэтому новых зависимостей не нужно. Берём не саму обложку,
/// а её цвета-роли — фон остаётся «цветом обложки», но не спорит с текстом
/// темы.
///
/// Композиция — как `PlayerBackgroundStyle.GRADIENT` в ArchiveTune
/// (`ui/player/PlayerComponents.kt`): три точки 0.0 / 0.5 / 1.0 с альфами
/// 0.92 / 0.75 / 0.65 и мягкая подложка 0.18. Размытия и «стекла» нет —
/// только градиент.
class _ArtworkBackdrop extends StatefulWidget {
  const _ArtworkBackdrop({
    required this.track,
    required this.style,
    required this.animate,
    this.blurSigma = 28,
  });

  final Track track;

  /// Стиль фона из настроек.
  final PlayerBackgroundStyle style;

  /// Идёт воспроизведение — нужно стилю «жидкость»: на паузе он замирает
  /// (см. `LiquidBackdrop`).
  final bool animate;

  /// Сила размытия для стиля «размытая обложка» (0 — без размытия).
  final double blurSigma;

  @override
  State<_ArtworkBackdrop> createState() => _ArtworkBackdropState();
}

class _ArtworkBackdropState extends State<_ArtworkBackdrop> {
  /// Палитра текущей обложки; `null` — ещё не разобрана (рисуем ролями темы).
  ColorScheme? _palette;

  /// Ключ (адрес + яркость), для которого посчитана палитра.
  String? _key;

  /// Яркость, для которой посчитана палитра: при её смене старую палитру
  /// показывать нельзя — контейнеры «чужой» яркости не подходят тексту темы.
  Brightness? _brightness;

  /// Номер запроса: устаревший ответ не должен перебить новый.
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPalette();
  }

  @override
  void didUpdateWidget(covariant _ArtworkBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.id != widget.track.id) _syncPalette();
  }

  /// Пересчитывает палитру, если сменился трек или яркость темы.
  void _syncPalette() {
    final Brightness brightness = Theme.of(context).brightness;
    final List<String> variants = widget.track.artworkFallbacks(kArtworkLarge);
    final String url = variants.isEmpty ? '' : variants.first;
    final String key = '$url|${brightness.name}';
    final bool brightnessChanged = brightness != _brightness;
    _brightness = brightness;
    if (key == _key) return;
    _key = key;
    // Смена темы — сразу на роли темы; смена трека той же яркости — оставляем
    // прошлую палитру, и градиент плавно переходит из цвета в цвет.
    if (brightnessChanged) _palette = null;
    if (url.isEmpty) {
      _palette = null;
      return;
    }
    final int generation = ++_generation;
    _extractArtworkPalette(url, brightness).then((ColorScheme? palette) {
      if (!mounted || generation != _generation) return;
      setState(() => _palette = palette);
    });
  }

  @override
  Widget build(BuildContext context) {
    // «Размытая обложка» — сама картинка трека с размытием и затемнением.
    if (widget.style == PlayerBackgroundStyle.blur) {
      return BlurredArtworkBackground(
        track: widget.track,
        blurSigma: widget.blurSigma,
      );
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Пока палитра не готова, рисуем фон ролями темы: тот же градиент, но без
    // вклада обложки. Подмена незаметна — цвета близки по светлоте.
    final ColorScheme palette = _palette ?? scheme;
    // «Жидкость» — свой шейдер из тех же трёх цветов, что у градиента: цвета
    // обложки, только текучие.
    if (widget.style == PlayerBackgroundStyle.liquid) {
      return LiquidBackdrop(
        colors: _backdropColors(palette),
        animate: widget.animate,
      );
    }
    if (widget.style == PlayerBackgroundStyle.glow) {
      return _GlowBackdrop(scheme: scheme, palette: palette);
    }
    if (widget.style == PlayerBackgroundStyle.coloring) {
      return _ColoringBackdrop(scheme: scheme, palette: palette);
    }
    return _GradientBackdrop(scheme: scheme, palette: palette);
  }
}

/// Три цвета фона из палитры обложки.
///
/// Роли контейнеров, а не `primary`/`tertiary`: у тёмной схемы они тёмные, у
/// светлой — светлые, поэтому текст темы (`onSurface`) читается в обоих режимах.
/// Одни и те же цвета берут и градиент, и «жидкость» — фон не меняет палитру при
/// смене стиля.
List<Color> _backdropColors(ColorScheme palette) => <Color>[
      palette.primaryContainer.withValues(alpha: 0.92),
      palette.secondaryContainer.withValues(alpha: 0.75),
      palette.tertiaryContainer.withValues(alpha: 0.65),
    ];

/// Кэш палитр по адресу обложки и яркости: квантование цвета небыстрое, а
/// треки повторяются.
final Map<String, ColorScheme> _artworkPaletteCache = <String, ColorScheme>{};

/// Считает палитру обложки общим механизмом темы (`fromImageProvider`).
Future<ColorScheme?> _extractArtworkPalette(
  String url,
  Brightness brightness,
) async {
  final String key = '$url|${brightness.name}';
  final ColorScheme? cached = _artworkPaletteCache[key];
  if (cached != null) return cached;
  try {
    final ColorScheme palette = await AppTheme.schemeFromArtwork(
      provider: artworkProvider(url),
      brightness: brightness,
    );
    _artworkPaletteCache[key] = palette;
    if (_artworkPaletteCache.length > 40) {
      _artworkPaletteCache.remove(_artworkPaletteCache.keys.first);
    }
    return palette;
  } on Object {
    // Обложка не разобралась (нет сети, битый файл) — тихо откатываемся на
    // роли темы: фон остаётся, просто без вклада картинки.
    return null;
  }
}

/// Сам градиент: три точки из ролей палитры и мягкая подложка.
class _GradientBackdrop extends StatelessWidget {
  const _GradientBackdrop({required this.scheme, required this.palette});

  /// Схема темы — база и ориентир по яркости.
  final ColorScheme scheme;

  /// Палитра из обложки; совпадает с [scheme], пока обложка не разобрана.
  final ColorScheme palette;

  @override
  Widget build(BuildContext context) {
    // Цвета те же, что у «жидкости» (`_backdropColors`) — фон не меняется при
    // смене стиля задним числом.
    final List<Color> colors = _backdropColors(palette);
    // Подложка поверх градиента — как чёрная 0.18 в ArchiveTune. На светлой
    // теме чёрная затемнила бы светлые контейнеры и испортила контраст с
    // тёмным текстом, поэтому там подложка того же назначения, но светлая.
    final Color scrim = scheme.brightness == Brightness.dark
        ? Colors.black
        : scheme.surface;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // Плавно переводим градиент при смене трека или готовности палитры.
        AnimatedContainer(
          duration: AppMotion.backdropShift.duration,
          curve: AppMotion.backdropShift.curve,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: colors,
              stops: const <double>[0.0, 0.5, 1.0],
            ),
          ),
        ),
        ColoredBox(color: scrim.withValues(alpha: 0.18)),
      ],
    );
  }
}

/// Стиль «Свечение»: мягкие пятна цветов обложки по краям.
///
/// В отличие от градиента, который заливает фон сверху вниз, здесь основу
/// остаётся поверхность темы: текст и управление читаются в любом месте, а
/// цвет обложки живёт по краям — тремя радиальными пятнами. Пятна плавно
/// гаснут к центру, поэтому границы не видно.
class _GlowBackdrop extends StatelessWidget {
  const _GlowBackdrop({required this.scheme, required this.palette});

  /// Схема темы — основа фона.
  final ColorScheme scheme;

  /// Палитра из обложки; совпадает с [scheme], пока обложка не разобрана.
  final ColorScheme palette;

  @override
  Widget build(BuildContext context) {
    final List<Color> colors = _backdropColors(palette);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ColoredBox(color: scheme.surface),
        _halo(colors[0], const Alignment(-1.0, -1.0), 1.15),
        _halo(colors[2], const Alignment(1.0, -0.55), 0.95),
        _halo(colors[1], const Alignment(0.0, 1.15), 1.1),
      ],
    );
  }

  /// Одно пятно: цвет у края, прозрачность к центру.
  Widget _halo(Color color, Alignment center, double radius) {
    return AnimatedContainer(
      duration: AppMotion.backdropShift.duration,
      curve: AppMotion.backdropShift.curve,
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: center,
          radius: radius,
          colors: <Color>[
            color.withValues(alpha: 0.62),
            color.withValues(alpha: 0),
          ],
          stops: const <double>[0.0, 1.0],
        ),
      ),
    );
  }
}

/// Стиль «Окрашивание»: фон залит одним цветом обложки.
///
/// Никакого перехода нет — весь экран одного тона. Это самый спокойный из
/// стилей: обложка задаёт оттенок, но не спорит с текстом и обложкой.
class _ColoringBackdrop extends StatelessWidget {
  const _ColoringBackdrop({required this.scheme, required this.palette});

  /// Схема темы — ориентир по яркости и подложка.
  final ColorScheme scheme;

  /// Палитра из обложки; совпадает с [scheme], пока обложка не разобрана.
  final ColorScheme palette;

  @override
  Widget build(BuildContext context) {
    final Color scrim = scheme.brightness == Brightness.dark
        ? Colors.black
        : scheme.surface;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        AnimatedContainer(
          duration: AppMotion.backdropShift.duration,
          curve: AppMotion.backdropShift.curve,
          color: _backdropColors(palette).first,
        ),
        // Подложка та же, что у градиента: плоский цвет без неё был бы
        // светлее, и текст терял бы контраст.
        ColoredBox(color: scrim.withValues(alpha: 0.18)),
      ],
    );
  }
}

/// Обложка в открытом виде — крупная и резкая.
///
/// Когда включён визуализатор, обложка на пару десятков пикселей уменьшается, а в
/// освободившемся зазоре рисуется гало по уровню звука: обложку оно не
/// перекрывает, потому что живёт снаружи неё. Если уровня нет (сборка libmpv без
/// фильтра `astats`), под обложкой появляется подпись с причиной — вместо
/// выдуманного движения.
///
/// С настройкой «Живая обложка» сама картинка оборачивается в [LiveCover]: она
/// дышит и светится по краю. Обёртка необязательная — без настройки дерево и вид
/// остаются прежними.
class _ArtworkStage extends StatelessWidget {
  const _ArtworkStage({required this.track, required this.animate});

  final Track track;

  /// Идёт воспроизведение: «живая обложка» на паузе замирает.
  final bool animate;

  /// Зазор под гало: и отступ кольца от обложки, и место, которое обложка
  /// уступает визуализатору.
  static const double _kHaloInset = 26;

  /// Радиус скругления обложки — как `Thumbnail` в ArchiveTune (16).
  static const double _kArtworkRadius = 16;

  /// Предел стороны обложки: на десктопе огромная обложка отбирала место у
  /// управления и очереди.
  static const double _kMaxSide = 420;

  @override
  Widget build(BuildContext context) {
    final List<String> variants = track.artworkFallbacks(kArtworkLarge);

    return Padding(
      // Отступы обложки — тот же боковой `playerInset`, что у остальных
      // блоков, и такой же сверху и снизу.
      padding: const EdgeInsets.symmetric(
        horizontal: AppLayout.playerInset,
        vertical: AppLayout.playerVerticalInset,
      ),
      child: Consumer(
        builder: (BuildContext context, WidgetRef ref, Widget? child) {
          final bool withVisualizer = ref.watch(
            settingsControllerProvider.select(
              (AppSettings s) => s.visualizerEnabled,
            ),
          );
          // «Отключить анимации» гасит живую обложку целиком: остаётся
          // статичная картинка, как без настройки. Дрейф — движение, и
          // выключать его наполовину (свет без движения) было бы странно.
          final bool liveCover = ref.watch(
            settingsControllerProvider.select(
              (AppSettings s) => s.liveCoverEnabled && !s.disableAnimations,
            ),
          );
          // Монитор читается только когда он кому-то нужен: провайдер ленивый, и
          // пока ни гало, ни живой обложки нет, libmpv для уровней не поднимается.
          final AudioLevelMonitor? monitor = withVisualizer || liveCover
              ? ref.watch(audioLevelMonitorProvider)
              : null;
          // Гало живёт отдельно от живой обложки: свечение обложки — не повод
          // рисовать кольцо вокруг неё.
          final AudioLevelMonitor? halo = withVisualizer ? monitor : null;
          final double Function()? levelOf =
              liveCover && monitor != null ? () => monitor.level : null;

          return Center(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                // Обложка квадратная и вписывается в доступное место.
                final double available = constraints.biggest.shortestSide;
                if (halo == null) {
                  return _artwork(
                    context,
                    variants,
                    _side(available),
                    null,
                    levelOf,
                  );
                }
                // Слушаем монитор: подпись «уровня нет» должна появиться сама,
                // без пересборки всего экрана.
                return AnimatedBuilder(
                  animation: halo,
                  builder: (BuildContext context, Widget? child) {
                    final bool noData = halo.availability ==
                        AudioLevelAvailability.unavailable;
                    // Подпись занимает место под обложкой: без вычета её высоты
                    // колонка переполнила бы отведённую высоту на низком окне.
                    final double limit = noData
                        ? available - SpectrumUnavailableNote.height
                        : available;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _artwork(
                          context,
                          variants,
                          _side(limit),
                          halo,
                          levelOf,
                        ),
                        if (noData) SpectrumUnavailableNote(monitor: halo),
                      ],
                    );
                  },
                );
              },
            ),
          );
        },
      ),
    );
  }

  static double _side(double available) {
    if (available > _kMaxSide) return _kMaxSide;
    return available < 0 ? 0 : available;
  }

  /// Обложка; при [monitor] — вместе с гало в том же квадрате.
  ///
  /// [levelOf] непустой — включена «живая обложка»: обёртка берёт уровень у того
  /// же монитора, что и гало.
  Widget _artwork(
    BuildContext context,
    List<String> variants,
    double side,
    AudioLevelMonitor? monitor,
    double Function()? levelOf,
  ) {
    // Правый клик по обложке — то же меню, что у «…»: меню трека лежит в
    // корневом навигаторе, потому что сам плеер открыт там же.
    Widget artwork = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTap: () => showTrackMenu(
        context,
        track,
        rootNavigator: true,
        onMediaInfo: () => showMediaInfoDialog(context),
      ),
      child: Artwork(
        url: variants.isEmpty ? null : variants.first,
        fallbacks:
            variants.length > 1 ? variants.sublist(1) : const <String>[],
        // Общий тег с миниатюрой островка: обложка перелетает и растёт
        // из мини-плеера в полный экран (и обратно).
        heroTag: kPlayerArtworkHeroTag,
        radius: BorderRadius.circular(_kArtworkRadius),
      ),
    );
    if (levelOf != null) {
      // Цвета свечения — из темы: когда выбрана палитра «из обложки», это те же
      // цвета, что у фона, а лишний разбор обложки ради света не нужен.
      artwork = LiveCover(
        enabled: true,
        animate: animate,
        level: levelOf,
        colors: _backdropColors(Theme.of(context).colorScheme),
        radius: _kArtworkRadius,
        child: artwork,
      );
    }
    if (monitor == null) {
      return SizedBox(width: side, height: side, child: artwork);
    }
    // Цвета гало — из темы: когда в настройках выбрана палитра «из обложки», это
    // те же цвета, что у фона, а лишний разбор обложки ради кольца не нужен.
    final List<Color> colors =
        _backdropColors(Theme.of(context).colorScheme);
    // На очень узком окне зазор может не поместиться — тогда обложка просто
    // занимает весь квадрат, а гало рисуется поверх края.
    final double inner = (side - 2 * _kHaloInset).clamp(0.0, side);
    return SizedBox(
      width: side,
      height: side,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Positioned.fill(
            child: SpectrumVisualizer(
              monitor: monitor,
              artworkInset: _kHaloInset,
              cornerRadius: _kArtworkRadius + _kHaloInset,
              colors: colors,
            ),
          ),
          SizedBox(width: inner, height: inner, child: artwork),
        ],
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({
    required this.showLyrics,
    required this.onToggleLyrics,
  });

  final bool showLyrics;
  final VoidCallback onToggleLyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool equalizer = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => s.equalizerEnabled,
      ),
    );
    final bool visualizer = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => s.visualizerEnabled,
      ),
    );
    final (double speed, double pitch) = ref.watch(
      playerControllerProvider.select(
        (PlayerUiState s) => (s.playback.speed, s.playback.pitch),
      ),
    );
    final bool tempoActive = speed != 1.0 || pitch != 1.0;
    final String tempoValue = tempoActive
        ? 'темп ${speed.toStringAsFixed(2)}×, питч ${pitch.toStringAsFixed(2)}×'
        : 'темп и питч обычные';

    return Padding(
      // Тот же боковой отступ, что и у блока управления: кнопки шапки не
      // должны начинаться с другого числа.
      padding: const EdgeInsets.symmetric(
        horizontal: AppLayout.playerInset,
        vertical: 4,
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: 'Свернуть',
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
            onPressed: () => Navigator.maybePop(context),
          ),
          const Spacer(),
          // Шапка — рабочая строка: текст, эквалайзер, темп и визуализатор
          // стоят рядом, как кнопки одного ряда. Поиск текста отсюда убран:
          // тот же значок есть в шапке самого текста, и он не дублируется.
          _TopBarButton(
            tooltip: showLyrics ? 'Скрыть текст' : 'Показать текст',
            icon: Icons.lyrics_outlined,
            selectedIcon: Icons.lyrics,
            selected: showLyrics,
            onPressed: onToggleLyrics,
          ),
          const SizedBox(width: AppLayout.playerItemGap),
          _TopBarButton(
            tooltip: equalizer ? 'Эквалайзер (включён)' : 'Эквалайзер',
            icon: Icons.graphic_eq,
            selected: equalizer,
            onPressed: () => showEqualizerDialog(context, ref),
          ),
          const SizedBox(width: AppLayout.playerItemGap),
          _TopBarButton(
            tooltip: 'Темп и питч ($tempoValue)',
            icon: Icons.speed,
            selected: tempoActive,
            onPressed: () => showTempoPitchDialog(context, ref),
          ),
          const SizedBox(width: AppLayout.playerItemGap),
          _TopBarButton(
            tooltip: visualizer ? 'Визуализатор включён' : 'Визуализатор',
            icon: Icons.bar_chart_rounded,
            selected: visualizer,
            onPressed: () => ref
                .read(settingsControllerProvider.notifier)
                .setVisualizerEnabled(!visualizer),
          ),
        ],
      ),
    );
  }
}

/// Кнопка шапки полного экрана — тот же `IconButton.filledTonal` и тот же
/// размер 40, что у прежней кнопки «текст»: ряд из четырёх кнопок читается
/// одной линией и не выше соседей.
class _TopBarButton extends StatelessWidget {
  const _TopBarButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selectedIcon,
    this.selected = false,
  });

  final String tooltip;
  final IconData icon;
  final IconData? selectedIcon;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      tooltip: tooltip,
      isSelected: selected,
      iconSize: 20,
      // Зона нажатия — сам квадрат: без `shrinkWrap` кнопка растягивала
      // строку до 48 и шапка становилась выше прежней.
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        fixedSize: const Size.square(40),
        padding: EdgeInsets.zero,
      ),
      icon: Icon(icon),
      selectedIcon: selectedIcon == null ? null : Icon(selectedIcon),
      onPressed: onPressed,
    );
  }
}

/// Название, исполнитель, кодек и кнопки действий.
///
/// Состояние лайка берём из общего [likedIdsProvider], а не из локального
/// флага: лайк, поставленный здесь, сразу виден в строках треков и островке
/// плеера (и наоборот). Выравнивание блока — настройка
/// `playerInfoAlignment`: по центру (ось обложки) или по левому краю.
class _InfoRow extends ConsumerWidget {
  const _InfoRow({required this.track, required this.player});

  final Track track;
  final PlayerUiState player;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool liked = ref.watch(
      likedIdsProvider.select((Set<String> ids) => ids.contains(track.id)),
    );
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );

    // Одно меню на «…» и правый клик по названию: так действия не разойдутся.
    void openMenu() => showTrackMenu(
          context,
          track,
          rootNavigator: true,
          // Параметры играющего потока и таймер сна — в том же меню, что и
          // действия над треком: второй «⋮» на экране только путал бы.
          onMediaInfo: () => showMediaInfoDialog(context),
          onSleepTimer: () => showSleepTimerMenu(context, ref),
        );

    // Выравнивание блока — настройка: по центру (прежний вид) или по левому
    // краю, где длинные названия читаются как строки списка.
    final PlayerInfoAlignment align = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => s.playerInfoAlignment,
      ),
    );
    final bool byLeft = align == PlayerInfoAlignment.left;

    // Кнопки действий одной группой: слева от названия стоит такая же по
    // ширине пустая полоса, поэтому центр заголовка совпадает с центром блока,
    // хотя справа от него кнопки. При выравнивании по левому краю распорка
    // обнуляется: иначе текст начинался бы не от края, а от её середины.
    final double actionsWidth = AppLayout.playerCompactAction * 2 +
        AppLayout.playerItemGap;
    final Widget actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // Лайк — как в V4, но цветом ошибки, а не акцентом.
        _PlayerActionButton(
          tooltip: liked ? 'Убрать из «Мне нравится»' : 'Нравится',
          icon: liked ? Icons.favorite : Icons.favorite_border,
          selected: liked,
          accent: true,
          onPressed: signedIn ? () => _like(context, ref) : null,
        ),
        const SizedBox(width: AppLayout.playerItemGap),
        // «…» открывает то же меню, что и из островка: исполнитель, альбом,
        // очередь и лайк. rootNavigator: плеер сам лежит в корневом
        // навигаторе — лист должен лежать там же, поверх плеера; переходы из
        // него сначала сворачивают плеер.
        _PlayerActionButton(
          tooltip: 'Действия',
          icon: Icons.more_vert,
          onPressed: openMenu,
        ),
      ],
    );

    return Padding(
      // Все блоки управления начинаются с одного бокового отступа — слева и
      // справа одинаково. Верхний отступ — шаг внутри блока
      // (`playerItemGap`): шапка должна быть плотной, но не прилипать к
      // верхней панели.
      padding: const EdgeInsets.fromLTRB(
        AppLayout.playerInset,
        AppLayout.playerItemGap,
        AppLayout.playerInset,
        0,
      ),
      // Название, исполнитель и действия — одной строкой. Раньше действия
      // стояли под названием третьей строкой и вместе с крупным кеглем
      // занимали 122 px; теперь высоту задаёт только текст.
      child: Row(
        children: <Widget>[
          SizedBox(
            width: byLeft ? 0 : actionsWidth + AppLayout.playerItemGap,
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: byLeft
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.center,
              children: <Widget>[
                // Название — крупнее подписи на ступень (`titleLarge`): это
                // главная строка экрана, а не подпись под обложкой.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onSecondaryTap: openMenu,
                  child: Text(
                    track.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: byLeft ? TextAlign.left : TextAlign.center,
                    style: text.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                // Название и подпись — одна пара, поэтому зазор между ними
                // меньше шага блока: 8 px разрывали бы их на две строки.
                const SizedBox(height: 2),
                Row(
                  mainAxisAlignment: byLeft
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  children: <Widget>[
                    Flexible(
                      // Исполнитель — ссылка на его страницу. Ошибку плеера
                      // показываем текстом: она не ссылка. Подсказка при
                      // наведении остаётся — причина отказа бывает длинной,
                      // а строка одна.
                      child: player.error != null
                          ? Tooltip(
                              message: player.error!,
                              child: Text(
                                player.error!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign:
                                    byLeft ? TextAlign.left : TextAlign.center,
                                style: text.bodySmall?.copyWith(
                                  fontSize: 11,
                                  color: scheme.error,
                                ),
                              ),
                            )
                          : ArtistLine(
                              artists: track.artists,
                              // Исполнитель на пиксель мельче прежнего
                              // `bodySmall`: кодек рядом — справка, и равный
                              // кегль заставлял их спорить за внимание.
                              style: text.bodySmall?.copyWith(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                              textAlign:
                                  byLeft ? TextAlign.left : TextAlign.center,
                              // Переход сам сворачивает плеер (см.
                              // [AppRoutes]): иначе страница оказалась бы под
                              // ним или легла бы поверх вторым слоем.
                              onArtistTap: (ArtistRef artist) =>
                                  AppRoutes.artistFromMenu(
                                    context,
                                    artist.id!,
                                  ),
                            ),
                    ),
                    const SizedBox(width: AppLayout.playerItemGap),
                    QualityBadge(player: player),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppLayout.playerItemGap),
          actions,
        ],
      ),
    );
  }

  Future<void> _like(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool wasLiked = ref.read(likedIdsProvider).contains(track.id);
    try {
      await ref.read(likedIdsProvider.notifier).toggle(track.id);
      messenger.showSnackBar(
        SnackBar(
          content: Text(wasLiked
              ? 'Убрано из «Мне нравится»'
              : 'Добавлено в «Мне нравится»'),
        ),
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

/// Действие в шапке полного экрана — компактный квадрат
/// ([AppLayout.playerCompactAction]) с радиусом около трети стороны.
///
/// Фон: 0.12 в покое и 0.2 во включённом виде (для лайка — `error` с 0.25);
/// иконка — `playerCompactActionIcon`, выбранная — цветом акцента. Полноразмерные
/// 44 были третьей по высоте строкой шапки, хотя это второстепенные действия.
class _PlayerActionButton extends StatelessWidget {
  const _PlayerActionButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
    this.accent = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;

  /// Лайк подсвечивается не акцентом, а цветом ошибки — как в V4.
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color background = selected
        ? (accent
            ? scheme.error.withValues(alpha: 0.25)
            : scheme.onSurface.withValues(alpha: 0.2))
        : scheme.onSurface.withValues(alpha: 0.12);
    final Color foreground = selected
        ? (accent ? scheme.error : scheme.primary)
        : scheme.onSurface;
    final double side = AppLayout.playerCompactAction;
    final BorderRadius shape = BorderRadius.circular(side * 0.32);

    // Свой квадрат поверх `Material`, а не `IconButton`: у выключенной
    // кнопки `IconButton` гасит и заливку, и лайк без входа в аккаунт
    // выглядел бы голой иконкой, выпадая из ряда.
    return Tooltip(
      message: tooltip,
      child: Material(
        color: background,
        borderRadius: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: shape,
          onTap: onPressed,
          child: SizedBox(
            width: side,
            height: side,
            child: Center(
              child: Icon(
                icon,
                size: AppLayout.playerCompactActionIcon,
                color: foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
              onPressed: onClose,
            ),
          ),
          const Expanded(
            child: Center(child: Text('Ничего не играет')),
          ),
        ],
      ),
    );
  }
}

/// Подпись длительности для панелей — оставлена для совместимости со старым
/// кодом; использует общий форматтер.
String progressLabel(PlayerUiState player) =>
    '${formatDurationClock(player.playback.position)} / '
    '${formatDurationClock(player.playback.duration)}';
