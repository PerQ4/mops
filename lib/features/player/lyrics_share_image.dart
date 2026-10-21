import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../widgets/app_progress.dart';

/// Сторона карточки в логических пикселях — она же размер готового PNG.
///
/// Карточка верстается сразу в экспортном размере, а предпросмотр лишь ужимает
/// её через [FittedBox]. Поэтому в файл попадает ровно нарисованное, без
/// повторной вёрстки под другой размер: уменьшение — это трансформация над
/// слоем, и снимок [RepaintBoundary] её не включает.
const double kLyricsShareSide = 1080;

/// Сколько строк показывать по умолчанию и в каких пределах можно выбрать.
const int kLyricsShareDefaultLines = 8;
const int kLyricsShareMinLines = 1;
const int kLyricsShareMaxLines = 20;

/// Фон карточки: градиент темы или обложка трека.
enum LyricsShareBackground {
  theme('Тема'),
  artwork('Обложка');

  const LyricsShareBackground(this.label);

  final String label;
}

/// Данные карточки: что написать и какую обложку подложить.
@immutable
class LyricsShareData {
  const LyricsShareData({
    required this.title,
    required this.artist,
    required this.lines,
    this.artworkUrl,
  });

  final String title;
  final String artist;

  /// Непустые строки текста — карточка берёт первые из них.
  final List<String> lines;

  /// Крупная обложка; `null` — у трека её нет.
  final String? artworkUrl;
}

/// Диалог «Поделиться текстом картинкой»: выбор числа строк и фона,
/// предпросмотр и сохранение в PNG.
///
/// Отдельная поверхность, а не ещё один пункт меню: настройки нужно видеть
/// рядом с результатом, иначе непонятно, что именно попадёт в файл.
Future<void> showLyricsShareDialog(BuildContext context, LyricsShareData data) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext _) => _LyricsShareDialog(data: data),
  );
}

/// Карточка со строками песни — то, что снимается в PNG.
class LyricsShareCard extends StatelessWidget {
  const LyricsShareCard({
    super.key,
    required this.data,
    required this.lines,
    required this.background,
  });

  final LyricsShareData data;

  /// Уже отобранные строки: их число задаёт пользователь в диалоге.
  final List<String> lines;

  final LyricsShareBackground background;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Обложка — фон только тогда, когда она есть: без ссылки «Обложка»
    // означала бы пустой градиент под белым текстом.
    final bool onArtwork =
        background == LyricsShareBackground.artwork && data.artworkUrl != null;
    final Color main = onArtwork ? Colors.white : scheme.onSurface;
    final Color secondary = onArtwork ? Colors.white70 : scheme.onSurfaceVariant;

    return SizedBox(
      width: kLyricsShareSide,
      height: kLyricsShareSide,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _background(scheme, onArtwork),
          Padding(
            padding: const EdgeInsets.all(72),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _header(main, secondary),
                const SizedBox(height: 40),
                Expanded(child: Center(child: _lyrics(main))),
                const SizedBox(height: 28),
                _footer(secondary),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Фон карточки: градиент темы либо обложка под затемнением.
  Widget _background(ColorScheme scheme, bool onArtwork) {
    final Widget themeGradient = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[scheme.primaryContainer, scheme.surface],
        ),
      ),
    );
    if (!onArtwork) return themeGradient;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // Градиент темы лежит и под обложкой: если картинка не отрисуется,
        // карточка не останется прозрачной.
        themeGradient,
        Image(
          image: CachedNetworkImageProvider(data.artworkUrl!),
          fit: BoxFit.cover,
          errorBuilder:
              (BuildContext context, Object error, StackTrace? stackTrace) =>
                  const SizedBox.shrink(),
        ),
        // Затемнение: на светлой обложке белый текст иначе не читался бы.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[Color(0x59000000), Color(0xCC000000)],
            ),
          ),
        ),
      ],
    );
  }

  /// Шапка: обложка, название и исполнитель.
  Widget _header(Color main, Color secondary) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        if (data.artworkUrl != null) ...<Widget>[
          _artworkThumb(),
          const SizedBox(width: 28),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                data.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 46,
                  height: 1.15,
                  fontWeight: FontWeight.w700,
                  color: main,
                ),
              ),
              if (data.artist.trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  data.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w500,
                    color: secondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _artworkThumb() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Image(
        image: CachedNetworkImageProvider(data.artworkUrl!),
        width: 128,
        height: 128,
        fit: BoxFit.cover,
        errorBuilder:
            (BuildContext context, Object error, StackTrace? stackTrace) =>
                const SizedBox(width: 128, height: 128),
      ),
    );
  }

  /// Строки по центру.
  ///
  /// [FittedBox] ужимает блок, когда строк много: размер шрифта задан
  /// фиксированным, а не подбирается на глаз, — так текст одного трека
  /// выглядит одинаково независимо от длины строк.
  Widget _lyrics(Color color) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: SizedBox(
        width: 900,
        child: Text(
          lines.join('\n'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 56,
            height: 1.35,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ),
    );
  }

  Widget _footer(Color secondary) {
    return Row(
      children: <Widget>[
        Icon(Icons.graphic_eq, size: 32, color: secondary),
        const SizedBox(width: 12),
        Text(
          'mOps',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
            color: secondary,
          ),
        ),
      ],
    );
  }
}

