import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Переиспользуемый выбор квадрата на картинке: перетаскивание и масштаб.
///
/// Нужен всюду, где обложка обязана быть квадратной: у плейлиста (9.5) и у
/// локальных аудиофайлов (8.3). Виджет только выбирает область и не трогает
/// исходник; готовый квадрат отдаёт вызывающему.
///
/// Результат считаем сами, а не снимаем скриншот виджета: сторона диалога
/// зависит от окна, а картинка нужна в заданном размере. Поэтому видимая на
/// экране область пересчитывается в координаты исходника ([_sourceRect]) и
/// заново рисуется через [ui.PictureRecorder] — без оглядки на размер окна и
/// без потери качества.
///
/// Вход и выход — [ui.Image] ([showArtworkCropper]); если удобнее байты, есть
/// [cropArtworkToPng]. Полученный [ui.Image] принадлежит вызывающему — его
/// нужно освободить (`dispose`), когда он больше не нужен.
Future<ui.Image?> showArtworkCropper(
  BuildContext context, {
  required ui.Image image,
  int outputSize = 1024,
  String title = 'Кадрирование обложки',
}) {
  return showDialog<ui.Image>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext dialogContext) => _ArtworkCropperDialog(
      image: image,
      outputSize: outputSize,
      title: title,
    ),
  );
}

/// То же, что [showArtworkCropper], но на вход и на выход — байты PNG.
///
/// Так удобнее вызывать из загрузки обложки: эндпоинт принимает именно файл.
/// Внутренние [ui.Image] освобождаются здесь же; исходный `source` не трогаем.
Future<Uint8List?> cropArtworkToPng(
  BuildContext context, {
  required Uint8List source,
  int outputSize = 1024,
  String title = 'Кадрирование обложки',
}) async {
  final ui.Image image = await decodeArtworkImage(source);
  if (!context.mounted) {
    image.dispose();
    return null;
  }

  final ui.Image? cropped = await showArtworkCropper(
    context,
    image: image,
    outputSize: outputSize,
    title: title,
  );
  image.dispose();
  if (cropped == null) return null;

  final Uint8List? png = await encodeArtworkPng(cropped);
  cropped.dispose();
  return png;
}

