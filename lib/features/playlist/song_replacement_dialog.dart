import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/format.dart';
import '../../data/models/models.dart';
import '../../data/sources/song_replacement.dart';
import '../../state/catalog_providers.dart';
import '../../widgets/app_progress.dart';
import '../../widgets/artwork.dart';
import '../../widgets/async_views.dart';

/// Диалог выбора замены недоступному треку.
///
/// Возвращает выбранный трек или `null`, если пользователь закрыл окно.
/// Никакого автоматического выбора нет: оценка совпадения — подсказка, а
/// решение принимает человек.
Future<Track?> showSongReplacementDialog(BuildContext context, Track track) {
  return showDialog<Track>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _SongReplacementDialog(track: track),
  );
}

class _SongReplacementDialog extends ConsumerStatefulWidget {
  const _SongReplacementDialog({required this.track});

  final Track track;

  @override
  ConsumerState<_SongReplacementDialog> createState() =>
      _SongReplacementDialogState();
}

class _SongReplacementDialogState
    extends ConsumerState<_SongReplacementDialog> {
  late Future<List<SongCandidate>> _candidates;

  @override
  void initState() {
    super.initState();
    _candidates = _find();
  }

  Future<List<SongCandidate>> _find() {
    return SongReplacementFinder(ref.read(catalogSourceProvider))
        .find(widget.track);
  }

  void _retry() {
    setState(() => _candidates = _find());
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('Найти замену'),
      content: ConstrainedBox(
        // На узком окне 520 не влезло бы: ограничиваем максимумом, а не
        // жёсткой шириной.
        constraints: const BoxConstraints(maxWidth: 520),
        child: SizedBox(
          height: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '«${widget.track.title}» — ${widget.track.artistLine}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: FutureBuilder<List<SongCandidate>>(
                  future: _candidates,
                  builder: (
                    BuildContext context,
                    AsyncSnapshot<List<SongCandidate>> snapshot,
                  ) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: AppProgress());
                    }
                    if (snapshot.hasError) {
                      return _ErrorState(
                        error: snapshot.error!,
                        onRetry: _retry,
                      );
                    }
                    final List<SongCandidate> candidates =
                        snapshot.data ?? const <SongCandidate>[];
                    if (candidates.isEmpty) return const _EmptyState();
                    return _CandidateList(candidates: candidates);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
      ],
    );
  }
}

class _CandidateList extends StatelessWidget {
  const _CandidateList({required this.candidates});

  final List<SongCandidate> candidates;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return ListView.separated(
      itemCount: candidates.length,
      separatorBuilder: (BuildContext _, int _) => const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) {
        final SongCandidate candidate = candidates[index];
        final Track track = candidate.track;
        final List<String> meta = <String>[
          track.artistLine,
          if (track.duration > Duration.zero) formatDuration(track.duration),
          ...candidate.reasons,
        ];

        final List<String> variants = track.artworkFallbacks(48);
        return ListTile(
          leading: Artwork(
            url: variants.isEmpty ? null : variants.first,
            fallbacks: variants.length > 1
                ? variants.sublist(1)
                : const <String>[],
            size: 48,
            radius: BorderRadius.circular(8),
          ),
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            meta.join(' • '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          trailing: Text(
            '${candidate.score}%',
            style: text.titleMedium?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          onTap: () => Navigator.pop(context, track),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.search_off, size: 40, color: scheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Text('Замена не найдена', style: text.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Поиск не нашёл трека, достаточно похожего по названию, '
            'исполнителю и длительности.',
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.cloud_off_outlined, size: 40, color: scheme.error),
          const SizedBox(height: 8),
          Text('Не удалось найти замену', style: text.titleMedium),
          const SizedBox(height: 4),
          Text(
            describeError(error),
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Повторить'),
          ),
        ],
      ),
    );
  }
}
