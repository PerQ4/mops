import 'package:flutter/material.dart';

import '../../core/theme/layout.dart';
import '../../data/models/models.dart';
import '../../widgets/artwork.dart';
import '../../widgets/artist_line.dart';

/// «Герой» страницы медиа: альбом, исполнитель, плейлист.
///
/// Форма взята у ArchiveTune (`ui/component/MediaDetailHero.kt`): обложка на всю
/// ширину, поверх неё затемняющий градиент, а внизу по центру — название,
/// подпись, описание, метаданные и действия. Порядок элементов и все размеры
/// повторяют оригинал, чтобы три страницы не разъезжались по оформлению.
class MediaHero extends StatelessWidget {
  const MediaHero({
    super.key,
    required this.title,
    this.subtitle,
    this.artists,
    this.meta,
    this.description,
    this.imageUrl,
    this.fallbackIcon,
    this.actions = const <Widget>[],
  });

  final String title;

  /// Подпись под названием: исполнитель или автор.
  final String? subtitle;

  /// Исполнители с идентификаторами. Если переданы — подпись собирается
  /// кликабельной (как `buildAnnotatedString` со ссылками в оригинале), иначе
  /// используется обычный [subtitle].
  final List<ArtistRef>? artists;

  /// Строка метаданных: «год • N треков • длительность».
  final String? meta;

  /// Описание медиа (может отсутствовать).
  final String? description;

  final String? imageUrl;
  final IconData? fallbackIcon;
  final List<Widget> actions;

  /// Минимальная высота героя и ширина текстового блока — из
  /// `MediaDetailHero.kt` (`MediaDetailHeroMinHeight`, `MediaDetailContentMaxWidth`).
  static const double minHeight = 560;
  static const double contentWidth = 720;

  /// Отступ содержимого героя по горизонтали и снизу —
  /// `MediaDetailHero.kt` (`MediaDetailHorizontalPadding`, bottom = 24.dp).
  static const double horizontalPadding = 24;

  /// Отступ содержимого сверху — `MediaDetailHero.kt`:
  /// `systemBarsTopPadding + AppBarHeight + 96.dp`. Внутри прокрутки герой
  /// прижат к низу блока высотой не меньше 560, поэтому запас сверху
  /// срабатывает только у очень длинного содержимого.
  static const double topReserve = AppLayout.appBarHeight + 96;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // В ArchiveTune цвет содержимого героя выбирается по яркости поверхности:
    // на тёмной теме это белый, на светлой — `onSurface` (MediaDetailHero.kt:89).
    final Color heroContent = heroContentColor(scheme);
    final bool hasArtists = artists != null && artists!.isNotEmpty;
    final bool hasSubtitle = subtitle != null && subtitle!.isNotEmpty;

