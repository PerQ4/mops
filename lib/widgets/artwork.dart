import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/theme/expressive_shape.dart';
import '../core/theme/motion.dart';
import '../core/utils/artwork_urls.dart';


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
    // Слушаем режим низкого трафика: при его переключении обложка должна
    // перезапроситься в меньшем размере, не дожидаясь перезахода на экран.
    return ValueListenableBuilder<bool>(
      valueListenable: artworkLowDataMode,
      builder: (BuildContext context, bool _, Widget? _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    // Без `heroTag` обложка мелкая (строка, карточка, панель): ей форма
    // крупной обложки не нужна, и лишний `LayoutBuilder` в дереве не нужен.
    if (widget.heroTag == null) return _buildImage(context, null);
    // Ограничения нужны, чтобы отличить крупную обложку от круглой миниатюры
    // островка: у миниатюры радиус равен половине стороны.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) =>
          _buildImage(context, constraints),
    );
  }

  Widget _buildImage(BuildContext context, BoxConstraints? constraints) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final BorderRadius shape =
        widget.radius ?? BorderRadius.circular(12);
    final double? w = widget.width ?? widget.size;
    final double? h = widget.height ?? widget.size;

    // Ссылки обложки приходят уже готовыми, поэтому в низком режиме понижаем
    // размер каждой на месте — иначе крупный адрес всё равно ушёл бы в сеть.
    final List<String> variants = <String>[];
    for (final String candidate in widget._variants) {
      final String shrunk = shrinkArtwork(candidate);
      if (shrunk.isNotEmpty && !variants.contains(shrunk)) variants.add(shrunk);
    }
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

    Widget image = _ArtworkClip(
      radius: shape,
      superellipse: _useSuperellipse(context, shape, constraints),
      child: content,
    );

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

  /// Рисовать ли обложку суперэллипсом.
  ///
  /// Только крупная обложка: она перелетает в полноэкранный плеер, и форма
  /// видна именно на ней. Круглая миниатюра островка остаётся круглой — её
  /// радиус равен половине стороны, а суперэллипс такого радиуса — уже не круг.
  bool _useSuperellipse(
    BuildContext context,
    BorderRadius radius,
    BoxConstraints? constraints,
  ) {
    if (widget.heroTag == null) return false;
    final ExpressiveShape? shape =
        Theme.of(context).extension<ExpressiveShape>();
    if (shape == null || !shape.superellipse) return false;
    final double side = constraints?.biggest.shortestSide ?? double.infinity;
    return radius.topLeft.x * 2 < side && radius.topLeft.y * 2 < side;
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
    final _ArtworkClip? fromClip = _heroClip(fromHeroContext);
    final _ArtworkClip? toClip = _heroClip(toHeroContext);
    final BorderRadius from = fromClip?.radius ?? BorderRadius.circular(12);
    final BorderRadius to = toClip?.radius ?? BorderRadius.circular(12);
    // Содержимое без скругления берём у целевого `Hero` (он летит), при
    // отсутствии — у исходного.
    final Widget? content = toClip?.child ?? fromClip?.child;
    // Скругление идёт по кривой перелёта, а не линейно, как анимация маршрута:
    // иначе углы «плывут» ровно и картинка выглядит вклеенной.
    final Animation<double> flight =
        animation.drive(AppMotion.heroFlight.tween);
    // Промежуточный кадр остаётся суперэллипсом, если им является хотя бы
    // один конец: иначе на последнем кадре форма скачком сменилась бы с
    // суперэллипса на обычное скругление.
    final bool superellipse =
        (fromClip?.superellipse ?? false) || (toClip?.superellipse ?? false);
    return AnimatedBuilder(
      animation: flight,
      child: content,
      builder: (BuildContext context, Widget? child) {
        final BorderRadius radius = BorderRadius.lerp(from, to, flight.value)!;
        if (!superellipse) {
          return ClipRRect(borderRadius: radius, child: child);
        }
        return ClipPath(
          clipper: ShapeBorderClipper(
            shape: RoundedSuperellipseBorder(borderRadius: radius),
          ),
          child: child,
        );
      },
    );
  }

  /// Обрезка обложки в указанном `Hero`: форма и радиус.
  static _ArtworkClip? _heroClip(BuildContext heroContext) {
    final Widget hero = heroContext.widget;
    if (hero is Hero && hero.child is _ArtworkClip) {
      return hero.child as _ArtworkClip;
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

/// Обложка, обрезанная по форме, вместе с описанием этой формы.
///
/// Отдельный виджет, а не голый `ClipRRect`: перелёт `Hero` должен знать
/// радиус и вид обрезки явно, не разбирая дерево виджетов. Суперэллипс
/// через `ClipRRect` не выражается — ему нужен путь.
class _ArtworkClip extends StatelessWidget {
  const _ArtworkClip({
    required this.radius,
    required this.superellipse,
    required this.child,
  });

  final BorderRadius radius;
  final bool superellipse;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!superellipse) {
      return ClipRRect(borderRadius: radius, child: child);
    }
    return ClipPath(
      clipper: ShapeBorderClipper(
        shape: RoundedSuperellipseBorder(borderRadius: radius),
      ),
      child: child,
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
