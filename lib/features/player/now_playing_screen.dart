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
import '../../state/catalog_providers.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
import '../../state/providers.dart';
import '../../widgets/artist_line.dart';
import '../../widgets/artwork.dart';
import '../../widgets/blurred_artwork_background.dart';
import '../../widgets/liquid_backdrop.dart';
import '../../widgets/spectrum_visualizer.dart';
import '../../widgets/track_menu.dart';
import 'lyrics_actions.dart';
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
                        track: track,
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
                                    ),
                                  ),
                                  Expanded(
                                    flex: 4,
                                    child: Padding(
                                      // Отступ справа: без него управление и
                                      // очередь прилипали к краю окна.
                                      padding: const EdgeInsets.only(right: 20),
                                      // Очередь сверху — своя прокручиваемая
                                      // область; шапку скрываем, название и
                                      // действия уже есть в блоке управления.
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
  const _Stage({required this.showLyrics, required this.track});

  final bool showLyrics;
  final Track track;

  @override
  Widget build(BuildContext context) {
    return AppMotion.stageSwitch.switcher(
      child: showLyrics
          ? LyricsView(
              key: ValueKey<String>('lyr-${track.id}'),
              videoId: track.id,
            )
          : _ArtworkStage(track: track),
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
    // Отступы между блоками — как в `PlayerControlsContent` (ArchiveTune):
    // 12 после названия, 12 после полосы перемотки, 30 в самом низу.
    // Боковой отступ — `PlayerHorizontalPadding` (32).
    const EdgeInsets side = EdgeInsets.symmetric(horizontal: 32);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _InfoRow(track: track, player: player),
        const SizedBox(height: 12),
        PlayerSeekBar(player: player),
        const SizedBox(height: 12),
        Padding(
          padding: side,
          child: PlayerTransportBar(player: player),
        ),
        const Padding(
          padding: side,
          child: PlayerVolumeControl(),
        ),
        // Таймер сна — строкой под громкостью, а не пятой кнопкой в ряду
        // действий: на узком экране тот ряд уже упирается в край (на 412 px
        // лишняя кнопка давала переполнение), а строкой состояние видно
        // текстом, без наведения на подсказку.
        const SleepTimerButton(),
        const SizedBox(height: 30),
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
class _ArtworkStage extends StatelessWidget {
  const _ArtworkStage({required this.track});

  final Track track;

  /// Зазор под гало: и отступ кольца от обложки, и место, которое обложка
  /// уступает визуализатору.
  static const double _kHaloInset = 18;

  /// Радиус скругления обложки — как `Thumbnail` в ArchiveTune (16).
  static const double _kArtworkRadius = 16;

  /// Предел стороны обложки: на десктопе огромная обложка отбирала место у
  /// управления и очереди.
  static const double _kMaxSide = 420;

  @override
  Widget build(BuildContext context) {
    final List<String> variants = track.artworkFallbacks(kArtworkLarge);

    return Padding(
      // Отступы обложки — `PlayerHorizontalPadding` по бокам (32) и 16 сверху
      // и снизу, как `Thumbnail` в ArchiveTune.
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
      child: Consumer(
        builder: (BuildContext context, WidgetRef ref, Widget? child) {
          final bool withVisualizer = ref.watch(
            settingsControllerProvider.select(
              (AppSettings s) => s.visualizerEnabled,
            ),
          );
          // Монитор читается только при включённом визуализаторе: провайдер
          // ленивый, и пока он не нужен, libmpv для уровней не поднимается.
          final AudioLevelMonitor? monitor =
              withVisualizer ? ref.watch(audioLevelMonitorProvider) : null;

          return Center(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                // Обложка квадратная и вписывается в доступное место.
                final double available = constraints.biggest.shortestSide;
                if (monitor == null) {
                  return _artwork(context, variants, _side(available), null);
                }
                // Слушаем монитор: подпись «уровня нет» должна появиться сама,
                // без пересборки всего экрана.
                return AnimatedBuilder(
                  animation: monitor,
                  builder: (BuildContext context, Widget? child) {
                    final bool noData = monitor.availability ==
                        AudioLevelAvailability.unavailable;
                    // Подпись занимает место под обложкой: без вычета её высоты
                    // колонка переполнила бы отведённую высоту на низком окне.
                    final double limit = noData
                        ? available - SpectrumUnavailableNote.height
                        : available;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _artwork(context, variants, _side(limit), monitor),
                        if (noData) SpectrumUnavailableNote(monitor: monitor),
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
  Widget _artwork(
    BuildContext context,
    List<String> variants,
    double side,
    AudioLevelMonitor? monitor,
  ) {
    final Widget artwork = Artwork(
      url: variants.isEmpty ? null : variants.first,
      fallbacks:
          variants.length > 1 ? variants.sublist(1) : const <String>[],
      // Общий тег с миниатюрой островка: обложка перелетает и растёт
      // из мини-плеера в полный экран (и обратно).
      heroTag: kPlayerArtworkHeroTag,
      radius: BorderRadius.circular(_kArtworkRadius),
    );
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
    required this.track,
    required this.showLyrics,
    required this.onToggleLyrics,
  });

  final Track track;
  final bool showLyrics;
  final VoidCallback onToggleLyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Метаданные для внешней базы текста (LRCLIB) — из играющего трека.
    final LyricsRequest request = LyricsRequest.fromTrack(track);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: 'Свернуть',
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
            onPressed: () => Navigator.maybePop(context),
          ),
          const Spacer(),
          // Подпись «Сейчас играет» убрана: название трека и так видно ниже.
          // Показ текста — отдельной кнопкой, а выбор источника — в меню
          // (пункт «Показать/скрыть» оттуда убран, чтобы не дублировать).
          IconButton.filledTonal(
            tooltip: showLyrics ? 'Скрыть текст' : 'Показать текст',
            isSelected: showLyrics,
            icon: const Icon(Icons.lyrics_outlined, size: 20),
            selectedIcon: const Icon(Icons.lyrics, size: 20),
            onPressed: onToggleLyrics,
          ),
          const SizedBox(width: 4),
          LyricsMenuButton(request: request),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// Название, исполнитель и кнопка «нравится».
///
/// Состояние берём из общего [likedIdsProvider], а не из локального флага:
/// лайк, поставленный здесь, сразу виден в строках треков и островке плеера
/// (и наоборот).
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

    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);

    return Padding(
      // Название и действия — с боковым отступом 32, как
      // `PlayerHorizontalPadding` в `PlayerControlsContent`.
      padding: const EdgeInsets.fromLTRB(32, 6, 8, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // `PlayerTitleSection`: titleLarge, жирный.
                  style: text.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: <Widget>[
                    Flexible(
                      // Исполнитель — ссылка на его страницу. Ошибку плеера
                      // показываем текстом: она не ссылка. Две строки и
                      // подсказка при наведении — причина отказа бывает
                      // длинной, в одну строку её не прочитать.
                      child: player.error != null
                          ? Tooltip(
                              message: player.error!,
                              child: Text(
                                player.error!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: text.titleMedium
                                    ?.copyWith(color: scheme.error),
                              ),
                            )
                          : ArtistLine(
                              artists: track.artists,
                              // `PlayerTitleSection`: titleMedium (16 sp).
                              style: text.titleMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                              // Переход сам сворачивает плеер (см. [AppRoutes]):
                              // иначе страница оказалась бы под ним или легла
                              // бы поверх вторым слоем.
                              onArtistTap: (ArtistRef artist) =>
                                  AppRoutes.artistFromMenu(context, artist.id!),
                            ),
                    ),
                    const SizedBox(width: 8),
                    QualityBadge(player: player),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Действия — как в стиле V4: квадраты 44 с радиусом 14, фон с
          // альфой 0.12, иконка 22, зазор 10. Перемешивание и повтор
          // переехали сюда из транспорта; рядом — клип, меню и лайк.
          _PlayerActionButton(
            tooltip: player.shuffle ? 'Перемешивание включено' : 'Перемешать',
            icon: Icons.shuffle,
            selected: player.shuffle,
            onPressed: controller.toggleShuffle,
          ),
          const SizedBox(width: 10),
          _PlayerActionButton(
            tooltip: player.repeat.label,
            icon: player.repeat == PlayerRepeatMode.one
                ? Icons.repeat_one
                : Icons.repeat,
            selected: player.repeat != PlayerRepeatMode.off,
            onPressed: controller.cycleRepeat,
          ),
          const SizedBox(width: 10),
          // «…» открывает то же меню, что и из островка: исполнитель, альбом,
          // очередь и лайк. rootNavigator: плеер сам лежит в корневом
          // навигаторе — лист должен лежать там же, поверх плеера; переходы из
          // него при этом сначала сворачивают плеер (см. [AppRoutes]).
          _PlayerActionButton(
            tooltip: 'Действия',
            icon: Icons.more_vert,
            onPressed: () => showTrackMenu(
              context,
              track,
              rootNavigator: true,
              // Параметры играющего потока — в том же меню, что и действия
              // над треком: второй «⋮» на экране только путал бы.
              onMediaInfo: () => showMediaInfoDialog(context),
            ),
          ),
          const SizedBox(width: 10),
          _PlayerActionButton(
            tooltip: liked ? 'Убрать из «Мне нравится»' : 'Нравится',
            icon: liked ? Icons.favorite : Icons.favorite_border,
            selected: liked,
            accent: true,
            onPressed: signedIn ? () => _like(context, ref) : null,
          ),
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

/// Действие в строке с названием — квадрат 44 с радиусом 14, как `Surface`
/// в `PlayerTopActions` (ArchiveTune, стиль V4).
///
/// Фон: 0.12 в покое и 0.2 во включённом виде (для лайка — `error` с 0.25);
/// иконка 22, выбранная — цветом акцента.
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
    final BorderRadius shape = BorderRadius.circular(14);

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
            width: 44,
            height: 44,
            child: Center(child: Icon(icon, size: 22, color: foreground)),
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
