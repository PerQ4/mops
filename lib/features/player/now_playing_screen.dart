import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../data/local/app_settings.dart';
import '../../data/models/models.dart';
import '../../state/player_controller.dart';
import '../../state/providers.dart';
import '../../widgets/artwork.dart';
import 'lyrics_view.dart';
import 'queue_sheet.dart';

/// Полноэкранный плеер.
///
/// Раскладка подстраивается под ширину окна: на телефоне — обложка сверху,
/// на широком экране — обложка слева, управление справа.
class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  /// Пока пользователь тянет ползунок, показываем его значение,
  /// а не «догоняющую» позицию из плеера.
  double? _dragValue;
  bool _showLyrics = false;

  @override
  Widget build(BuildContext context) {
    final PlayerUiState player = ref.watch(playerControllerProvider);
    final Track? track = player.current;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    final bool wide = MediaQuery.sizeOf(context).width >= 900;
    final PlayerLayout layout = ref.watch(
      settingsControllerProvider.select((s) => s.playerLayout),
    );
    final bool split = layout == PlayerLayout.split && wide;

    return Scaffold(
      body: Stack(
        children: <Widget>[
          // Мягкий градиент из ролей темы — «воздушный» фон в духе Expressive.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    scheme.primaryContainer.withValues(alpha: 0.55),
                    scheme.surface,
                    scheme.surface,
                  ],
                  stops: const <double>[0.0, 0.45, 1.0],
                ),
              ),
            ),
          ),
          SafeArea(
            child: track == null
                ? _NothingPlaying(onClose: () => Navigator.maybePop(context))
                : Column(
                    children: <Widget>[
                      _TopBar(
                        onClose: () => Navigator.maybePop(context),
                        showLyrics: _showLyrics,
                        onToggleLyrics: () =>
                            setState(() => _showLyrics = !_showLyrics),
                      ),
                      Expanded(
                        child: split
                            ? _SplitLayout(
                                track: track,
                                player: player,
                                showLyrics: _showLyrics,
                                dragValue: _dragValue,
                                onDragChanged: _onDragChanged,
                                onDragEnd: _onDragEnd,
                              )
                            : _StackedLayout(
                                track: track,
                                player: player,
                                showLyrics: _showLyrics,
                                dragValue: _dragValue,
                                onDragChanged: _onDragChanged,
                                onDragEnd: _onDragEnd,
                              ),
                      ),
                      const _BottomActions(),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  void _onDragChanged(double value) => setState(() => _dragValue = value);

  void _onDragEnd(double value) {
    ref.read(playerControllerProvider.notifier).seekFraction(value);
    setState(() => _dragValue = null);
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.onClose,
    required this.showLyrics,
    required this.onToggleLyrics,
  });

  final VoidCallback onClose;
  final bool showLyrics;
  final VoidCallback onToggleLyrics;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: 'Свернуть',
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: onClose,
          ),
          const Spacer(),
          Text(
            'Сейчас играет',
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          IconButton(
            tooltip: showLyrics ? 'Скрыть текст' : 'Показать текст',
            isSelected: showLyrics,
            icon: const Icon(Icons.lyrics_outlined),
            selectedIcon: const Icon(Icons.lyrics),
            onPressed: onToggleLyrics,
          ),
          IconButton(
            tooltip: 'Очередь',
            icon: const Icon(Icons.queue_music),
            onPressed: () => QueueSheet.show(context),
          ),
        ],
      ),
    );
  }
}

/// Классическая раскладка: обложка, подписи, ползунок, управление.
class _StackedLayout extends StatelessWidget {
  const _StackedLayout({
    required this.track,
    required this.player,
    required this.showLyrics,
    required this.dragValue,
    required this.onDragChanged,
    required this.onDragEnd,
  });

  final Track track;
  final PlayerUiState player;
  final bool showLyrics;
  final double? dragValue;
  final ValueChanged<double> onDragChanged;
  final ValueChanged<double> onDragEnd;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: AnimatedSwitcher(
              duration: AppMotion.medium,
              switchInCurve: AppMotion.gentle,
              child: showLyrics
                  ? LyricsView(
                      key: ValueKey<String>('lyrics-${track.id}'),
                      videoId: track.id,
                      compact: true,
                    )
                  : _ArtworkHero(key: ValueKey<String>(track.id), track: track),
            ),
          ),
        ),
        _Titles(track: track),
        _SeekBar(
          player: player,
          dragValue: dragValue,
          onChanged: onDragChanged,
          onChangeEnd: onDragEnd,
        ),
        _Controls(player: player),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// Широкая раскладка: обложка слева, всё остальное справа.
class _SplitLayout extends StatelessWidget {
  const _SplitLayout({
    required this.track,
    required this.player,
    required this.showLyrics,
    required this.dragValue,
    required this.onDragChanged,
    required this.onDragEnd,
  });