    return Stack(
      children: <Widget>[
        // Обложка на всю ширину героя.
        Positioned.fill(
          child: imageUrl != null && imageUrl!.isNotEmpty
              ? Artwork(
                  url: imageUrl,
                  // Размер задан только ради крупной иконки-заглушки: в
                  // `Positioned.fill` картинка всё равно растягивается по
                  // контейнеру.
                  size: 200,
                  radius: BorderRadius.zero,
                  fit: BoxFit.cover,
                  icon: fallbackIcon,
                )
              // Обложки нет: в оригинале это `surfaceContainerHigh` с иконкой
              // 96 по центру цветом `onSurfaceVariant` (MediaDetailHero.kt:107-122).
              : ColoredBox(
                  color: scheme.surfaceContainerHigh,
                  child: Center(
                    child: Icon(
                      fallbackIcon ?? Icons.music_note,
                      size: 96,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
        ),
        // Градиент из пяти остановок (MediaDetailHero.kt:138-144): тёмный верх,
        // прозрачная середина и переход в цвет поверхности снизу.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Colors.black.withValues(alpha: 0.42),
                  Colors.transparent,
                  Colors.transparent,
                  scheme.surface.withValues(alpha: 0.78),
                  scheme.surface,
                ],
                stops: const <double>[0, 0.18, 0.42, 0.72, 1],
              ),
            ),
          ),
        ),
        // Единственный непозиционированный ребёнок задаёт высоту героя.
        // `ConstrainedBox` держит минимум 560, но в отличие от фиксированной
        // высоты не обрезает содержимое: в оригинале это `heightIn(min = 560.dp)`.
        // `Align` прижимает содержимое вниз — иначе `Stack` сжался бы по
        // контенту и текст оказался сверху.
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: minHeight),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: contentWidth),
              child: Padding(
                padding: const EdgeInsets.only(
                  left: horizontalPadding,
                  top: topReserve,
                  right: horizontalPadding,
                  bottom: horizontalPadding,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.headlineLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: heroContent,
                        ),
                      ),
                      if (hasArtists) ...<Widget>[
                        const SizedBox(height: 6),
                        // Имена исполнителей кликабельны — как ссылки в
                        // `AnnotatedString` оригинала (AlbumScreen.kt:256-272).
                        ArtistLine(
                          artists: artists!,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          style: text.titleMedium?.copyWith(
                            color: heroContent.withValues(alpha: 0.82),
                          ),
                        ),
                      ] else if (hasSubtitle) ...<Widget>[
                        const SizedBox(height: 6),
                        Text(
                          subtitle!,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleMedium?.copyWith(
                            color: heroContent.withValues(alpha: 0.82),
                          ),
                        ),
                      ],
                      // Описание идёт перед метаданными — как в оригинале.
                      if (description != null &&
                          description!.trim().isNotEmpty) ...<Widget>[
                        const SizedBox(height: 8),
                        Text(
                          description!.trim(),
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(
                            color: heroContent.withValues(alpha: 0.76),
                          ),
                        ),
                      ],
                      if (meta != null && meta!.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: Text(
                            meta!,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                              color: heroContent.withValues(alpha: 0.62),
                            ),
                          ),
                        ),
                      ],
                      if (actions.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: actions,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Цвет содержимого героя: на светлой поверхности — `onSurface`, на тёмной —
/// белый. Соответствует `MediaDetailHero.kt:89-94` (там проверяется
/// `surfaceColor.luminance() > 0.5f`).
Color heroContentColor(ColorScheme scheme) =>
    scheme.surface.computeLuminance() > 0.5 ? scheme.onSurface : Colors.white;

/// Капсульная кнопка запуска воспроизведения в герое.
///
/// В ArchiveTune это `Button` высотой `ButtonDefaults.MediumContainerHeight`
/// (56) с текстом `titleMedium`, иконкой 24, зазором 8 и отступом 24, фон
/// `contentColor`, текст `contrastingColor` (Button.kt, ButtonMediumTokens).
class HeroPlayButton extends StatelessWidget {
  const HeroPlayButton({
    super.key,
    required this.label,
    required this.icon,
    this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final Color content = heroContentColor(scheme);

    return FilledButton.icon(
      style: FilledButton.styleFrom(
        shape: const StadiumBorder(),
        backgroundColor: content,
        foregroundColor: scheme.surface,
        minimumSize: const Size(0, 56),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        iconSize: 24,
        textStyle: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

/// Круглая кнопка-действие героя.
///
/// В ArchiveTune это `FilledTonalIconButton` с фоном `contentColor.copy(0.16)`
/// и содержимым `contentColor`; «главные» действия (перемешать, добавить)
/// используют размер 52, остальные — 48 (MediaDetailHero.kt:302-308, 603-604).
class HeroCircleButton extends StatelessWidget {
  const HeroCircleButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.size = 48,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color content = heroContentColor(scheme);
    final bool enabled = onPressed != null;

    return Tooltip(
      message: tooltip,
      child: SizedBox.square(
        dimension: size,
        child: Material(
          color: content.withValues(alpha: enabled ? 0.16 : 0.08),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Icon(
              icon,
              size: 22,
              color: content.withValues(alpha: enabled ? 1 : 0.38),
            ),
          ),
        ),
      ),
    );
  }
}

/// Разделитель метаданных героя — `MediaDetailMetadataSeparator` из
/// `AlbumScreen.kt:753` (два пробела, точка, два пробела).
const String mediaDetailMetadataSeparator = '  •  ';

/// Заглушка страницы медиа до загрузки: герой и несколько строк списка.
///
/// Повторяет форму `ShimmerHost` из ArchiveTune (`AlbumScreen.kt:512-578`,
/// `shimmer/ListItemPlaceHolder.kt`, `shimmer/TextPlaceholder.kt`): блок
/// высотой не меньше 560 с прижатым к низу содержимым и строки-заглушки.
/// Анимация «шиммера» не нужна — в приложении скелетоны статичные, поэтому
/// фигуры залиты `onSurface` с небольшой прозрачностью (в оригинале поверх
/// лежит шиммер-шейдер, из-за которого они не выглядят «намертво» белыми).
class MediaDetailSkeleton extends StatelessWidget {
  const MediaDetailSkeleton({super.key, this.rows = 6});

  final int rows;

  /// Высота строки списка — `ListItemHeight` из `constants/Dimensions.kt`.
  static const double _rowHeight = 72;

  /// Сторона обложки строки — `ListThumbnailSize`.
  static const double _thumbSize = 56;

  /// Радиус обложки строки — `ThumbnailCornerRadius`.
  static const double _thumbRadius = 10;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color fill = scheme.onSurface.withValues(alpha: 0.12);

    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      children: <Widget>[
        SizedBox(
          height: MediaHero.minHeight,
          width: double.infinity,
          child: Container(
            // Фон заглушки героя — `surfaceContainerLow` (AlbumScreen.kt:521).
            color: scheme.surfaceContainerLow,
            padding: const EdgeInsets.symmetric(
              horizontal: MediaHero.horizontalPadding,
              vertical: MediaHero.horizontalPadding,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                _textPlaceholder(fill, widthFactor: 0.55, height: 36),
                const SizedBox(height: 12),
                _textPlaceholder(fill, widthFactor: 0.40, height: 18),
                const SizedBox(height: 16),
                _textPlaceholder(fill, widthFactor: 0.72, height: 14),
                const SizedBox(height: 12),
                // Три фигуры действий: круглая 52, капсула 132×48, круглая 52
                // (AlbumScreen.kt:552-573).
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    _circle(fill, 52),
                    const SizedBox(width: 12),
                    Container(
                      width: 132,
                      height: 48,
                      decoration: BoxDecoration(
                        color: fill,
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _circle(fill, 52),
                  ],
                ),
              ],
            ),
          ),
        ),
        for (int i = 0; i < rows; i++) _listRow(fill),
      ],
    );
  }

  /// Круглая фигура действия.
  static Widget _circle(Color color, double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );

  /// Строка-заглушка списка — `ListItemPlaceHolder` из ArchiveTune.
  ///
  /// Высота 72, внешний отступ 6, обложка 56 с полями 6 и радиусом 10,
  /// подпись — две полосы высотой 16 (каждая с полем 4 сверху и снизу).
  static Widget _listRow(Color color) {
    return SizedBox(
      height: _rowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(6),
              child: Container(
                width: _thumbSize,
                height: _thumbSize,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(_thumbRadius),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _textPlaceholder(color, widthFactor: 0.62, height: 16),
                    _textPlaceholder(color, widthFactor: 0.38, height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Текстовая полоса — `TextPlaceholder` из ArchiveTune: квадратные углы,
  /// поле 4 по вертикали, ширина — доля доступного места.
  static Widget _textPlaceholder(
    Color color, {
    required double widthFactor,
    required double height,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: FractionallySizedBox(
        alignment: Alignment.center,
        widthFactor: widthFactor,
        child: Container(height: height, color: color),
      ),
    );
  }
}

/// Панель состояния страницы медиа: пусто, ошибка, «не найдено».
///
/// В ArchiveTune это `MediaDetailStatePanel` (`MediaDetailStatePanel.kt`):
/// по центру колонка шириной не больше 400 с круглой иконкой 72 на
/// `primaryContainer`, заголовком `headlineSmall` полужирным, описанием
/// `bodyLarge` цветом `onSurfaceVariant` и кнопкой действия.
class MediaDetailStatePanel extends StatelessWidget {
  const MediaDetailStatePanel({
    super.key,
    required this.title,
    required this.description,
    this.icon,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String description;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    icon,
                    size: 32,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Text(
                title,
                textAlign: TextAlign.center,
                style: text.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                description,
                textAlign: TextAlign.center,
                style: text.bodyLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (actionLabel != null && onAction != null) ...<Widget>[
                // В оригинале между описанием и кнопкой ещё `Spacer(4)`
                // поверх `spacedBy(12)` — итого 16.
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: onAction,
                  child: Text(actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// «1 ч 20 мин» / «45 мин» — длительность альбома или плейлиста.
///
/// Отдельный помощник, потому что [formatDuration] показывает время трека
/// (`1:20:00`), а в метаданных страницы принят человеческий вид.
String formatTotalDuration(Duration duration) {
  if (duration <= Duration.zero) return '';
  final int hours = duration.inHours;
  final int minutes = duration.inMinutes % 60;
  if (hours <= 0) return '$minutes мин';
  return minutes == 0 ? '$hours ч' : '$hours ч $minutes мин';
}
