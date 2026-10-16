import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../common/navigation.dart';
import '../shell/content_navigator.dart';
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
import '../../widgets/track_menu.dart';
import 'lyrics_actions.dart';
import 'lyrics_view.dart';
import 'queue_list.dart';
import 'player_controls.dart';

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

    return Scaffold(
      backgroundColor: scheme.surface,
      body: track == null
          ? _Empty(onClose: () => Navigator.maybePop(context))
          : Stack(
              children: <Widget>[
                // Фон: размытая обложка, плавно переходящая в тёмную панель.
                Positioned.fill(child: _ArtworkBackdrop(track: track)),
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
                                    // Очередь сверху — своя прокручиваемая
                                    // область; шапку скрываем, название и
                                    // действия уже есть в блоке управления.
                                    child: _StackedControls(
                                      reserve: _kQueueMinHeight,
                                      track: track,
                                      player: player,
                                      flexible: const QueueList(
                                        showHeader: false,
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
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
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
        const SizedBox(height: 30),
      ],
    );
  }
}

/// Фон: сама обложка во всю площадь, притемнённая к низу.
///
/// Без размытия — так дешевле для отрисовки и ближе к ArchiveTune, где
/// виден настоящий рисунок, а не «стекло».
class _ArtworkBackdrop extends StatelessWidget {
  const _ArtworkBackdrop({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<String> variants = track.artworkFallbacks(kArtworkLarge);

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (variants.isNotEmpty)
          // Размытие: резкая обложка на всю площадь отвлекала от управления,
          // а размытая читается как фон.
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
            child: Artwork(
              url: variants.first,
              fallbacks:
                  variants.length > 1 ? variants.sublist(1) : const <String>[],
              fit: BoxFit.cover,
              radius: BorderRadius.zero,
            ),
          ),
        // Градиент поверх размытой обложки — как `PlayerBackground` в
        // ArchiveTune (стиль GRADIENT): три точки на 0.0 / 0.5 / 1.0 с
        // альфами 0.92 / 0.75 / 0.65, плюс мягкая чёрная подложка 0.18.
        // Цвета берём ролями схемы: извлечения палитры обложки у нас нет.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                scheme.surface.withValues(alpha: 0.92),
                scheme.surface.withValues(alpha: 0.75),
                scheme.surface.withValues(alpha: 0.65),
              ],
              stops: const <double>[0.0, 0.5, 1.0],
            ),
          ),
        ),
        ColoredBox(color: Colors.black.withValues(alpha: 0.18)),
      ],
    );
  }
}

/// Обложка в открытом виде — крупная и резкая.
class _ArtworkStage extends StatelessWidget {
  const _ArtworkStage({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final List<String> variants = track.artworkFallbacks(kArtworkLarge);

    return Padding(
      // Отступы обложки — `PlayerHorizontalPadding` по бокам (32) и 16 сверху
      // и снизу, как `Thumbnail` в ArchiveTune.
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
      child: Center(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // Обложка квадратная и вписывается в доступное место, но не
            // растягивается на пол-экрана: на десктопе огромная обложка
            // отбирала место у управления и очереди.
            final double available = constraints.biggest.shortestSide;
            final double side = available > 420 ? 420 : available;
            return SizedBox(
              width: side,
              height: side,
              child: Artwork(
                url: variants.isEmpty ? null : variants.first,
                fallbacks: variants.length > 1
                    ? variants.sublist(1)
                    : const <String>[],
                // Радиус обложки плеера в ArchiveTune — 16.
                radius: BorderRadius.circular(16),
              ),
            );
          },
        ),
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
                      // показываем текстом: она не ссылка.
                      child: player.error != null
                          ? Text(
                              player.error!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.titleMedium
                                  ?.copyWith(color: scheme.error),
                            )
                          : ArtistLine(
                              artists: track.artists,
                              // `PlayerTitleSection`: titleMedium (16 sp).
                              style: text.titleMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                              // Сначала сворачиваем плеер, потом открываем
                              // исполнителя: иначе страница уходит под плеер,
                              // и он остаётся на экране.
                              onArtistTap: (ArtistRef artist) {
                                rootNavigatorKey.currentState?.maybePop();
                                AppRoutes.artist(context, artist.id!);
                              },
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
          // переехали сюда из транспорта, поэтому здесь их четыре.
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
          // навигаторе — иначе переход остался бы под его экраном.
          _PlayerActionButton(
            tooltip: 'Действия',
            icon: Icons.more_vert,
            onPressed: () =>
                showTrackMenu(context, track, rootNavigator: true),
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
