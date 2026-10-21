import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'json_store.dart';
import 'lyrics_cache.dart' show appDataDirectory;

/// Ошибка загрузки, которую можно показать пользователю словами.
class DownloadsException implements Exception {
  DownloadsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Запись о скачанном треке.
///
/// Хранит только то, что нужно, чтобы показать трек без сети и снова его
/// включить: имя, исполнителей, альбом и длительность. Ссылка на поток не
/// сохраняется — она живёт несколько часов, а файл на диске уже не зависит от
/// неё. Обложка необязательна: без интернета она не загрузится, но её адрес
/// пригодится, когда сеть появится.
@immutable
class DownloadedTrack {
  const DownloadedTrack({
    required this.id,
    required this.title,
    this.artists = const <String>[],
    this.album,
    this.duration = Duration.zero,
    this.artworkUrl,
    this.bytes = 0,
    required this.downloadedAt,
    this.container,
  });

  /// YouTube videoId — он же имя файла.
  final String id;
  final String title;
  final List<String> artists;
  final String? album;
  final Duration duration;
  final String? artworkUrl;

  /// Размер файла на момент завершения загрузки.
  final int bytes;
  final DateTime downloadedAt;

  /// Фактический контейнер потока (`m4a` или `webm`). Расширение файла при
  /// этом всегда [DownloadsStore.audioExtension] — см. пояснение у хранилища.
  final String? container;

  String get artistLine => artists.isEmpty
      ? 'Неизвестный исполнитель'
      : artists.join(', ');

  /// Трек для списков, очереди и плеера.
  Track toTrack() => Track(
        id: id,
        title: title,
        artists: <ArtistRef>[
          for (final String name in artists) ArtistRef(name: name),
        ],
        album: album == null ? null : AlbumRef(name: album!),
        duration: duration,
        thumbnails: artworkUrl == null
            ? const <Thumbnail>[]
            : <Thumbnail>[Thumbnail(url: artworkUrl!)],
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'artists': artists,
        'album': album,
        'durationMs': duration.inMilliseconds,
        'artwork': artworkUrl,
        'bytes': bytes,
        'at': downloadedAt.millisecondsSinceEpoch,
        'container': container,
      };

  /// Разбирает запись; битая строка пропускается, а не обнуляет весь список.
  static DownloadedTrack? fromJson(dynamic raw) {
    if (raw is! Map<String, dynamic>) return null;
    final dynamic id = raw['id'];
    final dynamic title = raw['title'];
    final dynamic at = raw['at'];
    if (id is! String || id.isEmpty || at is! num) return null;

    final dynamic artists = raw['artists'];
    final dynamic album = raw['album'];
    final dynamic duration = raw['durationMs'];
    final dynamic artwork = raw['artwork'];
    final dynamic bytes = raw['bytes'];
    final dynamic container = raw['container'];

    return DownloadedTrack(
      id: id,
      title: title is String && title.trim().isNotEmpty
          ? title.trim()
          : 'Без названия',
      artists: artists is List
          ? artists
              .whereType<String>()
              .map((String name) => name.trim())
              .where((String name) => name.isNotEmpty)
              .toList(growable: false)
          : const <String>[],
      album: album is String && album.trim().isNotEmpty ? album.trim() : null,
      duration: duration is num
          ? Duration(milliseconds: duration.toInt().clamp(0, 1 << 31))
          : Duration.zero,
      artworkUrl:
          artwork is String && artwork.trim().isNotEmpty ? artwork : null,
      bytes: bytes is num ? bytes.toInt().clamp(0, 1 << 42) : 0,
      downloadedAt: DateTime.fromMillisecondsSinceEpoch(at.toInt()),
      container:
          container is String && container.trim().isNotEmpty ? container : null,
    );
  }
}

/// Каталог загрузок и их метаданные.
///
/// Загрузки — не кэш: пользователь просил сохранить трек, поэтому они лежат
/// в каталоге данных приложения (рядом с настройками и журналом) и переживают
/// очистку временных файлов. Аудио — отдельными файлами, метаданные — одним
/// JSON: список небольшой, а переписывать его целиком дешевле, чем держать
/// отдельный файл на каждый трек.
///
/// Файл всегда называется `<videoId>.m4a`, как в эталонном приложении. При
/// скачивании мы просим поток в контейнере m4a; если YouTube такого не отдал,
/// в метаданных останется фактический контейнер (`webm`), а плеер всё равно
/// играет файл по содержимому, а не по расширению.
class DownloadsStore {
  DownloadsStore({this.fileName = 'downloads.json', Directory? directory})
      : _directoryOverride = directory;

