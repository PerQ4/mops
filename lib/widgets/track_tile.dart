import 'package:flutter/material.dart';

import '../core/theme/layout.dart';
import '../core/utils/format.dart';
import '../data/models/models.dart';
import 'artwork.dart';
import 'track_menu.dart';

/// Строка трека в списке.
///
/// Форма взята у ArchiveTune: крупная обложка, название и исполнитель двумя
/// строками, справа длительность и меню. Никаких «прыгающих» размеров —
/// высота строки зафиксирована, поэтому список не дёргается при прокрутке
/// и при изменении системного масштаба.
class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    this.onTap,
    this.onMenu,
    this.trailing,
    this.isCurrent = false,
    this.isPlaying = false,
    this.isDimmed = false,
    this.subtitleOverride,
    this.showDuration = true,
    this.leadingNumber,
  });

  final Track track;
  final VoidCallback? onTap;

  /// Действие кнопки «три точки». Если не задано — показывается меню
  /// с типовыми действиями.
  final VoidCallback? onMenu;
  final Widget? trailing;

  final bool isCurrent;
  final bool isPlaying;

  /// Приглушённый вид — для уже проигранных треков.
  final bool isDimmed;
  final String? subtitleOverride;
  final bool showDuration;

  /// Показывать номер вместо обложки (страницы альбомов и плейлистов).
  final int? leadingNumber;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    // Активная строка идёт на `secondaryContainer`, поэтому цвет текста —
    // `onSecondaryContainer`, а не `primary`: иначе подпись сливается с фоном.
    final Color titleColor =
        isCurrent ? scheme.onSecondaryContainer : scheme.onSurface;
    final Color subtitleColor = isCurrent
        ? scheme.onSecondaryContainer.withValues(alpha: 0.7)
        : scheme.onSurfaceVariant;
    final double artworkSize = AppLayout.trackArtwork;

    // Одна точка входа в меню: и кнопка «…», и долгое нажатие открывают одно
    // и то же, поэтому действие не приходится искать по интерфейсу.
    final VoidCallback openMenu =
        onMenu ?? () => showTrackMenu(context, track);

    return SizedBox(
      height: AppLayout.trackRowHeight,
      // Внешний отступ строки — 8 по спецификации; внутренний добираем до
      // прежних 20, чтобы обложка не съезжала относительно заголовков секций.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Material(
          // Активная строка подсвечивается `secondaryContainer`, радиус 12.
          color: isCurrent ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(AppLayout.radiusS),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: openMenu,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: artworkSize,
                    height: artworkSize,
                    child: leadingNumber != null
                        ? Center(
                            child: Text(
                              '$leadingNumber',
                              style: text.titleSmall?.copyWith(
                                color: isCurrent
                                    ? scheme.onSecondaryContainer
                                    : scheme.onSurfaceVariant,
                                fontFeatures: const <FontFeature>[
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          )
                        : _Leading(
                            track: track,
                            size: artworkSize,
                            isCurrent: isCurrent,
                            isPlaying: isPlaying,
                            isDimmed: isDimmed,
                          ),
                  ),
                  const SizedBox(width: 14),
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
                            color: isDimmed
                                ? titleColor.withValues(alpha: 0.6)
                                : titleColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitleOverride ?? _subtitle(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(
                            color: subtitleColor.withValues(
                              alpha: isDimmed
                                  ? subtitleColor.a * 0.6
                                  : subtitleColor.a,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (trailing != null)
                    trailing!
                  else ...<Widget>[
                    if (showDuration && track.duration > Duration.zero)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          formatDuration(track.duration),
                          style: text.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                    IconButton(
                      tooltip: 'Действия',
                      iconSize: 20,
                      color: scheme.onSurfaceVariant,
                      icon: const Icon(Icons.more_vert),
                      onPressed: openMenu,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _subtitle() {
    final List<String> parts = <String>[];
    if (track.artists.isNotEmpty) {
      parts.add(cleanArtistName(track.artistLine));
    }
    final String? album = track.album?.name;
    if (album != null && album.isNotEmpty && album != track.title) {
      parts.add(album);
    }
    return parts.isEmpty ? 'Неизвестный исполнитель' : parts.join(' • ');
  }
}

/// Обложка с индикатором воспроизведения поверх неё.
class _Leading extends StatelessWidget {
  const _Leading({
    required this.track,
    required this.size,
    required this.isCurrent,
    required this.isPlaying,
    required this.isDimmed,
  });

  final Track track;
  final double size;
  final bool isCurrent;
  final bool isPlaying;
  final bool isDimmed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Обложку просим под плотность экрана: ссылка переписывается на нужный
    // размер, поэтому картинка не растягивается из мелкого превью.
    final int physical =
        (size * MediaQuery.devicePixelRatioOf(context)).round();
    final List<String> variants = track.artworkFallbacks(physical);

    return Opacity(
      opacity: isDimmed ? 0.5 : 1,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Artwork(
            url: variants.isEmpty ? null : variants.first,
            fallbacks:
                variants.length > 1 ? variants.sublist(1) : const <String>[],
            size: size,
            radius: BorderRadius.circular(AppLayout.thumbnailRadius),
          ),
          if (isCurrent)
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: scheme.scrim.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(
                  AppLayout.thumbnailRadius,
                ),
              ),
              child: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: scheme.onPrimary,
                size: 26,
              ),
            ),
        ],
      ),
    );
  }
}

