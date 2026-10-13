import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';


/// Обложка с кэшем, заглушкой и запасными ссылками.
///
/// Запасные ссылки важны: у части видео нет максимального превью
/// (`maxresdefault`), и сервер отвечает 404. Без отката такая обложка
/// показывалась бы заглушкой, поэтому при ошибке виджет пробует следующий
/// вариант из списка — от большего к меньшему.
class Artwork extends StatefulWidget {
  const Artwork({
    super.key,
    required this.url,
    this.fallbacks = const <String>[],
    this.size,
    this.width,
    this.height,
    this.radius,
    this.fit = BoxFit.cover,
    this.heroTag,
    this.icon,
  });

  /// Основная ссылка; `null` — показываем заглушку.
  final String? url;

  /// Варианты на случай, если основная ссылка недоступна.
  final List<String> fallbacks;

  final double? size;
  final double? width;
  final double? height;
  final BorderRadius? radius;
  final BoxFit fit;
  final Object? heroTag;
  final IconData? icon;

  /// Все ссылки по порядку: основная и запасные, начиная с текущей.
  List<String> get _variants => <String>[
        if (url != null && url!.isNotEmpty) url!,
        ...fallbacks.where((String f) => f.isNotEmpty && f != url),
      ];

  @override
  State<Artwork> createState() => _ArtworkState();
}

class _ArtworkState extends State<Artwork> {
  /// Индекс текущей пробуемой ссылки.
  int _attempt = 0;

  @override
  void didUpdateWidget(covariant Artwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Сменилась обложка — начинаем пробовать заново с первой ссылки.
    if (oldWidget.url != widget.url) _attempt = 0;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final BorderRadius shape =
        widget.radius ?? BorderRadius.circular(12);
    final double? w = widget.width ?? widget.size;
    final double? h = widget.height ?? widget.size;

    final List<String> variants = widget._variants;
    final bool hasImage = variants.isNotEmpty && _attempt < variants.length;

    Widget image = ClipRRect(
      borderRadius: shape,
      child: hasImage
          ? CachedNetworkImage(
              imageUrl: variants[_attempt],
              width: w,
              height: h,
              fit: widget.fit,
              fadeInDuration: const Duration(milliseconds: 150),
              placeholder: (BuildContext context, String _) =>
                  _placeholder(scheme),
              errorWidget: (BuildContext context, String url, Object error) {
                // Переходим к следующему варианту, если он есть.
                if (_attempt + 1 < variants.length) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _attempt++);
                  });
                }
                // Все варианты исчерпаны — вот это уже «битая картинка».
                return _placeholder(
                  scheme,
                  broken: _attempt + 1 >= variants.length,
                );
              },
            )
          // Ссылки нет вовсе — это не «битая картинка», а обычная заглушка.
          : _placeholder(scheme),
    );

    if (widget.heroTag != null) {
      image = Hero(tag: widget.heroTag!, child: image);
    }
    return image;
  }

  Widget _placeholder(ColorScheme scheme, {bool broken = false}) {
    final double side = widget.size ?? widget.width ?? widget.height ?? 48;
    return Container(
      width: widget.width ?? widget.size,
      height: widget.height ?? widget.size,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        broken ? Icons.broken_image_outlined : (widget.icon ?? Icons.music_note),
        size: side * 0.36,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}

/// Приводит ссылку к `ImageProvider` — например, для палитры из обложки.
ImageProvider artworkProvider(String url) {
  if (url.startsWith('http://') || url.startsWith('https://')) {
    return CachedNetworkImageProvider(url);
  }
  return FileImage(File(url));
}
