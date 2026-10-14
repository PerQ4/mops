import 'package:flutter/widgets.dart';

/// Единая система размеров и точки перехода.
///
/// Зачем отдельный файл: раньше размеры считались в разных местах и часть
/// зависела от масштаба текста — из-за этого элементы «дёргались» при
/// изменении ширины окна и при системном масштабе. Здесь все числа заданы
/// константами, а раскладка меняется только в явных точках перехода.
abstract final class AppLayout {
  // ------------------------------------------------------------- точки перехода

  /// Уже этого — телефонная раскладка.
  static const double compactMax = 700;

  /// Уже этого — только боковая навигация; шире — добавляется панель плеера.
  static const double mediumMax = 1080;

  /// Шире этого боковая навигация разворачивается с подписями.
  static const double extendedRailFrom = 1400;

  static bool isCompact(double width) => width < compactMax;
  static bool isMedium(double width) => width >= compactMax && width < mediumMax;
  static bool isExpanded(double width) => width >= mediumMax;
  static bool useExtendedRail(double width) => width >= extendedRailFrom;

  /// Показывать ли постоянную панель плеера справа.
  static bool showPlayerPanel(double width) => width >= mediumMax;

  /// Показывать ли нижнюю навигацию (телефонная раскладка).
  static bool showBottomNav(double width) => width < compactMax;

  // ------------------------------------------------------------- общие размеры

  /// Ширина боковой навигации. Фиксированная — иначе панель «прыгает».
  static const double railWidth = 96;
  static const double railExtendedWidth = 232;

  /// Ширина панели плеера на широких экранах.
  static const double playerPanelWidth = 400;

  /// Высота нижней навигации и панели плеера в компактной раскладке.
  static const double bottomNavHeight = 72;
  static const double miniPlayerHeight = 72;

  /// Отступ снизу, чтобы содержимое экранов не уходило под плавающий островок.
  ///
  /// Высота островка (64) + его отступ от края окна (14) + запас (8).
  /// Значения должны совпадать с `FloatingDock.islandHeight` и
  /// `FloatingDock.margin`.
  static const double floatingDockClearance = 86;

  /// Максимальная ширина содержимого.
  ///
  /// Без ограничения на широком мониторе строки растягиваются на всю ширину,
  /// и название трека оказывается в одном углу, а длительность — в другом.
  static const double contentMaxWidth = 1200;

  // ----------------------------------------------------------------- элементы

  /// Строка трека в списке.
  static const double trackRowHeight = 72;
  static const double trackArtwork = 56;
  static const double trackArtworkRadius = 12;

  /// Карточки в каруселях (альбомы, исполнители, плейлисты).
  static const double cardWidth = 160;
  static const double cardArtworkRadius = 18;
  /// Высота карточки целиком: обложка + две строки подписи.
  static const double cardHeight = cardWidth + 62;

  /// Круглые аватары исполнителей.
  static const double artistAvatar = 136;

  /// Обложка в шапке страницы (альбом/исполнитель/плейлист).
  static const double headerArtwork = 208;

  /// Скругления.
  static const double radiusS = 12;
  static const double radiusM = 18;
  static const double radiusL = 24;
  static const double radiusXL = 32;

  /// Отступы страницы.
  static const double gutter = 20;

  // -------------------------------------------------------------- вычисления

  /// Сколько колонок помещается при данной ширине содержимого.
  static int gridColumns(double width, {double minItemWidth = cardWidth}) {
    if (width <= 0) return 1;
    // На широком экране не даём колонкам становиться крошечными.
    final int columns = (width / (minItemWidth + gutter)).floor();
    return columns.clamp(1, 8);
  }

  /// Ширина содержимого с учётом максимальной ширины страницы.
  static double contentWidth(double available) =>
      available > contentMaxWidth ? contentMaxWidth : available;
}

/// Удобный доступ к текущей ширине из виджетов.
extension LayoutContext on BuildContext {
  double get layoutWidth => MediaQuery.sizeOf(this).width;

  bool get isCompactLayout => AppLayout.isCompact(layoutWidth);
  bool get isMediumLayout => AppLayout.isMedium(layoutWidth);
  bool get isExpandedLayout => AppLayout.isExpanded(layoutWidth);
}

/// Ограничивает ширину содержимого и центрирует его.
///
/// Списки и карусели оборачиваются в этот виджет: так на широком окне они
/// остаются читаемыми, а не растягиваются от края до края.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppLayout.contentMaxWidth),
        child: child,
      ),
    );
  }
}
