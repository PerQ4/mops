import 'package:flutter/material.dart';

import '../../widgets/artwork.dart';

/// «Герой» страницы медиа: альбом, исполнитель, плейлист.
///
/// Форма взята у ArchiveTune: обложка на всю ширину, поверх неё затемняющий
/// градиент, а внизу по центру — название, подпись, метаданные и действия.
///
/// Почему отдельный виджет, а не общий `PageHeader`: герой принципиально
/// другой — он занимает всю ширину и минимум 560 по высоте, тогда как
/// `PageHeader` остаётся компактной шапкой. Держим одну реализацию на три
/// страницы, чтобы они не разъезжались по оформлению.
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

  /// Минимальная высота героя и ширина текстового блока — из спецификации.
  static const double minHeight = 560;
  static const double contentWidth = 720;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

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
        // Тёмный верх, прозрачная середина и переход в цвет поверхности
        // снизу — так текст и действия всегда читаются поверх картинки.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Colors.black.withValues(alpha: 0.42),
                  Colors.transparent,
                  scheme.surface.withValues(alpha: 0.78),
                ],
                stops: const <double>[0, 0.55, 1],
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
            padding: const EdgeInsets.all(24),
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
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        subtitle!,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.82),
                        ),
                      ),
                    ],
                    if (meta != null && meta!.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        meta!,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.labelMedium?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.62),
                        ),
                      ),
                    ],
                    if (description != null &&
                        description!.trim().isNotEmpty) ...<Widget>[
                      const SizedBox(height: 10),
                      Text(
                        description!.trim(),
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.78),
                        ),
                      ),
                    ],
                    if (actions.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 20),
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

/// Капсульная кнопка запуска воспроизведения в герое.
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
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        shape: const StadiumBorder(),
        minimumSize: const Size(0, 52),
        padding: const EdgeInsets.symmetric(horizontal: 28),
      ),
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

/// Круглая кнопка-действие героя.
///
/// Диаметр по умолчанию — 48; «главные» действия (перемешать, добавить)
/// передают 52, как в спецификации.
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

    return Tooltip(
      message: tooltip,
      child: SizedBox.square(
        dimension: size,
        child: Material(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.72),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Icon(
              icon,
              size: size * 0.44,
              color: scheme.onSurface
                  .withValues(alpha: onPressed == null ? 0.38 : 1),
            ),
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
