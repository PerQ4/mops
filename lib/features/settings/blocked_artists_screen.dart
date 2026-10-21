import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/local/blocked_artists.dart';
import '../../state/library_providers.dart';
import '../../widgets/empty_state.dart';

/// Управление заблокированными исполнителями.
///
/// Экран нужен как обратный вход: заблокировать можно из меню трека или со
/// страницы исполнителя, а увидеть весь список и снять блокировку — только
/// здесь. Список хранится на диске, поэтому переживает перезапуск.
class BlockedArtistsScreen extends ConsumerWidget {
  const BlockedArtistsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<BlockedArtist> artists = ref.watch(blockedArtistsProvider);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Заблокированные исполнители'),
        actions: <Widget>[
          if (artists.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Разблокировать всех',
              onPressed: () => _confirmClear(context, ref, artists.length),
            ),
        ],
      ),
      body: ContentWidth(
        child: artists.isEmpty
            ? const EmptyState(
                icon: Icons.person_off_outlined,
                title: 'Никого нет',
                subtitle: 'Заблокировать исполнителя можно из меню трека или '
                    'со страницы исполнителя — тогда его песни пропадут из '
                    'каталога, поиска и плейлистов.',
              )
            : ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: artists.length,
                separatorBuilder: (BuildContext context, int index) =>
                    const Divider(height: 1),
                itemBuilder: (BuildContext context, int index) {
                  final BlockedArtist artist = artists[index];
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: scheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.person_outline,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    title: Text(
                      artist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: const Text('Песни скрыты в каталоге'),
                    trailing: TextButton(
                      onPressed: () =>
                          _unblock(context, ref, artist),
                      child: const Text('Разблокировать'),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _unblock(
    BuildContext context,
    WidgetRef ref,
    BlockedArtist artist,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(blockedArtistsProvider.notifier).unblock(artist.id);
      messenger.showSnackBar(
        SnackBar(content: Text('Блокировка снята: ${artist.name}')),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Не удалось снять блокировку.')),
      );
    }
  }

  Future<void> _confirmClear(
    BuildContext context,
    WidgetRef ref,
    int count,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Разблокировать всех?'),
        content: Text(
          'Вернутся в каталог: $count '
          '${count == 1 ? 'исполнитель' : 'исполнителей'}.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Разблокировать'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(blockedArtistsProvider.notifier).clear();
      messenger.showSnackBar(
        const SnackBar(content: Text('Все блокировки сняты')),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Не удалось снять блокировки.')),
      );
    }
  }
}
