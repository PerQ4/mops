import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Скачивает аудиопоток через приложение на диск.
///
/// Зачем это нужно: обход блокировок реализован на уровне HTTP-клиента
/// приложения (`dart:io`), а звук на Linux воспроизводит GStreamer — он ходит
/// в сеть сам и про обход не знает. Поэтому при включённом обходе поток
/// сначала скачивается сюда, а затем отдаётся движку как локальный файл.
///
/// Побочная выгода — прослушанные треки остаются в кэше и играют мгновенно.
class StreamDownloader {
  StreamDownloader({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  /// Ограничение кэша, после которого старые треки удаляются.
  static const int maxCacheBytes = 700 * 1024 * 1024;

  Directory? _cacheDir;

  Future<Directory> _directory() async {
    final Directory? cached = _cacheDir;
    if (cached != null && cached.existsSync()) return cached;

    final Directory base = await getTemporaryDirectory();
    final Directory dir = Directory('${base.path}/mops_audio');
    if (!dir.existsSync()) await dir.create(recursive: true);
    _cacheDir = dir;
    return dir;
  }

  /// Возвращает путь к файлу с потоком.
  ///
  /// Если файл уже скачан, сеть не используется. [onProgress] получает
  /// значение от 0 до 1, когда сервер сообщает размер.
  Future<String> fetch(
    Uri url, {
    required String cacheKey,
    void Function(double progress)? onProgress,
  }) async {
    final Directory dir = await _directory();
    final File file = File('${dir.path}/$cacheKey.audio');

    // Уже скачано — отдаём сразу.
    if (file.existsSync() && await file.length() > 0) {
      onProgress?.call(1);
      return file.path;
    }

    final File partial = File('${file.path}.part');
    final HttpClientRequest request = await _client.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);

    final HttpClientResponse response = await request.close();
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw StreamDownloadException(
        'Сервер вернул HTTP ${response.statusCode} при загрузке трека.',
      );
    }

    final int total = response.contentLength;
    int received = 0;
    final IOSink sink = partial.openWrite();

    try {
      await for (final List<int> chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress?.call((received / total).clamp(0.0, 1.0));
        }
      }
      await sink.flush();
      await sink.close();
    } on Object {
      await sink.close();
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
      final List<FileSystemEntity> entries = dir.listSync();
      final List<File> files = entries.whereType<File>().toList();
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
    final Directory dir = await _directory();
    if (dir.existsSync()) await dir.delete(recursive: true);
    _cacheDir = null;
  }

  /// Размер кэша в байтах.
  Future<int> cacheSize() async {
    final Directory dir = await _directory();
    if (!dir.existsSync()) return 0;
    int total = 0;
    for (final FileSystemEntity entry in dir.listSync()) {
      if (entry is File) total += await entry.length();
    }
    return total;
  }

  void dispose() => _client.close(force: true);

  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0';
}

/// Ошибка загрузки потока с понятным пользователю текстом.
class StreamDownloadException implements Exception {
  StreamDownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}
