import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/models/models.dart';
import '../../state/player_controller.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/track_menu.dart';
import '../../widgets/track_tile.dart';

/// Очередь воспроизведения.
///
/// Один виджет на все поверхности: в панели плеера на десктопе и в нижнем
/// листе на телефоне. Раньше это было продублировано.
class QueueList extends ConsumerWidget {
  const QueueList({super.key, this.scrollController, this.padding});

  final ScrollController? scrollController;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Следим только за составом очереди и текущим треком. Позиция
    // воспроизведения меняется несколько раз в секунду, и если смотреть на
    // неё, весь список перестраивался бы на каждом тике — это и подтормаживало.
    final (List<Track> queue, int currentIndex, bool isPlaying) = ref.watch(
      playerControllerProvider.select(
        (PlayerUiState s) => (s.queue, s.index, s.isPlaying),
      ),
    );
    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);

    final Track? current = (currentIndex >= 0 && currentIndex < queue.length)
        ? queue[currentIndex]
        : null;
    final List<Track> upNext = (currentIndex < 0 || queue.isEmpty)
        ? queue
        : queue.sublist(currentIndex + 1);
    final List<Track> played = currentIndex <= 0
        ? const <Track>[]
        : queue.sublist(0, currentIndex);

    if (queue.isEmpty) {
      return const EmptyState(
        icon: Icons.queue_music,
        title: 'Очередь пуста',
        subtitle: 'Включите трек — он появится здесь.',
      );
    }

    final int playedCount = played.length;

    return CustomScrollView(
      controller: scrollController,
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppLayout.gutter,
              8,
              AppLayout.gutter,
              4,
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Очередь',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Очистить',
                  icon: const Icon(Icons.clear_all),
                  onPressed: controller.clearQueue,
                ),
              ],
            ),
          ),
        ),

        if (current != null) ...<Widget>[
          const SliverToBoxAdapter(child: _GroupLabel('Сейчас играет')),
          SliverToBoxAdapter(
            child: TrackTile(
              track: current,
              isCurrent: true,
              isPlaying: isPlaying,
              onTap: () {},
            ),
          ),
        ],

        if (upNext.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(AppLayout.gutter),
              child: Text('Дальше треков нет — включится радио по текущему.'),
            ),
          )
        else ...<Widget>[
          SliverToBoxAdapter(child: _GroupLabel('Далее — ${upNext.length}')),
          SliverReorderableList(
            itemCount: upNext.length,
            // onReorderItem отдаёт уже скорректированный индекс.
            onReorderItem: (int oldIndex, int newIndex) {
              final int base = currentIndex + 1;
              controller.reorderQueue(oldIndex + base, newIndex + base);
            },
            itemBuilder: (BuildContext context, int index) {
              final Track track = upNext[index];
              return _ReorderableTile(
                key: ValueKey<String>('${track.id}-$index'),
                index: index,
                track: track,
                onTap: () => controller.jumpTo(currentIndex + 1 + index),
                onRemove: () =>
                    controller.removeFromQueue(currentIndex + 1 + index),
              );
            },
          ),
        ],

        if (playedCount > 0) ...<Widget>[
          SliverToBoxAdapter(child: _GroupLabel('Уже проиграно — $playedCount')),
          SliverList.builder(
            itemCount: playedCount,
            itemBuilder: (BuildContext context, int index) {
              return TrackTile(
                track: played[index],
                isDimmed: true,
                onTap: () => controller.jumpTo(index),
              );
            },
          ),
        ],

        const SliverToBoxAdapter(child: SizedBox(height: 24)),
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
      padding: const EdgeInsets.fromLTRB(
        AppLayout.gutter,
        16,
        AppLayout.gutter,
        4,
      ),
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
    return Row(
      children: <Widget>[
        Expanded(
          child: TrackTile(
            track: track,
            onTap: onTap,
            // У строки очереди свой хвост (убрать + ручка перетаскивания),
            // поэтому штатная кнопка «…» не рисуется — добавляем её сами,
            // иначе из очереди не открыть меню трека.
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  tooltip: 'Действия',
                  iconSize: 20,
                  icon: const Icon(Icons.more_vert),
                  onPressed: () => showTrackMenu(context, track),
                ),
                IconButton(
                  tooltip: 'Убрать',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onRemove,
                ),
              ],
            ),
          ),
        ),
        ReorderableDragStartListener(
          index: index,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Icon(Icons.drag_indicator, size: 20),
          ),
        ),
      ],
    );
  }
}
