import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../core/utils/format.dart';
import '../../data/local/local_media.dart';
import '../../data/models/models.dart';
import '../../state/player_controller.dart';
import '../../state/providers.dart';
import '../../widgets/empty_state.dart';
import '../common/navigation.dart';

/// Раздел «Локальные файлы» в коллекции.
///
/// Список собран вручную, а не через `TrackTile`: у локального трека нет
/// видео на YouTube, поэтому меню «радио», «скачать», «поделиться» и переходы
/// к исполнителю/альбому были бы нерабочими. Здесь нужны только название,
/// подпись, обложка из тега и запуск очереди.
class LocalFilesSection extends ConsumerWidget {
  const LocalFilesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final LocalMediaState media = ref.watch(localMediaControllerProvider);

    if (!media.hasFolder) {
      return EmptyState(
        icon: Icons.folder_outlined,
        title: 'Папка не выбрана',
        subtitle:
            'Укажите папку с музыкой в настройках — приложение найдёт файлы '
            'во всех подпапках. Поддерживаются mp3, m4a, flac, ogg, opus и wav.',
        action: FilledButton.icon(
          onPressed: () => AppRoutes.settings(context),
          icon: const Icon(Icons.settings_outlined),
          label: const Text('Открыть настройки'),
        ),
      );
    }

    if (media.scanning && media.files.isEmpty) {
      return const _ScanningPane();
    }

    final String? error = media.error;
    if (error != null) {
      return EmptyState(
        icon: Icons.folder_off_outlined,
        title: 'Не удалось прочитать папку',
        subtitle: error,
        action: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: <Widget>[
            FilledButton.tonalIcon(
              onPressed: () => ref.read(localMediaControllerProvider.notifier).rescan(),
              icon: const Icon(Icons.refresh),
              label: const Text('Повторить'),
            ),
            OutlinedButton.icon(
              onPressed: () => AppRoutes.settings(context),
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('Изменить папку'),
            ),
          ],
        ),
      );
    }

    if (media.files.isEmpty) {
      return EmptyState(
        icon: Icons.music_off_outlined,
        title: 'В папке нет музыки',
        subtitle: 'Проверьте путь в настройках или положите файлы в эту папку.',
        action: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: <Widget>[
            FilledButton.tonalIcon(
              onPressed: () => ref.read(localMediaControllerProvider.notifier).rescan(),
              icon: const Icon(Icons.refresh),
              label: const Text('Пересканировать'),
            ),
            OutlinedButton.icon(
              onPressed: () => AppRoutes.settings(context),
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('Изменить папку'),
            ),
          ],
        ),
      );
    }

    final List<Track> tracks =
        media.files.map((LocalMediaFile file) => file.toTrack()).toList();

    return CustomScrollView(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: _LocalHeader(
            folder: media.folder,
            count: media.files.length,
            scanning: media.scanning,
            onRescan: () =>
                ref.read(localMediaControllerProvider.notifier).rescan(),
            onPlayAll: () => ref
                .read(playerControllerProvider.notifier)
                .playQueue(tracks),
            onShuffle: () => ref
                .read(playerControllerProvider.notifier)
                .playQueue(
                  tracks,
                  startIndex: math.Random().nextInt(tracks.length),
                  shuffle: true,
                ),
          ),
        ),
        SliverList.builder(
          itemCount: media.files.length,
          itemBuilder: (BuildContext context, int index) => _LocalFileRow(
            file: media.files[index],
            track: tracks[index],
            tracks: tracks,
          ),
        ),
        const SliverToBoxAdapter(
          child: SizedBox(height: AppLayout.floatingDockClearance),
        ),
      ],
    );
  }
}

