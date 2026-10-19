import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../data/sources/library_source.dart';
import '../../widgets/artwork_cropper.dart';

/// Верхняя граница исходного файла, который готовы декодировать.
///
/// Предел YouTube (2 МБ) относится к готовой обложке, а не к исходнику:
/// фотография на 12 Мп легко весит больше. Ограничение здесь только для
/// того, чтобы случайно не съесть память гигантским файлом.
const int maxPlaylistCoverSourceBytes = 25 * 1024 * 1024;

/// Спрашивает путь к картинке.
///
/// Отдельного выбора файла в приложении нет (и `file_picker` не подключён),
/// поэтому путь вводят вручную — тем же способом, что и путь для M3U и
/// резервной копии. `null` — отмена.
Future<String?> showPlaylistCoverPathDialog(BuildContext context) async {
  final TextEditingController field = TextEditingController();
  final String? result = await showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('Сменить обложку'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: field,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Путь к картинке',
              hintText: r'C:\Users\…\Pictures\cover.jpg',
              helperText: 'PNG или JPEG. Квадрат выберете в следующем окне.',
            ),
            onSubmitted: (String value) => Navigator.pop(dialogContext, value),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, field.text),
          child: const Text('Далее'),
        ),
      ],
    ),
  );
  field.dispose();

  final String path = _cleanPath(result);
  return path.isEmpty ? null : path;
}

/// Обрезает путь, скопированный из проводника Windows: тот добавляет кавычки.
String _cleanPath(String? raw) {
  String value = raw?.trim() ?? '';
  if (value.length >= 2) {
    final bool doubleQuoted = value.startsWith('"') && value.endsWith('"');
    final bool singleQuoted = value.startsWith("'") && value.endsWith("'");
    if (doubleQuoted || singleQuoted) {
      value = value.substring(1, value.length - 1).trim();
    }
  }
  return value;
}

/// Читает файл, даёт выбрать квадрат и укладывает PNG в лимит YouTube.
///
/// `null` — пользователь закрыл кроппер. Ошибки — [PlaylistImageException]
/// с готовым для показа текстом.
Future<Uint8List?> cropPlaylistCover(BuildContext context, String path) async {
  final File file = File(path);
  if (!file.existsSync()) {
    throw PlaylistImageException('Файл не найден: $path');
  }

  final int length;
  try {
    length = await file.length();
  } on FileSystemException catch (error) {
    throw PlaylistImageException(
      'Не удалось прочитать файл: ${error.message}',
    );
  }
  if (length == 0) {
    throw const PlaylistImageException('Файл пуст.');
  }
  if (length > maxPlaylistCoverSourceBytes) {
    throw PlaylistImageException(
      'Исходная картинка весит больше '
      '${maxPlaylistCoverSourceBytes ~/ (1024 * 1024)} МБ. Возьмите файл '
      'поменьше.',
    );
  }

  final Uint8List source;
  try {
    source = await file.readAsBytes();
  } on FileSystemException catch (error) {
    throw PlaylistImageException(
      'Не удалось прочитать файл: ${error.message}',
    );
  }

  final Uint8List? cropped;
  if (!context.mounted) return null;
  try {
    // 1024×1024 — обычный размер квадратной обложки для YouTube.
    cropped = await cropArtworkToPng(
      context,
      source: source,
      outputSize: 1024,
      title: 'Обложка плейлиста',
    );
  } on Object {
    // `instantiateImageCodec` не говорит, что именно не так с файлом.
    throw const PlaylistImageException(
      'Не удалось открыть картинку. Нужен корректный файл PNG или JPEG.',
    );
  }
  if (cropped == null) return null;

  return _fitUnderLimit(cropped);
}

/// Уменьшает PNG, пока он не влезет в предел.
///
/// Кроппер всегда отдаёт PNG, а PNG фотографии в 1024×1024 легко весит
/// больше 2 МБ. Переспрашивать пользователя из-за этого неправильно:
/// квадрат уже выбран, поэтому уменьшаем сторону на четверть за шаг.
Future<Uint8List> _fitUnderLimit(Uint8List png) async {
  const int limit = LibrarySource.maxPlaylistImageBytes;
  if (png.length <= limit) return png;

  final ui.Image source = await decodeArtworkImage(png);
  try {
    int side = source.width;
    while (side > 256) {
      side = math.max(256, (side * 0.75).round());
      final ui.Image scaled = await _scale(source, side);
      final Uint8List? encoded = await encodeArtworkPng(scaled);
      scaled.dispose();
      if (encoded != null && encoded.length <= limit) return encoded;
    }
  } finally {
    source.dispose();
  }

  throw const PlaylistImageException(
    'Не удалось уложить обложку в 2 МБ даже после уменьшения. '
    'Возьмите картинку попроще.',
  );
}

/// Перерисовывает картинку в квадрат заданной стороны.
Future<ui.Image> _scale(ui.Image source, int side) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawImageRect(
    source,
    Rect.fromLTWH(
      0,
      0,
      source.width.toDouble(),
      source.height.toDouble(),
    ),
    Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    Paint()..filterQuality = FilterQuality.high,
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(side, side);
  picture.dispose();
  return image;
}
