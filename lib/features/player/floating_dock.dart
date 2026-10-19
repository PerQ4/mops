import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/local/app_settings.dart';
import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/catalog_providers.dart';
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
import 'artwork_progress_ring.dart';
import 'lyrics_actions.dart';
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
class FloatingDock extends ConsumerStatefulWidget {
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
  ConsumerState<FloatingDock> createState() => _FloatingDockState();
}

class _FloatingDockState extends ConsumerState<FloatingDock> {
  /// Прогресс жеста по островку плеера: по горизонтали −1…1, по вертикали 0…1.
  ///
  /// Держим в состоянии дока, а не внутри островка: на жест должен отзываться
  /// и соседний островок навигации — они читаются одной фигурой, поэтому
  /// двигаются вместе.
  final ValueNotifier<Offset> _swipe = ValueNotifier<Offset>(Offset.zero);

  @override
  void dispose() {
    _swipe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Островок плеера виден всегда, пока в очереди есть трек, — в том числе
    // на паузе. Прятать его при паузе не нужно: он же показывает состояние.
    final bool hasTrack = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.current != null),
    );

    // Боковая панель есть и в средней раскладке — свёрнутой полосой (см.
    // `AppShell`), поэтому «панель видна» — это всё, что не компакт.
    final bool sidebarVisible = !context.isCompactLayout;

    // Настройка «панель вместо островка»: панель уже несёт навигацию, и
    // островок навигации в доке был бы её дублем. Плеерный островок остаётся.
    final bool navInSidebar = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => s.sidebarNavigation,
      ),
    );
    final bool showNavIsland = !(sidebarVisible && navInSidebar);

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
      child: showPlayerIsland
          ? _PlayerIsland(swipe: _swipe, navHidden: !showNavIsland)
          : const SizedBox.shrink(),
    );

    // Навигация — слева, плеер — справа. Если места не хватает, док не
    // переносится в столбик, а уменьшается целиком (`scaleDown`): форма и
    // стык сохраняются, переполнения нет. Так же поступает ArchiveTune:
    // мини-плеер и навигация остаются единой фигурой.
    // Порядок в списке задаёт порядок отрисовки: навигация идёт ПОСЛЕ плеера,
    // то есть ложится поверх него. Благодаря этому капсула трека может
    // уезжать под навигацию — стык при этом не двигается. `textDirection: rtl`
    // разворачивает только порядок вдоль оси, текст внутри островков остаётся
    // слева направо.
    final Widget row = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.bottomCenter,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        textDirection: TextDirection.rtl,
        children: <Widget>[
          playerIsland,
          if (showPlayerIsland && showNavIsland)
            const SizedBox(width: FloatingDock.gap),
          if (showNavIsland)
            _NavIsland(
              joinedOnRight: showPlayerIsland,
              sidebarVisible: sidebarVisible,
            ),
        ],
      ),
    );

    // Весь ряд чуть подаётся за пальцем: островок плеера двигается сильнее
    // (он под рукой), навигация — слабее. Вместе это читается как одна
    // упругая фигура, а не как два независимых блока.
    final Widget islands = ValueListenableBuilder<Offset>(
      valueListenable: _swipe,
      builder: (BuildContext context, Offset swipe, Widget? child) {
        return Transform.translate(
          offset: Offset(0, swipe.dy * 10),
          child: child,
        );
      },
      child: row,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(FloatingDock.margin, 0, FloatingDock.margin, FloatingDock.margin),
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

  /// Видна ли боковая панель библиотеки. Тогда из островка прячем «Библиотеку»
  /// и «Настройки»: и то и другое несёт сама панель, а в островке они были бы
  /// дублем.
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
            // «Настройки» есть и в самом низу панели библиотеки, поэтому при
            // видимой панели не дублируем её в островке — там остаются только
            // разделы. На узком окне панели нет, и кнопка нужна.
            if (!sidebarVisible) ...<Widget>[
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
            ],
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
  const _PlayerIsland({required this.swipe, this.navHidden = false});

  /// Островка навигации рядом нет (настройка «панель вместо островка» или
  /// компактное окно): тогда левый край круглый сразу, а не только после
  /// свайпа — иначе он остался бы со «спиленным» стыком.
  final bool navHidden;

  /// Признак жеста для соседнего островка: пишем сюда, читает док.
  final ValueNotifier<Offset> swipe;

  @override
  ConsumerState<_PlayerIsland> createState() => _PlayerIslandState();
}

