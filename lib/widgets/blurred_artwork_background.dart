import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/utils/artwork_urls.dart';
import '../data/models/models.dart';
import 'artwork.dart';

/// Фон из обложки трека: размытая и затемнённая картинка под цвет темы.
///
/// Используется как подложка плеера (правой панели и полного экрана), когда в
/// настройках включён «размытый фон». Затемнение — градиентом темы, чтобы текст
/// и управление читались поверх любой обложки.
class BlurredArtworkBackground extends StatelessWidget {
  const BlurredArtworkBackground({
    super.key,
    required this.track,
    this.child,
    this.blurSigma = 28,
  });

  final Track track;
  final Widget? child;

  /// Сила размытия; больше — мягче и «глубже».
  final double blurSigma;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<String> variants = track.artworkFallbacks(kArtworkLarge);

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (variants.isNotEmpty)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
            child: Artwork(
              url: variants.first,
              fallbacks:
                  variants.length > 1 ? variants.sublist(1) : const <String>[],
              fit: BoxFit.cover,
              radius: BorderRadius.zero,
            ),
          ),
        // Затемнение: сильнее к низу, чтобы управление и очередь читались.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                scheme.surface.withValues(alpha: 0.72),
                scheme.surface.withValues(alpha: 0.92),
                scheme.surface,
              ],
              stops: const <double>[0.2, 0.6, 0.92],
            ),
          ),
        ),
        ?child,
      ],
    );
  }
}
