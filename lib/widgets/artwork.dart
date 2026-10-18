import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/theme/motion.dart';


/// Тег [Hero] для обложки плеера.
///
/// Связывает круглую миниатюру в островке с крупной обложкой полноэкранного
/// плеера: при развороте и сворачивании картинка не «подменяется», а перелетает
/// и вырастает. Тег один на приложение, но одновременно в дереве живёт ровно
/// одна обложка с ним в каждом маршруте (островок и полный экран не видны
/// в одном маршруте), поэтому конфликта нет.
const String kPlayerArtworkHeroTag = 'player-artwork';


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

    // Содержимое обложки без скругления. Его же переиспользует перелёт
    // [Hero]: тогда меняется только радиус, а картинка не пересобирается.
    final Widget content = hasImage
        ? CachedNetworkImage(
            imageUrl: variants[_attempt],
            width: w,
            height: h,
            fit: widget.fit,
            // Появление обложки — тот же темп, что у остальных проявлений:
            // картинка из кэша не «мигает», а проявляется.
            fadeInDuration: AppMotion.artworkFade.duration,
            fadeInCurve: AppMotion.artworkFade.curve,
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
        : _placeholder(scheme);

    Widget image = ClipRRect(borderRadius: shape, child: content);

    if (widget.heroTag != null) {
      image = Hero(
        tag: widget.heroTag!,
        // Перелёт обложки: изображение растягивается по промежуточному
        // прямоугольнику (`fit`), а скругление плавно переходит от круглой
        // миниатюры островка к квадрату полного экрана — и обратно.
        flightShuttleBuilder: _flightShuttle,
        child: image,
      );
    }
    return image;
  }

  /// «Летящая» обложка: содержимое целевого `Hero` в скруглении,
  /// промежуточном между миниатюрой плеера и полноэкранной картинкой.
  Widget _flightShuttle(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection flightDirection,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    final BorderRadius from = _heroRadius(fromHeroContext);
    final BorderRadius to = _heroRadius(toHeroContext);
    // Содержимое без скругления берём у целевого `Hero` (он летит), при
    // отсутствии — у исходного.
    final Widget? content =
        _heroContent(toHeroContext) ?? _heroContent(fromHeroContext);
    // Скругление идёт по кривой перелёта, а не линейно, как анимация маршрута:
    // иначе углы «плывут» ровно и картинка выглядит вклеенной.
    final Animation<double> flight =
        animation.drive(AppMotion.heroFlight.tween);
    return AnimatedBuilder(
      animation: flight,
      child: content,
      builder: (BuildContext context, Widget? child) => ClipRRect(
        borderRadius: BorderRadius.lerp(from, to, flight.value)!,
        child: child,
      ),
    );
  }

  /// Скругление, с которым обложка лежит в дереве указанного `Hero`.
  static BorderRadius _heroRadius(BuildContext heroContext) {
    final Widget hero = heroContext.widget;
    if (hero is Hero && hero.child is ClipRRect) {
      final BorderRadiusGeometry radius =
          (hero.child as ClipRRect).borderRadius;
      return radius.resolve(Directionality.of(heroContext));
    }
    return BorderRadius.circular(12);
  }

  /// Содержимое обложки без скругления — то, что лежит внутри `ClipRRect`.
  static Widget? _heroContent(BuildContext heroContext) {
    final Widget hero = heroContext.widget;
    if (hero is Hero && hero.child is ClipRRect) {
      return (hero.child as ClipRRect).child;
    }
    return null;
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
