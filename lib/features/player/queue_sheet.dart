import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/player_controller.dart';
import '../../widgets/async_views.dart';
import '../../widgets/track_tile.dart';

/// Нижняя панель с очередью воспроизведения.
abstract final class QueueSheet {
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (BuildContext context) => const DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        minChildSize: 0.35,
        builder: _queueBuilder,
      ),
    );
  }
}

/// Ссылка на функцию — константа времени компиляции, поэтому
/// `DraggableScrollableSheet` можно оставить `const`.
Widget _queueBuilder(BuildContext context, ScrollController controller) =>
    _QueueContent(scrollController: controller);

class _QueueContent extends ConsumerWidget {
  const _QueueContent({required this.scrollController});

  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerUiState player = ref.watch(playerControllerProvider);
    final PlayerController controller = ref.read(playerControllerProvider.notifier);
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    if (player.queue.isEmpty) {
      return const EmptyView(
        icon: Icons.queue_music,
        title: 'Очередь пуста',
        subtitle: 'Включите трек — он появится здесь.',
      );
    }

    final List<Track> upNext = player.upNext;
    final int playedCount = player.played.length;

    return CustomScrollView(
      controller: scrollController,
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Очередь',
                    style: text.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton.icon(
                  onPressed: controller.clearQueue,
                  icon: const Icon(Icons.clear_all),
                  label: const Text('Очистить'),
                ),
              ],
            ),
          ),
        ),

        if (player.current != null) ...<Widget>[
          SliverToBoxAdapter(
            child: _GroupLabel('Сейчас играет'),
          ),
          SliverToBoxAdapter(
            child: TrackTile(
              track: player.current!,
              isCurrent: true,
              isPlaying: player.isPlaying,
              trailing: IconButton(
                tooltip: 'Убрать из очереди',
                icon: const Icon(Icons.close),
                onPressed: () => controller.removeFromQueue(player.index),
              ),
            ),
          ),
        ],

        if (upNext.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Дальше треков нет — включится радио по текущему треку.',
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          )
        else ...<Widget>[
          SliverToBoxAdapter(child: _GroupLabel('Далее — ${upNext.length}')),
          SliverReorderableList(
            itemCount: upNext.length,
            // onReorderItem отдаёт уже скорректированный индекс: элемент
            // oldIndex мысленно удалён, поэтому вычитать единицу не нужно.
            onReorderItem: (int oldIndex, int newIndex) {
              final int base = player.index + 1;
              controller.reorderQueue(oldIndex + base, newIndex + base);
            },
            itemBuilder: (BuildContext context, int index) {
              final Track track = upNext[index];
              return _ReorderableTile(
                key: ValueKey<String>('${track.id}-$index'),
                index: index,
                track: track,
                onTap: () => controller.jumpTo(player.index + 1 + index),
                onRemove: () => controller.removeFromQueue(player.index + 1 + index),
              );
            },
          ),
        ],

        if (playedCount > 0) ...<Widget>[
          SliverToBoxAdapter(child: _GroupLabel('Уже проиграно — $playedCount')),
          SliverList.builder(
            itemCount: playedCount,
            itemBuilder: (BuildContext context, int index) {
              final Track track = player.played[index];
              return TrackTile(
                track: track,
                dense: true,
                onTap: () => controller.jumpTo(index),
              );
            },
          ),
        ],

        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

/// Элемент очереди с ручкой для перетаскивания.
class _ReorderableTile extends StatelessWidget {
  const _ReorderableTile({
    super.key,
    required this.index,
    required this.track,
    required this.onTap,
    required this.onRemove,
  });

  final int index;
  final Track track;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Row(
        children: <Widget>[
          Expanded(
            child: TrackTile(
              track: track,
              onTap: onTap,
              trailing: IconButton(
                tooltip: 'Убрать',
                icon: const Icon(Icons.close),
                onPressed: onRemove,
              ),
            ),
          ),
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.drag_handle),
            ),
          ),
        ],
      ),
    );
  }
}