class _PlayerIslandState extends ConsumerState<_PlayerIsland> {
  /// Накопленное смещение свайпа. Порог считаем в конце жеста, поэтому
  /// промежуточное значение нужно держать между вызовами.
  double _dragDx = 0;
  double _dragDy = 0;

  /// Идёт ли жест прямо сейчас: пока идёт — островок следует за пальцем без
  /// анимации, после отпускания — возвращается пружиной.
  bool _dragging = false;

  /// Эталонная ширина для прогресса жеста: островок меняет ширину от подписи,
  /// поэтому берём постоянную величину, а не текущую.
  static const double _referenceWidth = 260;

  /// Прогресс жеста, −1…1 по горизонтали.
  double get _progress => (_dragDx / _referenceWidth).clamp(-1.0, 1.0);

  /// Прогресс свайпа вниз, 0…1.
  double get _downProgress => (_dragDy / 120).clamp(0.0, 1.0);

  void _publishSwipe() {
    widget.swipe.value = Offset(_progress, _downProgress);
  }

  /// Возвращает островок на место и гасит отклик соседнего островка.
  void _resetDrag() {
    setState(() {
      _dragDx = 0;
      _dragDy = 0;
      _dragging = false;
    });
    _publishSwipe();
  }

  @override
  Widget build(BuildContext context) {
    // Позицию сюда не подмешиваем: её слушает только кольцо прогресса
    // (`ArtworkProgressRing`), и тик позиции не должен перестраивать весь
    // островок. Запись сравнивается по значению, поэтому подписка срабатывает
    // лишь на смену трека, состояния загрузки или очереди.
    final (
      Track? current,
      bool isPlaying,
      bool isLoading,
      bool downloading,
      double downloadProgress,
      String? error,
      List<Track> queue,
    ) = ref.watch(
      playerControllerProvider.select(
        (PlayerUiState s) => (
          s.current,
          s.isPlaying,
          s.isLoading,
          s.downloading,
          s.downloadProgress,
          s.error,
          s.queue,
        ),
      ),
    );
    final Track track = current!;
    final bool wide = context.isExpandedLayout;

    // Насколько жест набран: подмешиваем акцент к поверхности островка, чтобы
    // свайп было видно. Раньше островок на движение не отвечал никак.
    final double tint =
        (_progress.abs() * 0.7 + _downProgress * 0.5).clamp(0.0, 1.0);

    // Свайп от навигации (вправо) — островок отрывается от неё, и левый край
    // становится таким же круглым, как правый. Если навигации рядом нет вовсе,
    // край круглый сразу.
    final double awayNav = widget.navHidden
        ? 1.0
        : (_dragDx / 140).clamp(0.0, 1.0);

    // Свайп К навигации (влево) — блок ОБРЕЗАЕТСЯ справа вместе с содержимым:
    // ширина становится меньше, а левый край с минимальным скруглением (стык)
    // остаётся ровно на месте. Сдвигать блок было неверно: ширина не менялась,
    // и стык уезжал вместе с ним.
    final double shrink = (-_dragDx * 0.9).clamp(0.0, 260.0);

    final BorderRadius radius = BorderRadius.only(
      topLeft: Radius.circular(
        FloatingDock.joinRadius +
            (FloatingDock.playerRadius - FloatingDock.joinRadius) * awayNav,
      ),
      bottomLeft: Radius.circular(
        FloatingDock.joinRadius +
            (FloatingDock.playerRadius - FloatingDock.joinRadius) * awayNav,
      ),
      topRight: Radius.circular(FloatingDock.playerRadius),
      bottomRight: Radius.circular(FloatingDock.playerRadius),
    );

    final Widget island = _DockSurface(
        // Слева всегда стоит остров навигации, поэтому левые углы почти
        // прямые: вместе островки читаются одной фигурой.
        radius: radius,
        elevation: 0,
        tint: tint,
        child: SizedBox(
          height: FloatingDock.playerIslandHeight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(width: 10),
              _ArtworkWithProgress(track: track),
              const SizedBox(width: 12),
              // Ширина подписи ограничена: островок не должен растягиваться
              // на всю ширину монитора.
              SizedBox(
                width: wide ? 220 : 150,
                child: _IslandTitles(
                  track: track,
                  downloading: downloading,
                  downloadProgress: downloadProgress,
                  error: error,
                ),
              ),
              _IslandControls(
                isPlaying: isPlaying,
                isLoading: isLoading,
                queue: queue,
                current: current,
                wide: wide,
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      );

    // Пока тянем, подсказки кнопок не должны всплывать: палец ведёт блок, а
    // подсказка «Предыдущий/Следующий» поверх него только мешает.
    final Widget islandWithJoint = TooltipVisibility(
      visible: !_dragging,
      child: island,
    );

    // Жесты островка: свайп влево/вправо — следующий/предыдущий трек, тап по
    // свободному месту — полноэкранный плеер. Кнопки управления лежат внутри
    // и перехватывают нажатия сами, поэтому тап по ним этот жест не ломает.
    // `opaque` — чтобы ловить и промежутки между элементами строки.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (DragUpdateDetails details) {
        setState(() {
          _dragging = true;
          _dragDx += details.delta.dx;
        });
        _publishSwipe();
      },
      onHorizontalDragCancel: _resetDrag,
      onHorizontalDragEnd: _onSwipeEnd,
      onVerticalDragUpdate: (DragUpdateDetails details) {
        setState(() {
          _dragging = true;
          // Вниз — уборка очереди: тянем только вниз, вверх не заводим.
          _dragDy = (_dragDy + details.delta.dy).clamp(0.0, 240.0);
        });
        _publishSwipe();
      },
      onVerticalDragCancel: _resetDrag,
      // Смахивание вниз убирает очередь целиком: островок плеера при этом
      // исчезает, потому что играть больше нечего.
      onVerticalDragEnd: (DragEndDetails details) {
        final bool clear = (details.primaryVelocity ?? 0) > 250 ||
            _downProgress >= 0.6;
        _resetDrag();
        if (clear) {
          unawaited(
            ref.read(playerControllerProvider.notifier).clearQueue(),
          );
        }
      },
      onTap: () => AppRoutes.nowPlaying(context),
      child: AnimatedContainer(
        // Пока ведём пальцем — следуем за ним без задержки; после отпускания
        // островок возвращается на место пружиной (`easeOutBack` даёт лёгкий
        // «перелёт», как у выразительных компонентов Material 3).
        duration:
            _dragging ? Duration.zero : const Duration(milliseconds: 280),
        curve: Curves.easeOutBack,
        transform: Matrix4.translationValues(
          // Влево — едем вместе с обрезкой: капсула уходит под навигацию, а
          // левый край (обрез) остаётся на её границе. Вправо — лёгкий сдвиг,
          // там обрезки нет.
          _dragDx > 0 ? _dragDx * 0.32 : -shrink,
          _dragDy * 0.30,
          0,
        ),
        child: shrink <= 0.5
            ? islandWithJoint
            : ClipRRect(
                clipper: _LeftInsetClipper(
                  inset: shrink,
                  edgeRadius: FloatingDock.joinRadius,
                  outerRadius: FloatingDock.playerRadius,
                ),
                child: islandWithJoint,
              ),
      ),
    );
  }

