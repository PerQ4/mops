import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/app_settings.dart';
import '../../state/providers.dart';
import '../../core/utils/artwork_urls.dart';
import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/artist_line.dart';
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
      child: Builder(
        builder: (BuildContext context) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _PanelTrackRow(
                track: track,
                player: player,
                showLyrics: _showLyrics,
                onToggleLyrics: () =>
                    setState(() => _showLyrics = !_showLyrics),
                onClose: () =>
                    ref.read(playerRightPanelProvider.notifier).close(),
              ),
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
    required this.showLyrics,
    required this.onToggleLyrics,
    required this.onClose,
  });

  final Track track;
  final PlayerUiState player;
  final bool showLyrics;
  final VoidCallback onToggleLyrics;
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
            ClipRRect(
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
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  // Исполнитель — ссылка на его страницу, как и везде, где
                  // он написан. Ошибку плеера показываем текстом: она не
                  // ссылка.
                  if (player.error != null)
                    Text(
                      player.error!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: scheme.error),
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
