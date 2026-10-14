import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/local/app_settings.dart';
import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
import '../../state/player_panel.dart';
import '../../state/providers.dart';
import '../../widgets/artwork.dart';
import '../../widgets/track_menu.dart';
import '../common/navigation.dart';
import '../shell/content_navigator.dart';
import '../shell/destinations.dart';
import '../shell/player_panel.dart';
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
/// Порядок: **навигация слева, плеер справа** (плеер и разворачивается в
/// правую панель — см. `PlayerRightPanelSlot`). Поэтому у навигации прямо
/// скруглён правый край, а у плеера — левый.
///
/// Над группой раскрывается панель с очередью или текстом: она растёт вверх
/// и ничего не сдвигает.
class FloatingDock extends ConsumerWidget {
  const FloatingDock({super.key});

  /// Высота островка навигации. ArchiveTune: 78.
  ///
  /// Он выше плеера, поэтому именно по нему считается запас снизу
  /// (`AppLayout.floatingDockClearance`).
  static const double islandHeight = 70;

  /// Высота мини-плеера. ArchiveTune: 70.
  ///
  /// Островок плеера ниже навигации: так у островков разные «роли» — плеер
  /// как мини-плеер ArchiveTune, а навигация повыше, потому что несёт подписи.
  /// Стык при этом остаётся ровным: островки выровнены по нижнему краю
  /// (`CrossAxisAlignment.end`), а скругление на стыке общее (`joinRadius`).
  static const double playerIslandHeight = 70;

  /// Полное скругление — половина высоты островка.
  static const double outerRadius = islandHeight / 2;
  static const double playerRadius = playerIslandHeight / 2;

  /// Минимальное скругление на стыке двух островков.
  static const double joinRadius = AppLayout.junctionRadius;

  /// Зазор между островками (стык).
  static const double gap = 8;

  /// Отступ от краёв окна.
  static const double margin = 14;

  /// Ширина панели-ящика и навигации. ArchiveTune: до 420.
  static const double panelWidth = AppLayout.navBarMaxWidth;
  static const double panelMaxHeight = 420;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Островок плеера виден всегда, пока в очереди есть трек, — в том числе
    // на паузе. Прятать его при паузе не нужно: он же показывает состояние.
    final bool hasTrack = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.current != null),
    );

    // Боковая панель рисуется только в широкой раскладке и сама показывает
    // библиотеку — тогда вкладка «Библиотека» в островке была бы дублем.
    final bool sidebarVisible = context.isExpandedLayout;

    // Настройка «Плеер справа» включает разворот островка в правую панель.
    // Панель есть только в широкой раскладке: на телефоне её размещать негде,
    // там по нажатию открывается полноэкранный плеер.
    final bool panelEnabled = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => s.playerPanelEnabled,
      ),
    );
    final bool panelOpen = ref.watch(playerRightPanelProvider);
    final bool expandedPanel =
        hasTrack && sidebarVisible && panelEnabled && panelOpen;

    // Когда плеер развёрнут в правую панель, островок убираем: панель
    // занимает его место, и держать оба было бы дублем.
    final bool showPlayerIsland = hasTrack && !expandedPanel;

    // Появление и исчезновение плеера анимируем размером: группа
    // центрируется целиком, поэтому навигация плавно отъезжает, а островок
    // плеера раскрывается вправо — он теперь справа от навигации. Якорь по
    // левому краю (стыку): островок словно выезжает из-под навигации вправо.
    final Widget playerIsland = AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: Alignment.centerLeft,
      child: showPlayerIsland ? const _PlayerIsland() : const SizedBox.shrink(),
    );

    // Навигация — слева, плеер — справа. Если места не хватает, док не
    // переносится в столбик, а уменьшается целиком (`scaleDown`): форма и
    // стык сохраняются, переполнения нет. Так же поступает ArchiveTune:
    // мини-плеер и навигация остаются единой фигурой.
    final Widget islands = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.bottomCenter,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          _NavIsland(
            joinedOnRight: showPlayerIsland,
            sidebarVisible: sidebarVisible,
          ),
          if (showPlayerIsland) const SizedBox(width: gap),
          playerIsland,
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(margin, 0, margin, margin),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const _DockPanel(),
          islands,
        ],
      ),
    );
  }
}

/// ------------------------------------------------------- остров навигации

class _NavIsland extends ConsumerWidget {
  const _NavIsland({
    required this.joinedOnRight,
    required this.sidebarVisible,
  });

  /// Стоит ли справа островок плеера — тогда правые углы почти прямые.
  final bool joinedOnRight;

  /// Видна ли боковая панель библиотеки. Тогда вкладку «Библиотека» прячем:
  /// её заменяет сама панель, и в островке она была бы дублем.
  final bool sidebarVisible;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int index = ref.watch(shellIndexProvider);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    final List<ShellDestination> destinations = sidebarVisible
        ? ShellDestination.values
            .where((ShellDestination d) => d != ShellDestination.library)
            .toList(growable: false)
        : ShellDestination.values;