  void _onSwipeEnd(DragEndDetails details) {
    // Ширину берём у самого островка (естественную — до масштабирования
    // `FittedBox`).
    final double width = context.size?.width ?? 360;
    // Порог — доля ширины из настройки: раньше он был зашит четвертью, и
    // «тугой» свайп раздражал. Чувствительность вынесена в настройки, как
    // в ArchiveTune. Быстрый «щелчок» всё так же срабатывает по скорости.
    final SwipeSensitivity sensitivity = ref.read(
      settingsControllerProvider
          .select((AppSettings s) => s.miniSwipeSensitivity),
    );
    final double threshold = width * sensitivity.thresholdFraction;
    final double velocity = details.primaryVelocity ?? 0;
    final double dx = _dragDx;
    _resetDrag();

    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);
    // Влево — следующий, вправо — предыдущий (как в каруселях).
    if (dx <= -threshold || velocity < -800) {
      controller.next();
    } else if (dx >= threshold || velocity > 800) {
      controller.previous();
    }
  }
}

/// Обложка с волнистым кольцом прогресса — вместо отдельной полосы перемотки.
class _ArtworkWithProgress extends StatelessWidget {
  const _ArtworkWithProgress({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    const double side = 44;
    // Толщину и волну кольцо берёт из стороны обложки само: островок задаёт
    // пропорции, а панель с крупной обложкой масштабирует их.
    final double extent = ArtworkProgressRing.extent(side);
    final List<String> variants = track.artworkFallbacks(
      (side * MediaQuery.devicePixelRatioOf(context)).round(),
    );

    return SizedBox(
      width: extent,
      height: extent,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // Кольцо под обложкой: оно само слушает позицию, а нажатия по
          // обложке не перехватывает.
          ArtworkProgressRing(
            side: side,
            shape: BorderRadius.circular(side / 2),
          ),
          SizedBox(
            width: side,
            height: side,
            // Размер задаёт `SizedBox`, а не сам `Artwork`: тогда перелёт
            // `Hero` растягивает картинку по промежуточному прямоугольнику,
            // а не тащит её фиксированной.
            child: Artwork(
              url: variants.isEmpty ? null : variants.first,
              fallbacks:
                  variants.length > 1 ? variants.sublist(1) : const <String>[],
              heroTag: kPlayerArtworkHeroTag,
              radius: BorderRadius.circular(side / 2),
            ),
          ),
        ],
      ),
    );
  }
}

