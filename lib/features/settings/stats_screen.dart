import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/local/listening_stats.dart';
import '../../state/providers.dart';
import '../../widgets/empty_state.dart';

/// Период статистики. Выбор живёт только на экране: это способ посмотреть
/// данные, а не настройка, и запоминать его между запусками незачем.
enum _StatsPeriod {
  week('7 дней', 7),
  month('30 дней', 30),
  all('Всё время', null);

  const _StatsPeriod(this.label, this.days);

  final String label;
  final int? days;
}

/// Статистика прослушиваний (задача 8.1).
///
/// Все числа выводятся из журнала зачтённых прослушиваний: топы, повторы и
/// «давно не слушали» — не оценки и не догадки. Запись локальная; выключить её
/// и стереть журнал можно здесь же и в настройках.
class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  _StatsPeriod _period = _StatsPeriod.all;

  @override
  Widget build(BuildContext context) {
    final List<ListenEvent> events = ref.watch(listeningStatsProvider);
    final bool recording = ref.watch(
      settingsControllerProvider.select(
        (settings) => settings.listeningStatsEnabled,
      ),
    );
    final DateTime? since = _period.days == null
        ? null
        : DateTime.now().subtract(Duration(days: _period.days!));
    final ListeningSummary summary = ListeningSummary.fromEvents(
      events,
      since: since,
    );
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Статистика'),
        actions: <Widget>[
          if (events.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Очистить статистику',
              onPressed: () => _confirmClear(events.length),
            ),
        ],
      ),
      body: ContentWidth(
        child: events.isEmpty
            ? EmptyState(
                icon: Icons.insights_outlined,
                title: 'Пока пусто',
                subtitle: 'Прослушивание попадёт сюда, когда трек сыграет '
                    'четыре минуты или половину своей длительности. '
                    'Считаются только реально проигранные секунды, и данные '
                    'остаются на этом компьютере.',
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: <Widget>[
                  if (!recording) ...<Widget>[
                    _Notice(
                      icon: Icons.pause_circle_outline,
                      text: 'Запись выключена: новые прослушивания не '
                          'учитываются. Включить можно в настройках.',
                      color: scheme.tertiary,
                    ),
                    const SizedBox(height: 12),
                  ],
                  SegmentedButton<_StatsPeriod>(
                    segments: <ButtonSegment<_StatsPeriod>>[
                      for (final _StatsPeriod period in _StatsPeriod.values)
                        ButtonSegment<_StatsPeriod>(
                          value: period,
                          label: Text(period.label),
                        ),
                    ],
                    selected: <_StatsPeriod>{_period},
                    showSelectedIcon: false,
                    onSelectionChanged: (Set<_StatsPeriod> selected) {
                      setState(() => _period = selected.first);
                    },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _Metric(
                          label: 'Прослушивания',
                          value: '${summary.plays}',
                          hint: summary.repeats > 0
                              ? 'повторных: ${summary.repeats}'
                              : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _Metric(
                          label: 'Время',
                          value: _duration(
                            Duration(seconds: summary.seconds),
                          ),
                          hint: 'в зачётных прослушиваниях',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _Metric(
                          label: 'Исполнители',
                          value: '${summary.uniqueArtists}',
                          hint: 'уникальных',
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _Metric(
                          label: 'Треки',
                          value: '${summary.uniqueTracks}',
                          hint: 'уникальных',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (summary.plays == 0)
                    _Notice(
                      icon: Icons.event_busy_outlined,
                      text: 'За этот период зачтённых прослушиваний нет — '
                          'выберите период пошире.',
                      color: scheme.secondary,
                    )
                  else ...<Widget>[
                    if (summary.repeatTrack != null) ...<Widget>[
                      _Highlight(
                        icon: Icons.replay,
                        title: 'Снова и снова',
                        name: summary.repeatTrack!.name,
                        subtitle:
                            '${_listensLabel(summary.repeatTrack!.plays)} '
                            'за период',
                        color: scheme.secondary,
                      ),
                      const SizedBox(height: 12),
                    ],
                    _TopSection(
                      title: 'Исполнители',
                      icon: Icons.person_outline,
                      entries: summary.artists,
                    ),
                    _TopSection(
                      title: 'Альбомы',
                      icon: Icons.album_outlined,
                      entries: summary.albums,
                    ),
                    _TopSection(
                      title: 'Треки',
                      icon: Icons.music_note_outlined,
                      entries: summary.tracks,
                    ),
                  ],
                  if (summary.forgottenArtist != null) ...<Widget>[
                    const SizedBox(height: 8),
                    _Highlight(
                      icon: Icons.history_toggle_off,
                      title: 'Давно не слушали',
                      name: summary.forgottenArtist!.name,
                      subtitle: 'Последний раз — '
                          '${_ago(summary.forgottenArtist!.lastPlayed)}',
                      color: scheme.tertiary,
                    ),
                  ],
                  const SizedBox(height: 20),
                  Text(
                    'Зачёт — четыре минуты или половина трека. Время '
                    'считается по реально проигранному, без пауз и '
                    'перемоток. Журнал хранится только на этом компьютере.',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _confirmClear(int count) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Очистить статистику?'),
        content: Text(
          'Будут удалены все записи: ${_listensLabel(count)}. '
          'Отменить это нельзя.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Очистить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(listeningStatsProvider.notifier).clear();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Статистика очищена')),
    );
  }
}

/// Короткая карточка-предупреждение (запись выключена, период пуст).
class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      color: color.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Большое число с подписью.
class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.hint,
  });

  final String label;
  final String value;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (hint != null)
              Text(
                hint!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Топ одного вида: исполнители, альбомы или треки.
class _TopSection extends StatelessWidget {
  const _TopSection({
    required this.title,
    required this.icon,
    required this.entries,
  });

  final String title;
  final IconData icon;
  final List<StatsEntry> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        margin: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: <Widget>[
                  Icon(icon, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ],
              ),
            ),
            for (int i = 0; i < entries.length; i++) ...<Widget>[
              if (i > 0) const Divider(height: 1, indent: 56),
              ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 14,
                  backgroundColor: scheme.surfaceContainerHighest,
                  child: Text(
                    '${i + 1}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                title: Text(
                  entries[i].name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: entries[i].subtitle == null
                    ? null
                    : Text(
                        entries[i].subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                trailing: Text(
                  _listensLabel(entries[i].plays),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Карточка наблюдения: «снова и снова» или «давно не слушали».
class _Highlight extends StatelessWidget {
  const _Highlight({
    required this.icon,
    required this.title,
    required this.name,
    required this.subtitle,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String name;
  final String subtitle;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      color: color.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: <Widget>[
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: text.labelMedium?.copyWith(
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleSmall,
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _listensLabel(int count) =>
    '$count ${_plural(count, 'прослушивание', 'прослушивания', 'прослушиваний')}';

String _plural(int count, String one, String few, String many) {
  final int mod100 = count % 100;
  if (mod100 >= 11 && mod100 <= 14) return many;
  switch (count % 10) {
    case 1:
      return one;
    case 2:
    case 3:
    case 4:
      return few;
    default:
      return many;
  }
}

String _duration(Duration value) {
  if (value.inHours > 0) {
    final int minutes = value.inMinutes % 60;
    return minutes == 0
        ? '${value.inHours} ч'
        : '${value.inHours} ч $minutes мин';
  }
  if (value.inMinutes > 0) return '${value.inMinutes} мин';
  return '${value.inSeconds} с';
}

String _ago(DateTime at) {
  final int days = DateTime.now().difference(at).inDays;
  if (days <= 0) return 'сегодня';
  return '$days ${_plural(days, 'день', 'дня', 'дней')} назад';
}
