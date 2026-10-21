import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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

/// Один файл на диске с прочитанными метаданными.
///
/// Обложка хранится не байтами, а положением в файле: держать в памяти
/// картинки всех найденных треков — это сотни мегабайт на большой папке.
/// Исключение — Ogg, где картинка закодирована в base64 внутри комментария
/// и готового куска в файле нет.
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

  /// Положение готовой картинки внутри файла (ID3 `APIC`, MP4 `covr`,
  /// FLAC `PICTURE`).
  final int? artworkOffset;
  final int? artworkLength;

  /// Байты картинки для контейнеров, где её нельзя прочитать куском.
  final Uint8List? artworkBytes;

  /// Идентификатор для очереди плеера.
  String get id => localTrackId(path);

  /// Имя файла с расширением — показывается в подписи.
  String get fileName => path.split(RegExp(r'[\\/]')).last;

  bool get hasArtwork =>
      artworkBytes != null ||
      (artworkOffset != null &&
          artworkLength != null &&
          artworkLength! > 0 &&
          artworkLength! <= _maxArtworkBytes);

  /// Читает обложку с диска по требованию.
  Future<Uint8List?> readArtwork() async {
    final Uint8List? embedded = artworkBytes;
    if (embedded != null) return embedded;
    final int? offset = artworkOffset;
    final int? length = artworkLength;
    if (offset == null || length == null || length <= 0) return null;
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

  /// Сколько файлов читать одновременно: теги читаются мелкими кусками, но
  /// на сетевом диске параллельные запросы всё равно заметно ускоряют дело.
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
  RandomAccessFile? file;
  try {
    final File handle = File(path);
    size = await handle.length();
    file = await handle.open();
    final _Tags tags = switch (_extension(fileName)) {
      'mp3' => await _readMp3(file, size),
      'm4a' => await _readMp4(file, size),
      'flac' => await _readFlac(file, size),
      'ogg' || 'opus' => await _readOgg(file, size),
      'wav' => await _readWav(file, size),
      _ => const _Tags(),
    };
    return LocalMediaFile(
      path: path,
      title: _clean(tags.title) ?? fallbackTitle,
      artist: _clean(tags.artist),
      album: _clean(tags.album),
      duration: tags.duration,
      sizeBytes: size,
      artworkOffset: tags.artOffset,
      artworkLength: tags.artLength,
      artworkBytes: tags.artBytes,
    );
  } on Object catch (error) {
    debugPrint('[Локальные файлы] теги $path: $error');
    return LocalMediaFile(
      path: path,
      title: fallbackTitle,
      sizeBytes: size,
    );
  } finally {
    await file?.close();
  }
}

// ---------------------------------------------------------------------------
// Общие помощники
// ---------------------------------------------------------------------------

/// Прочитанные теги в общем виде.
class _Tags {
  const _Tags({
    this.title,
    this.artist,
    this.album,
    this.duration = Duration.zero,
    this.artOffset,
    this.artLength,
    this.artBytes,
  });

  final String? title;
  final String? artist;
  final String? album;
  final Duration duration;
  final int? artOffset;
  final int? artLength;
  final Uint8List? artBytes;
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

Future<Uint8List> _readAt(RandomAccessFile file, int offset, int length) async {
  if (offset < 0 || length <= 0) return Uint8List(0);
  await file.setPosition(offset);
  return file.read(length);
}

String _ascii(Uint8List bytes, int offset, int length) {
  if (offset < 0 || offset + length > bytes.length) return '';
  return String.fromCharCodes(bytes, offset, offset + length);
}

int _be16(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 2 > bytes.length) return 0;
  return (bytes[offset] << 8) | bytes[offset + 1];
}

int _be32(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 4 > bytes.length) return 0;
  return (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
}

int _be64(Uint8List bytes, int offset) =>
    (_be32(bytes, offset) << 32) | _be32(bytes, offset + 4);

int _le32(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 4 > bytes.length) return 0;
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

int _be24(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 3 > bytes.length) return 0;
  return (bytes[offset] << 16) | (bytes[offset + 1] << 8) | bytes[offset + 2];
}

/// Размер в формате synchsafe: по семь значащих бит на байт (ID3v2).
int _synchsafe(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 4 > bytes.length) return 0;
  return ((bytes[offset] & 0x7F) << 21) |
      ((bytes[offset + 1] & 0x7F) << 14) |
      ((bytes[offset + 2] & 0x7F) << 7) |
      (bytes[offset + 3] & 0x7F);
}

/// Снимает «десинхронизацию» ID3: байт 0x00 после 0xFF при записи вставляли,
/// чтобы ложный синхросигнал не путал декодеры.
Uint8List _deUnsynchronise(Uint8List input) {
  final BytesBuilder out = BytesBuilder(copy: false);
  for (int i = 0; i < input.length; i++) {
    out.addByte(input[i]);
    if (input[i] == 0xFF && i + 1 < input.length && input[i + 1] == 0x00) {
      i++;
    }
  }
  return out.takeBytes();
}