    return _DockSurface(
      // У стыка скругление минимальное, снаружи — полное. Навигация слева,
      // поэтому «прямой» её край — правый.
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
            const SizedBox(width: 10),
            for (final ShellDestination d in destinations)
              _NavButton(
                destination: d,
                selected: ShellDestination.values.indexOf(d) == index,
                onTap: () => selectShellDestination(
                  ref,
                  ShellDestination.values.indexOf(d),
                ),
              ),
            const SizedBox(width: 6),
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
            const SizedBox(width: 10),
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
    final TextTheme text = Theme.of(context).textTheme;

    // Геометрия выделения: отступ от краёв одинаковый, а радиус концентричен
    // внешнему (внешний минус отступ). Высоту задаём явно: если оставить её
    // по содержимому, «таблетка» выходит ниже задуманного, отступ перестаёт
    // совпадать с радиусом и скругление выглядит чужим.
    const double inset = 10;
    final BorderRadius pillRadius =
        BorderRadius.circular(FloatingDock.outerRadius - inset);
    const double pillHeight = FloatingDock.islandHeight - inset * 2;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Tooltip(
        message: destination.label,
        child: InkWell(
          onTap: onTap,
          borderRadius: pillRadius,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            height: pillHeight,
            padding: EdgeInsets.symmetric(horizontal: selected ? 16 : 14),
            decoration: BoxDecoration(
              color: selected ? scheme.secondaryContainer : Colors.transparent,
              borderRadius: pillRadius,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  selected ? destination.selectedIcon : destination.icon,
                  size: 22,
                  color: selected
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant,
                ),
                // Название показываем только у выбранного пункта: список
                // остаётся компактным, но видно, где находишься.
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.centerLeft,
                  child: selected
                      ? Padding(
                          padding: const EdgeInsets.only(left: 10),
                          child: Text(
                            destination.label,
                            maxLines: 1,
                            style: text.labelLarge?.copyWith(
                              color: scheme.onSecondaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// --------------------------------------------------------- островок плеера

class _PlayerIsland extends ConsumerStatefulWidget {
  const _PlayerIsland();

  @override
  ConsumerState<_PlayerIsland> createState() => _PlayerIslandState();
}

class _PlayerIslandState extends ConsumerState<_PlayerIsland> {
  @override
  Widget build(BuildContext context) {
    final PlayerUiState player = ref.watch(playerControllerProvider);
    final Track track = player.current!;
    final bool wide = context.isExpandedLayout;

    return _DockSurface(
        // Слева всегда стоит остров навигации, поэтому левые углы почти
        // прямые: вместе островки читаются одной фигурой.
        radius: BorderRadius.only(
          topLeft: const Radius.circular(FloatingDock.joinRadius),
          bottomLeft: const Radius.circular(FloatingDock.joinRadius),
          topRight: Radius.circular(FloatingDock.playerRadius),
          bottomRight: Radius.circular(FloatingDock.playerRadius),
        ),
        elevation: 0,
        child: SizedBox(
          height: FloatingDock.playerIslandHeight,
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
    // Разворот в правую панель доступен только в широкой раскладке и только
    // при включённой настройке «Плеер справа»: на узком экране панели негде
    // жить — там работает полноэкранный плеер.
    final bool panelEnabled = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => s.playerPanelEnabled,
      ),
    );
    // Лайк текущего трека — из общего источника правды: кнопка в островке и
    // в полноэкранном плеере всегда показывают одно и то же.
    final bool liked = ref.watch(
      likedIdsProvider.select(
        (Set<String> ids) => ids.contains(player.current?.id),
      ),
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
          tooltip: liked ? 'Убрать из «Мне нравится»' : 'Нравится',
          iconSize: 20,
          icon: Icon(
            liked ? Icons.favorite : Icons.favorite_border,
            color: liked ? scheme.primary : null,
          ),
          onPressed: signedIn && player.current != null
              ? () => _like(context, ref, player.current!)
              : null,
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
        // Разворачивает островок в панель справа (свернуть её можно уже из
        // самой панели). Кнопка — только на широком экране.
        if (wide && panelEnabled)
          IconButton(
            tooltip: 'Развернуть справа',
            iconSize: 20,
            icon: const Icon(Icons.open_in_full),
            onPressed: () {
              // Разворачиваем плеер в панель — всплывающий ящик закрываем,
              // иначе очередь висела бы и над островком, и в панели.
              panel.close();
              ref.read(playerRightPanelProvider.notifier).toggle();
            },
          ),
        // «…» ведёт к исполнителю, альбому и действиям над текущим треком —
        // раньше из островка не было ни одного перехода к исполнителю.
        IconButton(
          tooltip: 'Действия',
          iconSize: 20,
          icon: const Icon(Icons.more_vert),
          onPressed: player.current == null
              ? null
              : () => showTrackMenu(context, player.current!),
        ),
      ],
    );
  }

  Future<void> _like(BuildContext context, WidgetRef ref, Track track) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool wasLiked = ref.read(likedIdsProvider).contains(track.id);
    try {
      // Переключатель, а не «поставить лайк»: повторное нажатие снимает —
      // раньше лайк только добавлялся, и снять его из островка было нельзя.
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: radius,
        // Тени нет: островок отделяется от фона только тональным цветом
        // поверхности, как в ArchiveTune.
      ),
      child: ClipRRect(borderRadius: radius, child: child),
    );
  }
}