/// Декодирует PNG/JPEG в [ui.Image] — вход для диалога кадрирования.
Future<ui.Image> decodeArtworkImage(Uint8List bytes) async {
  final ui.Codec codec = await ui.instantiateImageCodec(bytes);
  final ui.FrameInfo frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

/// Кодирует картинку в PNG. `null` — если кодировщик не справился.
Future<Uint8List?> encodeArtworkPng(ui.Image image) async {
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data?.buffer.asUint8List();
}

/// Интерактивный квадратный кроппер.
///
/// Сверху — квадрат с картинкой, снизу — ползунок масштаба (его можно
/// выключить, если управление вынесено наружу). Перетаскивание — пальцем или
/// мышью, масштаб — щипком, колесом или ползунком. Картинка всегда покрывает
/// квадрат: «пустых» полей по краям не бывает.
class ArtworkCropper extends StatefulWidget {
  const ArtworkCropper({
    super.key,
    required this.image,
    this.maxZoom = 6,
    this.showGuides = true,
    this.showControls = true,
  });

  /// Исходник. Владение не передаётся: виджет картинку не освобождает.
  final ui.Image image;

  /// Во сколько раз можно увеличить относительно «ровно по квадрату».
  final double maxZoom;

  /// Сетка третей поверх кадра — помогает держать горизонт.
  final bool showGuides;

  /// Показывать ли ползунок масштаба под квадратом.
  final bool showControls;

  @override
  State<ArtworkCropper> createState() => ArtworkCropperState();
}

class ArtworkCropperState extends State<ArtworkCropper> {
  /// Масштаб относительно минимального: 1 — картинка ровно покрывает квадрат.
  double _zoom = 1;

  /// Смещение центра картинки от центра квадрата, в пикселях экрана.
  Offset _offset = Offset.zero;

  Size? _viewport;

  double _startZoom = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  /// Масштаб «ровно по квадрату»: сторона делится на сторону картинки.
  double _coverScale(Size viewport) => math.max(
        viewport.width / widget.image.width,
        viewport.height / widget.image.height,
      );

  /// Область исходника, видимая в квадрате. Из неё же получается результат.
  Rect _sourceRect(Size viewport) {
    final double scale = _coverScale(viewport) * _zoom;
    return Rect.fromCenter(
      center: Offset(widget.image.width / 2, widget.image.height / 2) -
          _offset / scale,
      width: viewport.width / scale,
      height: viewport.height / scale,
    );
  }

  /// Не даёт картинке отойти от краёв: при любом сдвиге квадрат остаётся
  /// полностью закрытым — иначе в результат попали бы чёрные поля.
  Offset _clampOffset(Offset value, Size viewport) {
    final double scale = _coverScale(viewport) * _zoom;
    final double maxX =
        math.max(0, widget.image.width * scale / 2 - viewport.width / 2);
    final double maxY =
        math.max(0, widget.image.height * scale / 2 - viewport.height / 2);
    return Offset(
      value.dx.clamp(-maxX, maxX),
      value.dy.clamp(-maxY, maxY),
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    _startZoom = _zoom;
    _startOffset = _offset;
    _startFocal = details.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final Size? viewport = _viewport;
    if (viewport == null) return;
    final double zoom = (_startZoom * details.scale).clamp(1.0, widget.maxZoom);
    _apply(
      viewport,
      zoom,
      details.localFocalPoint,
      _startFocal,
      _startZoom,
      _startOffset,
    );
  }

  /// Масштабирует так, чтобы точка под [focal] осталась на месте.
  void _zoomTo(Offset focal, double targetZoom) {
    final Size? viewport = _viewport;
    if (viewport == null) return;
    final double zoom = targetZoom.clamp(1.0, widget.maxZoom);
    _apply(viewport, zoom, focal, focal, _zoom, _offset);
  }

  void _apply(
    Size viewport,
    double zoom,
    Offset focalNow,
    Offset focalStart,
    double zoomStart,
    Offset offsetStart,
  ) {
    final Offset center = Offset(viewport.width / 2, viewport.height / 2);
    final double scaleStart = _coverScale(viewport) * zoomStart;
    final double scaleNow = _coverScale(viewport) * zoom;
    // Точка картинки под пальцем при старте жеста — её и удерживаем под
    // пальцем: без этого кадр уезжает из-под курсора при каждом щелчке
    // колесом.
    final Offset anchor = (focalStart - center - offsetStart) / scaleStart;
    final Offset next = focalNow - center - anchor * scaleNow;
    setState(() {
      _zoom = zoom;
      _offset = _clampOffset(next, viewport);
    });
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    _zoomTo(event.localPosition, _zoom * math.exp(-event.scrollDelta.dy / 300));
  }

  /// Возвращает кадр к исходному виду: без сдвига, ровно по квадрату.
  void reset() {
    setState(() {
      _zoom = 1;
      _offset = Offset.zero;
    });
  }

  /// Рисует выбранный квадрат заново в заданном размере.
  ///
  /// [outputSize] — сторона результата. Вызывать после первой отрисовки: до
  /// неё неизвестна сторона квадрата на экране.
  Future<ui.Image> export({required int outputSize}) async {
    final Size viewport = _viewport ??
        Size(widget.image.width.toDouble(), widget.image.height.toDouble());
    final Rect src = _sourceRect(viewport);
    final double side = math.max(1, outputSize).toDouble();

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.drawImageRect(
      widget.image,
      src,
      Rect.fromLTWH(0, 0, side, side),
      Paint()..filterQuality = FilterQuality.high,
    );
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(side.toInt(), side.toInt());
    picture.dispose();
    return image;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AspectRatio(
          aspectRatio: 1,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double side = math.min(
                constraints.maxWidth,
                constraints.maxHeight.isFinite
                    ? constraints.maxHeight
                    : constraints.maxWidth,
              );
              final Size viewport = Size(side, side);
              _viewport = viewport;
              // Смещение могло упереться в край при прошлой стороне квадрата —
              // подгоняем под новую.
              _offset = _clampOffset(_offset, viewport);

              return ClipRect(
                child: Listener(
                  onPointerSignal: _onPointerSignal,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onScaleStart: _onScaleStart,
                    onScaleUpdate: _onScaleUpdate,
                    child: CustomPaint(
                      size: viewport,
                      painter: _CropPainter(
                        image: widget.image,
                        source: _sourceRect(viewport),
                        showGuides: widget.showGuides,
                        guides: scheme.onSurface.withValues(alpha: 0.32),
                        border: scheme.outlineVariant,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (widget.showControls)
          Row(
            children: <Widget>[
              Icon(Icons.zoom_out, size: 20, color: scheme.onSurfaceVariant),
              Expanded(
                child: Slider(
                  value: _zoom.clamp(1.0, widget.maxZoom),
                  min: 1,
                  max: widget.maxZoom,
                  onChanged: (double value) => _zoomTo(
                    Offset(_viewport!.width / 2, _viewport!.height / 2),
                    value,
                  ),
                ),
              ),
              Icon(Icons.zoom_in, size: 20, color: scheme.onSurfaceVariant),
              IconButton(
                onPressed: reset,
                tooltip: 'Сбросить',
                icon: const Icon(Icons.restart_alt, size: 20),
              ),
            ],
          ),
      ],
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter({
    required this.image,
    required this.source,
    required this.showGuides,
    required this.guides,
    required this.border,
  });

  final ui.Image image;
  final Rect source;
  final bool showGuides;
  final Color guides;
  final Color border;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect dst = Offset.zero & size;
    canvas.drawImageRect(
      image,
      source,
      dst,
      Paint()..filterQuality = FilterQuality.high,
    );

    if (showGuides) {
      final Paint line = Paint()
        ..color = guides
        ..strokeWidth = 1;
      for (int i = 1; i <= 2; i++) {
        final double t = size.width * i / 3;
        canvas.drawLine(Offset(t, 0), Offset(t, size.height), line);
        canvas.drawLine(Offset(0, t), Offset(size.width, t), line);
      }
    }

    canvas.drawRect(
      dst.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = border,
    );
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) =>
      oldDelegate.source != source ||
      oldDelegate.image != image ||
      oldDelegate.showGuides != showGuides ||
      oldDelegate.guides != guides ||
      oldDelegate.border != border;
}

/// Сам диалог: квадрат с управлением, подсказка и кнопки.
class _ArtworkCropperDialog extends StatefulWidget {
  const _ArtworkCropperDialog({
    required this.image,
    required this.outputSize,
    required this.title,
  });

  final ui.Image image;
  final int outputSize;
  final String title;

  @override
  State<_ArtworkCropperDialog> createState() => _ArtworkCropperDialogState();
}

class _ArtworkCropperDialogState extends State<_ArtworkCropperDialog> {
  final GlobalKey<ArtworkCropperState> _cropper =
      GlobalKey<ArtworkCropperState>();
  bool _busy = false;

  Future<void> _confirm() async {
    final ArtworkCropperState? state = _cropper.currentState;
    if (state == null) {
      Navigator.pop(context);
      return;
    }
    setState(() => _busy = true);
    final ui.Image result = await state.export(outputSize: widget.outputSize);
    if (!mounted) {
      result.dispose();
      return;
    }
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Size window = MediaQuery.sizeOf(context);
    // Квадрат вписываем и в ширину, и в высоту: на низком окне иначе не
    // осталось бы места под подсказку и кнопки.
    final double side = math.max(
      120,
      math.min(480, math.min(window.width - 96, window.height - 320)),
    );

    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      content: SizedBox(
        width: side,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ArtworkCropper(key: _cropper, image: widget.image),
            const SizedBox(height: 4),
            Text(
              'Двигайте и масштабируйте кадр',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _busy ? null : _confirm,
          child: const Text('Готово'),
        ),
      ],
    );
  }
}