class _IslandTitles extends StatelessWidget {
  const _IslandTitles({
    required this.track,
    required this.downloading,
    required this.downloadProgress,
    required this.error,
  });

  final Track track;
  final bool downloading;
  final double downloadProgress;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String subtitle = downloading
        ? 'Загрузка ${(downloadProgress * 100).round()}%'
        : error ?? track.artistLine;

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
                color: error != null
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
  const _IslandControls({
    required this.isPlaying,
    required this.isLoading,
    required this.queue,
    required this.current,
    required this.wide,
  });

  final bool isPlaying;
  final bool isLoading;
  final List<Track> queue;

  /// Текущий трек: нужен кнопкам лайка и «…».
  final Track? current;

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
        (Set<String> ids) => ids.contains(current?.id),
      ),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          tooltip: 'Предыдущий',
          iconSize: 24,
          icon: const Icon(Icons.skip_previous_rounded),
          onPressed: queue.isEmpty ? null : controller.previous,
        ),
        // Один индикатор загрузки на весь островок: пока идёт подготовка,
        // вместо иконки воспроизведения показываем круг. Раньше их было
        // несколько сразу — и в кольце, и поверх обложки, и здесь.
        SizedBox(
          width: 40,
          height: 40,
          child: isLoading
              ? const Padding(
                  padding: EdgeInsets.all(9),
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : IconButton.filled(
                  tooltip: isPlaying ? 'Пауза' : 'Играть',
                  iconSize: 24,
                  icon: Icon(
                    isPlaying
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
          onPressed: queue.isEmpty ? null : controller.next,
        ),
        IconButton(
          tooltip: liked ? 'Убрать из «Мне нравится»' : 'Нравится',
          iconSize: 20,
          icon: Icon(
            liked ? Icons.favorite : Icons.favorite_border,
            color: liked ? scheme.primary : null,
          ),
          onPressed: signedIn && current != null
              ? () => _like(context, ref, current!)
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
            tooltip: 'Открыть панель плеера',
            iconSize: 20,
            icon: const Icon(Icons.vertical_split),
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
          onPressed: current == null
              ? null
              : () => showTrackMenu(context, current!),
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
                        _PanelHeader(mode: mode, track: track),
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
  const _PanelHeader({required this.mode, required this.track});

  final PlayerPanelMode mode;

  /// Играющий трек — нужен, чтобы сменить источник текста отсюда же.
  final Track track;

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
            onPressed: () {
              controller.toggle(PlayerPanelMode.queue);
              // Очередь и текст — одно состояние на всё приложение, поэтому
              // переключение здесь видно и в правой панели, и на полном экране.
              ref
                  .read(settingsControllerProvider.notifier)
                  .setShowLyrics(false);
            },
          ),
          IconButton(
            tooltip: 'Текст песни',
            isSelected: mode == PlayerPanelMode.lyrics,
            icon: const Icon(Icons.lyrics_outlined, size: 20),
            selectedIcon: Icon(Icons.lyrics, size: 20, color: scheme.primary),
            onPressed: () {
              final bool showing = mode == PlayerPanelMode.lyrics;
              controller.toggle(PlayerPanelMode.lyrics);
              ref
                  .read(settingsControllerProvider.notifier)
                  .setShowLyrics(!showing);
            },
          ),
          // Смена источника текста прямо из островка: раньше из меню
          // островка этого нельзя было сделать вовсе.
          LyricsMenuButton(
            request: LyricsRequest.fromTrack(track),
            // Когда открыт текст, пункт «скрыть» закрывает ящик целиком —
            // другого «показать/скрыть» у островка нет.
            onToggleVisibility: mode == PlayerPanelMode.lyrics
                ? () {
                    controller.close();
                    ref
                        .read(settingsControllerProvider.notifier)
                        .setShowLyrics(false);
                  }
                : null,
            lyricsVisible: mode == PlayerPanelMode.lyrics,
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
/// Обрезает левый край блока на заданную величину.
///
/// Нужен для свайпа к навигации: капсула «уезжает» влево под остров навигации,
/// поэтому прячется именно левая часть, а правый край остаётся на месте.
/// Кромка обрезки скруглена как базовый стык (`joinRadius`), а внешний правый
/// угол сохраняет штатный радиус — иначе кромка выглядит чужим капсульным
/// закруглением.
class _LeftInsetClipper extends CustomClipper<RRect> {
  const _LeftInsetClipper({
    required this.inset,
    required this.edgeRadius,
    required this.outerRadius,
  });

  final double inset;

  /// Радиус обрезанной (левой) кромки — как у стыка с навигацией.
  final double edgeRadius;

  /// Радиус внешнего (правого) угла — как в покое.
  final double outerRadius;

  @override
  RRect getClip(Size size) {
    final double left = inset.clamp(0.0, size.width);
    return RRect.fromRectAndCorners(
      Rect.fromLTRB(left, 0, size.width, size.height),
      topLeft: Radius.circular(edgeRadius),
      bottomLeft: Radius.circular(edgeRadius),
      topRight: Radius.circular(outerRadius),
      bottomRight: Radius.circular(outerRadius),
    );
  }

  @override
  bool shouldReclip(_LeftInsetClipper oldClipper) =>
      oldClipper.inset != inset ||
      oldClipper.edgeRadius != edgeRadius ||
      oldClipper.outerRadius != outerRadius;
}

class _DockSurface extends StatelessWidget {
  const _DockSurface({
    required this.child,
    required this.radius,
    this.elevation = 8,
    this.tint = 0,
  });

  final Widget child;
  final BorderRadius radius;
  final double elevation;

  /// Насколько подмешать цвет акцента: 0 — покой, 1 — жест набран целиком.
  /// Нужен как отклик на свайп: раньше островок на жест не отвечал вовсе.
  final double tint;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Color.lerp(
          scheme.surfaceContainerHigh,
          scheme.primaryContainer,
          tint * 0.5,
        ),
        borderRadius: radius,
        // Тени нет: островок отделяется от фона только тональным цветом
        // поверхности, как в ArchiveTune.
      ),
      child: ClipRRect(borderRadius: radius, child: child),
    );
  }
}
