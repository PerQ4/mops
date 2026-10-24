import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../core/utils/format.dart';
import '../../data/models/models.dart';
import '../../state/player_controller.dart';
import '../../widgets/artist_line.dart';
import '../../widgets/artwork.dart';
import '../../widgets/track_menu.dart';

/// Горизонтальный отступ содержимого страницы медиа на широком окне.
///
/// Страница не растягивается на всю ширину окна: содержимое живёт колонкой
/// [AppLayout.mediaContentMaxWidth] по центру. Отступ считают и баннер, и
/// список, поэтому функция общая — иначе обложка и строки разъехались бы.
double mediaContentInset(double pageWidth) {
  final double centered = (pageWidth - AppLayout.mediaContentMaxWidth) / 2;
  return centered > AppLayout.gutter ? centered : AppLayout.gutter;
}

/// Шапка-баннер страницы медиа на широком окне.
///
/// Фон — размытая обложка, уходящая в цвет поверхности; поверх неё слева
/// обложка, справа название, подпись, метаданные и действия. Высота не
/// фиксированная: [minHeight] задаёт нижнюю границу, а длинное название может
/// баннер вырастить — обрезать его ради ровных 280 нельзя.
class MediaBanner extends StatelessWidget {
  const MediaBanner({
    super.key,
    required this.title,
    this.label,
    this.subtitle,
    this.artists,
    this.meta,
    this.metaSecondary,
    this.imageUrl,
    this.fallbackIcon,
    this.circular = false,
    this.actions = const <Widget>[],
  });

  final String title;

  /// Надпись над названием: «Альбом», «Плейлист», «Исполнитель».
  final String? label;

  /// Подпись, если исполнителей-ссылок нет (автор плейлиста).
  final String? subtitle;

  /// Исполнители-ссылки: подпись собирается кликабельной.
  final List<ArtistRef>? artists;

  /// Строка метаданных: «2024  •  12 треков  •  45 мин».
  final String? meta;

  /// Вторая строка метаданных — у исполнителя это каталог.
  final String? metaSecondary;

  final String? imageUrl;
  final IconData? fallbackIcon;

  /// Круглая обложка — для исполнителя.
  final bool circular;

  final List<Widget> actions;

  static const double minHeight = AppLayout.mediaBannerMinHeight;