/// Текст в восьмибитной кодировке: сначала пробуем UTF-8 (так пишут многие
/// теггеры, не ставя флаг), затем читаем как Latin-1 — по спецификации ID3.
/// Кириллицу в cp1251 без таблицы не разобрать; лучше показать как есть,
/// чем придумывать перевод.
String _decodeLegacy(Uint8List bytes) {
  if (bytes.isEmpty) return '';
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

String _decodeUtf16(Uint8List bytes, {required bool bigEndian}) {
  int start = 0;
  bool big = bigEndian;
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      big = false;
      start = 2;
    } else if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      big = true;
      start = 2;
    }
  }
  final List<int> units = <int>[];
  for (int i = start; i + 1 < bytes.length; i += 2) {
    units.add(big
        ? (bytes[i] << 8) | bytes[i + 1]
        : bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(units);
}

// ---------------------------------------------------------------------------
// MP3: ID3v2 (2.2/2.3/2.4) + оценка длительности по кадрам MPEG
// ---------------------------------------------------------------------------

Future<_Tags> _readMp3(RandomAccessFile file, int size) async {
  _Id3v2? id3;
  int audioStart = 0;

  final Uint8List head = await _readAt(file, 0, math.min(10, size));
  if (head.length >= 10 && _ascii(head, 0, 3) == 'ID3') {
    final int major = head[3];
    final int flags = head[5];
    final int tagSize = _synchsafe(head, 6);
    if (tagSize > 0 && tagSize <= 32 * 1024 * 1024) {
      Uint8List body = await _readAt(file, 10, tagSize);
      final bool unsynchronised = (flags & 0x80) != 0;
      if (unsynchronised) body = _deUnsynchronise(body);
      id3 = _parseId3(
        body,
        major,
        flags,
        // При десинхронизации позиции в файле не совпадают с позициями в
        // разобранном теле, и картинку придётся сохранить в память.
        absoluteBody: unsynchronised ? null : 10,
      );
      audioStart = 10 + tagSize + ((flags & 0x10) != 0 ? 10 : 0);
    } else if (tagSize > 0) {
      // Тег слишком велик, чтобы читать его целиком, но звук всё равно
      // начинается после него.
      audioStart = 10 + tagSize;
    }
  }

  _Tags? v1;
  // ID3v1 — последние 128 байт. Читаем всегда: он дешёвый, а метки в нём
  // бывают единственными.
  if (size > 128) {
    final Uint8List tail = await _readAt(file, size - 128, 128);
    if (_ascii(tail, 0, 3) == 'TAG') v1 = _parseId3v1(tail);
  }

  Duration duration = id3?.duration ?? Duration.zero;
  if (duration <= Duration.zero) {
    final int probeLength = math.min(64 * 1024, math.max(0, size - audioStart));
    final Uint8List probe = await _readAt(file, audioStart, probeLength);
    final _MpegFrame? frame = _findMpegFrame(probe);
    if (frame != null) {
      duration = _xingDuration(probe, frame) ?? Duration.zero;
      if (duration <= Duration.zero && frame.bitrateKbps > 0) {
        int audioBytes = size - audioStart;
        if (v1 != null) audioBytes -= 128;
        if (audioBytes > 0) {
          // Байты × 8 / кбит/с = миллисекунды.
          duration = Duration(
            milliseconds: (audioBytes * 8 / frame.bitrateKbps).round(),
          );
        }
      }
    }
  }

  return _Tags(
    title: id3?.title ?? v1?.title,
    artist: id3?.artist ?? v1?.artist,
    album: id3?.album ?? v1?.album,
    duration: duration,
    artOffset: id3?.artOffset,
    artLength: id3?.artLength,
    artBytes: id3?.artBytes,
  );
}

class _Id3v2 {
  const _Id3v2({
    this.title,
    this.artist,
    this.album,
    this.duration = Duration.zero,
    this.artOffset,
    this.artLength,
    this.artBytes,
  });

  final String? title;
  final String? artist;
  final String? album;
  final Duration duration;
  final int? artOffset;
  final int? artLength;
  final Uint8List? artBytes;
}

_Id3v2 _parseId3(
  Uint8List body,
  int major,
  int headerFlags, {
  required int? absoluteBody,
}) {
  String? title;
  String? artist;
  String? album;
  Duration duration = Duration.zero;
  int? artOffset;
  int? artLength;
  Uint8List? artBytes;

  int position = 0;
  // Расширенный заголовок: в 2.3 его размер не включает сам размер, в 2.4 —
  // включает и записан как synchsafe.
  if ((headerFlags & 0x40) != 0 && body.length >= 4) {
    final int extended = major >= 4 ? _synchsafe(body, 0) : 4 + _be32(body, 0);
    if (extended > 0 && extended < body.length) position = extended;
  }

  while (position + (major == 2 ? 6 : 10) <= body.length) {
    final String id;
    int frameSize;
    int frameFlags = 0;
    if (major == 2) {
      id = _ascii(body, position, 3);
      frameSize = _be24(body, position + 3);
      position += 6;
    } else {
      id = _ascii(body, position, 4);
      frameSize = major >= 4
          ? _synchsafe(body, position + 4)
          : _be32(body, position + 4);
      frameFlags = _be16(body, position + 8);
      position += 10;
    }
    if (!RegExp(r'^[A-Z0-9]{3,4}$').hasMatch(id)) break;
    if (frameSize <= 0 || position + frameSize > body.length) break;

    final int frameStart = position;
    Uint8List frame =
        Uint8List.sublistView(body, frameStart, frameStart + frameSize);
    int? absoluteFrameStart =
        absoluteBody == null ? null : absoluteBody + frameStart;
    position += frameSize;

    // Сжатые/зашифрованные кадры без внешних ключей не разобрать.
    final bool compressed = major == 3 ? (frameFlags & 0x0080) != 0 : false;
    final bool encrypted = major == 3 ? (frameFlags & 0x0040) != 0 : false;
    if (major >= 4) {
      if ((frameFlags & 0x0008) != 0 || (frameFlags & 0x0004) != 0) continue;
      if ((frameFlags & 0x0002) != 0) {
        frame = _deUnsynchronise(frame);
        // После снятия десинхронизации позиции сместились.
        absoluteFrameStart = null;
      }
      if ((frameFlags & 0x0001) != 0 && frame.length >= 4) {
        frame = Uint8List.sublistView(frame, 4);
        absoluteFrameStart = null;
      }
    }
    if (compressed || encrypted) continue;

    switch (id) {
      case 'TIT2':
      case 'TT2':
        title = _decodeId3Text(frame);
      case 'TPE1':
      case 'TP1':
        artist = _decodeId3Text(frame);
      case 'TPE2':
      case 'TP2':
        artist ??= _decodeId3Text(frame);
      case 'TALB':
      case 'TAL':
        album = _decodeId3Text(frame);
      case 'TLEN':
      case 'TLE':
        final String? text = _decodeId3Text(frame);
        final int? ms = text == null ? null : int.tryParse(text.trim());
        if (ms != null && ms > 0 && ms < 24 * 60 * 60 * 1000) {
          duration = Duration(milliseconds: ms);
        }
      case 'APIC':
      case 'PIC':
        final _ArtworkSlice? picture = _parseId3Picture(
          frame,
          major == 2,
          absoluteFrameStart: absoluteFrameStart,
        );
        if (picture != null) {
          artOffset = picture.offset;
          artLength = picture.length;
          artBytes = picture.bytes;
        }
    }
  }

  return _Id3v2(
    title: title,
    artist: artist,
    album: album,
    duration: duration,
    artOffset: artOffset,
    artLength: artLength,
    artBytes: artBytes,
  );
}

String? _decodeId3Text(Uint8List frame) {
  if (frame.isEmpty) return null;
  final int encoding = frame[0];
  final Uint8List body = Uint8List.sublistView(frame, 1);
  final String text = switch (encoding) {
    1 => _decodeUtf16(body, bigEndian: false),
    2 => _decodeUtf16(body, bigEndian: true),
    3 => utf8.decode(body, allowMalformed: true),
    _ => _decodeLegacy(body),
  };
  return _clean(text);
}

class _ArtworkSlice {
  const _ArtworkSlice({this.offset, this.length, this.bytes});

  final int? offset;
  final int? length;
  final Uint8List? bytes;
}

_ArtworkSlice? _parseId3Picture(
  Uint8List frame,
  bool version22, {
  required int? absoluteFrameStart,
}) {
  if (frame.length < 4) return null;
  final int encoding = frame[0];
  int position = 1;
  if (version22) {
    position = 4; // формат картинки — три байта вместо MIME
  } else {
    while (position < frame.length && frame[position] != 0) {
      position++;
    }
    position++; // нулевой байт после MIME
  }
  if (position >= frame.length) return null;
  position++; // тип картинки

  if (encoding == 1 || encoding == 2) {
    while (position + 1 < frame.length &&
        !(frame[position] == 0 && frame[position + 1] == 0)) {
      position += 2;
    }
    position += 2;
  } else {
    while (position < frame.length && frame[position] != 0) {
      position++;
    }
    position++;
  }
  if (position < 0 || position >= frame.length) return null;

  final int length = frame.length - position;
  if (length <= 0 || length > _maxArtworkBytes) return null;
  if (absoluteFrameStart != null) {
    return _ArtworkSlice(
      offset: absoluteFrameStart + position,
      length: length,
    );
  }
  return _ArtworkSlice(
    bytes: Uint8List.fromList(
      Uint8List.sublistView(frame, position),
    ),
  );
}

_Tags _parseId3v1(Uint8List tail) {
  String text(int offset, int length) =>
      _clean(_decodeLegacy(Uint8List.sublistView(tail, offset, offset + length))) ??
      '';
  final String title = text(3, 30);
  final String artist = text(33, 30);
  final String album = text(63, 30);
  return _Tags(
    title: title.isEmpty ? null : title,
    artist: artist.isEmpty ? null : artist,
    album: album.isEmpty ? null : album,
  );
}

class _MpegFrame {
  const _MpegFrame({
    required this.offset,
    required this.bitrateKbps,
    required this.sampleRate,
    required this.samplesPerFrame,
    required this.mono,
  });

  /// Смещение начала кадра в прочитанном куске.
  final int offset;
  final int bitrateKbps;
  final int sampleRate;
  final int samplesPerFrame;
  final bool mono;
}

const List<int> _mpeg1Layer1 = <int>[
  0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448,
];
const List<int> _mpeg1Layer2 = <int>[
  0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384,
];
const List<int> _mpeg1Layer3 = <int>[
  0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320,
];
const List<int> _mpeg2Layer1 = <int>[
  0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256,
];
const List<int> _mpeg2Layer23 = <int>[
  0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160,
];

_MpegFrame? _findMpegFrame(Uint8List bytes) {
  for (int i = 0; i + 4 <= bytes.length; i++) {
    if (bytes[i] != 0xFF || (bytes[i + 1] & 0xE0) != 0xE0) continue;
    final int versionBits = (bytes[i + 1] >> 3) & 0x03;
    final int layerBits = (bytes[i + 1] >> 1) & 0x03;
    if (versionBits == 1 || layerBits == 0) continue;

    final int bitrateIndex = (bytes[i + 2] >> 4) & 0x0F;
    final int rateIndex = (bytes[i + 2] >> 2) & 0x03;
    if (bitrateIndex == 0 || bitrateIndex == 0x0F || rateIndex == 0x03) {
      continue;
    }

    final bool mpeg1 = versionBits == 3;
    final List<int> rates = switch (versionBits) {
      3 => const <int>[44100, 48000, 32000],
      2 => const <int>[22050, 24000, 16000],
      _ => const <int>[11025, 12000, 8000],
    };
    final int layer = 4 - layerBits; // 1, 2 или 3
    final List<int> bitrates = mpeg1
        ? switch (layer) {
            1 => _mpeg1Layer1,
            2 => _mpeg1Layer2,
            _ => _mpeg1Layer3,
          }
        : switch (layer) {
            1 => _mpeg2Layer1,
            _ => _mpeg2Layer23,
          };
    final int kbps = bitrates[bitrateIndex];
    final int sampleRate = rates[rateIndex];
    if (kbps <= 0 || sampleRate <= 0) continue;

    final int padding = (bytes[i + 2] >> 1) & 0x01;
    final int frameLength = switch (layer) {
      1 => (12 * kbps * 1000 ~/ sampleRate + padding) * 4,
      2 => 144 * kbps * 1000 ~/ sampleRate + padding,
      _ => (mpeg1 ? 144 : 72) * kbps * 1000 ~/ sampleRate + padding,
    };
    if (frameLength < 4) continue;

    return _MpegFrame(
      offset: i,
      bitrateKbps: kbps,
      sampleRate: sampleRate,
      samplesPerFrame: switch (layer) {
        1 => 384,
        2 => 1152,
        _ => mpeg1 ? 1152 : 576,
      },
      mono: ((bytes[i + 3] >> 6) & 0x03) == 3,
    );
  }
  return null;
}

Duration? _xingDuration(Uint8List bytes, _MpegFrame frame) {
  final int sideInfo = frame.mono ? 17 : 32;
  final int xing = frame.offset + 4 + sideInfo;
  if (_ascii(bytes, xing, 4) == 'Xing' || _ascii(bytes, xing, 4) == 'Info') {
    final int flags = _be32(bytes, xing + 4);
    if ((flags & 0x01) != 0) {
      final int frames = _be32(bytes, xing + 8);
      return _durationFromFrames(frames, frame);
    }
  }
  // VBRI — альтернатива Xing от Fraunhofer.
  final int vbri = frame.offset + 4 + 32;
  if (_ascii(bytes, vbri, 4) == 'VBRI') {
    final int frames = _be32(bytes, vbri + 14);
    return _durationFromFrames(frames, frame);
  }
  return null;
}

Duration? _durationFromFrames(int frames, _MpegFrame frame) {
  if (frames <= 0 || frame.sampleRate <= 0) return null;
  final int micros = frames * frame.samplesPerFrame * 1000000 ~/ frame.sampleRate;
  return Duration(microseconds: micros);
}

// ---------------------------------------------------------------------------
// MP4/M4A: ilst (©nam, ©ART, ©alb, covr) + mvhd
// ---------------------------------------------------------------------------

class _Mp4Tags {
  String? title;
  String? artist;
  String? album;
  Duration duration = Duration.zero;
  int? artOffset;
  int? artLength;
}

Future<_Tags> _readMp4(RandomAccessFile file, int size) async {
  final _Mp4Tags tags = _Mp4Tags();
  await _walkMp4(file, 0, size, 0, tags);
  return _Tags(
    title: tags.title,
    artist: tags.artist,
    album: tags.album,
    duration: tags.duration,
    artOffset: tags.artOffset,
    artLength: tags.artLength,
  );
}

Future<void> _walkMp4(
  RandomAccessFile file,
  int start,
  int end,
  int depth,
  _Mp4Tags tags,
) async {
  if (depth > 8) return;
  int offset = start;
  while (offset + 8 <= end) {
    final Uint8List header = await _readAt(file, offset, 8);
    if (header.length < 8) return;
    int boxSize = _be32(header, 0);
    final String type = _ascii(header, 4, 4);
    int headerSize = 8;
    if (boxSize == 1) {
      final Uint8List large = await _readAt(file, offset + 8, 8);
      if (large.length < 8) return;
      boxSize = _be64(large, 0);
      headerSize = 16;
    } else if (boxSize == 0) {
      boxSize = end - offset;
    }
    if (boxSize < headerSize) return;

    final int bodyStart = offset + headerSize;
    final int bodyEnd = math.min(offset + boxSize, end);
    switch (type) {
      case 'moov':
      case 'trak':
      case 'mdia':
      case 'minf':
      case 'stbl':
      case 'udta':
        await _walkMp4(file, bodyStart, bodyEnd, depth + 1, tags);
      case 'meta':
        // Полный бокс: версия и флаги.
        await _walkMp4(file, bodyStart + 4, bodyEnd, depth + 1, tags);
      case 'ilst':
        await _readMp4Ilst(file, bodyStart, bodyEnd, tags);
      case 'mvhd':
        await _readMp4Duration(file, bodyStart, bodyEnd, tags);
    }
    offset += boxSize;
  }
}

Future<void> _readMp4Duration(
  RandomAccessFile file,
  int start,
  int end,
  _Mp4Tags tags,
) async {
  if (tags.duration > Duration.zero) return;
  final Uint8List data = await _readAt(file, start, math.min(32, end - start));
  if (data.length < 20) return;
  final int version = data[0];
  final int timescale;
  final int duration;
  if (version == 1) {
    if (data.length < 32) return;
    timescale = _be32(data, 20);
    duration = _be64(data, 24);
  } else {
    timescale = _be32(data, 12);
    duration = _be32(data, 16);
  }
  if (timescale > 0 && duration > 0) {
    tags.duration = Duration(
      microseconds: duration * 1000000 ~/ timescale,
    );
  }
}

Future<void> _readMp4Ilst(
  RandomAccessFile file,
  int start,
  int end,
  _Mp4Tags tags,
) async {
  int offset = start;
  while (offset + 8 <= end) {
    final Uint8List header = await _readAt(file, offset, 8);
    if (header.length < 8) return;
    final int itemSize = _be32(header, 0);
    final String itemType = _ascii(header, 4, 4);
    if (itemSize < 8) return;
    final int itemEnd = math.min(offset + itemSize, end);

    int position = offset + 8;
    while (position + 8 <= itemEnd) {
      final Uint8List boxHeader = await _readAt(file, position, 8);
      if (boxHeader.length < 8) break;
      final int boxSize = _be32(boxHeader, 0);
      final String boxType = _ascii(boxHeader, 4, 4);
      if (boxSize < 8 || position + boxSize > itemEnd) break;
      if (boxType == 'data' && boxSize >= 16) {
        final int payloadStart = position + 16;
        final int payloadLength = boxSize - 16;
        if (payloadLength > 0) {
          switch (itemType) {
            case '©nam':
              tags.title = await _readMp4Text(file, payloadStart, payloadLength);
            case '©ART':
              tags.artist = await _readMp4Text(file, payloadStart, payloadLength);
            case 'aART':
              tags.artist ??=
                  await _readMp4Text(file, payloadStart, payloadLength);
            case '©alb':
              tags.album = await _readMp4Text(file, payloadStart, payloadLength);
            case 'covr':
              if (payloadLength <= _maxArtworkBytes &&
                  tags.artOffset == null) {
                tags.artOffset = payloadStart;
                tags.artLength = payloadLength;
              }
          }
        }
      }
      position += boxSize;
    }
    offset += itemSize;
  }
}

Future<String?> _readMp4Text(
  RandomAccessFile file,
  int offset,
  int length,
) async {
  if (length <= 0 || length > 1024 * 1024) return null;
  final Uint8List bytes = await _readAt(file, offset, length);
  return _clean(utf8.decode(bytes, allowMalformed: true));
}

// ---------------------------------------------------------------------------
// FLAC: STREAMINFO, VORBIS_COMMENT, PICTURE
// ---------------------------------------------------------------------------

Future<_Tags> _readFlac(RandomAccessFile file, int size) async {
  final Uint8List head = await _readAt(file, 0, math.min(4, size));
  if (_ascii(head, 0, 4) != 'fLaC') return const _Tags();

  int offset = 4;
  int sampleRate = 0;
  int totalSamples = 0;
  String? title;
  String? artist;
  String? album;
  int? artOffset;
  int? artLength;
  Uint8List? artBytes;

  while (offset + 4 <= size) {
    final Uint8List header = await _readAt(file, offset, 4);
    if (header.length < 4) break;
    final bool last = (header[0] & 0x80) != 0;
    final int type = header[0] & 0x7F;
    final int length = _be24(header, 1);
    final int dataStart = offset + 4;
    if (length < 0 || dataStart + length > size) break;

    if (type == 0 && length >= 18) {
      final Uint8List info = await _readAt(file, dataStart, math.min(34, length));
      if (info.length >= 18) {
        final int packed = _be64(info, 10);
        sampleRate = packed >> 44;
        totalSamples = packed & 0xFFFFFFFFF;
      }
    } else if (type == 4) {
      final Uint8List comments =
          await _readAt(file, dataStart, math.min(length, 4 * 1024 * 1024));
      final Map<String, String> fields = _parseVorbisComment(comments, 0);
      title = fields['TITLE'];
      artist = fields['ARTIST'] ?? fields['ALBUMARTIST'];
      album = fields['ALBUM'];
      final String? picture = fields['METADATA_BLOCK_PICTURE'];
      if (picture != null && picture.isNotEmpty) {
        artBytes = _pictureBytesFromBase64(picture);
      } else {
        final String? cover = fields['COVERART'];
        if (cover != null && cover.isNotEmpty) artBytes = _decodeBase64(cover);
      }
    } else if (type == 6 && artOffset == null) {
      final _FlacPicture? picture =
          await _readFlacPicture(file, dataStart, length);
      if (picture != null) {
        artOffset = picture.offset;
        artLength = picture.length;
      }
    }

    if (last) break;
    offset = dataStart + length;
  }

  Duration duration = Duration.zero;
  if (sampleRate > 0 && totalSamples > 0) {
    duration = Duration(
      microseconds: totalSamples * 1000000 ~/ sampleRate,
    );
  }

  return _Tags(
    title: title,
    artist: artist,
    album: album,
    duration: duration,
    artOffset: artOffset,
    artLength: artLength,
    artBytes: artBytes,
  );
}

class _FlacPicture {
  const _FlacPicture({required this.offset, required this.length});

  final int offset;
  final int length;
}

Future<_FlacPicture?> _readFlacPicture(
  RandomAccessFile file,
  int start,
  int length,
) async {
  if (length < 32) return null;
  final Uint8List head =
      await _readAt(file, start, math.min(length, 1024));
  if (head.length < 8) return null;
  final int mimeLength = _be32(head, 4);
  final int descriptionOffset = 8 + mimeLength;
  if (descriptionOffset + 4 > head.length) return null;
  final int descriptionLength = _be32(head, descriptionOffset);
  final int dataLengthOffset = descriptionOffset + 4 + descriptionLength + 16;
  if (dataLengthOffset + 4 > head.length) return null;
  final int dataLength = _be32(head, dataLengthOffset);
  final int dataOffset = start + dataLengthOffset + 4;
  if (dataLength <= 0 || dataLength > _maxArtworkBytes) return null;
  return _FlacPicture(offset: dataOffset, length: dataLength);
}

/// Разбирает блок Vorbis Comment: вендор, затем пары `КЛЮЧ=значение`.
///
/// [position] — смещение длины вендора: у FLAC блок начинается сразу с неё,
/// у Ogg перед ней стоит сигнатура `OpusTags` или `\x03vorbis`.
Map<String, String> _parseVorbisComment(Uint8List bytes, int position) {
  final Map<String, String> result = <String, String>{};
  if (position < 0 || position + 4 > bytes.length) return result;
  final int vendorLength = _le32(bytes, position);
  position += 4 + vendorLength;
  if (position + 4 > bytes.length) return result;
  final int count = _le32(bytes, position);
  position += 4;
  for (int i = 0; i < count && position + 4 <= bytes.length; i++) {
    final int length = _le32(bytes, position);
    position += 4;
    if (length < 0 || position + length > bytes.length) break;
    final String entry = utf8.decode(
      Uint8List.sublistView(bytes, position, position + length),
      allowMalformed: true,
    );
    position += length;
    final int equals = entry.indexOf('=');
    if (equals <= 0) continue;
    result[entry.substring(0, equals).toUpperCase()] =
        _clean(entry.substring(equals + 1)) ?? '';
  }
  return result;
}

/// Декодирует base64, отбрасывая мусор и слишком крупные картинки.
Uint8List? _decodeBase64(String value) {
  try {
    final Uint8List decoded = base64.decode(value.trim());
    if (decoded.isEmpty || decoded.length > _maxArtworkBytes) return null;
    return decoded;
  } on FormatException {
    return null;
  }
}

/// Картинка, закодированная в комментарии, — это тот же блок FLAC PICTURE,
/// только в base64. Устаревший `COVERART` хранит сразу байты картинки.
Uint8List? _pictureBytesFromBase64(String value) {
  final Uint8List? block = _decodeBase64(value);
  if (block == null || block.length < 32) return null;
  final int mimeLength = _be32(block, 4);
  final int descriptionOffset = 8 + mimeLength;
  if (descriptionOffset + 4 > block.length) return null;
  final int descriptionLength = _be32(block, descriptionOffset);
  final int dataLengthOffset = descriptionOffset + 4 + descriptionLength + 16;
  if (dataLengthOffset + 4 > block.length) return null;
  final int dataLength = _be32(block, dataLengthOffset);
  final int dataOffset = dataLengthOffset + 4;
  if (dataLength <= 0 || dataOffset + dataLength > block.length) return null;
  return Uint8List.sublistView(block, dataOffset, dataOffset + dataLength);
}

// ---------------------------------------------------------------------------
// Ogg/Opus: страницы Ogg, заголовки Vorbis/Opus, гранула в конце файла
// ---------------------------------------------------------------------------

Future<_Tags> _readOgg(RandomAccessFile file, int size) async {
  final int probeLength = math.min(size, 512 * 1024);
  final Uint8List probe = await _readAt(file, 0, probeLength);
  final List<Uint8List> packets = _oggPackets(probe, 3);

  int sampleRate = 0;
  int granule = 0;
  String? title;
  String? artist;
  String? album;
  Uint8List? artBytes;

  for (final Uint8List packet in packets) {
    if (packet.length >= 8 && _ascii(packet, 0, 8) == 'OpusHead') {
      sampleRate = 48000;
      continue;
    }
    if (packet.length >= 7 && _ascii(packet, 0, 7) == '\x01vorbis') {
      sampleRate = _le32(packet, 12);
      continue;
    }
    if (packet.length >= 8 && _ascii(packet, 0, 8) == 'OpusTags') {
      final Map<String, String> fields = _parseVorbisComment(packet, 8);
      title = fields['TITLE'];
      artist = fields['ARTIST'] ?? fields['ALBUMARTIST'];
      album = fields['ALBUM'];
      final String? picture = fields['METADATA_BLOCK_PICTURE'];
      if (picture != null && picture.isNotEmpty) {
        artBytes = _pictureBytesFromBase64(picture);
      } else {
        final String? cover = fields['COVERART'];
        if (cover != null && cover.isNotEmpty) {
          artBytes = _decodeBase64(cover);
        }
      }
      continue;
    }
    if (packet.length >= 7 && _ascii(packet, 0, 7) == '\x03vorbis') {
      final Map<String, String> fields = _parseVorbisComment(packet, 7);
      title ??= fields['TITLE'];
      artist ??= fields['ARTIST'] ?? fields['ALBUMARTIST'];
      album ??= fields['ALBUM'];
      final String? picture = fields['METADATA_BLOCK_PICTURE'];
      if (artBytes == null && picture != null && picture.isNotEmpty) {
        artBytes = _pictureBytesFromBase64(picture);
      }
    }
  }

  // Последняя страница: её гранула — число сэмплов всего потока.
  final int tailLength = math.min(size, 128 * 1024);
  final Uint8List tail = await _readAt(file, size - tailLength, tailLength);
  int search = tail.length - 4;
  while (search >= 0) {
    final int found = _lastIndexOfAscii(tail, 'OggS', search);
    if (found < 0) break;
    if (found + 14 <= tail.length) {
      final int low = _le32(tail, found + 6);
      final int high = _le32(tail, found + 10);
      final int value = low | (high << 32);
      if (value > 0) {
        granule = value;
        break;
      }
    }
    search = found - 1;
  }

  Duration duration = Duration.zero;
  if (sampleRate > 0 && granule > 0) {
    duration = Duration(microseconds: granule * 1000000 ~/ sampleRate);
  }

  return _Tags(
    title: title,
    artist: artist,
    album: album,
    duration: duration,
    artBytes: artBytes,
  );
}

/// Собирает первые пакеты Ogg из страниц.
///
/// Пакет может занимать несколько страниц: его куски склеиваются, пока
/// сегмент не окажется короче 255 байт.
List<Uint8List> _oggPackets(Uint8List bytes, int limit) {
  final List<Uint8List> packets = <Uint8List>[];
  Uint8List pending = Uint8List(0);
  int position = 0;

  while (position + 27 <= bytes.length && packets.length < limit) {
    if (_ascii(bytes, position, 4) != 'OggS') {
      final int next = _indexOfAscii(bytes, 'OggS', position + 1);
      if (next < 0) break;
      position = next;
      continue;
    }
    final int headerType = bytes[position + 5];
    final int segments = bytes[position + 26];
    if (position + 27 + segments > bytes.length) break;

    int payloadSize = 0;
    for (int i = 0; i < segments; i++) {
      payloadSize += bytes[position + 27 + i];
    }
    final int payloadStart = position + 27 + segments;
    if (payloadStart + payloadSize > bytes.length) break;

    // Если страница не продолжает пакет, недособранный пакет отбрасываем:
    // его начало потеряно и склеивать нечего.
    if ((headerType & 0x01) == 0) pending = Uint8List(0);

    int segmentOffset = payloadStart;
    for (int i = 0; i < segments; i++) {
      final int segmentLength = bytes[position + 27 + i];
      pending = _concat(
        pending,
        Uint8List.sublistView(
          bytes,
          segmentOffset,
          segmentOffset + segmentLength,
        ),
      );
      segmentOffset += segmentLength;
      if (segmentLength < 255) {
        packets.add(pending);
        pending = Uint8List(0);
        if (packets.length >= limit) break;
      }
    }
    position = payloadStart + payloadSize;
  }
  return packets;
}

Uint8List _concat(Uint8List a, Uint8List b) {
  if (a.isEmpty) return b;
  if (b.isEmpty) return a;
  final Uint8List result = Uint8List(a.length + b.length)
    ..setRange(0, a.length, a)
    ..setRange(a.length, a.length + b.length, b);
  return result;
}

int _indexOfAscii(Uint8List bytes, String pattern, int from) {
  final List<int> codes = pattern.codeUnits;
  for (int i = math.max(0, from); i + codes.length <= bytes.length; i++) {
    bool matches = true;
    for (int j = 0; j < codes.length; j++) {
      if (bytes[i + j] != codes[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return i;
  }
  return -1;
}

int _lastIndexOfAscii(Uint8List bytes, String pattern, int from) {
  final List<int> codes = pattern.codeUnits;
  final int start = math.min(from, bytes.length - codes.length);
  for (int i = start; i >= 0; i--) {
    bool matches = true;
    for (int j = 0; j < codes.length; j++) {
      if (bytes[i + j] != codes[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return i;
  }
  return -1;
}

// ---------------------------------------------------------------------------
// WAV: fmt, data, LIST/INFO
// ---------------------------------------------------------------------------

Future<_Tags> _readWav(RandomAccessFile file, int size) async {
  final Uint8List head = await _readAt(file, 0, math.min(12, size));
  if (head.length < 12 ||
      _ascii(head, 0, 4) != 'RIFF' ||
      _ascii(head, 8, 4) != 'WAVE') {
    return const _Tags();
  }

  String? title;
  String? artist;
  String? album;
  int byteRate = 0;
  int? dataSize;

  int offset = 12;
  while (offset + 8 <= size) {
    final Uint8List header = await _readAt(file, offset, 8);
    if (header.length < 8) break;
    final String type = _ascii(header, 0, 4);
    final int chunkSize = _le32(header, 4);
    if (chunkSize < 0) break;
    final int dataStart = offset + 8;
    if (dataStart + chunkSize > size) break;

    if (type == 'fmt ' && chunkSize >= 12) {
      final Uint8List format =
          await _readAt(file, dataStart, math.min(chunkSize, 16));
      if (format.length >= 12) byteRate = _le32(format, 8);
    } else if (type == 'data') {
      dataSize = chunkSize;
      if (byteRate > 0) break;
    } else if (type == 'LIST') {
      final Uint8List list =
          await _readAt(file, dataStart, math.min(chunkSize, 256 * 1024));
      if (_ascii(list, 0, 4) == 'INFO') {
        int position = 4;
        while (position + 8 <= list.length) {
          final String id = _ascii(list, position, 4);
          final int length = _le32(list, position + 4);
          position += 8;
          if (length < 0 || position + length > list.length) break;
          final String value = _clean(
            _decodeLegacy(
              Uint8List.sublistView(list, position, position + length),
            ),
          ) ??
              '';
          position += length + (length.isOdd ? 1 : 0);
          if (value.isEmpty) continue;
          switch (id) {
            case 'INAM':
              title = value;
            case 'IART':
              artist = value;
            case 'IPRD':
              album = value;
          }
        }
      }
    }
    offset = dataStart + chunkSize + (chunkSize.isOdd ? 1 : 0);
  }

  Duration duration = Duration.zero;
  if (dataSize != null && byteRate > 0) {
    duration = Duration(
      milliseconds: dataSize * 1000 ~/ byteRate,
    );
  }

  return _Tags(
    title: title,
    artist: artist,
    album: album,
    duration: duration,
  );
}
