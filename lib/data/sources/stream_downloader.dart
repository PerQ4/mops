import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'range_downloader.dart';

/// Исключение живёт в загрузчике диапазонов — переэкспортируем,
/// чтобы вызывающий код не зависел от расположения файлов.
export 'range_downloader.dart' show StreamDownloadException;

/// Скачивает аудиопоток через приложение в кэш.
///
/// Зачем это нужно: обход блокировок реализован на уровне HTTP-клиента
/// приложения (`dart:io`), а звук на Linux воспроизводит GStreamer — он ходит
/// в сеть сам и про обход не знает. Поэтому при обходе поток сначала
/// скачивается сюда, а затем отдаётся движку как локальный файл.
///
/// Побочная выгода — прослушанные треки остаются в кэше и играют мгновенно.
///
/// Само скачивание живёт в [RangeDownloader]: медиасерверы YouTube отдают
/// файл только по явному диапазону, и это правило вынесено в чистый Dart,
/// чтобы его можно было проверить без запуска Flutter.
class StreamDownloader {
  StreamDownloader({
    HttpClient? client,
    this.directory,
    RangeDownloader? downloader,
  }) : _downloader = downloader ?? RangeDownloader(client: client);

  final RangeDownloader _downloader;

  /// Каталог кэша. Если не задан — берётся временный каталог приложения.
  Directory? directory;

  /// Ограничение кэша, после которого старые треки удаляются.
  static const int maxCacheBytes = 700 * 1024 * 1024;

  Future<Directory> _resolveDirectory() async {
    final Directory? existing = directory;
    if (existing != null) {
      if (!existing.existsSync()) await existing.create(recursive: true);
      return existing;
    }

    final Directory base = await getTemporaryDirectory();
    final Directory dir = Directory('${base.path}/mops_audio');
    if (!dir.existsSync()) await dir.create(recursive: true);
    directory = dir;
    return dir;
  }

  /// Возвращает путь к файлу с потоком.
  ///
  /// Если файл уже скачан, сеть не используется.
  Future<String> fetch(
    Uri url, {
    required String cacheKey,
    void Function(double progress)? onProgress,
  }) async {
    final Directory dir = await _resolveDirectory();
    final File file = File('${dir.path}/$cacheKey.audio');

    if (file.existsSync() && await file.length() > 0) {
      onProgress?.call(1);
      return file.path;
    }

    final File partial = File('${file.path}.part');
    try {
      await _downloader.downloadTo(url, partial, onProgress: onProgress);
    } on Object {
      if (partial.existsSync()) await partial.delete();
      rethrow;
    }

    // Переименовываем только полностью скачанный файл.
    await partial.rename(file.path);
    unawaited(_trimCache(dir, keep: file.path));
    onProgress?.call(1);
    return file.path;
  }

  /// Удаляет старые файлы, если кэш превысил лимит.
  Future<void> _trimCache(Directory dir, {required String keep}) async {
    try {
      final List<File> files = dir.listSync().whereType<File>().toList();
      int total = 0;
      for (final File file in files) {
        total += await file.length();
      }
      if (total <= maxCacheBytes) return;

      files.sort((File a, File b) =>
          a.statSync().modified.compareTo(b.statSync().modified));

      for (final File file in files) {
        if (total <= maxCacheBytes) break;
        if (file.path == keep) continue;
        total -= await file.length();
        await file.delete();
      }
    } on FileSystemException {
      // Кэш — не критичная часть: при сбое просто ничего не удаляем.
    }
  }

  /// Удаляет весь кэш аудио.
  Future<void> clearCache() async {
    final Directory dir = await _resolveDirectory();
    if (dir.existsSync()) await dir.delete(recursive: true);
    directory = null;
  }

  /// Размер кэша в байтах.
  Future<int> cacheSize() async {
    final Directory dir = await _resolveDirectory();
    if (!dir.existsSync()) return 0;
    int total = 0;
    for (final FileSystemEntity entry in dir.listSync()) {
      if (entry is File) total += await entry.length();
    }
    return total;
  }

  void dispose() => _downloader.dispose();
}
