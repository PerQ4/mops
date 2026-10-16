import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/app_settings.dart';
import '../../data/models/models.dart';
import '../../state/catalog_providers.dart';
import '../../state/lyrics_edits.dart';
import '../../state/providers.dart';

/// Кнопка меню текста песни — одно на все поверхности плеера.
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
      tooltip: 'Поиск текста',
      iconSize: iconSize,
      icon: const Icon(Icons.manage_search),
      onPressed: () => showLyricsMenu(
        context,
        request,
        onToggleVisibility: onToggleVisibility,
        lyricsVisible: lyricsVisible,
      ),
    );
  }
}

/// Открывает меню поиска и выбора текста.
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

/// Меню поиска текста — как `LyricsMenu` в ArchiveTune: ряд действий сверху
/// (обновить, ручной поиск, сбросить) и список найденных вариантов карточками.
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
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    // Действующий источник: ручной выбор для этого трека важнее настройки.
    final LyricsSource current =
        ref.watch(lyricsSourceOverrideProvider)[request.videoId] ??
            ref.watch(
              settingsControllerProvider.select(
                (AppSettings s) => s.lyricsSource,
              ),
            );

    // Ручной запрос для трека важнее данных из YouTube — по нему и ищем.
    final LyricsRequest? manual = ref.watch(
      manualLyricsRequestsProvider
          .select((Map<String, LyricsRequest> m) => m[request.videoId]),
    );
    final LyricsRequest effective = manual ?? request;

    final LyricsSearchState search =
        ref.watch(lyricsProvider(effective)).value ??
            const LyricsSearchState();

    // Порядок источников из настроек — участвует в выборе лучшего варианта.
    final List<LyricsSource> order = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => s.lyricsProviderOrder,
      ),
    );

    // Какой вариант показывается сейчас: в «Авто» — лучший по приоритету,
    // иначе выбранный вручную.
    final LyricsSource? shownSource = current == LyricsSource.auto
        ? search.bestByOrder(order)?.source
        : current;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Поиск текста',
                        style: text.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        manual != null
                            ? 'Ручной поиск: '
                                '${manual.title ?? ''} ${manual.artist ?? ''}'
                                    .trim()
                            : 'Источник: ${current.label}',
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: <Widget>[
                _MenuAction(
                  icon: Icons.refresh,
                  label: 'Обновить',
                  onTap: () => ref.invalidate(lyricsProvider(effective)),
                ),
                _MenuAction(
                  icon: Icons.manage_search,
                  label: 'Ручной поиск',
                  onTap: () => _manualSearch(context, ref),
                ),
                _MenuAction(
                  icon: Icons.edit_outlined,
                  label: 'Изменить текст',
                  onTap: () => _editLyrics(context, ref),
                ),
                _MenuAction(
                  icon: Icons.restart_alt,
                  label: 'Сбросить',
                  onTap: () {
                    ref
                        .read(lyricsSourceOverrideProvider.notifier)
                        .setSource(request.videoId, LyricsSource.auto);
                    ref
                        .read(manualLyricsRequestsProvider.notifier)
                        .set(request.videoId, null);
                    ref.invalidate(lyricsProvider(request));
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 20),
          if (search.candidates.isEmpty && search.loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
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
            )
          else if (search.candidates.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Ничего не нашлось. Попробуйте ручной поиск.'),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                itemCount: search.candidates.length,
                itemBuilder: (BuildContext context, int index) {
                  final LyricsCandidate candidate = search.candidates[index];
                  return _ResultCard(
                    candidate: candidate,
                    selected: candidate.source == shownSource,
                    onTap: () => _select(context, ref, candidate.source),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  /// Ручной поиск текста: ввод своих названия/исполнителя и поиск по ним —
  /// как `SearchLyricsInputDialog` в ArchiveTune. После «Искать» список
  /// вариантов обновляется прямо в этом меню, из него и выбирается нужный.
  Future<void> _manualSearch(BuildContext context, WidgetRef ref) async {
    final LyricsRequest base =
        ref.read(manualLyricsRequestsProvider)[request.videoId] ?? request;
    final TextEditingController title =
        TextEditingController(text: base.title ?? '');
    final TextEditingController artist =
        TextEditingController(text: base.artist ?? '');
    final TextEditingController album =
        TextEditingController(text: base.album ?? '');
    final TextEditingController duration = TextEditingController(
      text: (base.duration == null || base.duration == Duration.zero)
          ? ''
          : '${base.duration!.inSeconds}',
    );

    final int? action = await showDialog<int>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Ручной поиск текста'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Название'),
              ),
              TextField(
                controller: artist,
                decoration: const InputDecoration(labelText: 'Исполнитель'),
              ),
              TextField(
                controller: album,
                decoration: const InputDecoration(labelText: 'Альбом'),
              ),
              TextField(
                controller: duration,
                decoration:
                    const InputDecoration(labelText: 'Длительность, сек'),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 0),
            child: const Text('Сбросить'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 1),
            child: const Text('Искать'),
          ),
        ],
      ),
    );

    final String t = title.text.trim();
    final String a = artist.text.trim();
    final String al = album.text.trim();
    final int? d = int.tryParse(duration.text.trim());
    title.dispose();
    artist.dispose();
    album.dispose();
    duration.dispose();

    final ManualLyricsRequests notifier =
        ref.read(manualLyricsRequestsProvider.notifier);
    if (action == 0) {
      notifier.set(request.videoId, null);
    } else if (action == 1) {
      notifier.set(
        request.videoId,
        LyricsRequest(
          videoId: request.videoId,
          title: t.isEmpty ? null : t,
          artist: a.isEmpty ? null : a,
          album: al.isEmpty ? null : al,
          duration: (d == null || d <= 0) ? null : Duration(seconds: d),
        ),
      );
    }
    // Меню не закрываем: список вариантов обновится прямо здесь.
  }

  /// Ручная правка текста: показываем найденный текст, даём поправить строки и
  /// кладём правку поверх — без перезапроса источников. Правка живёт по треку,
  /// поэтому её можно снять отдельной кнопкой.
  Future<void> _editLyrics(BuildContext context, WidgetRef ref) async {
    // Берём ровно тот текст, что показан сейчас: тот же выбор источника, что
    // и в плеере, иначе пользователь правил бы не то, что видит.
    final AppSettings settings = ref.read(settingsControllerProvider);
    final LyricsSource current =
        ref.read(lyricsSourceOverrideProvider)[request.videoId] ??
            settings.lyricsSource;
    final LyricsRequest? manual =
        ref.read(manualLyricsRequestsProvider)[request.videoId];
    final LyricsRequest effective = manual ?? request;
    final LyricsSearchState search =
        ref.read(lyricsProvider(effective)).value ??
            const LyricsSearchState();
    final Lyrics? base = current == LyricsSource.auto
        ? search.bestByOrder(settings.lyricsProviderOrder)?.lyrics
        : search.candidateFor(current)?.lyrics;

    final LyricsEdits edits = ref.read(lyricsEditsProvider.notifier);
    final String? existing = ref.read(lyricsEditsProvider)[request.videoId];
    final TextEditingController field = TextEditingController(
      text: existing ?? _lyricsText(base),
    );

    final int? action = await showDialog<int>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Изменить текст'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          // Поле многострочное и может не влезть в диалог — прокручиваем.
          child: SingleChildScrollView(
            child: TextField(
              controller: field,
              // Многострочное поле: по строке на строку — так времена
              // сохраняются по индексу строки, когда число строк совпало.
              maxLines: null,
              minLines: 10,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'По строке на строку',
              ),
            ),
          ),
        ),
        actions: <Widget>[
          if (existing != null)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 0),
              child: const Text('Сбросить правку'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 1),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );

    final String text = field.text;
    field.dispose();

    if (action == 0) {
      await edits.set(request.videoId, null);
    } else if (action == 1) {
      await edits.set(request.videoId, text);
    }
  }

  /// Текущий текст строками — то, что видит пользователь в плеере.
  static String _lyricsText(Lyrics? lyrics) {
    if (lyrics == null) return '';
    final List<TimedLyric>? timed = lyrics.timed;
    if (timed != null && timed.isNotEmpty) {
      return timed.map((TimedLyric l) => l.text).join('\n');
    }
    return lyrics.plain ?? '';
  }

  void _select(BuildContext context, WidgetRef ref, LyricsSource source) {
    // Источник запоминаем для этого трека: смена настройки затронула бы все
    // треки, а пользователь просил другой текст именно здесь.
    ref
        .read(lyricsSourceOverrideProvider.notifier)
        .setSource(request.videoId, source);
    // Перезапрашивать не нужно: все варианты уже получены параллельным
    // поиском и лежат в состоянии — переключение мгновенное.
    Navigator.pop(context);
  }
}

