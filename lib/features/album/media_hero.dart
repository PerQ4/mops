import 'package:flutter/material.dart';

import '../../widgets/artwork.dart';

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
    this.meta,
    this.description,
    this.imageUrl,
    this.fallbackIcon,
    this.actions = const <Widget>[],
  });

  final String title;

  /// Подпись под названием: исполнитель или автор.
  final String? subtitle;

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

  /// Отступ содержимого героя — `MediaDetailHero.kt` (`MediaDetailHorizontalPadding`).
  static const double horizontalPadding = 24;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // В ArchiveTune цвет содержимого героя выбирается по яркости поверхности:
    // на тёмной теме это белый, на светлой — `onSurface` (MediaDetailHero.kt:89).
    final Color heroContent = heroContentColor(scheme);

    return Stack(
      children: <Widget>[
        // Обложка на всю ширину героя.
        Positioned.fill(
          child: Artwork(
            url: imageUrl,
            // Размер задан только ради крупной иконки-заглушки: в
            // `Positioned.fill` картинка всё равно растягивается по контейнеру.
            size: 200,
            radius: BorderRadius.zero,
            fit: BoxFit.cover,
            icon: fallbackIcon,
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
        // Единственный непозиционированный ребёнок задаёт высоту героя:
        // `SizedBox` фиксирует минимум 560, а `Align` прижимает содержимое
        // вниз — иначе `Stack` сжался бы по контенту и текст оказался сверху.
        SizedBox(
          height: minHeight,
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.all(horizontalPadding),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: contentWidth),
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
                    if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
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
      ],
    );
  }
}

/// Цвет содержимого героя: на тёмной поверхности — белый, на светлой —
/// `onSurface`. Соответствует `MediaDetailHero.kt:89-94`.
Color heroContentColor(ColorScheme scheme) =>
    scheme.brightness == Brightness.dark ? Colors.white : scheme.onSurface;

/// Капсульная кнопка запуска воспроизведения в герое.
///
/// В ArchiveTune это `Button` высотой `ButtonDefaults.MediumContainerHeight`
/// (56) с фоном `contentColor` и текстом `contrastingColor`
/// (MediaDetailHero.kt:359-386).
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
    final Color content = heroContentColor(scheme);

    return FilledButton.icon(
      style: FilledButton.styleFrom(
        shape: const StadiumBorder(),
        backgroundColor: content,
        foregroundColor: scheme.surface,
        minimumSize: const Size(0, 56),
        padding: const EdgeInsets.symmetric(horizontal: 24),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 22),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
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

/// Скелетон страницы медиа до загрузки: герой и несколько строк списка.
///
/// Повторяет форму `ShimmerHost` из ArchiveTune (`AlbumScreen.kt:512-578`):
/// блок высотой не меньше 560 с прижатым к низу содержимым и строки-заглушки.
/// Анимация «шиммера» не нужна — в приложении скелетоны статичные.
class MediaDetailSkeleton extends StatelessWidget {
  const MediaDetailSkeleton({super.key, this.rows = 6});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color fill = scheme.surfaceContainerHighest;

    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      children: <Widget>[
        SizedBox(
          height: MediaHero.minHeight,
          width: double.infinity,
          child: Container(
            color: scheme.surfaceContainerLow,
            padding: const EdgeInsets.all(MediaHero.horizontalPadding),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                _bar(fill, widthFactor: 0.55, height: 36),
                const SizedBox(height: 12),
                _bar(fill, widthFactor: 0.40, height: 18),
                const SizedBox(height: 16),
                _bar(fill, widthFactor: 0.72, height: 14),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Container(
                      width: 52,
                      height: 52,
                      decoration:
                          BoxDecoration(color: fill, shape: BoxShape.circle),
                    ),
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
                    Container(
                      width: 52,
                      height: 52,
                      decoration:
                          BoxDecoration(color: fill, shape: BoxShape.circle),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        for (int i = 0; i < rows; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: <Widget>[
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _bar(fill, widthFactor: 0.6, height: 14),
                      const SizedBox(height: 8),
                      _bar(fill, widthFactor: 0.35, height: 12),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static Widget _bar(Color color, {required double widthFactor, required double height}) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
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
