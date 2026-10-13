import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/catalog_providers.dart';
import '../../state/player_controller.dart';
import '../../state/player_panel.dart';
import '../../widgets/artwork.dart';
import '../common/navigation.dart';
import 'lyrics_view.dart';
import 'queue_list.dart';

/// Плавающий «островок» плеера внизу экрана.
///
/// Отдельная сущность, а не полоса во всю ширину: он парит над содержимым,
/// не участвует в раскладке и поэтому ничего не сдвигает при появлении,
/// открытии панели или смене трека. Оформлен как стеклянная капсула с тенью.
///
/// Над островком раскрывается панель с очередью или текстом — как выдвижной
/// ящик самого островка, без отдельной боковой колонки.
class FloatingDock extends ConsumerWidget {
  const FloatingDock({super.key});

  /// Высота капсулы.
  static const double height = 64;

  /// Максимальная ширина: на широком мониторе островок остаётся островком,
  /// а не растягивается во всю ширину.
  static const double maxWidth = 780;

  /// Отступ от краёв — за счёт него он и «парит».
  static const double margin = 14;

  /// Ширина панели-ящика над островком (чуть шире самого островка).
  static const double panelWidth = 420;
  static const double panelMaxHeight = 420;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.current),
    );
    if (track == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(margin, 0, margin, margin),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const _DockPanel(),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: maxWidth),
            child: const _Island(),
          ),
        ],
      ),
    );
  }
}

/// --------------------------------------------------------------- панель-ящик

/// Раскрывающаяся часть островка: очередь или текст.
///
/// Свёрнута в ноль высоты, поэтому при открытии содержимое под ней не
/// перестраивается — панель растёт вверх поверх страницы.
class _DockPanel extends ConsumerWidget {
  const _DockPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerPanelMode mode = ref.watch(playerPanelProvider);
    final Track? track = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.current),
    );
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return AnimatedSize(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      alignment: Alignment.bottomCenter,
      child: mode == PlayerPanelMode.none || track == null
          ? const SizedBox(width: FloatingDock.panelWidth)
          : Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SizedBox(
                width: FloatingDock.panelWidth,
                child: _DockSurface(
                  radius: AppLayout.radiusXL,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxHeight: FloatingDock.panelMaxHeight,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _PanelHeader(mode: mode),
                        Divider(height: 1, color: scheme.outlineVariant),
                        Flexible(
                          child: mode == PlayerPanelMode.lyrics
                              ? LyricsView(
                                  key: ValueKey<String>(
                                    'dock-lyrics-${track.id}',
                                  ),
                                  videoId: track.id,
                                )
                              : const QueueList(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

class _PanelHeader extends ConsumerWidget {
  const _PanelHeader({required this.mode});

  final PlayerPanelMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final PlayerPanelController controller =
        ref.read(playerPanelProvider.notifier);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: 'Очередь',
            isSelected: mode == PlayerPanelMode.queue,
            icon: const Icon(Icons.queue_music, size: 20),
            selectedIcon: Icon(Icons.queue_music, size: 20, color: scheme.primary),
            onPressed: () => controller.toggle(PlayerPanelMode.queue),
          ),
          IconButton(
            tooltip: 'Текст песни',
            isSelected: mode == PlayerPanelMode.lyrics,
            icon: const Icon(Icons.lyrics_outlined, size: 20),
            selectedIcon: Icon(Icons.lyrics, size: 20, color: scheme.primary),
            onPressed: () => controller.toggle(PlayerPanelMode.lyrics),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Закрыть',
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
            onPressed: controller.close,
          ),
        ],
      ),
    );
  }
}

/// -------------------------------------------------------------- сам островок

class _Island extends ConsumerStatefulWidget {
  const _Island();

  @override
  ConsumerState<_Island> createState() => _IslandState();
}