  final String fileName;

  /// Каталог для проверок и тестов; в приложении — `null`, и тогда аудио
  /// лежит в подкаталоге данных приложения.
  final Directory? _directoryOverride;

  /// Имя подкаталога с аудио внутри каталога данных.
  static const String directoryName = 'downloads';

  static const String audioExtension = 'm4a';
  static const String partialExtension = 'part';

  List<DownloadedTrack>? _memory;
  Map<String, int?> _partials = <String, int?>{};

  /// Файл метаданных: атомарная запись и запрет записи до чтения — иначе
  /// после сбоя чтения список загрузок затирался бы пустым.
  late final JsonStore _json = JsonStore(resolve: _metaFile, label: 'Downloads');

  /// Файл прочитан не был: записи в него не будет. Аудиофайлы при этом
  /// остаются на диске, поэтому список нельзя перезаписывать «с нуля».
  bool get readFailed => _json.readFailed;

  /// Файл читается один раз: параллельные чтения ждут ту же загрузку.
  Future<void>? _loading;

  /// Все завершённые загрузки, новые сверху.
  Future<List<DownloadedTrack>> readAll() async {
    await _ensureLoaded();
    return List<DownloadedTrack>.unmodifiable(
      _memory ?? const <DownloadedTrack>[],
    );
  }

  /// Путь к готовому файлу или `null`, если трек не скачан.
  ///
  /// Файл проверяется на диске: метаданные могли остаться, а файл — пропасть
  /// (пользователь почистил каталог вручную). В таком случае сеть остаётся
  /// рабочим путём, а офлайн-ветка честно скажет, что трека нет.
  Future<String?> localPath(String videoId) async {
    if (videoId.isEmpty) return null;
    final List<DownloadedTrack> items = await readAll();
    if (!items.any((DownloadedTrack item) => item.id == videoId)) return null;

    try {
      final File file = await finalFile(videoId);
      if (!file.existsSync() || await file.length() == 0) return null;
      return file.path;
    } on FileSystemException {
      return null;
    }
  }

  /// Ожидаемый размер начатой загрузки — по нему докачка понимает, когда
  /// файл уже полон.
  Future<int?> partialExpected(String videoId) async {
    await _ensureLoaded();
    return _partials[videoId];
  }

  /// Запоминает размер, до которого нужно докачать файл.
  ///
  /// Нужен, чтобы после перезапуска приложения не начинать с нуля и не
  /// считать оборванный файл целым.
  Future<void> markPartial(String videoId, int? expectedBytes) async {
    await _ensureLoaded();
    if (_partials[videoId] == expectedBytes) return;
    _partials[videoId] = expectedBytes;
    await _persist();
  }

  /// Готовый файл трека.
  Future<File> finalFile(String videoId) async {
    final Directory dir = await _downloadsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$videoId.$audioExtension');
  }

  /// Недокачанный файл: лежит рядом и переименовывается только после проверки.
  Future<File> partialFile(String videoId) async {
    final File file = await finalFile(videoId);
    return File('${file.path}.$partialExtension');
  }

  /// Переносит недокачанный файл на место готового и записывает метаданные.
  Future<DownloadedTrack> complete({
    required Track track,
    required int bytes,
    String? container,
  }) async {
    await _ensureLoaded();

    final File part = await partialFile(track.id);
    final File file = await finalFile(track.id);
    if (!part.existsSync()) {
      throw DownloadsException('Недокачанный файл пропал — скачайте трек заново.');
    }
    if (file.existsSync()) await file.delete();
    await part.rename(file.path);

    final DownloadedTrack item = DownloadedTrack(
      id: track.id,
      title: track.title,
      artists: <String>[
        for (final ArtistRef artist in track.artists) artist.name,
      ],
      album: track.album?.name,
      duration: track.duration,
      artworkUrl: track.artwork,
      bytes: bytes,
      downloadedAt: DateTime.now(),
      container: container,
    );

    final List<DownloadedTrack> previousItems =
        _memory ?? const <DownloadedTrack>[];
    final Map<String, int?> previousPartials = Map<String, int?>.of(_partials);

    _memory = <DownloadedTrack>[
      item,
      for (final DownloadedTrack existing in previousItems)
        if (existing.id != track.id) existing,
    ];
    _partials.remove(track.id);
    if (!await _persist()) {
      // Список не сохранился — значит после перезапуска трек «пропадёт», хотя
      // файл скачан. Честнее вернуть его в недокачанное состояние и сказать
      // об ошибке, чем показывать скачанным то, чего нет в метаданных.
      _memory = previousItems;
      _partials = previousPartials;
      try {
        if (file.existsSync()) await file.rename(part.path);
      } on FileSystemException catch (error) {
        debugPrint('[Downloads] не удалось вернуть файл в .part: $error');
      }
      throw DownloadsException(
        'Файл скачан, но список загрузок сохранить не удалось. '
        'Проверьте свободное место и права на каталог данных.',
      );
    }
    return item;
  }

