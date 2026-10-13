import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/layout.dart';
import '../core/utils/format.dart';
import '../data/models/models.dart';
import '../state/player_controller.dart';
import 'artwork.dart';

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

    final Color titleColor = isCurrent ? scheme.primary : scheme.onSurface;
    final double artworkSize = AppLayout.trackArtwork;

    return SizedBox(
      height: AppLayout.trackRowHeight,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppLayout.gutter),
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
                                ? scheme.primary
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
                        color: scheme.onSurfaceVariant.withValues(
                          alpha: isDimmed ? 0.6 : 1,
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
                  onPressed: onMenu ?? () => showTrackActions(context, track),
                ),
              ],
            ],
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

    return Opacity(
      opacity: isDimmed ? 0.5 : 1,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Artwork(
            url: track.thumbnails.sized((size * 2).round()),
            size: size,
            radius: BorderRadius.circular(AppLayout.trackArtworkRadius),
          ),
          if (isCurrent)
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: scheme.scrim.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(
                  AppLayout.trackArtworkRadius,
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

/// Типовые действия над треком. Одна реализация на всё приложение.
Future<void> showTrackActions(BuildContext context, Track track) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext sheetContext) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded),
              title: const Text('Играть сейчас'),
              onTap: () {
                Navigator.pop(sheetContext);
                playNow(sheetContext, track);
              },
            ),
            ListTile(
              leading: const Icon(Icons.queue_play_next),
              title: const Text('Играть следующим'),
              onTap: () {
                Navigator.pop(sheetContext);
                playNext(sheetContext, track);
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('В конец очереди'),
              onTap: () {
                Navigator.pop(sheetContext);
                addToQueue(sheetContext, track);
              },
            ),
          ],
        ),
      );
    },
  );
}

/// Обёртки, чтобы действия можно было вызывать и из списков, и из меню.
void playNow(BuildContext context, Track track) {
  final ProviderContainer container = ProviderScope.containerOf(context);
  container.read(playerControllerProvider.notifier).playTrack(track);
}

void playNext(BuildContext context, Track track) {
  final ProviderContainer container = ProviderScope.containerOf(context);
  container.read(playerControllerProvider.notifier).playNext(track);
}

void addToQueue(BuildContext context, Track track) {
  final ProviderContainer container = ProviderScope.containerOf(context);
  container.read(playerControllerProvider.notifier).enqueue(track);
}
