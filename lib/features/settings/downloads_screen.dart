import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../core/utils/format.dart';
import '../../data/local/downloads.dart';
import '../../data/models/models.dart';
import '../../state/player_controller.dart';
import '../../state/providers.dart';
import '../../widgets/app_progress.dart';
import '../../widgets/track_menu.dart';
import '../../widgets/track_tile.dart';

/// Экран «Загрузки»: что скачано, сколько это занимает и как это убрать.
///
/// Список и прогресс берутся из [downloadsControllerProvider]: тот же источник
/// рисует пункт меню трека и подпись в островке, поэтому здесь не бывает
/// «скачано», пока файл ещё пишется.
class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DownloadsState downloads = ref.watch(downloadsControllerProvider);
    final List<Track> queue = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.queue),
    );
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    // В очередь на скачивание попадают только те треки, которых ещё нет:
    // «Скачать всё» не должно заново тянуть уже сохранённое.
    final List<Track> pending = <Track>[
      for (final Track track in queue)
        if (!downloads.isDownloaded(track.id)) track,
    ];

    final List<DownloadTask> tasks = downloads.active.values.toList()
      ..sort((DownloadTask a, DownloadTask b) {
        // Сначала идущие, потом ошибки: прогресс важнее уже случившегося.
        if (a.failed != b.failed) return a.failed ? 1 : -1;
        return a.track.title.compareTo(b.track.title);
      });

    return Scaffold(
      appBar: AppBar(title: const Text('Загрузки')),
      body: ContentWidth(
        child: !downloads.loaded
            ? const Center(child: AppProgress())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: <Widget>[
                  Text(
                    'Скачанные треки хранятся в данных приложения и играют без '
                    'интернета. Файлы не удаляются автоматически: место '
                    'освобождается только здесь.',
                    style: text.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 16),

                  _SummaryRow(
                    count: downloads.items.length,
                    bytes: downloads.totalBytes,
                  ),

                  if (pending.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        // Пока идёт загрузка, вторую пачку не запускаем: они
                        // пошли бы через тот же резолвер и мешали друг другу.
                        onPressed: downloads.workingCount > 0
                            ? null
                            : () => _downloadQueue(context, ref, pending),
                        icon: const Icon(Icons.download_for_offline_outlined),
                        label: Text('Скачать очередь (${pending.length})'),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'В очереди плеера есть треки, которых нет на диске. '
                        'Скачиваются по одному, чтобы не мешать звуку.',
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],

                  if (downloads.items.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => _confirmRemoveAll(context, ref),
                        icon: const Icon(Icons.delete_sweep_outlined),
                        label: const Text('Удалить все загрузки'),
                      ),
                    ),
                  ],

                  if (tasks.isNotEmpty) ...<Widget>[
                    const Divider(height: 32),
                    Text(
                      'В работе',
                      style: text.titleSmall?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    for (final DownloadTask task in tasks)
                      _ActiveDownloadTile(
                        task: task,
                        onRetry: () => ref
                            .read(downloadsControllerProvider.notifier)
                            .download(task.track),
                        onDismiss: () => ref
                            .read(downloadsControllerProvider.notifier)
                            .dismiss(task.track.id),
                      ),
                  ],

                  const Divider(height: 32),
                  Text(
                    'Скачанные треки',
                    style: text.titleSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (downloads.items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Column(
                        children: <Widget>[
                          Icon(
                            Icons.download_outlined,
                            size: 40,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Пока ничего не скачано',
                            style: text.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Откройте меню трека и выберите «Скачать» — он '
                            'появится здесь и сыграет без сети.',
                            textAlign: TextAlign.center,
                            style: text.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    for (int i = 0; i < downloads.items.length; i++)
                      _DownloadedTile(
                        item: downloads.items[i],
                        onPlay: () => _play(context, ref, downloads.items, i),
                        onRemove: () =>
                            _confirmRemove(context, ref, downloads.items[i]),
                      ),
                ],
              ),
      ),
    );
  }

  /// Играет скачанный трек вместе с остальными загрузками — получается
  /// офлайн-список, который резолвер открывает прямо с диска.
  void _play(
    BuildContext context,
    WidgetRef ref,
    List<DownloadedTrack> items,
    int index,
  ) {
    final List<Track> tracks = <Track>[
      for (final DownloadedTrack item in items) item.toTrack(),
    ];
    ref.read(playerControllerProvider.notifier).playQueue(
          tracks,
          startIndex: index,
        );
  }

  Future<void> _downloadQueue(
    BuildContext context,
    WidgetRef ref,
    List<Track> pending,
  ) async {
    final DownloadsController controller =
        ref.read(downloadsControllerProvider.notifier);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ({int done, int failed}) result =
        await controller.downloadMany(pending);
    if (!context.mounted) return;

    // Ошибки уже видны в списке: здесь только итог, чтобы не гадать, сколько
    // из очереди сохранилось.
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.failed == 0
              ? 'Скачано треков: ${result.done}'
              : 'Скачано: ${result.done}, с ошибкой: ${result.failed}. '
                  'Причины — в списке выше.',
        ),
      ),
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    DownloadedTrack item,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Удалить загрузку?'),
        content: Text(
          '«${item.title}» будет удалён с диска, и место освободится. '
          'Трек останется в плейлистах и снова будет играть из сети.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? error =
        await ref.read(downloadsControllerProvider.notifier).remove(item.id);
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          error == null ? 'Загрузка удалена' : 'Не удалось удалить: $error',
        ),
      ),
    );
  }

  Future<void> _confirmRemoveAll(BuildContext context, WidgetRef ref) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Удалить все загрузки?'),
        content: const Text(
          'С диска будут удалены все скачанные треки. Слушать их снова '
          'можно будет только из сети.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Удалить все'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final int failed =
        await ref.read(downloadsControllerProvider.notifier).removeAll();
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? 'Все загрузки удалены'
              : 'Не удалось удалить $failed: файл может быть занят плеером.',
        ),
      ),
    );
  }
}