  /// Удаляет загрузку: файл, недокачанный остаток и запись.
  ///
  /// Ошибку удаления не глотаем: на Windows файл, открытый плеером, нельзя
  /// удалить, и пользователь должен узнать, почему место не освободилось.
  Future<void> remove(String videoId) async {
    await _ensureLoaded();

    final File file = await finalFile(videoId);
    if (file.existsSync()) {
      try {
        await file.delete();
      } on FileSystemException catch (error) {
        debugPrint('[Downloads] не удалось удалить ${file.path}: $error');
        throw DownloadsException(
          'Не удалось удалить файл: возможно, трек сейчас играет. '
          'Остановите воспроизведение и повторите.',
        );
      }
    }

    final File part = await partialFile(videoId);
    if (part.existsSync()) {
      try {
        await part.delete();
      } on FileSystemException catch (error) {
        debugPrint('[Downloads] не удалось удалить ${part.path}: $error');
      }
    }

    _memory = <DownloadedTrack>[
      for (final DownloadedTrack item in _memory ?? const <DownloadedTrack>[])
        if (item.id != videoId) item,
    ];
    _partials.remove(videoId);
    await _persist();
  }

  /// Убирает недокачанный остаток, который больше не годится (например,
  /// сервер отдал вместо аудио страницу ошибки).
  Future<void> discardPartial(String videoId) async {
    await _ensureLoaded();
    final File part = await partialFile(videoId);
    try {
      if (part.existsSync()) await part.delete();
    } on FileSystemException catch (error) {
      debugPrint('[Downloads] не удалось удалить ${part.path}: $error');
    }
    if (_partials.remove(videoId) != null) await _persist();
  }

  /// Суммарный размер всех загрузок.
  Future<int> totalBytes() async {
    final List<DownloadedTrack> items = await readAll();
    return items.fold<int>(
      0,
      (int sum, DownloadedTrack item) => sum + item.bytes,
    );
  }

