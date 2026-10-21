import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';

import '../models/models.dart';

/// Расширения, которые считаются музыкой при сканировании папки.
///
/// Список закрытый: видео и постеры, лежащие рядом с треками, в библиотеку
/// попадать не должны.
const Set<String> kLocalAudioExtensions = <String>{
  'mp3',
  'm4a',
  'flac',
  'ogg',
  'opus',
  'wav',
};

/// Префикс идентификатора локального трека.
///
/// Идентификатор — это префикс плюс абсолютный путь: плеер и очередь хранят
/// только строку `id`, а путь нужен при загрузке в движок. Префикс отделяет
/// такие треки от видео YouTube, чтобы их не пытались резолвить через сеть.
const String kLocalTrackIdPrefix = 'local:';

/// Это идентификатор локального файла?
bool isLocalTrackId(String id) => id.startsWith(kLocalTrackIdPrefix);

/// Идентификатор локального трека по пути.
String localTrackId(String path) => '$kLocalTrackIdPrefix$path';

/// Путь из идентификатора; `null` — идентификатор не локальный.
String? localPathFromId(String id) =>
    isLocalTrackId(id) ? id.substring(kLocalTrackIdPrefix.length) : null;

/// Обложку больше этого размера не читаем: в тег могли вложить постер
/// размером с сам трек, а список библиотеки столько не переварит.
const int _maxArtworkBytes = 8 * 1024 * 1024;

/// Файлы, у которых обложку уже искали и не нашли.
///
/// Пакет отдаёт картинку только вместе с полным разбором файла, поэтому при
/// сканировании о ней ничего не известно. Отрицательный ответ запоминаем,
/// чтобы прокрутка списка не разбирала те же файлы заново.
final Set<String> _filesWithoutArtwork = <String>{};

/// Один файл на диске с прочитанными метаданными.
///
/// Обложки в списке нет: пакет умеет отдавать картинку только байтами и
/// только вместе с полным разбором файла, а держать в памяти обложки всех
/// найденных треков — это сотни мегабайт на большой папке. Поэтому картинка
/// читается по требованию в [readArtwork], и только для строк, попавших на
/// экран.
class LocalMediaFile {
  const LocalMediaFile({
    required this.path,
    required this.title,
    this.artist,
    this.album,
    this.duration = Duration.zero,
    this.sizeBytes = 0,
    this.artworkOffset,
    this.artworkLength,
    this.artworkBytes,
  });

  /// Абсолютный путь к файлу.
  final String path;

  /// Название: из тега, а если тега нет — имя файла без расширения.
  final String title;

  /// Исполнитель. `null` — тега нет; выдумывать его нельзя.
  final String? artist;

  /// Альбом. `null` — тега нет.
  final String? album;

  final Duration duration;
  final int sizeBytes;

  /// Положение готовой картинки внутри файла.
  ///
  /// Пакет такого не отдаёт, поэтому при сканировании эти поля остаются
  /// пустыми: они сохранены для совместимости и для тех, кто собирает
  /// [LocalMediaFile] сам.
  final int? artworkOffset;
  final int? artworkLength;

  /// Байты картинки, если они уже есть под рукой.
  final Uint8List? artworkBytes;

  /// Идентификатор для очереди плеера.
  String get id => localTrackId(path);

  /// Имя файла с расширением — показывается в подписи.
  String get fileName => path.split(RegExp(r'[\\/]')).last;

  /// Возможно, у файла есть обложка.
  ///
  /// Пока картинка не прочитана, наличие неизвестно: пакет не умеет отвечать
  /// на этот вопрос, не разбирая её. Считаем, что обложка может быть, иначе
  /// список не показал бы ни одной; после [readArtwork] с пустым ответом
  /// файл запоминается как «без обложки».
  bool get hasArtwork =>
      artworkBytes != null ||
      (artworkOffset != null &&
          artworkLength != null &&
          artworkLength! > 0 &&
          artworkLength! <= _maxArtworkBytes) ||
      (sizeBytes > 0 && !_filesWithoutArtwork.contains(path));