/// Папка читается впервые: показываем спиннер, а не пустой список.
class _ScanningPane extends StatelessWidget {
  const _ScanningPane();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(height: 16),
          Text(
            'Сканируем папку…',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

/// Шапка списка: путь, количество треков и кнопки запуска.
class _LocalHeader extends StatelessWidget {
  const _LocalHeader({
    required this.folder,
    required this.count,
    required this.scanning,
    required this.onRescan,
    required this.onPlayAll,
    required this.onShuffle,
  });

  final String folder;
  final int count;
  final bool scanning;
  final VoidCallback onRescan;
  final VoidCallback onPlayAll;
  final VoidCallback onShuffle;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Локальные файлы',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              if (scanning)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              IconButton(
                tooltip: 'Пересканировать',
                onPressed: scanning ? null : onRescan,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Tooltip(
            message: folder,
            child: Text(
              '${trackCountLabel(count)} · $folder',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                onPressed: onPlayAll,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Слушать'),
              ),
              OutlinedButton.icon(
                onPressed: onShuffle,
                icon: const Icon(Icons.shuffle, size: 18),
                label: const Text('Перемешать'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Строка локального файла.
class _LocalFileRow extends ConsumerWidget {
  const _LocalFileRow({
    required this.file,
    required this.track,
    required this.tracks,
  });

  final LocalMediaFile file;
  final Track track;
  final List<Track> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final bool current = ref.watch(
      playerControllerProvider.select(
        (PlayerUiState state) => state.current?.id == track.id,
      ),
    );

    final String details = <String>[
      if (file.artist != null) file.artist!,
      if (file.album != null) file.album!,
    ].join(' · ');

    return SizedBox(
      height: AppLayout.trackRowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Material(
          color: current ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(AppLayout.radiusS),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => ref
                .read(playerControllerProvider.notifier)
                .playTrack(track, context: tracks),
            child: Row(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: SizedBox(
                    width: AppLayout.trackArtwork,
                    height: AppLayout.trackArtwork,
                    child: _LocalArtwork(file: file),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          file.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleSmall?.copyWith(
                            color: current
                                ? scheme.onSecondaryContainer
                                : scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          details.isEmpty ? 'Файл без тегов' : details,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(
                            color: current
                                ? scheme.onSecondaryContainer
                                    .withValues(alpha: 0.7)
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          file.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.labelSmall?.copyWith(
                            color: current
                                ? scheme.onSecondaryContainer
                                    .withValues(alpha: 0.6)
                                : scheme.onSurfaceVariant
                                    .withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(
                    formatDuration(file.duration),
                    style: text.labelMedium?.copyWith(
                      color: current
                          ? scheme.onSecondaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Обложка, вложенная в тег файла.
///
/// Байты читаются по требованию и кладутся в маленький кэш: без него каждая
/// прокрутка списка заново открывала бы файлы и читала картинки.
class _LocalArtwork extends StatefulWidget {
  const _LocalArtwork({required this.file});

  final LocalMediaFile file;

  @override
  State<_LocalArtwork> createState() => _LocalArtworkState();
}

class _LocalArtworkState extends State<_LocalArtwork> {
  Uint8List? _bytes;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(_LocalArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _bytes = null;
      _start();
    }
  }

  void _start() {
    final LocalMediaFile file = widget.file;
    final Uint8List? cached = _LocalArtworkCache.get(file.path);
    if (cached != null) {
      _bytes = cached;
      return;
    }
    if (!file.hasArtwork) return;
    _loading = true;
    unawaited(_read(file));
  }

  Future<void> _read(LocalMediaFile file) async {
    final Uint8List? bytes = await file.readArtwork();
    if (!mounted || widget.file.path != file.path) return;
    if (bytes != null) _LocalArtworkCache.put(file.path, bytes);
    setState(() {
      _bytes = bytes;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Uint8List? bytes = _bytes;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppLayout.trackArtworkRadius),
      child: ColoredBox(
        color: scheme.surfaceContainerHighest,
        child: bytes != null
            ? Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => _placeholder(scheme, _loading),
              )
            : _placeholder(scheme, _loading),
      ),
    );
  }

  Widget _placeholder(ColorScheme scheme, bool loading) {
    return Center(
      child: loading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              Icons.music_note,
              size: 24,
              color: scheme.onSurfaceVariant,
            ),
    );
  }
}

/// Кэш обложек: ограничен по количеству файлов, чтобы большая папка не
/// занимала память целиком.
abstract final class _LocalArtworkCache {
  static const int _limit = 128;
  static final Map<String, Uint8List> _entries = <String, Uint8List>{};

  static Uint8List? get(String path) => _entries[path];

  static void put(String path, Uint8List bytes) {
    if (_entries.length >= _limit && !_entries.containsKey(path)) {
      _entries.remove(_entries.keys.first);
    }
    _entries[path] = bytes;
  }
}
