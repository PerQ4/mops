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

  /// Ширина панели плеера на широких экранах.
  static const double playerPanelWidth = 400;

  // ---------------------------------------------------- размеры ArchiveTune
  //
  // Взяты из исходников ArchiveTune (`constants/Dimensions.kt`), чтобы
  // интерфейс совпадал с оригиналом.

  /// Ширина панели навигации на широком экране.
  static const double navBarMaxWidth = 420;

  /// Обложка в сетке.
  static const double gridThumbnailHeight = 128;

  /// Радиус обложки в списке и в сетке.
  static const double thumbnailRadius = 10;
  static const double gridThumbnailRadius = 8;

  /// Ширина боковой панели с навигацией и библиотекой на широком экране.
  static const double sidebarWidth = 280;

  /// Ширина свёрнутой боковой панели — узкая полоса с обложками плейлистов.
  ///
  /// Панель не исчезает совсем: свернуть её «в ноль» значило бы потерять
  /// доступ к своим плейлистам, а так остаётся быстрый доступ по обложкам.
  static const double sidebarCollapsedWidth = 72;

  /// Пределы ширины развёрнутой панели библиотеки.
  ///
  /// Минимум — чтобы помещались обложка, название и подпись, максимум —
  /// чтобы на большом мониторе панель не растягивалась в пустую полосу.
  static const double sidebarMinWidth = 220;
  static const double sidebarMaxWidth = 480;

  /// Доля окна, которую развёрнутая панель не должна превышать.
  ///
  /// Одних констант не хватало: на окне 1100 панель в 480 пикселей съедала
  /// почти половину. На узком окне доля важнее абсолютного максимума.
  static const double sidebarMaxWidthFraction = 0.4;

  /// Ширина зоны захвата у правой кромки панели.
  ///
  /// Раньше кромка была 8 пикселей — по ней приходилось попадать точно; 14
  /// заметно снисходительнее к промаху и не мешает содержимому.
  static const double sidebarResizeHandleWidth = 14;

  /// Высота строки навигации внутри левой панели.
  static const double sidebarNavRowHeight = 40;

  /// Отступ над заголовком категории в списке библиотеки: категории идут друг
  /// под другом, и верхний отступ отделяет одну от следующей.
  static const double sidebarCategoryTopGap = 14;

  /// Отступ под заголовком категории — до первой строки списка.
  static const double sidebarCategoryBottomGap = 4;

  /// Предел ширины счётчика в заголовке категории. Длинную подпись
  /// («123 исполнителя») обрезаем, чтобы она не выдавила название категории.
  static const double sidebarCategoryCountMaxWidth = 96;

  /// Высота шапки экрана.
  static const double appBarHeight = 64;

  /// Скругления: отдельный островок и стык с соседним.
  static const double standaloneBarRadius = 32;
  static const double junctionRadius = 12;

  /// Отступ снизу, чтобы содержимое экранов не уходило под плавающий островок.
  ///
  /// Высота островка (70) + его отступ от края окна (14) + запас (8).
  /// Значения должны совпадать с `FloatingDock.islandHeight` и
  /// `FloatingDock.margin`.
  static const double floatingDockClearance = 92;

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

  /// Горизонтальный отступ строки трека — `padding(horizontal = 8.dp)`.
  static const double trackRowInset = 8;

  /// Отступ обложки внутри строки — `Box(padding(8.dp))` у `ListItem`.
  static const double trackArtworkInset = 8;

  /// Зазор между обложкой и подписью.
  static const double trackTextInset = 6;

  /// Зазор между названием и подписью.
  static const double trackTitleGap = 2;

  /// Плотный режим строк (пункт 11.2): 52 — обложка 40 и по 6 пикселей
  /// запаса сверху и снизу. Мобильные 72 оставляли на 1080p около десяти
  /// строк; здесь их почти в полтора раза больше, а пропорции сохранены.
  static const double trackRowHeightCompact = 52;
  static const double trackArtworkCompact = 40;
  static const double trackRowInsetCompact = 6;
  static const double trackArtworkInsetCompact = 6;
  static const double trackTextInsetCompact = 4;
  static const double trackTitleGapCompact = 1;

  /// Кнопка «…» в плотной строке: стандартные 48 не помещаются в 40
  /// пикселей, оставшихся после отступов.
  static const double trackActionSizeCompact = 32;

  /// Строка библиотеки в боковой панели.
  static const double libraryRowHeight = 64;
  static const double libraryArtwork = 48;
  static const double libraryRowGap = 12;
  static const double libraryRowVerticalMargin = 2;

  /// Плотный вариант строки библиотеки: та же логика, что у строки трека, —
  /// меньше обложка, кегль названия и вертикальные отступы вместе.
  static const double libraryRowHeightCompact = 52;
  static const double libraryArtworkCompact = 40;
  static const double libraryRowGapCompact = 8;
  static const double libraryRowVerticalMarginCompact = 1;

  /// Карточки в каруселях (альбомы, исполнители, плейлисты).
  static const double cardWidth = 160;

  /// Круглые аватары исполнителей.
  static const double artistAvatar = 136;

  /// Обложка в шапке страницы (альбом/исполнитель/плейлист).
  static const double headerArtwork = 208;

  /// Скругления.
  static const double radiusS = 12;
  static const double radiusM = 18;
  static const double radiusL = 24;
  static const double radiusXL = 32;

  /// Радиус скругления основной области со стороны боковой панели.
  ///
  /// Благодаря ему содержимое читается отдельной панелью, лежащей поверх
  /// фона боковой панели, — как в Spotify Desktop. Скруглены только углы,
  /// примыкающие к боковой панели (левый верхний и левый нижний).
  static const double contentPanelRadius = radiusL;

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

  /// Максимальная ширина развёрнутой панели библиотеки для окна [windowWidth].
  ///
  /// Не больше [sidebarMaxWidth] и не больше доли окна, но не меньше
  /// [sidebarMinWidth]: на узком окне панель обязана оставаться читаемой.
  static double sidebarWidthLimit(double windowWidth) {
    final double byWindow = windowWidth * sidebarMaxWidthFraction;
    final double limit =
        byWindow < sidebarMaxWidth ? byWindow : sidebarMaxWidth;
    return limit < sidebarMinWidth ? sidebarMinWidth : limit;
  }

  /// Свёрнута ли панель библиотеки по умолчанию при этой ширине окна.
  ///
  /// На среднем окне — да: развёрнутая панель съедала бы половину ширины, а
  /// полоса значков помещается. На широком — как выбрал пользователь
  /// ([saved]). Средняя раскладка не должна навязывать сворачивание тому,
  /// кто сам развернул панель, — за это отвечает отдельный выбор в сеансе,
  /// а здесь только умолчание.
  static bool sidebarCollapsedByDefault(double width, {required bool saved}) =>
      isMedium(width) || saved;
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