/// Счётчик и общий размер — как «Stored tracks 12 · 63 MB» в эталоне.
class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.count, required this.bytes});

  final int count;
  final int bytes;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        Icon(Icons.download_done, color: scheme.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            count == 0 ? 'Загрузок пока нет' : trackCountLabel(count),
            style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        Text(
          count == 0 ? '' : _formatBytes(bytes),
          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Строка идущей или неудавшейся загрузки: прогресс по байтам или причина.
class _ActiveDownloadTile extends StatelessWidget {
  const _ActiveDownloadTile({
    required this.task,
    required this.onRetry,
    required this.onDismiss,
  });

  final DownloadTask task;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final int? total = task.total;
    final bool failed = task.failed;

    final Widget tile = ListTile(
      contentPadding: EdgeInsets.zero,
      leading: SizedBox(
        width: 32,
        height: 32,
        child: failed
            ? Icon(Icons.error_outline, color: scheme.error)
            : Padding(
                padding: const EdgeInsets.all(3),
                child: CircularProgressIndicator(
                  // Без общего размера честнее показать неопределённый
                  // индикатор, чем выдуманный процент.
                  value: total == null ? null : task.progress,
                  strokeWidth: 3,
                ),
              ),
      ),
      title: Text(
        task.track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: failed
          ? Text(
              task.error!,
              style: text.bodySmall?.copyWith(color: scheme.error),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: total == null ? null : task.progress,
                  minHeight: 4,
                ),
                const SizedBox(height: 4),
                Text(
                  total == null
                      ? 'Получено ${_formatBytes(task.received)}'
                      : '${_formatBytes(task.received)} из '
                          '${_formatBytes(total)} · '
                          '${(task.progress * 100).round()}%',
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
      isThreeLine: !failed,
      trailing: failed
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  tooltip: 'Повторить',
                  icon: const Icon(Icons.refresh),
                  onPressed: onRetry,
                ),
                IconButton(
                  tooltip: 'Скрыть',
                  icon: const Icon(Icons.close),
                  onPressed: onDismiss,
                ),
              ],
            )
          : null,
    );

    // Правый клик — общее меню трека: в нём уже есть состояние загрузки,
    // повтор для неудачной и удаление файла. Своё меню у строки не рисуем,
    // чтобы не дублировать кнопки «Повторить» и «Скрыть».
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTap: () => showTrackMenu(context, task.track),
      child: tile,
    );
  }
}

/// Скачанный трек: подпись с размером и датой, удаление и запуск.
class _DownloadedTile extends StatelessWidget {
  const _DownloadedTile({
    required this.item,
    required this.onPlay,
    required this.onRemove,
  });

  final DownloadedTrack item;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return TrackTile(
      track: item.toTrack(),
      onTap: onPlay,
      subtitleOverride: '${item.artistLine} · ${_formatBytes(item.bytes)} · '
          '${_formatDate(item.downloadedAt)}',
      showDuration: false,
      trailing: IconButton(
        tooltip: 'Удалить загрузку',
        icon: const Icon(Icons.delete_outline),
        onPressed: onRemove,
      ),
    );
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

/// Дата загрузки без времени: для списка хватает дня.
String _formatDate(DateTime at) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(at.day)}.${two(at.month)}.${at.year}';
}