class _IslandState extends ConsumerState<_Island> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final PlayerUiState player = ref.watch(playerControllerProvider);
    final Track track = player.current!;
    final bool wide = context.isExpandedLayout;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(0, _hovered ? -3 : 0, 0),
        child: _DockSurface(
          radius: FloatingDock.height / 2,
          // Сильную тень даём только под курсором: так островок заметно
          // «поднимается», но в покое не отвлекает.
          elevation: _hovered ? 18 : 10,
          child: SizedBox(
            height: FloatingDock.height,
            child: Row(
              children: <Widget>[
                const SizedBox(width: 10),
                _ArtworkWithProgress(track: track, player: player),
                const SizedBox(width: 12),
                Expanded(
                  child: _IslandTitles(track: track, player: player),
                ),
                _IslandControls(player: player, wide: wide),
                const SizedBox(width: 6),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Обложка с кольцом прогресса вокруг — вместо отдельной полосы перемотки.
class _ArtworkWithProgress extends StatelessWidget {
  const _ArtworkWithProgress({required this.track, required this.player});

  final Track track;
  final PlayerUiState player;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    const double side = 44;
    const double ring = 3;

    return SizedBox(
      width: side + ring * 2,
      height: side + ring * 2,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // Кольцо: серый круг и дуга прогресса.
          SizedBox(
            width: side + ring * 2,
            height: side + ring * 2,
            child: CircularProgressIndicator(
              value: player.playback.duration > Duration.zero
                  ? player.playback.progress
                  : null,
              strokeWidth: ring,
              color: scheme.primary,
              backgroundColor: scheme.onSurface.withValues(alpha: 0.12),
            ),
          ),
          Artwork(
            url: track.thumbnails.sized(128) ?? track.artwork,
            size: side,
            radius: BorderRadius.circular(side / 2),
          ),
          if (player.isLoading)
            SizedBox(
              width: side - 8,
              height: side - 8,
              child: const CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }
}

class _IslandTitles extends StatelessWidget {
  const _IslandTitles({required this.track, required this.player});

  final Track track;
  final PlayerUiState player;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String subtitle = player.downloading
        ? 'Загрузка ${(player.downloadProgress * 100).round()}%'
        : player.error ?? track.artistLine;

    return InkWell(
      // Клик по подписи открывает полноэкранный плеер.
      onTap: () => AppRoutes.nowPlaying(context),
      borderRadius: BorderRadius.circular(AppLayout.radiusS),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 1),
            Text(
              subtitle,
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
    );
  }
}

/// Управление внутри островка.
class _IslandControls extends ConsumerWidget {
  const _IslandControls({required this.player, required this.wide});

  final PlayerUiState player;
  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);
    final PlayerPanelController panel = ref.read(playerPanelProvider.notifier);
    final PlayerPanelMode mode = ref.watch(playerPanelProvider);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (wide)
          IconButton(
            tooltip: player.shuffle ? 'Перемешивание включено' : 'Перемешать',
            isSelected: player.shuffle,
            iconSize: 20,
            icon: const Icon(Icons.shuffle),
            selectedIcon: Icon(Icons.shuffle, size: 20, color: scheme.primary),
            onPressed: controller.toggleShuffle,
          ),
        IconButton(
          tooltip: 'Предыдущий',
          iconSize: wide ? 26 : 24,
          icon: const Icon(Icons.skip_previous_rounded),
          onPressed: player.queue.isEmpty ? null : controller.previous,
        ),
        IconButton.filled(
          tooltip: player.isPlaying ? 'Пауза' : 'Играть',
          iconSize: wide ? 26 : 24,
          icon: Icon(
            player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          ),
          onPressed: controller.togglePlayPause,
        ),
        IconButton(
          tooltip: 'Следующий',
          iconSize: wide ? 26 : 24,
          icon: const Icon(Icons.skip_next_rounded),
          onPressed: player.queue.isEmpty ? null : controller.next,
        ),
        if (wide)
          IconButton(
            tooltip: player.repeat.label,
            isSelected: player.repeat != PlayerRepeatMode.off,
            iconSize: 20,
            icon: Icon(
              player.repeat == PlayerRepeatMode.one
                  ? Icons.repeat_one
                  : Icons.repeat,
            ),
            selectedIcon: Icon(
              player.repeat == PlayerRepeatMode.one
                  ? Icons.repeat_one
                  : Icons.repeat,
              size: 20,
              color: scheme.primary,
            ),
            onPressed: controller.cycleRepeat,
          ),
        const SizedBox(width: 2),
        IconButton(
          tooltip: 'Нравится',
          iconSize: 20,
          icon: const Icon(Icons.favorite_border),
          onPressed:
              signedIn ? () => _like(context, ref, player.current!) : null,
        ),
        IconButton(
          tooltip: 'Очередь',
          isSelected: mode == PlayerPanelMode.queue,
          iconSize: 20,
          icon: const Icon(Icons.queue_music),
          selectedIcon:
              Icon(Icons.queue_music, size: 20, color: scheme.primary),
          onPressed: () => panel.toggle(PlayerPanelMode.queue),
        ),
      ],
    );
  }

  Future<void> _like(BuildContext context, WidgetRef ref, Track track) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(librarySourceProvider).setLiked(track.id, liked: true);
      messenger.showSnackBar(
        const SnackBar(content: Text('Добавлено в «Мне нравится»')),
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

/// ------------------------------------------------------------- подложка островка

/// Поверхность островка: плотный цвет темы, скругление и мягкая тень.
///
/// Без размытия и полупрозрачности — в ArchiveTune такой «стеклянности» нет,
/// а размытие фона заметно нагружает отрисовку и даёт подтормаживания.
class _DockSurface extends StatelessWidget {
  const _DockSurface({
    required this.child,
    required this.radius,
    this.elevation = 8,
  });

  final Widget child;
  final double radius;
  final double elevation;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final BorderRadius shape = BorderRadius.circular(radius);
    final bool isDark = scheme.brightness == Brightness.dark;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: shape,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: scheme.shadow.withValues(alpha: isDark ? 0.5 : 0.18),
            blurRadius: elevation * 1.4,
            offset: Offset(0, elevation * 0.4),
          ),
        ],
      ),
      child: ClipRRect(borderRadius: shape, child: child),
    );
  }
}
