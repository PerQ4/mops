import 'package:flutter/material.dart';

import '../core/utils/format.dart';
import '../data/models/models.dart';
import 'artwork.dart';

/// Строка трека в списке: обложка, название, исполнитель, длительность.
class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    this.onTap,
    this.onLongPress,
    this.trailing,
    this.leadingIndex,
    this.showArtwork = true,
    this.isCurrent = false,
    this.isPlaying = false,
    this.dense = false,
    this.showDuration = true,
    this.subtitleOverride,
  });

  final Track track;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Свой trailing (например, кнопка «лайк»). Если не задан — длительность.
  final Widget? trailing;

  /// Если задан — вместо обложки показывается номер позиции.
  final int? leadingIndex;
  final bool showArtwork;

  /// Совпадает ли с текущим треком в плеере.
  final bool isCurrent;
  final bool isPlaying;
  final bool dense;
  final bool showDuration;
  final String? subtitleOverride;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    final Color titleColor =
        isCurrent ? scheme.primary : scheme.onSurface;

    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      dense: dense,
      visualDensity: dense ? VisualDensity.compact : VisualDensity.standard,
      leading: _buildLeading(scheme, text),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: text.bodyLarge?.copyWith(
          color: titleColor,
          fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
      subtitle: Text(
        subtitleOverride ?? _subtitle(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
      trailing: trailing ??
          (showDuration
              ? Text(
                  formatDuration(track.duration),
                  style: text.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                )
              : null),
    );
  }

  Widget? _buildLeading(ColorScheme scheme, TextTheme text) {
    if (leadingIndex != null) {
      return SizedBox(
        width: 40,
        child: Center(
          child: isCurrent && isPlaying
              ? _NowPlayingBars(color: scheme.primary)
              : Text(
                  '$leadingIndex',
                  style: text.labelLarge?.copyWith(
                    color: isCurrent ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
        ),
      );
    }

    if (!showArtwork) return null;

    return SizedBox(
      width: 52,
      height: 52,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          TrackArtwork(track: track),
          if (isCurrent)
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: scheme.scrim.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                isPlaying ? Icons.graphic_eq : Icons.pause,
                color: scheme.onPrimary,
                size: 22,
              ),
            ),
        ],
      ),
    );
  }

  String _subtitle() {
    final StringBuffer buffer = StringBuffer();
    if (track.artists.isNotEmpty) {
      buffer.write(cleanArtistName(track.artistLine));
    }
    final String? album = track.album?.name;
    if (album != null && album.isNotEmpty) {
      if (buffer.isNotEmpty) buffer.write(' • ');
      buffer.write(album);
    }
    if (track.isVideo && buffer.isNotEmpty) buffer.write(' • видео');
    return buffer.isEmpty ? 'Неизвестный исполнитель' : buffer.toString();
  }
}

/// Три прыгающие полоски — индикатор «сейчас играет».
class _NowPlayingBars extends StatefulWidget {
  const _NowPlayingBars({required this.color});

  final Color color;

  @override
  State<_NowPlayingBars> createState() => _NowPlayingBarsState();
}

class _NowPlayingBarsState extends State<_NowPlayingBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 16,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List<Widget>.generate(3, (int i) {
              // Разные фазы дают эффект «эквалайзера».
              final double phase = (_controller.value + i * 0.33) % 1.0;
              final double h = 4 + (phase < 0.5 ? phase : 1 - phase) * 24;
              return Container(
                width: 3,
                height: h.clamp(4, 16),
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