  final Track track;
  final PlayerUiState player;
  final bool showLyrics;
  final double? dragValue;
  final ValueChanged<double> onDragChanged;
  final ValueChanged<double> onDragEnd;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: _ArtworkHero(track: track),
          ),
        ),
        Expanded(
          flex: 6,
          child: showLyrics
              ? LyricsView(videoId: track.id)
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    _Titles(track: track, centered: false, padded: true),
                    const SizedBox(height: 8),
                    _SeekBar(
                      player: player,
                      dragValue: dragValue,
                      onChanged: onDragChanged,
                      onChangeEnd: onDragEnd,
                    ),
                    _Controls(player: player),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Обложка с тенью и скруглением Expressive.
class _ArtworkHero extends StatelessWidget {
  const _ArtworkHero({super.key, required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final PlayerTheme? playerTheme =
        Theme.of(context).extension<PlayerTheme>();

    return Center(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // Обложка всегда квадратная и вписывается в доступное место.
          final double side = constraints.biggest.shortestSide.clamp(0.0, 460.0);
          return Container(
            width: side,
            height: side,
            decoration: BoxDecoration(
              borderRadius: playerTheme?.heroRadius ?? BorderRadius.circular(32),
              boxShadow: <BoxShadow>[
                playerTheme?.artworkShadow ??
                    const BoxShadow(blurRadius: 32, offset: Offset(0, 12)),
              ],
            ),
            child: Artwork(
              url: track.thumbnails.sized(1024) ?? track.artwork,
              size: side,
              radius: playerTheme?.heroRadius ?? BorderRadius.circular(32),
            ),
          );
        },
      ),
    );
  }
}

class _Titles extends StatelessWidget {
  const _Titles({
    required this.track,
    this.centered = true,
    this.padded = false,
  });

  final Track track;
  final bool centered;
  final bool padded;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: padded ? 32 : 24),
      child: Column(
        crossAxisAlignment:
            centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            track.title,
            textAlign: centered ? TextAlign.center : TextAlign.start,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            track.artistLine,
            textAlign: centered ? TextAlign.center : TextAlign.start,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Ползунок перемотки с временем слева и справа.
class _SeekBar extends StatelessWidget {
  const _SeekBar({
    required this.player,
    required this.dragValue,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final PlayerUiState player;
  final double? dragValue;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final Duration duration = player.playback.duration;
    final double value = dragValue ?? player.playback.progress;
    final Duration shownPosition = dragValue == null
        ? player.playback.position
        : duration * dragValue!;

    final TextStyle? labelStyle = Theme.of(context)
        .textTheme
        .labelMedium
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: <Widget>[
          Slider(
            value: value.clamp(0.0, 1.0),
            onChanged: duration > Duration.zero ? onChanged : null,
            onChangeEnd: duration > Duration.zero ? onChangeEnd : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(formatDurationClock(shownPosition), style: labelStyle),
                Text(formatDurationClock(duration), style: labelStyle),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Кнопки управления: перемешать, назад, играть/пауза, вперёд, повтор.
class _Controls extends ConsumerWidget {
  const _Controls({required this.player});

  final PlayerUiState player;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerController controller = ref.read(playerControllerProvider.notifier);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool isLoading = player.isLoading;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          IconButton(
            tooltip: player.shuffle ? 'Перемешивание включено' : 'Перемешать',
            isSelected: player.shuffle,
            icon: const Icon(Icons.shuffle),
            selectedIcon: Icon(Icons.shuffle, color: scheme.primary),
            onPressed: controller.toggleShuffle,
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Предыдущий',
            iconSize: 40,
            icon: const Icon(Icons.skip_previous),
            onPressed: controller.previous,
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 72,
            height: 72,
            child: isLoading
                ? const Padding(
                    padding: EdgeInsets.all(18),
                    child: CircularProgressIndicator(strokeWidth: 3),
                  )
                : IconButton.filled(
                    tooltip: player.isPlaying ? 'Пауза' : 'Играть',
                    iconSize: 40,
                    icon: Icon(player.isPlaying ? Icons.pause : Icons.play_arrow),
                    onPressed: controller.togglePlayPause,
                  ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Следующий',
            iconSize: 40,
            icon: const Icon(Icons.skip_next),
            onPressed: controller.next,
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: player.repeat.label,
            isSelected: player.repeat != PlayerRepeatMode.off,
            icon: Icon(
              player.repeat == PlayerRepeatMode.one ? Icons.repeat_one : Icons.repeat,
            ),
            selectedIcon: Icon(
              player.repeat == PlayerRepeatMode.one ? Icons.repeat_one : Icons.repeat,
              color: scheme.primary,
            ),
            onPressed: controller.cycleRepeat,
          ),
        ],
      ),
    );
  }
}

/// Нижняя строка: скорость воспроизведения и добавление в очередь.
class _BottomActions extends ConsumerWidget {
  const _BottomActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerUiState player = ref.watch(playerControllerProvider);
    final PlayerController controller = ref.read(playerControllerProvider.notifier);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    const List<double> speeds = <double>[0.75, 1.0, 1.25, 1.5, 2.0];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: <Widget>[
          PopupMenuButton<double>(
            tooltip: 'Скорость',
            initialValue: player.playback.speed,
            onSelected: controller.setSpeed,
            itemBuilder: (BuildContext context) => <PopupMenuEntry<double>>[
              for (final double speed in speeds)
                PopupMenuItem<double>(
                  value: speed,
                  child: Text('${speed}x'),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.speed, size: 20),
                  const SizedBox(width: 6),
                  Text('${player.playback.speed}x'),
                ],
              ),
            ),
          ),
          const Spacer(),
          if (player.error != null)
            Expanded(
              child: Text(
                player.error!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.error),
              ),
            ),
          const Spacer(),
          IconButton(
            tooltip: 'Очередь',
            icon: const Icon(Icons.queue_music),
            onPressed: () => QueueSheet.show(context),
          ),
        ],
      ),
    );
  }
}

class _NothingPlaying extends StatelessWidget {
  const _NothingPlaying({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: onClose,
          ),
        ),
        const Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.music_note_outlined, size: 64),
                SizedBox(height: 16),
                Text('Ничего не играет'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