/// Действие в шапке меню: иконка + подпись (как `NewAction` в ArchiveTune).
class _MenuAction extends StatelessWidget {
  const _MenuAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            children: <Widget>[
              Icon(icon, color: scheme.onSurfaceVariant),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Карточка найденного варианта — как `LyricsSearchResultItem` в ArchiveTune:
/// источник, тип синхронизации, объём и превью. Тап — выбрать этот вариант.
class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.candidate,
    required this.selected,
    required this.onTap,
  });

  final LyricsCandidate candidate;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    final String syncLabel = candidate.isWordSynced
        ? 'Пословная синхронизация'
        : candidate.isLineSynced
            ? 'Построчная синхронизация'
            : 'Без синхронизации';
    final IconData icon = candidate.isWordSynced
        ? Icons.graphic_eq
        : candidate.isLineSynced
            ? Icons.sync
            : Icons.format_align_left;

    final Color container =
        selected ? scheme.secondaryContainer : scheme.surfaceContainerHighest;
    final Color content =
        selected ? scheme.onSecondaryContainer : scheme.onSurface;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: container,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(icon, color: content),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          candidate.source.label,
                          style: text.labelLarge?.copyWith(color: content),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          syncLabel,
                          style: text.titleSmall?.copyWith(
                            color: content,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (selected)
                    Icon(Icons.check, color: scheme.primary)
                  else
                    Text(
                      '${candidate.score}',
                      style: text.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              if (candidate.preview.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  candidate.preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                '${candidate.lineCount} строк · '
                '${candidate.characterCount} символов',
                style: text.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