  /// Сторона обложки в баннере — та же, что у шапки страницы.
  static const double coverSize = AppLayout.headerArtwork;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool hasArtists = artists != null && artists!.isNotEmpty;
    final bool hasSubtitle = subtitle != null && subtitle!.trim().isNotEmpty;
    final bool hasMeta = meta != null && meta!.trim().isNotEmpty;
    final bool hasSecondary =
        metaSecondary != null && metaSecondary!.trim().isNotEmpty;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double inset = mediaContentInset(constraints.maxWidth);
        // +12 — тот же внутренний отступ, что у шапки списка и заголовков
        // секций: обложка баннера должна стоять в одной линии с ними.
        final double horizontal = inset + 12;
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: _BannerBackdrop(
                imageUrl: imageUrl,
                fallbackIcon: fallbackIcon,
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: minHeight),
              child: Padding(
                padding: EdgeInsets.fromLTRB(horizontal, 8, horizontal, 24),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      _BannerCover(
                        imageUrl: imageUrl,
                        fallbackIcon: fallbackIcon,
                        circular: circular,
                      ),
                      const SizedBox(width: 28),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            if (label != null) ...<Widget>[
                              Text(
                                label!.toUpperCase(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1.4,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                            Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: text.displaySmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                height: 1.08,
                                letterSpacing: -0.5,
                                color: scheme.onSurface,
                              ),
                            ),
                            if (hasArtists) ...<Widget>[
                              const SizedBox(height: 8),
                              ArtistLine(
                                artists: artists!,
                                maxLines: 1,
                                style: text.titleMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ] else if (hasSubtitle) ...<Widget>[
                              const SizedBox(height: 8),
                              Text(
                                subtitle!.trim(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.titleMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                            if (hasMeta) ...<Widget>[
                              const SizedBox(height: 10),
                              Text(
                                meta!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w500,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                            if (hasSecondary) ...<Widget>[
                              SizedBox(height: hasMeta ? 4 : 10),
                              Text(
                                metaSecondary!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w500,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                            if (actions.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 20),
                              Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: actions,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Обложка баннера: тень отделяет её от размытого фона.
class _BannerCover extends StatelessWidget {
  const _BannerCover({
    required this.imageUrl,
    required this.fallbackIcon,
    required this.circular,
  });

  final String? imageUrl;
  final IconData? fallbackIcon;
  final bool circular;

  @override
  Widget build(BuildContext context) {
    const double size = MediaBanner.coverSize;
    final BorderRadius radius = BorderRadius.circular(
      circular ? size / 2 : AppLayout.radiusL,
    );

    return Artwork(
      url: imageUrl,
      // Для заглушки размер иконки: сам квадрат задаёт `size`.
      size: size,
      radius: radius,
      fit: BoxFit.cover,
      icon: fallbackIcon ?? (circular ? Icons.person : null),
    );
  }
}

/// Фон баннера: размытая обложка под градиентом цвета поверхности.
///
/// Без градиента текст на светлой обложке не читался бы; к низу он доходит до
/// чистого цвета поверхности, поэтому список под баннером начинается без шва.
class _BannerBackdrop extends StatelessWidget {
  const _BannerBackdrop({required this.imageUrl, required this.fallbackIcon});

  final String? imageUrl;
  final IconData? fallbackIcon;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool hasImage = imageUrl != null && imageUrl!.isNotEmpty;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (hasImage)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 42, sigmaY: 42),
            child: Artwork(
              url: imageUrl,
              size: 200,
              radius: BorderRadius.zero,
              fit: BoxFit.cover,
            ),
          )
        else
          ColoredBox(
            color: scheme.surfaceContainerHigh,
            child: Center(
              child: Icon(
                fallbackIcon ?? Icons.music_note,
                size: 96,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
              ),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                scheme.surface.withValues(alpha: 0.58),
                scheme.surface.withValues(alpha: 0.82),
                scheme.surface,
              ],
              stops: const <double>[0, 0.62, 1],
            ),
          ),
        ),
      ],
    );
  }
}

/// Описание страницы на широком окне: две строки и «Показать полностью».
///
/// Кнопка появляется, только если текст действительно не помещается: иначе
/// короткое описание получало бы бесполезное действие.
class MediaDescription extends StatefulWidget {
  const MediaDescription({super.key, required this.text});

  final String text;

  /// Строк в свёрнутом виде.
  static const int collapsedLines = 2;

  @override
  State<MediaDescription> createState() => _MediaDescriptionState();
}

class _MediaDescriptionState extends State<MediaDescription> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle? style = text.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final String content = widget.text.trim();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // Мерим уже с учётом собственных отступов блока: иначе текст,
          // который не влезает в реальную ширину, считался бы помещающимся,
          // и «Показать полностью» не появлялось.
          final TextPainter measure = TextPainter(
            text: TextSpan(text: content, style: style),
            maxLines: MediaDescription.collapsedLines,
            textDirection: Directionality.of(context),
          )..layout(maxWidth: constraints.maxWidth);
          final bool overflows = measure.didExceedMaxLines;
          measure.dispose();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                content,
                maxLines: _expanded ? null : MediaDescription.collapsedLines,
                overflow: _expanded ? null : TextOverflow.ellipsis,
                style: style,
              ),
              if (overflows || _expanded)
                TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.only(top: 6),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(_expanded ? 'Свернуть' : 'Показать полностью'),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Шапка широкого списка: номер, название, длительность.
///
/// Колонки совпадают по ширине со строкой [MediaTrackRow], поэтому подписи
/// стоят ровно над своими значениями.
class MediaTrackListHeader extends StatelessWidget {
  const MediaTrackListHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle? style = Theme.of(context).textTheme.labelSmall?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: 0.8,
      color: scheme.onSurfaceVariant,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Container(
        height: AppLayout.mediaTrackHeaderHeight,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
        ),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: AppLayout.mediaTrackNumberWidth,
              child: Text('#', textAlign: TextAlign.right, style: style),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text('Название', style: style)),
            const SizedBox(width: 12),
            SizedBox(
              width: AppLayout.mediaTrackDurationWidth,
              child: Text(
                'Длительность',
                textAlign: TextAlign.right,
                style: style,
              ),
            ),
            const SizedBox(width: AppLayout.mediaTrackActionWidth),
          ],
        ),
      ),
    );
  }
}