  /// Читает обложку с диска по требованию.
  ///
  /// Разбор идёт в отдельном изоляте: чтение мегабайтов картинки не должно
  /// подвешивать кадр списка.
  Future<Uint8List?> readArtwork() async {
    final Uint8List? embedded = artworkBytes;
    if (embedded != null) return embedded;

    final int? offset = artworkOffset;
    final int? length = artworkLength;
    if (offset != null && length != null && length > 0) {
      return _readArtworkSlice(offset, length);
    }

    try {
      final Uint8List? bytes =
          await Isolate.run(() => _readEmbeddedArtwork(path));
      if (bytes == null) _filesWithoutArtwork.add(path);
      return bytes;
    } on Object catch (error) {
      debugPrint('[Локальные файлы] обложка $path: $error');
      // Файл, который пакет не разобрал, всё равно не покажет обложку:
      // помечаем его, чтобы прокрутка не разбирала его заново.
      _filesWithoutArtwork.add(path);
      return null;
    }
  }

  Future<Uint8List?> _readArtworkSlice(int offset, int length) async {
    if (length > _maxArtworkBytes) return null;
    RandomAccessFile? file;
    try {
      file = await File(path).open();
      await file.setPosition(offset);
      return await file.read(length);
    } on Object catch (error) {
      debugPrint('[Локальные файлы] обложка $path: $error');
      return null;
    } finally {
      await file?.close();
    }
  }

  /// Трек для очереди плеера. Обложки здесь нет: экран библиотеки рисует её
  /// сам, а остальные экраны рассчитаны на ссылки YouTube.
  Track toTrack() => Track(
        id: id,
        title: title,
        artists: artist == null
            ? const <ArtistRef>[]
            : <ArtistRef>[ArtistRef(name: artist!)],
        album: album == null ? null : AlbumRef(name: album!),
        duration: duration,
      );
}

/// Ошибка сканирования с текстом для интерфейса.
class LocalMediaException implements Exception {
  LocalMediaException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Сканирование папки на диске.
class LocalMediaScanner {
  const LocalMediaScanner({this.concurrency = 4});

  /// Сколько файлов разбирать одновременно: каждый файл читается в своём
  /// изоляте, но на сетевом диске параллельные запросы всё равно заметно
  /// ускоряют дело.
  final int concurrency;

