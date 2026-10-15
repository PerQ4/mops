import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/app_settings.dart';
import '../../data/models/models.dart';
import '../../state/catalog_providers.dart';
import '../../state/providers.dart';

/// Меню текста песни — одно на все поверхности плеера.
///
/// Раньше сменить источник было негде: текст показывался, но переключиться на
/// субтитры из плеера было нельзя. Меню живёт в файле плеера и переиспользуется
/// полным экраном, правой панелью и островком, поэтому пункт не приходится
/// искать заново в каждой раскладке.
class LyricsMenuButton extends ConsumerWidget {
  const LyricsMenuButton({
    super.key,
    required this.request,
    this.onToggleVisibility,
    this.lyricsVisible = true,
    this.iconSize = 20,
  });

  final LyricsRequest request;

  /// Показ/скрытие текста конкретной поверхностью. Если не задано, пункт
  /// в меню не показывается: у самой поверхности нет такого состояния.
  final VoidCallback? onToggleVisibility;
  final bool lyricsVisible;

  final double iconSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      tooltip: 'Источник текста',
      iconSize: iconSize,
      icon: const Icon(Icons.tune),
      onPressed: () => showLyricsMenu(
        context,
        request,
        onToggleVisibility: onToggleVisibility,
        lyricsVisible: lyricsVisible,
      ),
    );
  }
}

/// Открывает меню текста.
Future<void> showLyricsMenu(
  BuildContext context,
  LyricsRequest request, {
  VoidCallback? onToggleVisibility,
  bool lyricsVisible = true,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) => _LyricsMenuSheet(
      request: request,
      onToggleVisibility: onToggleVisibility,
      lyricsVisible: lyricsVisible,
    ),
  );
}

class _LyricsMenuSheet extends ConsumerWidget {
  const _LyricsMenuSheet({
    required this.request,
    this.onToggleVisibility,
    this.lyricsVisible = true,
  });

  final LyricsRequest request;
  final VoidCallback? onToggleVisibility;
  final bool lyricsVisible;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Действующий источник: ручной выбор для этого трека важнее настройки.
    final LyricsSource current =
        ref.watch(lyricsSourceOverrideProvider)[request.videoId] ??
            ref.watch(
              settingsControllerProvider.select(
                (AppSettings s) => s.lyricsSource,
              ),
            );

    // Найденные параллельным поиском варианты: лучший уже выбран, остальные
    // можно посмотреть и переключиться. Пока поиск идёт, список пополняется.
    final LyricsSearchState search = ref.watch(lyricsProvider(request)).value ??
        const LyricsSearchState();

    // Какой вариант показывается сейчас: в «Авто» — лучший, иначе выбранный.
    final LyricsSource? shownSource = current == LyricsSource.auto
        ? search.best?.source
        : current;

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Текст песни',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    // Подпись честно показывает, откуда текст сейчас.
                    'Источник: ${current.label}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (search.candidates.isNotEmpty) ...<Widget>[
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Text('Найденные варианты — по совместимости'),
              ),
              for (final LyricsCandidate candidate in search.candidates)
                ListTile(
                  leading: Icon(_iconFor(candidate.source)),
                  title: Row(
                    children: <Widget>[
                      Flexible(child: Text(candidate.source.label)),
                      const SizedBox(width: 8),
                      _SyncBadge(candidate: candidate),
                    ],
                  ),
                  subtitle: Text(_candidateSubtitle(candidate)),
                  trailing: candidate.source == shownSource
                      ? Icon(
                          Icons.check,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : Text(
                          '${candidate.score}',
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(
                                color:
                                    Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                        ),
                  selected: candidate.source == shownSource,
                  onTap: () => _select(context, ref, candidate.source),
                ),
              if (search.loading)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Row(
                    children: <Widget>[
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 12),
                      Text('Поиск ещё идёт…'),
                    ],
                  ),
                ),
              const Divider(height: 1),
            ] else if (search.loading)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 12),
                    Text('Ищем текст во всех источниках…'),
                  ],
                ),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Text('Все источники'),
            ),
            for (final LyricsSource source in LyricsSource.values)
              ListTile(
                leading: Icon(_iconFor(source)),
                title: Text(source.label),
                subtitle: Text(source.description),
                trailing: source == current
                    ? Icon(
                        Icons.check,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                selected: source == current,
                onTap: () => _select(context, ref, source),
              ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Обновить текст'),
              onTap: () {
                ref.invalidate(lyricsProvider(request));
                Navigator.pop(context);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Подпись варианта: причины оценки, а если их нет — описание источника.
  String _candidateSubtitle(LyricsCandidate candidate) {
    if (candidate.reasons.isEmpty) return candidate.source.description;
    return candidate.reasons.join(' · ');
  }

  IconData _iconFor(LyricsSource source) => switch (source) {
        LyricsSource.auto => Icons.auto_awesome,
        LyricsSource.music => Icons.library_music_outlined,
        LyricsSource.subtitles => Icons.subtitles_outlined,
        LyricsSource.betterLyrics => Icons.graphic_eq,
        LyricsSource.youlyPlus => Icons.music_note_outlined,
        LyricsSource.lrclib => Icons.public,
        LyricsSource.kugou => Icons.cloud_outlined,
        LyricsSource.megalobiz => Icons.travel_explore,
        LyricsSource.simpmusic => Icons.queue_music,
        LyricsSource.unison => Icons.album_outlined,
        LyricsSource.musixmatch => Icons.music_note,
      };

  void _select(BuildContext context, WidgetRef ref, LyricsSource source) {
    // Источник запоминаем для этого трека: смена настройки затронула бы все
    // треки, а пользователь просил другой текст именно здесь.
    ref
        .read(lyricsSourceOverrideProvider.notifier)
        .setSource(request.videoId, source);
    // Перезапрашивать не нужно: все варианты уже получены параллельным
    // поиском и лежат в состоянии — переключение мгновенное. Если нужного
    // источника в списке не оказалось, есть пункт «Обновить текст».
    Navigator.pop(context);
  }
}

/// Метка типа синхронизации у варианта текста.
class _SyncBadge extends StatelessWidget {
  const _SyncBadge({required this.candidate});

  final LyricsCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool wordSynced = candidate.lyrics.timed
            ?.any((TimedLyric line) => line.hasWords) ??
        false;
    final String label;
    final Color background;
    final Color foreground;
    if (wordSynced) {
      label = 'пословно';
      background = scheme.primaryContainer;
      foreground = scheme.onPrimaryContainer;
    } else if (candidate.lyrics.isSynced) {
      label = 'построчно';
      background = scheme.secondaryContainer;
      foreground = scheme.onSecondaryContainer;
    } else {
      label = 'без синхр.';
      background = scheme.surfaceContainerHighest;
      foreground = scheme.onSurfaceVariant;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foreground,
            ),
      ),
    );
  }
}
