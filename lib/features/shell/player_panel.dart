import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/local/app_settings.dart';
import '../../state/providers.dart';
import '../../core/utils/artwork_urls.dart';
import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/artwork.dart';
import '../../widgets/track_menu.dart';
import '../player/lyrics_view.dart';
import '../player/player_controls.dart';
import '../player/queue_list.dart';

/// Открыта ли правая панель плеера.
///
/// Отдельный провайдер, а не общий с [PlayerPanelMode]: тот управляет
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
          ? const Duration(milliseconds: 260)
          : Duration.zero,
      curve: Curves.easeOutCubic,
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
              const PlayerRightPanel(),
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
  /// Показывать текст вместо очереди — как кнопка «текст» на полном экране.
  bool _showLyrics = false;

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

    return Material(
      color: scheme.surfaceContainer,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // Обложка занимает около трети высоты, но не больше «шапки» и не
          // меньше читаемого размера: на низком окне панель не переполняется.
          final double artSide = (constraints.maxHeight * 0.28)
              .clamp(88.0, AppLayout.headerArtwork);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _PanelHeader(
                showLyrics: _showLyrics,
                onToggleLyrics: () =>
                    setState(() => _showLyrics = !_showLyrics),
                onClose: () =>
                    ref.read(playerRightPanelProvider.notifier).close(),
              ),
              _PanelArtwork(track: track, side: artSide),
              _PanelInfo(track: track, player: player),
              const SizedBox(height: 4),
              PlayerSeekBar(player: player, compact: true),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: PlayerTransportBar(player: player, dense: true),
              ),
              PlayerVolumeBarSliderOnly(),
              const SizedBox(height: 4),
              Expanded(
                child: _showLyrics
                    ? LyricsView(
                        key: ValueKey<String>('panel-lyrics-${track.id}'),
                        videoId: track.id,
                      )
                    : const QueueList(),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Шапка панели: подпись, переключатель текста и сворачивание в островок.
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.showLyrics,
    required this.onToggleLyrics,
    required this.onClose,
  });

  final bool showLyrics;
  final VoidCallback onToggleLyrics;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 4, 0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              'Сейчас играет',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
            ),
          ),
          IconButton(
            tooltip: showLyrics ? 'Скрыть текст' : 'Показать текст',
            isSelected: showLyrics,
            iconSize: 20,
            icon: const Icon(Icons.lyrics_outlined),
            selectedIcon: Icon(Icons.lyrics, size: 20, color: scheme.primary),
            onPressed: onToggleLyrics,
          ),
          // Стрелка вправо — потому что панель справа; она же намекает, что
          // плеер «уезжает» обратно в островок.
          IconButton(
            tooltip: 'Свернуть в островок',
            iconSize: 20,
            icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// Обложка играющего трека — крупная, но по ширине панели.
class _PanelArtwork extends StatelessWidget {
  const _PanelArtwork({required this.track, required this.side});

  final Track track;

  /// Сторона квадрата; уменьшается на низком окне (см. `LayoutBuilder`).
  final double side;

  @override
  Widget build(BuildContext context) {
    final List<String> variants = track.artworkFallbacks(kArtworkLarge);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Center(
        child: SizedBox(
          width: side,
          height: side,
          child: Artwork(
            url: variants.isEmpty ? null : variants.first,
            fallbacks:
                variants.length > 1 ? variants.sublist(1) : const <String>[],
            radius: BorderRadius.circular(AppLayout.radiusL),
          ),
        ),
      ),
    );
  }
}

/// Название, исполнитель и действия — лайк и «…».
class _PanelInfo extends ConsumerWidget {
  const _PanelInfo({required this.track, required this.player});

  final Track track;
  final PlayerUiState player;

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

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 4, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  track.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  player.error ?? track.artistLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(
                    color: player.error != null
                        ? scheme.error
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: liked ? 'Убрать из «Мне нравится»' : 'Нравится',
            iconSize: 20,
            icon: Icon(
              liked ? Icons.favorite : Icons.favorite_border,
              color: liked ? scheme.primary : null,
            ),
            onPressed: signedIn ? () => _like(context, ref) : null,
          ),
          IconButton(
            tooltip: 'Действия',
            iconSize: 20,
            icon: const Icon(Icons.more_vert),
            onPressed: () => showTrackMenu(context, track),
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
