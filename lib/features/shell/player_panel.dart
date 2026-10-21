import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../core/theme/motion.dart';
import '../../data/local/app_settings.dart';
import '../../state/providers.dart';
import '../../core/utils/artwork_urls.dart';
import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/artist_line.dart';
import '../../widgets/artwork.dart';
import '../../widgets/marquee_text.dart';
import '../../widgets/track_menu.dart';
import '../../widgets/track_tile.dart';
import '../player/artwork_progress_ring.dart';
import '../player/lyrics_view.dart';
import '../player/player_controls.dart';
import '../player/queue_list.dart';

/// Открыта ли правая панель плеера.
///
/// Отдельный провайдер, а не общий с [RightPanelMode]: тот управляет
/// выезжающим вверх ящиком очереди/текста, а этот — полноценной панелью,
/// которая отнимает ширину у содержимого. Смешивать их нельзя: ящик
/// всплывает поверх, панель же ведёт себя как боковая.
class PlayerRightPanelController extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;

  void close() => state = false;
}

final NotifierProvider<PlayerRightPanelController, bool>
    playerRightPanelProvider =
    NotifierProvider<PlayerRightPanelController, bool>(
  PlayerRightPanelController.new,
);

/// Место правой панели в раскладке.
///
/// Ширину анимируем `AnimatedContainer` с той же кривой и длительностью, что
/// и у сворачиваемой библиотеки: содержимое слева сужается плавно, без рывка.
/// Панель при этом всегда построена и просто прячется под `ClipRect` — так
/// при повторном развороте не мигает и не пересоздаётся.
class PlayerRightPanelSlot extends ConsumerStatefulWidget {
  const PlayerRightPanelSlot({super.key, required this.open});

  final bool open;

  @override
  ConsumerState<PlayerRightPanelSlot> createState() =>
      _PlayerRightPanelSlotState();
}

class _PlayerRightPanelSlotState extends ConsumerState<PlayerRightPanelSlot> {
  /// Ширина во время перетаскивания: настройка сохраняется только в конце,
  /// иначе каждый пиксель писался бы в файл настроек.
  double? _dragging;

  /// Пределы, чтобы панель не превращалась ни в щель, ни в пол-экрана.
  static const double _minWidth = 260;
  static const double _maxWidth = 560;