class _LyricsShareDialog extends StatefulWidget {
  const _LyricsShareDialog({required this.data});

  final LyricsShareData data;

  @override
  State<_LyricsShareDialog> createState() => _LyricsShareDialogState();
}

class _LyricsShareDialogState extends State<_LyricsShareDialog> {
  final GlobalKey _cardKey = GlobalKey();
  final TextEditingController _path = TextEditingController();

  late int _lineCount;
  LyricsShareBackground _background = LyricsShareBackground.theme;

  /// Обложка ещё грузится или уже не загрузилась — пока это так, фоном её
  /// выбирать нельзя: карточка ушла бы в PNG без картинки.
  bool _coverLoading = false;
  bool _coverFailed = false;
  bool _coverRequested = false;

  bool _busy = false;
  String? _message;
  String? _error;
  String? _savedPath;

  @override
  void initState() {
    super.initState();
    final int total = widget.data.lines.length;
    _lineCount = total < kLyricsShareDefaultLines
        ? total
        : kLyricsShareDefaultLines;
    _coverLoading = widget.data.artworkUrl?.isNotEmpty ?? false;
    unawaited(_fillDefaultPath());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Обложку просим здесь, а не в `initState`: `precacheImage` читает
    // `MediaQuery` из контекста, а это до `initState` ещё запрещено.
    if (_coverRequested) return;
    _coverRequested = true;
    unawaited(_loadCover());
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  /// Кладёт обложку в общий кэш до отрисовки: иначе в PNG могла попасть
  /// заглушка, если картинка не успела загрузиться.
  Future<void> _loadCover() async {
    final String? url = widget.data.artworkUrl;
    if (url == null || url.isEmpty) return;

    bool failed = false;
    await precacheImage(
      CachedNetworkImageProvider(url),
      context,
      onError: (Object error, StackTrace? stackTrace) => failed = true,
    );
    if (!mounted) return;
    setState(() {
      _coverLoading = false;
      _coverFailed = failed;
      if (failed) _background = LyricsShareBackground.theme;
    });
  }

  /// Путь по умолчанию — «Загрузки», а если системы их не отдали, документы:
  /// так же, как в резервной копии и экспорте плейлиста.
  Future<void> _fillDefaultPath() async {
    final String path = await _defaultLyricsImagePath(widget.data.title);
    if (!mounted) return;
    setState(() {
      if (_path.text.isEmpty) _path.text = path;
    });
  }

  @override
  Widget build(BuildContext context) {
    final LyricsShareData data = widget.data;
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int maxLines = data.lines.length > kLyricsShareMaxLines
        ? kLyricsShareMaxLines
        : data.lines.length;
    final List<String> shown = data.lines.take(_lineCount).toList();
    final bool coverReady =
        data.artworkUrl != null && !_coverLoading && !_coverFailed;

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Поделиться текстом',
                    style: text.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    data.artist.isEmpty
                        ? data.title
                        : '${data.title} — ${data.artist}',
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // Предпросмотр — вне прокрутки: снимок берётся с этого же виджета,
            // и он должен быть нарисован, а не прокручен за край экрана.
            Center(child: _preview(shown, coverReady)),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text('Строк на картинке', style: text.titleSmall),
                        ),
                        Text(
                          '$_lineCount',
                          style: text.labelLarge?.copyWith(
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ),
                    if (maxLines > kLyricsShareMinLines)
                      Slider(
                        value: _lineCount.toDouble(),
                        min: kLyricsShareMinLines.toDouble(),
                        max: maxLines.toDouble(),
                        divisions: maxLines - kLyricsShareMinLines,
                        label: '$_lineCount',
                        onChanged: (double value) =>
                            setState(() => _lineCount = value.round()),
                      ),
                    const SizedBox(height: 8),
                    Text('Фон', style: text.titleSmall),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: <Widget>[
                        ChoiceChip(
                          label: const Text('Тема'),
                          selected: _background == LyricsShareBackground.theme,
                          onSelected: (bool _) => setState(
                            () => _background = LyricsShareBackground.theme,
                          ),
                        ),
                        ChoiceChip(
                          label: const Text('Обложка'),
                          selected:
                              _background == LyricsShareBackground.artwork,
                          // Без загруженной обложки вариант недоступен.
                          onSelected: coverReady
                              ? (bool _) => setState(
                                    () => _background =
                                        LyricsShareBackground.artwork,
                                  )
                              : null,
                        ),
                      ],
                    ),
                    if (data.artworkUrl != null && !coverReady) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        _coverLoading
                            ? 'Загружаем обложку…'
                            : 'Обложка не загрузилась — доступен фон из темы.',
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    TextField(
                      controller: _path,
                      decoration: const InputDecoration(
                        labelText: 'Путь к файлу',
                        helperText: 'Существующий файл будет перезаписан',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (_message != null)
                    _StatusLine(
                      icon: Icons.check_circle_outline,
                      text: _message!,
                      color: scheme.primary,
                    ),
                  if (_error != null)
                    _StatusLine(
                      icon: Icons.error_outline,
                      text: _error!,
                      color: scheme.error,
                    ),
                  Row(
                    children: <Widget>[
                      if (_savedPath != null)
                        TextButton.icon(
                          onPressed: _busy
                              ? null
                              : () => unawaited(_openFolder(_savedPath!)),
                          icon: const Icon(Icons.folder_open),
                          label: const Text('Открыть папку'),
                        ),
                      const Spacer(),
                      TextButton(
                        onPressed:
                            _busy ? null : () => Navigator.of(context).pop(),
                        child: const Text('Отмена'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: _busy ? null : () => unawaited(_save()),
                        icon: _busy
                            ? const AppProgress(size: 24)
                            : const Icon(Icons.save_alt),
                        label: Text(_busy ? 'Сохраняем…' : 'Сохранить PNG'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Предпросмотр: карточка в экспортном размере, ужатая по месту.
  Widget _preview(List<String> shown, bool coverReady) {
    return SizedBox(
      width: 300,
      height: 300,
      child: FittedBox(
        fit: BoxFit.contain,
        child: RepaintBoundary(
          key: _cardKey,
          child: LyricsShareCard(
            data: widget.data,
            lines: shown,
            // Обложка фоном — только когда она уже загружена.
            background: coverReady
                ? _background
                : LyricsShareBackground.theme,
          ),
        ),
      ),
    );
  }

  /// Рисует карточку в PNG и пишет файл по введённому пути.
  Future<void> _save() async {
    final String path = _path.text.trim();
    if (path.isEmpty) {
      setState(() => _error = 'Укажите путь к файлу.');
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
      _error = null;
    });

    try {
      // Ждём кадр: снимок берётся с уже нарисованного слоя, а `toImage`
      // отказывается работать с непрорисованным.
      await WidgetsBinding.instance.endOfFrame;
      final Uint8List bytes = await _captureCard(_cardKey);
      final File file = File(path);
      // Родительский каталог может не существовать — создаём, иначе запись
      // упадёт с «путь не найден» на ровном месте.
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _savedPath = path;
        _message = 'Картинка сохранена: $path';
      });
    } on FileSystemException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Не удалось записать файл: ${error.message}';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Не удалось сохранить картинку: $error';
      });
    }
  }

  /// Открывает папку с сохранённым файлом в системном проводнике.
  Future<void> _openFolder(String path) async {
    final Uri uri = Uri.file(File(path).parent.path);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      setState(() => _error = 'Не удалось открыть папку: ${uri.toFilePath()}');
    }
  }
}

/// Снимок карточки в PNG.
Future<Uint8List> _captureCard(GlobalKey key) async {
  final RenderObject? render = key.currentContext?.findRenderObject();
  if (render is! RenderRepaintBoundary) {
    throw StateError('Карточка ещё не готова к отрисовке.');
  }
  // Множитель 1: карточка свёрстана в экспортном размере (1080), и лишний
  // множитель только раздул бы файл.
  final ui.Image image = await render.toImage(pixelRatio: 1);
  try {
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (data == null) throw StateError('Не удалось закодировать PNG.');
    return data.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// Путь по умолчанию для картинки: «Загрузки», иначе документы.
Future<String> _defaultLyricsImagePath(String title) async {
  Directory? dir;
  try {
    dir = await getDownloadsDirectory();
  } on Object {
    // На части платформ «Загрузок» нет — не повод не предложить путь.
  }
  dir ??= await getApplicationDocumentsDirectory();
  return '${dir.path}${Platform.pathSeparator}'
      '${_suggestedFileName(title)}';
}

/// Имя файла по названию трека.
///
/// Запрещённые в именах файлов символы заменяются подчёркиванием: иначе
/// сохранение упало бы на треке вроде «AC/DC».
String _suggestedFileName(String title) {
  final String safe = title
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  final String stamp = _dateStamp(DateTime.now());
  return 'mops-lyrics-${safe.isEmpty ? 'track' : safe}-$stamp.png';
}

String _dateStamp(DateTime moment) {
  final String month = moment.month.toString().padLeft(2, '0');
  final String day = moment.day.toString().padLeft(2, '0');
  return '${moment.year}-$month-$day';
}

/// Строка результата под предпросмотром: успех или причина отказа.
class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
