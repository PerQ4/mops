import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/lyrics_cache.dart';
import '../../state/catalog_providers.dart';
import '../../state/lyrics_edits.dart';

/// Хранилище: сколько места занимают данные приложения и очистка кэша текстов.
///
/// Размер считается по реальным файлам на диске (`dart:io`), а не по числу
/// записей в памяти: файл может быть вытеснен, обрезан или переписан — важно
/// именно то, что лежит в каталоге данных.
///
/// Загрузок треков для офлайн-прослушивания в mOps пока нет (задача 2.1), как
/// и кэша обложек, поэтому в списке только то, что существует: кэш текстов,
/// ручные правки и сессия входа. Притворяться, что загрузки есть, нельзя —
/// кнопки очистили бы пустоту.
class StorageScreen extends ConsumerStatefulWidget {
  const StorageScreen({super.key});

  @override
  ConsumerState<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends ConsumerState<StorageScreen> {
  bool _busy = false;
  _StorageUsage? _usage;
  String? _message;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// Пересчитывает занятое место. `null` в полях означает, что посчитать не
  /// удалось: показываем «нет данных», а не ноль — ноль означал бы пустой
  /// каталог, то есть другое состояние.
  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final Directory dir = await appDataDirectory();
      final LyricsCache cache = ref.read(lyricsCacheProvider);
      final LyricsEditsStore edits = ref.read(lyricsEditsStoreProvider);

      final File cacheFile =
          File('${dir.path}${Platform.pathSeparator}${cache.fileName}');
      final File editsFile =
          File('${dir.path}${Platform.pathSeparator}${edits.fileName}');

      final int? cacheBytes = await _fileSize(cacheFile);
      final int? editsBytes = await _fileSize(editsFile);
      final ({int bytes, int files})? total = await _dirTotal(dir);
      final int? totalBytes = total?.bytes;

      // «Остальное» — это сессия и всё, что рядом; отрицательным быть не
      // может, но при округлении или частичном сбое подстрахуемся.
      int? otherBytes;
      if (totalBytes != null && cacheBytes != null && editsBytes != null) {
        final int rest = totalBytes - cacheBytes - editsBytes;
        otherBytes = rest < 0 ? 0 : rest;
      }

      if (!mounted) return;
      setState(() {
        _busy = false;
        _usage = _StorageUsage(
          directoryPath: dir.path,
          totalBytes: totalBytes,
          fileCount: total?.files,
          lyricsCacheBytes: cacheBytes,
          editsBytes: editsBytes,
          otherBytes: otherBytes,
        );
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _usage = null;
        _error = 'Не удалось прочитать каталог данных: $error';
      });
    }
  }

  /// Очистка идёт методом кэша, а не удалением файла: `clear()` чистит и
  /// память, иначе приложение продолжило бы отдавать тексты из памяти, а на
  /// диске их уже не было бы — состояние разъехалось бы.
  Future<void> _clearLyricsCache() async {
    final bool confirmed = await _confirmClear() ?? false;
    if (!confirmed) return;

    setState(() {
      _busy = true;
      _message = null;
      _error = null;
    });

    try {
      await ref.read(lyricsCacheProvider).clear();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = 'Кэш текстов очищен. Ручные правки текста сохранены.';
      });
      // Размер показываем по диску — то есть уже после очистки.
      await _refresh();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Не удалось очистить кэш текстов: $error';
      });
    }
  }

  Future<bool?> _confirmClear() {
    return showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Очистить кэш текстов?'),
        content: const Text(
          'Найденные тексты будут удалены и при следующем открытии трека '
          'загрузятся заново. Ручные правки текста не затрагиваются.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Очистить'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final _StorageUsage? usage = _usage;
    final int? fileCount = usage?.fileCount;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Хранилище'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Обновить',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: <Widget>[
          Text(
            'Данные приложения лежат в одном каталоге. Ниже — сколько места '
            'занимает каждый файл и кэш текстов, который можно очистить.',
            style: text.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),

          const Divider(height: 32),
          const _SectionHeader('Каталог данных'),
          SelectableText(
            usage?.directoryPath ?? 'нет данных',
            style: text.bodyMedium?.copyWith(
              fontFamily: 'monospace',
              color: scheme.onSurfaceVariant,
            ),
          ),

          const Divider(height: 32),
          const _SectionHeader('Занятое место'),
          _SizeTile(
            icon: Icons.lyrics_outlined,
            label: 'Кэш текстов',
            bytes: usage?.lyricsCacheBytes,
            caption: 'Найденные тексты: id трека + источник',
          ),
          _SizeTile(
            icon: Icons.edit_note_outlined,
            label: 'Правки текста',
            bytes: usage?.editsBytes,
            caption: 'Ручные правки — не кэш, очисткой не удаляются',
          ),
          _SizeTile(
            icon: Icons.folder_outlined,
            label: 'Остальное в каталоге',
            bytes: usage?.otherBytes,
            caption: 'Сессия входа и прочие данные приложения',
          ),
          const Divider(height: 24),
          _SizeTile(
            icon: Icons.storage_outlined,
            label: 'Всего',
            bytes: usage?.totalBytes,
            caption: fileCount == null
                ? null
                : '$fileCount ${_filesWord(fileCount)}',
          ),
          if (usage == null && _error == null && !_busy)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Размер посчитать не удалось.',
                style: text.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Загрузок треков для офлайн-прослушивания и кэша обложек в mOps '
              'пока нет, поэтому их в списке нет.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),

          const Divider(height: 32),
          const _SectionHeader('Очистка'),
          Text(
            'Кэш текстов можно очистить целиком: место освободится, а тексты '
            'при следующем открытии трека загрузятся заново. Ручные правки '
            'текста сохраняются — это не кэш, а ваша работа.',
            style: text.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: _busy ? null : _clearLyricsCache,
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text('Очистить кэш текстов'),
            ),
          ),

          if (_message != null) ...<Widget>[
            const SizedBox(height: 20),
            _ResultLine(
              icon: Icons.check_circle_outline,
              text: _message!,
              color: scheme.primary,
            ),
          ],
          if (_error != null) ...<Widget>[
            const SizedBox(height: 20),
            _ResultLine(
              icon: Icons.error_outline,
              text: _error!,
              color: scheme.error,
            ),
          ],
        ],
      ),
    );
  }
}