  @override
  Widget build(BuildContext context) {
    final double saved = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.playerPanelWidth),
    );
    final double width = (_dragging ?? saved).clamp(_minWidth, _maxWidth);

    return AnimatedContainer(
      duration: _dragging == null
          ? AppMotion.panelResize.duration
          : Duration.zero,
      curve: AppMotion.panelResize.curve,
      width: widget.open ? width : 0,
      child: ClipRect(
        // Панель держим фиксированной ширины и «выезжаем» ею из-за края:
        // так при закрытии содержимое не сжимается, а уезжает за границу.
        child: OverflowBox(
          alignment: Alignment.centerLeft,
          minWidth: width,
          maxWidth: width,
          child: Stack(
            children: <Widget>[
              // Панель свёрнута — её тикеры выключены: бегущая строка не
              // должна крутиться за закрытой панелью (да и `pumpAndSettle`
              // в тестах тогда не зависал бы).
              TickerMode(
                enabled: widget.open,
                child: const PlayerRightPanel(),
              ),
              // Ручка ширины: тянем за левый край панели.
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragUpdate: (DragUpdateDetails details) {
                      // Панель справа: сдвиг влево её расширяет.
                      setState(() {
                        _dragging = ((_dragging ?? saved) - details.delta.dx)
                            .clamp(_minWidth, _maxWidth);
                      });
                    },
                    onHorizontalDragEnd: (DragEndDetails _) {
                      final double? value = _dragging;
                      if (value != null) {
                        ref
                            .read(settingsControllerProvider.notifier)
                            .setPlayerPanelWidth(value);
                      }
                      setState(() => _dragging = null);
                    },
                    child: const SizedBox(width: 8),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Правая панель плеера: то же, что в полноэкранном плеере, но узкой колонкой.
///
/// Наполнение не копируем: шкала, транспорт, очередь и текст — те же виджеты,
/// что и на полном экране ([PlayerSeekBar], [PlayerTransportBar],
/// [QueueList], [LyricsView]). Отличается только компоновка: вертикальная
/// колонка шириной с библиотеку.
class PlayerRightPanel extends ConsumerStatefulWidget {
  const PlayerRightPanel({super.key});

  @override
  ConsumerState<PlayerRightPanel> createState() => _PlayerRightPanelState();
}

class _PlayerRightPanelState extends ConsumerState<PlayerRightPanel> {
  @override
  Widget build(BuildContext context) {
    final PlayerUiState player = ref.watch(playerControllerProvider);
    final Track? track = player.current;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    // Трека нет — панель пустая; сюда не попадаем, но защищаемся от гонки,
    // когда трек доиграл ровно в момент отрисовки.
    if (track == null) {
      return Material(color: scheme.surfaceContainer);
    }

    // Режим панели — настройка, а не локальное состояние: он должен
    // сохраняться между запусками, иначе каждый раз приходится переключать.
    final RightPanelMode mode = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => s.playerPanelMode,
      ),
    );

    // Показ текста — общая настройка для всех экранов (панель, полный экран,
    // островок). Своего состояния у панели больше нет.
    final bool showLyrics = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => s.showLyricsInPlayer,
      ),
    );

    // В режиме плеера очередь не помещается целиком, но и один трек мало:
    // показываем все, что идут следом, списком с прокруткой.
    final List<Track> upcoming = player.index + 1 < player.queue.length
        ? player.queue.sublist(player.index + 1)
        : const <Track>[];

    return Material(
      color: scheme.surfaceContainer,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // Обложка — от доступной высоты, а не фиксированная: на низком окне
          // фиксированные 260 не влезали и панель переполнялась снизу. Ширину
          // тоже учитываем: кольцу нужно место снаружи обложки, и на узкой
          // панели обложка с кольцом иначе вылезала бы за край. Габарит кольца
          // растёт вместе с обложкой (`ArtworkProgressRing.outerRatio`),
          // поэтому ширину делим на этот множитель, а не вычитаем константу.
          final double availableWidth =
              constraints.maxWidth - _PanelArtwork.horizontalPadding * 2;
          final double artSide = math.min(
            (constraints.maxHeight * 0.30).clamp(96.0, 260.0),
            (availableWidth / ArtworkProgressRing.outerRatio)
                .clamp(72.0, 260.0),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _PanelTrackRow(
                track: track,
                player: player,
                mode: mode,
                // В режиме плеера крупная обложка стоит ниже, и маленькая
                // в строке дублировала бы её.
                showArtwork: mode != RightPanelMode.player,
                showLyrics: showLyrics,
                onToggleLyrics: () => ref
                    .read(settingsControllerProvider.notifier)
                    .setShowLyrics(!showLyrics),
                onToggleMode: () => ref
                    .read(settingsControllerProvider.notifier)
                    .setRightPanelMode(mode == RightPanelMode.player
                        ? RightPanelMode.queue
                        : RightPanelMode.player),
                onClose: () =>
                    ref.read(playerRightPanelProvider.notifier).close(),
              ),
              // В режиме плеера — крупная обложка; в режиме очереди её нет,
              // всё место отдано списку.
              if (mode == RightPanelMode.player)
                _PanelArtwork(track: track, side: artSide),
              PlayerSeekBar(player: player, compact: true),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: PlayerTransportBar(
                  player: player,
                  dense: true,
                  showModes: true,
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: PlayerVolumeControl(),
              ),
              const SizedBox(height: 2),
              Expanded(
                child: showLyrics
                    ? LyricsView(
                        key: ValueKey<String>('panel-lyrics-${track.id}'),
                        videoId: track.id,
                      )
                    : mode == RightPanelMode.player
                        ? _NextTracks(tracks: upcoming)
                        : const QueueList(
                            // Шапку очереди скрываем: она повторяет текущий
                            // трек (обложка, название, исполнитель, лайк) и
                            // панель действий, а всё это уже есть в строке
                            // трека сверху. Строка текущего трека и карусель
                            // скрыты по той же причине — в панели остаются
                            // только «Далее — N» и список. На полном экране и
                            // в островке флаги свои, там вид не меняется.
                            showHeader: false,
                            showCurrent: false,
                            showCarousel: false,
                          ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Крупная обложка играющего трека — для режима «Плеер».
///
/// Вокруг обложки идёт волнистое кольцо прогресса, как у мини-плеера
/// ArchiveTune. Обложка в панели — скруглённый квадрат (как и на полном
/// экране), поэтому кольцо повторяет её форму.
class _PanelArtwork extends StatelessWidget {
  const _PanelArtwork({required this.track, required this.side});

  final Track track;
  final double side;

  /// Боковой отступ обложки в панели — из раскладки выше.
  static const double horizontalPadding = 20;

  @override
  Widget build(BuildContext context) {
    final List<String> variants = track.artworkFallbacks(kArtworkLarge);
    final BorderRadius shape = BorderRadius.circular(AppLayout.radiusL);
    final double extent = ArtworkProgressRing.extent(side);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: 4,
      ),
      child: Center(
        child: SizedBox(
          width: extent,
          height: extent,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              // Кольцо под обложкой: позицию слушает само, нажатий не ловит.
              ArtworkProgressRing(
                side: side,
                shape: shape,
              ),
              SizedBox(
                width: side,
                height: side,
                // Правый клик по обложке — то же меню, что у «…» в строке:
                // на крупной обложке это самая очевидная цель.
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onSecondaryTap: () => showTrackMenu(context, track),
                  child: Artwork(
                    url: variants.isEmpty ? null : variants.first,
                    fallbacks: variants.length > 1
                        ? variants.sublist(1)
                        : const <String>[],
                    radius: shape,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Что играет дальше — в режиме «Плеер» очередь не помещается целиком, но
/// один трек показывать мало: нужен весь список с прокруткой.
class _NextTracks extends ConsumerWidget {
  const _NextTracks({required this.tracks});

  final List<Track> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (tracks.isEmpty) return const SizedBox.shrink();
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Text(
            'Далее — ${tracks.length}',
            style: text.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 8),
            itemCount: tracks.length,
            itemBuilder: (BuildContext context, int index) {
              final Track track = tracks[index];
              return TrackTile(
                track: track,
                onTap: () => ref
                    .read(playerControllerProvider.notifier)
                    .playTrack(track, context: tracks),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Строка играющего трека в правой панели.
///
/// Вариант «очередь главная»: вместо крупной обложки — одна строка высотой 72
/// с миниатюрой 56, как `CurrentSongHeader` в ArchiveTune
/// (`ui/player/QueueComponents.kt`): обложка 64 с радиусом 12, название
/// `titleLarge` жирным, исполнитель `bodyMedium` приглушённым, лайк и «…».
///
/// Освободившиеся ~300 px уходят очереди — раньше она обрезалась, потому что
/// делила колонку с обложкой и управлением.
class _PanelTrackRow extends ConsumerWidget {
  const _PanelTrackRow({
    required this.track,
    required this.player,
    required this.mode,
    required this.showArtwork,
    required this.showLyrics,
    required this.onToggleLyrics,
    required this.onToggleMode,
    required this.onClose,
  });

  final Track track;
  final PlayerUiState player;
  final RightPanelMode mode;

  /// Показывать миниатюру в строке. В режиме плеера она не нужна.
  final bool showArtwork;
  final bool showLyrics;
  final VoidCallback onToggleLyrics;
  final VoidCallback onToggleMode;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Лайк — из общего источника правды: кнопка здесь, в островке и на
    // полном экране всегда показывает одно состояние.
    final bool liked = ref.watch(
      likedIdsProvider.select((Set<String> ids) => ids.contains(track.id)),
    );
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );
    final List<String> variants = track.artworkFallbacks(kArtworkLarge);

    // Компактные кнопки: в строке их четыре, обычный размер не поместился бы
    // в узкую панель.
    Widget action({
      required String tooltip,
      required IconData icon,
      IconData? selectedIcon,
      bool selected = false,
      VoidCallback? onPressed,
    }) {
      return IconButton(
        tooltip: tooltip,
        isSelected: selected,
        iconSize: 20,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        // Без этого `IconButton` держит минимальную зону нажатия 40x40, и
        // пять кнопок в строке уже не помещались (переполнение на 10 px).
        // В панели на десктопе мышь, а не палец, поэтому 34 хватает.
        style: IconButton.styleFrom(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        constraints: const BoxConstraints.tightFor(width: 34, height: 34),
        icon: Icon(icon, color: selected ? scheme.primary : null),
        selectedIcon: selectedIcon == null
            ? null
            : Icon(selectedIcon, size: 20, color: scheme.primary),
        onPressed: onPressed,
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 6, 6),
      child: SizedBox(
        height: 72,
        child: Row(
          children: <Widget>[
            if (showArtwork) ...<Widget>[
              // Правый клик по миниатюре — то же меню трека, что у «…».
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onSecondaryTap: () => showTrackMenu(context, track),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: Artwork(
                      url: variants.isEmpty ? null : variants.first,
                      fallbacks: variants.length > 1
                          ? variants.sublist(1)
                          : const <String>[],
                      radius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // Название — тоже цель для правого клика: это подпись
                  // играющего трека, и меню здесь ждут в первую очередь.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onSecondaryTap: () => showTrackMenu(context, track),
                    child: MarqueeText(
                      track.title,
                      // Прокрутка стоит на паузе вместе с треком.
                      playing: player.isPlaying,
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  // Исполнитель — ссылка на его страницу, как и везде, где
                  // он написан. Ошибку плеера показываем текстом: она не
                  // ссылка. Две строки и подсказка при наведении: причина
                  // отказа бывает длинной («YouTube требует вход в аккаунт…»),
                  // и в одну строку её не прочитать.
                  if (player.error != null)
                    Tooltip(
                      message: player.error!,
                      child: Text(
                        player.error!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: scheme.error),
                      ),
                    )
                  else
                    ArtistLine(
                      artists: track.artists,
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            action(
              // Переключатель режима: обложка против списка.
              tooltip: mode == RightPanelMode.player
                  ? 'Показать очередь'
                  : 'Показать обложку',
              icon: mode == RightPanelMode.player
                  ? Icons.queue_music
                  : Icons.album_outlined,
              onPressed: onToggleMode,
            ),
            action(
              tooltip: showLyrics ? 'Скрыть текст' : 'Показать текст',
              icon: Icons.lyrics_outlined,
              selectedIcon: Icons.lyrics,
              selected: showLyrics,
              onPressed: onToggleLyrics,
            ),
            action(
              tooltip: 'Свернуть в островок',
              icon: Icons.keyboard_double_arrow_right_rounded,
              onPressed: onClose,
            ),
            action(
              tooltip: liked ? 'Убрать из «Мне нравится»' : 'Нравится',
              icon: liked ? Icons.favorite : Icons.favorite_border,
              selected: liked,
              onPressed: signedIn ? () => _like(context, ref) : null,
            ),
            action(
              tooltip: 'Действия',
              icon: Icons.more_vert,
              onPressed: () => showTrackMenu(context, track),
            ),
          ],
        ),
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
