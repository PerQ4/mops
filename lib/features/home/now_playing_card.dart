import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/models/models.dart';
import '../../state/player_controller.dart';
import '../../widgets/artist_line.dart';
import '../../widgets/artwork.dart';
import '../../widgets/track_menu.dart';
import '../player/player_controls.dart';

/// Крупная карточка «сейчас играет» на главной — вид из десктопного Swiftify.
///
/// Данные берём из [playerControllerProvider]: что играет, идёт ли звук и
/// позицию. Без текущего трека карточки нет вовсе — выдумывать нечего.
///
/// Полоса прогресса — тот же [PlayerSeekBar], что и в плеере, только в
/// компактном виде: он сам берёт стиль из настроек (`ProgressBarStyle`) и
/// позицию из движка, поэтому волну здесь рисовать заново не нужно.
class NowPlayingCard extends ConsumerWidget {
  const NowPlayingCard({super.key});

  /// Обложка карточки: крупнее строки списка, но меньше шапки страницы.
  static const double _artworkSize = 96;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerUiState player = ref.watch(playerControllerProvider);
    final Track? track = player.current;
    if (track == null) return const SizedBox.shrink();

    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int artPhysical =
        (_artworkSize * MediaQuery.devicePixelRatioOf(context)).round();
    final List<String> variants = track.artworkFallbacks(artPhysical);
    final String? album = track.album?.name;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppLayout.radiusL),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: <Widget>[
                  Artwork(
                    url: variants.isEmpty ? null : variants.first,
                    fallbacks: variants.length > 1
                        ? variants.sublist(1)
                        : const <String>[],
                    size: _artworkSize,
                    radius: BorderRadius.circular(AppLayout.radiusM),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        // Надпись-ярлык как в Swiftify: мелкая, разреженная,
                        // цветом акцента.
                        Text(
                          'NOW PLAYING',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.labelSmall?.copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        ArtistLine(
                          artists: track.artists,
                          maxLines: 1,
                          style: text.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        // Альбом — только если YouTube его отдал и он не
                        // повторяет название (у синглов они совпадают).
                        if (album != null &&
                            album.isNotEmpty &&
                            album != track.title) ...<Widget>[
                          const SizedBox(height: 2),
                          Text(
                            album,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Пауза/играть — крупной кнопкой: карточка и есть мини-плеер.
                  IconButton.filled(
                    tooltip: player.isPlaying ? 'Пауза' : 'Играть',
                    iconSize: 26,
                    onPressed: ref
                        .read(playerControllerProvider.notifier)
                        .togglePlayPause,
                    icon: player.isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          )
                        : Icon(
                            player.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                  ),
                  IconButton(
                    tooltip: 'Действия',
                    icon: const Icon(Icons.more_vert),
                    onPressed: () => showTrackMenu(context, track),
                  ),
                ],
              ),
            ),
          ),
          // Полоса перемотки идёт сразу под карточкой — как волна в Swiftify.
          PlayerSeekBar(player: player, compact: true),
        ],
      ),
    );
  }
}
