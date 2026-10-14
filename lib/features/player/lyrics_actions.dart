import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/app_settings.dart';
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
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Text('Найти текст в другом источнике'),
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
    // Перезапрашиваем явно: даже если источник совпал с прежним, текст
    // обновится (может, предыдущий запрос упал).
    ref.invalidate(lyricsProvider(request));
    Navigator.pop(context);
  }
}
