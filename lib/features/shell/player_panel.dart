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
import '../player/sleep_timer.dart';

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
          // считает сам виджет (`sideForWidth` — обратная к его `extent`), а не
          // постоянный множитель: штрих кольца ограничен сверху.
          final double availableWidth =
              constraints.maxWidth - AppLayout.playerInset * 2;
          final double artSide = math.min(
            (constraints.maxHeight * 0.30).clamp(96.0, 260.0),
            ArtworkProgressRing.sideForWidth(availableWidth).clamp(72.0, 260.0),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _PanelTrackRow(
                track: track,
                player: player,
                mode: mode,
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
              if (mode == RightPanelMode.player) ...<Widget>[
                _PanelArtwork(
                  track: track,
                  side: artSide,
                  onTap: () => ref
                      .read(settingsControllerProvider.notifier)
                      .setRightPanelMode(RightPanelMode.queue),
                ),
                const SizedBox(height: AppLayout.playerItemGap),
              ],
              PlayerSeekBar(player: player),
              // Транспорт и действия — одной колонкой по центру: отступы
              // равны `playerInset`, поэтому края совпадают с обложкой,
              // подписями и полосой перемотки. Перемешивание и повтор стоят
              // по краям того же ряда: отдельной строки режимов больше нет.
              const SizedBox(height: AppLayout.playerItemGap),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppLayout.playerInset,
                ),
                child: PlayerTransportBar(
                  player: player,
                  leading: const ShuffleButton(),
                  trailing: const RepeatButton(),
                ),
              ),
              const SizedBox(height: AppLayout.playerGroupGap),
              const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: AppLayout.playerInset,
                ),
                child: PlayerVolumeControl(),
              ),
              const SizedBox(height: AppLayout.playerItemGap),
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
  const _PanelArtwork({
    required this.track,
    required this.side,
    required this.onTap,
  });

  final Track track;
  final double side;

  /// Клик по обложке. Крупная обложка сама переключает панель в очередь:
  /// отдельная кнопка режима в шапке больше не нужна.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final List<String> variants = track.artworkFallbacks(kArtworkLarge);
    final BorderRadius shape = BorderRadius.circular(AppLayout.radiusL);
    final double extent = ArtworkProgressRing.extent(side);

    return Padding(
      // Обложка — по центру колонки, с тем же боковым отступом, что и всё
      // остальное в панели.
      padding: const EdgeInsets.symmetric(
        horizontal: AppLayout.playerInset,
        vertical: AppLayout.playerVerticalInset,
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
                // Клик по обложке — переключение в очередь (та же функция,
                // что раньше была у кнопки в шапке); правый — меню трека.
                child: Tooltip(
                  message: 'Показать очередь',
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onTap,
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
          padding: const EdgeInsets.fromLTRB(
            AppLayout.playerInset,
            AppLayout.playerVerticalInset,
            AppLayout.playerInset,
            2,
          ),
          child: Text(
            'Далее — ${tracks.length}',
            style: text.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: ListView.builder(
            // Нижний отступ — как верхний у шапки панели: список не должен
            // упираться в кромку панели.
            padding: const EdgeInsets.only(
              bottom: AppLayout.playerVerticalInset,
            ),
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
/// Одно правило для обоих режимов: миниатюра 56 (только в очереди),
/// название с исполнителем и сетка действий 3×2 справа. В режиме плеера
/// миниатюры нет — там крупная обложка стоит ниже, — но сетка занимает то же
/// место. Переключение режима живёт на обложке, а не отдельной кнопкой в
/// шапке: в строке остаются только действия над треком.
class _PanelTrackRow extends ConsumerWidget {
  const _PanelTrackRow({
    required this.track,
    required this.player,
    required this.mode,
    required this.showLyrics,
    required this.onToggleLyrics,
    required this.onToggleMode,
    required this.onClose,
  });

  final Track track;
  final PlayerUiState player;
  final RightPanelMode mode;
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

    // Кнопки одного размера: сетка 3×2 занимает 104 px вместе с зазорами и
    // оставляет место подписи даже на минимальной ширине панели (260).
    const double actionGap = 4;

    // Сетка 3×2 справа от подписи. Порядок — по парам «действие и его
    // настройка»: в первой строке лайк, темп и «…», во второй — текст,
    // эквалайзер и свёртывание. Визуализатора здесь нет: он живёт только на
    // полном экране, где для него есть место.
    final Widget actionsGrid = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            PlayerSquareAction(
              tooltip: liked ? 'Убрать из «Мне нравится»' : 'Нравится',
              icon: liked ? Icons.favorite : Icons.favorite_border,
              selected: liked,
              onPressed: signedIn ? () => _like(context, ref) : null,
            ),
            const SizedBox(width: actionGap),
            const TempoPitchButton(),
            const SizedBox(width: actionGap),
            PlayerSquareAction(
              tooltip: 'Действия',
              icon: Icons.more_vert,
              onPressed: () => showTrackMenu(
                context,
                track,
                onSleepTimer: () => showSleepTimerMenu(context, ref),
              ),
            ),
          ],
        ),
        const SizedBox(height: actionGap),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            PlayerSquareAction(
              tooltip: showLyrics ? 'Скрыть текст' : 'Показать текст',
              icon: Icons.lyrics_outlined,
              selectedIcon: Icons.lyrics,
              selected: showLyrics,
              onPressed: onToggleLyrics,
            ),
            const SizedBox(width: actionGap),
            const EqualizerButton(),
            const SizedBox(width: actionGap),
            PlayerSquareAction(
              tooltip: 'Свернуть в островок',
              icon: Icons.keyboard_double_arrow_right_rounded,
              onPressed: onClose,
            ),
          ],
        ),
      ],
    );

    /// Исполнитель или ошибка плеера. Ошибка — не ссылка, поэтому это
    /// обычный текст. В обоих режимах подпись идёт от левого края: справа от
    /// неё стоит сетка кнопок, и центрирование съезжало бы влево от центра.
    Widget subtitle() {
      if (player.error != null) {
        return Tooltip(
          message: player.error!,
          child: Text(
            player.error!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: text.bodySmall?.copyWith(color: scheme.error),
          ),
        );
      }
      // Исполнитель — ссылка на его страницу, как и везде, где он написан.
      // Две строки и подсказка при наведении: причина отказа бывает длинной,
      // и в одну строку её не прочитать.
      return ArtistLine(
        artists: track.artists,
        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      );
    }

    // Название и исполнитель. Название — тоже цель для правого клика: это
    // подпись играющего трека, и меню здесь ждут в первую очередь.
    final Widget caption = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onSecondaryTap: () => showTrackMenu(context, track),
          child: MarqueeText(
            track.title,
            // Прокрутка стоит на паузе вместе с треком.
            playing: player.isPlaying,
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 2),
        subtitle(),
      ],
    );

    // Миниатюра в режиме очереди — вторая цель переключения: клик по ней
    // возвращает крупную обложку. Правый клик по-прежнему открывает меню.
    final Widget thumbnail = Tooltip(
      message: 'Показать обложку',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onToggleMode,
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
      ),
    );

    // Одно правило для обоих режимов: [миниатюра], подпись, сетка. Миниатюры
    // нет только в режиме плеера — там ниже стоит крупная обложка.
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppLayout.playerInset,
        AppLayout.playerVerticalInset,
        AppLayout.playerInset,
        // В очереди под строкой сразу полоса перемотки — без зазора она
        // прилипала к сетке. В режиме плеера ниже обложка со своим отступом.
        mode != RightPanelMode.player ? AppLayout.playerItemGap : 0,
      ),
      child: Row(
        children: <Widget>[
          if (mode != RightPanelMode.player) ...<Widget>[
            thumbnail,
            const SizedBox(width: AppLayout.playerItemGap),
          ],
          // Подпись занимает остаток и обрезается, а не выдавливает сетку.
          Expanded(child: caption),
          const SizedBox(width: AppLayout.playerItemGap),
          actionsGrid,
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