/// Строка трека в широком списке.
///
/// Это не [TrackTile]: там строка живёт с обложкой и длительностью в подписи,
/// а на широком окне нужны колонки — номер, название и отдельная длительность.
/// Обложка в строке при этом не нужна: таблица читается по названиям.
class MediaTrackRow extends ConsumerWidget {
  const MediaTrackRow({
    super.key,
    required this.track,
    required this.number,
    this.isCurrent = false,
    this.isPlaying = false,
    this.onTap,
    this.onMenu,
    this.trailing,
  });

  final Track track;
  final int number;
  final bool isCurrent;
  final bool isPlaying;
  final VoidCallback? onTap;

  /// Действие «…»; по умолчанию открывается меню трека.
  final VoidCallback? onMenu;

  /// Свой хвост строки (в плейлисте — удаление и меню).
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool unavailable = ref.watch(
      playerControllerProvider.select(
        (PlayerUiState s) => s.unavailableIds.contains(track.id),
      ),
    );

    final Color titleColor = isCurrent
        ? scheme.onSecondaryContainer
        : scheme.onSurface;
    final Color subtitleColor = isCurrent
        ? scheme.onSecondaryContainer.withValues(alpha: 0.7)
        : scheme.onSurfaceVariant;

    void openMenu({Offset? position}) {
      if (onMenu != null) {
        onMenu!();
      } else {
        showTrackMenu(context, track, position: position);
      }
    }

    return SizedBox(
      height: AppLayout.mediaTrackRowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Material(
          color: isCurrent ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(AppLayout.radiusS),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: openMenu,
            // Правый клик — то же меню, что и «…»: на десктопе это привычный
            // способ, а искать кнопку в строке никто не хочет.
            onSecondaryTapUp: (TapUpDetails details) =>
                openMenu(position: details.globalPosition),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: AppLayout.mediaTrackNumberWidth,
                  child: isCurrent
                      ? Icon(
                          isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 20,
                          color: scheme.primary,
                        )
                      : Text(
                          '$number',
                          textAlign: TextAlign.right,
                          style: text.labelLarge?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyLarge?.copyWith(
                          color: titleColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: ArtistLine(
                              artists: track.artists,
                              maxLines: 1,
                              style: text.bodySmall?.copyWith(
                                color: subtitleColor,
                              ),
                            ),
                          ),
                          if (unavailable)
                            Text(
                              ' • Недоступен',
                              maxLines: 1,
                              style: text.bodySmall?.copyWith(
                                color: scheme.error,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: AppLayout.mediaTrackDurationWidth,
                  child: Text(
                    track.duration > Duration.zero
                        ? formatDuration(track.duration)
                        : '',
                    textAlign: TextAlign.right,
                    style: text.bodySmall?.copyWith(
                      color: subtitleColor,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: AppLayout.mediaTrackActionWidth,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child:
                        trailing ??
                        IconButton(
                          tooltip: 'Действия',
                          iconSize: 18,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 36,
                            height: 36,
                          ),
                          color: scheme.onSurfaceVariant,
                          icon: const Icon(Icons.more_vert),
                          onPressed: () => openMenu(),
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