  /// Находит все поддерживаемые аудиофайлы и читает их теги.
  ///
  /// [cancelled] проверяется между файлами: смену папки во время долгого
  /// сканирования не нужно доводить до конца.
  Future<List<LocalMediaFile>> scan(
    String folder, {
    bool Function()? cancelled,
  }) async {
    final Directory root = Directory(folder);
    if (!await root.exists()) {
      throw LocalMediaException('Папка не найдена: $folder');
    }

    final List<File> files = <File>[];
    try {
      await for (final FileSystemEntity entity
          in root.list(recursive: true, followLinks: false)) {
        if (cancelled?.call() ?? false) return const <LocalMediaFile>[];
        if (entity is! File) continue;
        final String name = entity.path.split(RegExp(r'[\\/]')).last;
        if (name.startsWith('.')) continue;
        if (!kLocalAudioExtensions.contains(_extension(name))) continue;
        files.add(entity);
      }
    } on FileSystemException catch (error) {
      throw LocalMediaException('Не удалось прочитать папку: ${error.message}');
    }

    files.sort((File a, File b) =>
        a.path.toLowerCase().compareTo(b.path.toLowerCase()));

    final List<LocalMediaFile> result = <LocalMediaFile>[];
    for (int i = 0; i < files.length; i += concurrency) {
      if (cancelled?.call() ?? false) return const <LocalMediaFile>[];
      final int end = math.min(i + concurrency, files.length);
      final List<LocalMediaFile> batch = await Future.wait(
        files.sublist(i, end).map((File file) => readLocalMediaFile(file.path)),
      );
      result.addAll(batch);
    }
    return result;
  }
}

/// Читает метаданные одного файла.
///
/// Ошибка разбора не скрывает файл: он всё равно попадёт в библиотеку с
/// именем вместо названия и нулевой длительностью. Так папка со странным
/// файлом не ломает весь список.
Future<LocalMediaFile> readLocalMediaFile(String path) async {
  final String fileName = path.split(RegExp(r'[\\/]')).last;
  final String fallbackTitle = _titleFromFileName(fileName);

  int size = 0;
  try {
    size = await File(path).length();
  } on Object catch (error) {
    debugPrint('[Локальные файлы] размер $path: $error');
  }

  _Tags tags = const _Tags();
  try {
    tags = await Isolate.run(() => _readTags(path));
  } on Object catch (error) {
    debugPrint('[Локальные файлы] теги $path: $error');
  }

  return LocalMediaFile(
    path: path,
    title: _clean(tags.title) ?? fallbackTitle,
    artist: _clean(tags.artist),
    album: _clean(tags.album),
    duration: tags.duration.isNegative ? Duration.zero : tags.duration,
    sizeBytes: size,
  );
}

// ---------------------------------------------------------------------------
// Помощники
// ---------------------------------------------------------------------------

/// Прочитанные теги в общем виде.
class _Tags {
  const _Tags({
    this.title,
    this.artist,
    this.album,
    this.duration = Duration.zero,
  });

  final String? title;
  final String? artist;
  final String? album;
  final Duration duration;
}

/// Разбирает теги пакетом `audio_metadata_reader`.
///
/// Вызывается в изоляте: пакет работает синхронно, и на папке в тысячи
/// треков разбор подвесил бы интерфейс. Картинка здесь не читается — она
/// нужна только там, где строка попала на экран.
_Tags _readTags(String path) {
  final AudioMetadata metadata = readMetadata(File(path));
  return _Tags(
    title: metadata.title,
    // Пакет для FLAC/Ogg берёт только `ARTIST`; у сборников исполнитель
    // бывает записан лишь в `ALBUMARTIST`.
    artist: metadata.artist ?? metadata.albumArtist,
    album: metadata.album,
    duration: metadata.duration ?? Duration.zero,
  );
}

/// Байты обложки из тегов.
///
/// Сначала берём лицевую обложку, остальные картинки — как запасной вариант:
/// иногда вместо неё в тег кладут иконку или фото исполнителя. Слишком
/// крупные пропускаем, чтобы не тянуть в память постер размером с трек.
Uint8List? _readEmbeddedArtwork(String path) {
  final List<Picture> pictures =
      readMetadata(File(path), getImage: true).pictures;
  final List<Picture> ordered = <Picture>[
    ...pictures.where((Picture p) => p.pictureType == PictureType.coverFront),
    ...pictures.where((Picture p) => p.pictureType != PictureType.coverFront),
  ];
  for (final Picture picture in ordered) {
    final Uint8List bytes = picture.bytes;
    if (bytes.isNotEmpty && bytes.length <= _maxArtworkBytes) return bytes;
  }
  return null;
}

String _extension(String fileName) {
  final int dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return '';
  return fileName.substring(dot + 1).toLowerCase();
}

/// Название по имени файла — единственное, что есть без тегов.
String _titleFromFileName(String fileName) {
  final int dot = fileName.lastIndexOf('.');
  return dot <= 0 ? fileName : fileName.substring(0, dot);
}

/// Убирает пустые значения и хвостовые разделители многозначных тегов.
String? _clean(String? value) {
  if (value == null) return null;
  String text = value.replaceAll('\u0000', ' ').trim();
  text = text.replaceAll(RegExp(r'[\s,;]+$'), '').trim();
  return text.isEmpty ? null : text;
}