/// Снимок занятого места. Каждое поле — `null`, если посчитать не удалось.
class _StorageUsage {
  const _StorageUsage({
    required this.directoryPath,
    required this.totalBytes,
    required this.fileCount,
    required this.lyricsCacheBytes,
    required this.editsBytes,
    required this.otherBytes,
  });

  final String directoryPath;
  final int? totalBytes;
  final int? fileCount;
  final int? lyricsCacheBytes;
  final int? editsBytes;
  final int? otherBytes;
}

/// Размер одного файла; `null` — файл есть, но прочитать его не вышло.
Future<int?> _fileSize(File file) async {
  try {
    if (!file.existsSync()) return 0;
    return await file.length();
  } on FileSystemException {
    return null;
  }
}

/// Суммарный размер каталога и число файлов; `null` — обойти не удалось.
Future<({int bytes, int files})?> _dirTotal(Directory dir) async {
  try {
    int bytes = 0;
    int files = 0;
    await for (final FileSystemEntity entity
        in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      bytes += await entity.length();
      files++;
    }
    return (bytes: bytes, files: files);
  } on FileSystemException {
    return null;
  }
}

/// Человекочитаемый размер: байты, килобайты, мегабайты, гигабайты.
String _formatBytes(int bytes) {
  const int kb = 1024;
  const int mb = kb * 1024;
  const int gb = mb * 1024;
  if (bytes < kb) return '$bytes Б';
  if (bytes < mb) return '${(bytes / kb).toStringAsFixed(1)} КБ';
  if (bytes < gb) return '${(bytes / mb).toStringAsFixed(1)} МБ';
  return '${(bytes / gb).toStringAsFixed(2)} ГБ';
}

/// Согласование слова «файл» с числом.
String _filesWord(int count) {
  final int mod100 = count % 100;
  final int mod10 = count % 10;
  if (mod100 >= 11 && mod100 <= 14) return 'файлов';
  if (mod10 == 1) return 'файл';
  if (mod10 >= 2 && mod10 <= 4) return 'файла';
  return 'файлов';
}

class _SizeTile extends StatelessWidget {
  const _SizeTile({
    required this.icon,
    required this.label,
    required this.bytes,
    this.caption,
  });

  final IconData icon;
  final String label;
  final int? bytes;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: scheme.onSurfaceVariant),
      title: Text(label),
      subtitle: caption == null
          ? null
          : Text(
              caption!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
      trailing: Text(
        bytes == null ? 'нет данных' : _formatBytes(bytes!),
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: bytes == null ? scheme.onSurfaceVariant : scheme.onSurface,
            ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _ResultLine extends StatelessWidget {
  const _ResultLine({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
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
    );
  }
}
