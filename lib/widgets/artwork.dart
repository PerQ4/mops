import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../data/models/models.dart';

/// Обложка с дисковым кэшем и аккуратным плейсхолдером.
///
/// Единственное место, где приложение знает про `cached_network_image` —
/// при необходимости бэкенд кэша меняется здесь.
class Artwork extends StatelessWidget {
  const Artwork({
    super.key,
    required this.url,
    this.size,
    this.width,
    this.height,
    this.radius,
    this.fit = BoxFit.cover,
    this.heroTag,
    this.icon,
  });

  /// URL обложки; `null` — показываем заглушку.
  final String? url;

  /// Квадратная сторона (если не заданы отдельные width/height).
  final double? size;
  final double? width;
  final double? height;

  /// Скругление. По умолчанию — «мягкий квадрат» из темы.
  final BorderRadius? radius;
  final BoxFit fit;
  final Object? heroTag;

  /// Иконка-заглушка (для плейлистов/артистов уместна другая).
  final IconData? icon;

  double? get _w => width ?? size;
  double? get _h => height ?? size;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final BorderRadius shape = radius ?? BorderRadius.circular(12);

    Widget image = ClipRRect(
      borderRadius: shape,
      child: (url == null || url!.isEmpty)
          ? _placeholder(scheme)
          : CachedNetworkImage(
              imageUrl: url!,
              width: _w,
              height: _h,
              fit: fit,
              fadeInDuration: const Duration(milliseconds: 220),
              placeholder: (BuildContext context, String _) => _placeholder(scheme),
              errorWidget: (BuildContext context, String _, Object __) =>
                  _placeholder(scheme, broken: true),
            ),
    );

    if (heroTag != null) {
      image = Hero(tag: heroTag!, child: image);
    }
    return image;
  }

  Widget _placeholder(ColorScheme scheme, {bool broken = false}) {
    return Container(
      width: _w,
      height: _h,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        broken ? Icons.broken_image_outlined : (icon ?? Icons.music_note),
        size: (_w ?? _h ?? 48) * 0.4,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}

/// Обложка трека с учётом размера в списке.
class TrackArtwork extends StatelessWidget {
  const TrackArtwork({
    super.key,
    required this.track,
    this.size = 52,
    this.radius = 12,
  });

  final Track track;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Artwork(
      url: track.thumbnails.sized((size * 2).round()),
      size: size,
      radius: BorderRadius.circular(radius),
    );
  }
}

/// Открывает изображение так, чтобы из него можно было собрать палитру.
///
/// Возвращает `ImageProvider` для `ColorScheme.fromImageProvider`.
/// Поддерживает и сетевые обложки, и локальные файлы.
ImageProvider artworkProvider(String url) {
  if (url.startsWith('http://') || url.startsWith('https://')) {
    return CachedNetworkImageProvider(url);
  }
  return FileImage(File(url));
}
