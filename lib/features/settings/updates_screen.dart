import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/layout.dart';
import '../../core/updates/app_version.dart';
import '../../core/updates/update_check.dart';
import '../../state/providers.dart';

/// «Обновления»: последний релиз с GitHub и его список изменений.
///
/// Проверка идёт по GitHub Releases. Сети может не быть — тогда экран не
/// ругается на весь экран, а одной строкой говорит, что проверить не удалось:
/// слушать музыку это не мешает.
class UpdatesScreen extends ConsumerWidget {
  const UpdatesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<UpdateCheck?> check = ref.watch(updateCheckProvider);
    final ThemeData theme = Theme.of(context);
    final String? version = resolveAppVersion();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Обновления'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Проверить снова',
            onPressed: () => ref.invalidate(updateCheckProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ContentWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
          children: <Widget>[
            Text(
              version == null
                  ? 'Версия не передана сборкой'
                  : 'Установлена версия $version',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            if (check.isLoading && !check.hasValue)
              const _CheckingLine()
            else if (check.value == null)
              const _QuietNote(
                icon: Icons.cloud_off_outlined,
                text: 'Не удалось проверить обновления — нет связи с GitHub. '
                    'Это не мешает слушать музыку.',
              )
            else
              ..._content(context, check.value!),
          ],
        ),
      ),
    );
  }

  /// Что показать, когда ответ получен: обновление, «последняя версия» и —
  /// в обоих случаях — что нового в последнем релизе.
  List<Widget> _content(BuildContext context, UpdateCheck check) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final ReleaseInfo? release = check.latest;

    final List<Widget> children = <Widget>[];

    if (check.updateAvailable && release != null) {
      children.add(
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.system_update_alt, color: scheme.onPrimaryContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Доступна версия ${release.tagName}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              if (release.publishedAt != null) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  'Опубликована ${_formatDate(release.publishedAt!)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: () => _openRelease(context, release.pageUrl),
                  icon: const Icon(Icons.download),
                  label: const Text('Скачать'),
                ),
              ),
            ],
          ),
        ),
      );
      children.add(const SizedBox(height: 24));
    } else {
      children.add(
        Row(
          children: <Widget>[
            Icon(Icons.check_circle_outline, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Установлена последняя версия',
                style: theme.textTheme.bodyLarge,
              ),
            ),
          ],
        ),
      );
      children.add(const SizedBox(height: 24));
    }

    if (release != null) {
      children.add(
        Text(
          'Что нового в ${release.tagName}',
          style: theme.textTheme.titleSmall?.copyWith(
            color: scheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      children.add(const SizedBox(height: 8));
      children.add(
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
          ),
          child: SelectableText(
            release.notes.isEmpty
                ? 'Автор релиза не заполнил список изменений.'
                : release.notes,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
        ),
      );
    }

    return children;
  }

  Future<void> _openRelease(BuildContext context, String url) async {
    final bool opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Не удалось открыть $url')));
    }
  }
}

/// Строка «проверяем»: без крупного прогресса на пол-экрана.
class _CheckingLine extends StatelessWidget {
  const _CheckingLine();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      children: <Widget>[
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        Text(
          'Проверяем обновления…',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Спокойное сообщение вместо ошибки: проверка — не то, ради чего открывают
/// приложение, и красная плашка здесь была бы неправдой.
class _QuietNote extends StatelessWidget {
  const _QuietNote({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 20, color: scheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}

String _formatDate(DateTime moment) {
  final DateTime local = moment.toLocal();
  final String month = local.month.toString().padLeft(2, '0');
  final String day = local.day.toString().padLeft(2, '0');
  return '$day.$month.${local.year}';
}
