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
import '../shell/destinations.dart';
import '../../state/shell.dart';
import 'lyrics_view.dart';
import 'queue_list.dart';

/// Островки внизу экрана.
///
/// Замысел: навигация и плеер — две отдельные «капсулы», которые стоят рядом
/// и центрируются **общей группой**. Пока ничего не играет, остров навигации
/// один и скруглён полностью. Когда появляется плеер, островки встают в ряд
/// через небольшой зазор, а на стыке скругление уменьшается до пары пунктов —
/// из-за этого пара читается как одна фигура, но остаётся двумя островами.
///
/// Над группой раскрывается панель с очередью или текстом: она растёт вверх
/// и ничего не сдвигает.
class FloatingDock extends ConsumerWidget {
  const FloatingDock({super.key});

  /// Высота островка.
  static const double islandHeight = 64;

  /// Полное скругление — снаружи пары.
  static const double outerRadius = islandHeight / 2;

  /// Минимальное скругление на стыке двух островков.
  static const double joinRadius = 6;

  /// Зазор между островками.
  static const double gap = 8;

  /// Отступ от краёв окна.
  static const double margin = 14;

  /// Ширина панели-ящика.
  static const double panelWidth = 420;
  static const double panelMaxHeight = 420;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Островок плеера виден всегда, пока в очереди есть трек, — в том числе
    // на паузе. Прятать его при паузе не нужно: он же показывает состояние.
    final bool hasTrack = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.current != null),
    );
    final bool wide = context.isExpandedLayout;

    // На узком экране навигация остаётся нижней панелью, поэтому здесь только
    // плеер. На широком обе части живут внизу и стоят рядом.
    final bool showNav = wide;
    if (!showNav && !hasTrack) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(margin, 0, margin, margin),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const _DockPanel(),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              if (showNav)
                _NavIsland(joinedOnRight: hasTrack),
              if (showNav && hasTrack)
                const SizedBox(width: gap),
              // Появление и исчезновение плеера анимируем размером: группа
              // центрируется целиком, поэтому навигация плавно отъезжает.
              AnimatedSize(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                alignment: Alignment.centerRight,
                child: hasTrack
                    ? _PlayerIsland(joinedOnLeft: showNav)
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// ------------------------------------------------------- остров навигации

class _NavIsland extends ConsumerWidget {
  const _NavIsland({required this.joinedOnRight});

  /// Стоит ли справа островок плеера — тогда правые углы почти прямые.
  final bool joinedOnRight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int index = ref.watch(shellIndexProvider);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return _DockSurface(
      // У стыка скругление минимальное, снаружи — полное.
      radius: BorderRadius.only(
        topLeft: const Radius.circular(FloatingDock.outerRadius),
        bottomLeft: const Radius.circular(FloatingDock.outerRadius),
        topRight: Radius.circular(
          joinedOnRight ? FloatingDock.joinRadius : FloatingDock.outerRadius,
        ),
        bottomRight: Radius.circular(
          joinedOnRight ? FloatingDock.joinRadius : FloatingDock.outerRadius,
        ),
      ),
      child: SizedBox(
        height: FloatingDock.islandHeight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(width: 8),
            for (final ShellDestination d in ShellDestination.values)
              _NavButton(
                destination: d,
                selected: ShellDestination.values.indexOf(d) == index,
                onTap: () =>
                    ref.read(shellIndexProvider.notifier).select(
                          ShellDestination.values.indexOf(d),
                        ),
              ),
            const SizedBox(width: 4),
            Container(
              width: 1,
              height: 24,
              color: scheme.outlineVariant,
            ),
            IconButton(
              tooltip: 'Настройки',
              iconSize: 22,
              color: scheme.onSurfaceVariant,
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => AppRoutes.settings(context),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final ShellDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    // Скругление выделения должно быть концентрично внешнему: иначе
    // «таблетка» внутри капсулы выглядит чужеродно. Внутренний радиус —
    // внешний минус вертикальный отступ.
    const double inset = 10;
    final BorderRadius pillRadius =
        BorderRadius.circular(FloatingDock.outerRadius - inset);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Tooltip(
        message: destination.label,
        child: InkWell(
          onTap: onTap,
          borderRadius: pillRadius,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: inset,
            ),
            decoration: BoxDecoration(
              color: selected ? scheme.secondaryContainer : Colors.transparent,
              borderRadius: pillRadius,
            ),
            child: Icon(
              selected ? destination.selectedIcon : destination.icon,
              size: 22,
              color: selected
                  ? scheme.onSecondaryContainer
                  : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// --------------------------------------------------------- островок плеера

class _PlayerIsland extends ConsumerStatefulWidget {
  const _PlayerIsland({required this.joinedOnLeft});

  /// Стоит ли слева остров навигации — тогда левые углы почти прямые.
  final bool joinedOnLeft;

  @override
  ConsumerState<_PlayerIsland> createState() => _PlayerIslandState();
}

class _PlayerIslandState extends ConsumerState<_PlayerIsland> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final PlayerUiState player = ref.watch(playerControllerProvider);
    final Track track = player.current!;
    final bool wide = context.isExpandedLayout;
    final double radius = FloatingDock.outerRadius;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: _DockSurface(
        radius: BorderRadius.only(
            topLeft: Radius.circular(
              widget.joinedOnLeft ? FloatingDock.joinRadius : radius,
            ),
            bottomLeft: Radius.circular(
              widget.joinedOnLeft ? FloatingDock.joinRadius : radius,
            ),
            topRight: const Radius.circular(FloatingDock.outerRadius),
            bottomRight: const Radius.circular(FloatingDock.outerRadius),
          ),
          elevation: _hovered ? 16 : 8,
          child: SizedBox(
            height: FloatingDock.islandHeight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(width: 10),
                _ArtworkWithProgress(track: track, player: player),
                const SizedBox(width: 12),
                // Ширина подписи ограничена: островок не должен растягиваться
                // на всю ширину монитора.
                SizedBox(
                  width: wide ? 220 : 150,
                  child: _IslandTitles(track: track, player: player),
                ),
                _IslandControls(player: player, wide: wide),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
    );
  }
}

/// Обложка с кольцом прогресса — вместо отдельной полосы перемотки.
class _ArtworkWithProgress extends StatelessWidget {
  const _ArtworkWithProgress({required this.track, required this.player});

  final Track track;
  final PlayerUiState player;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    const double side = 44;
    const double ring = 3;
    final List<String> variants = track.artworkFallbacks(
      (side * MediaQuery.devicePixelRatioOf(context)).round(),
    );

    return SizedBox(
      width: side + ring * 2,
      height: side + ring * 2,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          SizedBox(
            width: side + ring * 2,
            height: side + ring * 2,
            child: CircularProgressIndicator(
              // Пока длительность неизвестна, кольцо остаётся пустым:
              // «бегущий» индикатор здесь дублировал бы кнопку загрузки.
              value: player.playback.duration > Duration.zero
                  ? player.playback.progress
                  : 0,
              strokeWidth: ring,
              color: scheme.primary,
              backgroundColor: scheme.onSurface.withValues(alpha: 0.12),
            ),
          ),
          Artwork(
            url: variants.isEmpty ? null : variants.first,
            fallbacks:
                variants.length > 1 ? variants.sublist(1) : const <String>[],
            size: side,
            radius: BorderRadius.circular(side / 2),
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
          iconSize: 24,
          icon: const Icon(Icons.skip_previous_rounded),
          onPressed: player.queue.isEmpty ? null : controller.previous,
        ),
        // Один индикатор загрузки на весь островок: пока идёт подготовка,
        // вместо иконки воспроизведения показываем круг. Раньше их было
        // несколько сразу — и в кольце, и поверх обложки, и здесь.
        SizedBox(
          width: 40,
          height: 40,
          child: player.isLoading
              ? const Padding(
                  padding: EdgeInsets.all(9),
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : IconButton.filled(
                  tooltip: player.isPlaying ? 'Пауза' : 'Играть',
                  iconSize: 24,
                  icon: Icon(
                    player.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                  onPressed: controller.togglePlayPause,
                ),
        ),
        IconButton(
          tooltip: 'Следующий',
          iconSize: 24,
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

/// --------------------------------------------------------------- панель-ящик

/// Раскрывающаяся вверх часть: очередь или текст.
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
                  radius: BorderRadius.circular(AppLayout.radiusXL),
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
            selectedIcon:
                Icon(Icons.queue_music, size: 20, color: scheme.primary),
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

/// ------------------------------------------------------------- подложка островка

/// Поверхность островка: плотный цвет темы, скругление и мягкая тень.
///
/// Без размытия и полупрозрачности — в ArchiveTune такой «стеклянности» нет,
/// а размытие фона заметно нагружает отрисовку.
class _DockSurface extends StatelessWidget {
  const _DockSurface({
    required this.child,
    required this.radius,
    this.elevation = 8,
  });

  final Widget child;
  final BorderRadius radius;
  final double elevation;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool isDark = scheme.brightness == Brightness.dark;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: radius,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: scheme.shadow.withValues(alpha: isDark ? 0.5 : 0.18),
            blurRadius: elevation * 1.4,
            offset: Offset(0, elevation * 0.4),
          ),
        ],
      ),
      child: ClipRRect(borderRadius: radius, child: child),
    );
  }
}