  Future<Directory> _downloadsDirectory() async {
    final Directory? override = _directoryOverride;
    if (override != null) {
      if (!override.existsSync()) await override.create(recursive: true);
      return override;
    }
    final Directory base = await appDataDirectory();
    final Directory dir =
        Directory('${base.path}${Platform.pathSeparator}$directoryName');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _ensureLoaded() async {
    if (_memory != null) return;
    _loading ??= _loadFromDisk();
    await _loading;
  }

  Future<void> _loadFromDisk() async {
    final dynamic decoded = await _json.read();
    final List<DownloadedTrack> parsed = <DownloadedTrack>[];
    final Map<String, int?> partials = <String, int?>{};

    if (decoded is Map<String, dynamic>) {
      final dynamic tracks = decoded['tracks'];
      if (tracks is List) {
        for (final dynamic item in tracks) {
          final DownloadedTrack? track = DownloadedTrack.fromJson(item);
          if (track != null) parsed.add(track);
        }
      }
      final dynamic stored = decoded['partials'];
      if (stored is Map) {
        for (final MapEntry<dynamic, dynamic> entry in stored.entries) {
          final String id = '${entry.key}';
          if (id.isEmpty) continue;
          final dynamic value = entry.value;
          final dynamic expected =
              value is Map<String, dynamic> ? value['expected'] : null;
          partials[id] = expected is num ? expected.toInt() : null;
        }
      }
    }
    if (_json.readFailed) {
      // Не «загрузок нет», а «список не прочитан». Писать в файл нельзя:
      // записи о скачанных треках потерялись бы, а файлы остались бы сиротами.
      debugPrint('[Downloads] список не прочитан — запись отключена');
    }

    // Запись без файла бесполезна и вводила бы в заблуждение: трек показан
    // скачанным, а играть нечего. Такие записи отбрасываем при чтении.
    final List<DownloadedTrack> existing = <DownloadedTrack>[];
    for (final DownloadedTrack item in parsed) {
      try {
        final File file = await finalFile(item.id);
        if (file.existsSync() && await file.length() > 0) existing.add(item);
      } on Object catch (error) {
        debugPrint('[Downloads] не удалось проверить файл ${item.id}: $error');
      }
    }
    existing.sort((DownloadedTrack a, DownloadedTrack b) =>
        b.downloadedAt.compareTo(a.downloadedAt));

    _memory = existing;
    _partials = <String, int?>{
      for (final MapEntry<String, int?> entry in partials.entries)
        if (existing.every((DownloadedTrack item) => item.id != entry.key))
          entry.key: entry.value,
    };
  }

  Future<bool> _persist() async {
    final String payload = jsonEncode(<String, dynamic>{
      'version': 1,
      'tracks': <Map<String, dynamic>>[
        for (final DownloadedTrack item in _memory ?? const <DownloadedTrack>[])
          item.toJson(),
      ],
      'partials': <String, dynamic>{
        for (final MapEntry<String, int?> entry in _partials.entries)
          entry.key: <String, dynamic>{'expected': entry.value},
      },
    });
    final bool saved = await _json.writeString(payload);
    if (!saved) debugPrint('[Downloads] список загрузок не сохранён');
    return saved;
  }

  Future<File> _metaFile() async {
    final Directory base = _directoryOverride ?? await appDataDirectory();
    if (!base.existsSync()) await base.create(recursive: true);
    return File('${base.path}${Platform.pathSeparator}$fileName');
  }
}

/// Проверяет, что скачанное действительно аудио.
///
/// Медиасервер иногда отвечает `200` с HTML-страницей (ошибка, заглушка
/// провайдера). Такой файл нельзя ни играть, ни докачивать: продолжение
/// дописало бы мусор к мусору. Поэтому перед переименованием смотрим
/// сигнатуру контейнера и ожидаемый размер.
///
/// Возвращает текст проблемы или `null`, если файл похож на аудио.
Future<String?> verifyDownloadedAudio(
  File file, {
  int? expectedBytes,
}) async {
  final int length;
  try {
    if (!file.existsSync()) return 'Файл не найден: сервер не отдал поток.';
    length = await file.length();
  } on FileSystemException catch (error) {
    return 'Не удалось прочитать скачанный файл: ${error.message}.';
  }

  if (length == 0) {
    return 'Сервер не отдал ни одного байта трека.';
  }
  if (expectedBytes != null && length < expectedBytes) {
    return 'Загрузка оборвалась: получено $length из $expectedBytes байт.';
  }

  RandomAccessFile? handle;
  try {
    handle = await file.open();
    final List<int> head = await handle.read(12);
    if (!_looksLikeAudio(head)) {
      return 'Сервер вернул не аудиофайл: вместо потока пришла страница '
          'ошибки. Попробуйте другой источник потока в настройках.';
    }
  } on FileSystemException catch (error) {
    return 'Не удалось прочитать скачанный файл: ${error.message}.';
  } finally {
    try {
      await handle?.close();
    } on FileSystemException {
      // Закрытие не влияет на результат проверки.
    }
  }
  return null;
}

/// Сигнатуры контейнеров, которые умеет играть движок.
bool _looksLikeAudio(List<int> head) {
  bool matches(int offset, String ascii) {
    if (head.length < offset + ascii.length) return false;
    for (int i = 0; i < ascii.length; i++) {
      if (head[offset + i] != ascii.codeUnitAt(i)) return false;
    }
    return true;
  }

  // MP4/M4A: размер + `ftyp`. WebM/Matroska: EBML-заголовок.
  if (matches(4, 'ftyp')) return true;
  if (head.length >= 4 &&
      head[0] == 0x1A &&
      head[1] == 0x45 &&
      head[2] == 0xDF &&
      head[3] == 0xA3) {
    return true;
  }
  // Ogg/Opus, FLAC, MP3 (ID3 или кадр MPEG) и ADTS AAC.
  if (matches(0, 'OggS')) return true;
  if (matches(0, 'fLaC')) return true;
  if (matches(0, 'ID3')) return true;
  if (head.length >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) {
    return true;
  }
  return false;
}
