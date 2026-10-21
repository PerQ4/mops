import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/custom_font.dart';
import '../../data/local/app_settings.dart';
import '../../state/providers.dart';
import '../../widgets/app_progress.dart';

/// Диалог выбора шрифта интерфейса (задача 7.4).
///
/// Экран отдельный от строки настроек, потому что у «Своего» варианта есть
/// путь к файлу, проверка и предупреждение о кириллице — в подпись строки это
/// не помещается.
Future<void> showFontDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => const _FontDialog(),
  );
}

class _FontDialog extends ConsumerStatefulWidget {
  const _FontDialog();

  @override
  ConsumerState<_FontDialog> createState() => _FontDialogState();
}

class _FontDialogState extends ConsumerState<_FontDialog> {
  late FontPreference _preference;
  late final TextEditingController _path;
  CustomFontStatus? _status;
  bool _checking = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    final AppSettings settings = ref.read(settingsControllerProvider);
    _preference = settings.fontPreference;
    _path = TextEditingController(text: settings.customFontPath);
    // Уже загруженный шрифт показываем сразу: пользователь должен видеть, что
    // именно применено и есть ли в нём кириллица.
    final CustomFontStatus? loaded = CustomFonts.lastStatus;
    if (loaded != null && loaded.path == settings.customFontPath.trim()) {
      _status = loaded;
    }
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<CustomFontStatus> _check() async {
    setState(() {
      _checking = true;
      _saveError = null;
    });
    final CustomFontStatus status =
        await CustomFonts.load(_path.text, force: true);
    if (mounted) {
      setState(() {
        _checking = false;
        _status = status;
      });
    }
    return status;
  }

  Future<void> _save() async {
    if (_preference == FontPreference.custom) {
      // Битый или отсутствующий файл не применяем: «выбрано, но ничего не
      // изменилось» — худший из возможных ответов интерфейса.
      final CustomFontStatus status = await _check();
      if (status.error != null) {
        if (mounted) setState(() => _saveError = status.error);
        return;
      }
    }
    if (!mounted) return;
    await ref.read(settingsControllerProvider.notifier).setFont(
          preference: _preference,
          customPath: _preference == FontPreference.custom ? _path.text : null,
        );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return AlertDialog(
      title: const Text('Шрифт'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              RadioGroup<FontPreference>(
                groupValue: _preference,
                onChanged: (FontPreference? value) {
                  if (value == null) return;
                  setState(() {
                    _preference = value;
                    _saveError = null;
                  });
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (final FontPreference preference
                        in FontPreference.values)
                      RadioListTile<FontPreference>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: preference,
                        title: Text(preference.label),
                        subtitle: Text(
                          preference.description,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (_preference == FontPreference.custom) ...<Widget>[
                const SizedBox(height: 8),
                TextField(
                  controller: _path,
                  decoration: const InputDecoration(
                    labelText: 'Путь к файлу шрифта',
                    helperText: 'TTF или OTF на этом компьютере',
                  ),
                  onChanged: (_) => setState(() {
                    _saveError = null;
                    _status = null;
                  }),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: _checking ? null : _check,
                      icon: _checking
                          ? const AppProgress(size: 24)
                          : const Icon(Icons.font_download_outlined, size: 18),
                      label: Text(_checking ? 'Проверка…' : 'Проверить файл'),
                    ),
                  ],
                ),
                if (_status != null) ...<Widget>[
                  const SizedBox(height: 12),
                  _FontStatusLine(status: _status!),
                ],
                if (_status != null && _status!.loaded) const _FontPreview(),
              ],
              if (_saveError != null) ...<Widget>[
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(Icons.error_outline, size: 18, color: scheme.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _saveError!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.error),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _checking ? null : _save,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

/// Результат проверки файла: загружен, кириллицы нет или причина отказа.
class _FontStatusLine extends StatelessWidget {
  const _FontStatusLine({required this.status});

  final CustomFontStatus status;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    final bool failed = status.error != null;
    final bool noCyrillic = !failed && status.hasCyrillic == false;
    final IconData icon = failed
        ? Icons.error_outline
        : noCyrillic
            ? Icons.warning_amber_outlined
            : Icons.check_circle_outline;
    final Color color = failed
        ? scheme.error
        : noCyrillic
            ? scheme.tertiary
            : scheme.primary;
    final String text = failed
        ? status.error!
        : noCyrillic
            ? 'В шрифте нет кириллицы. Русский текст останется читаемым — он '
                'будет набран Montserrat, как и сейчас.'
            : 'Шрифт загружен: ${status.fileName}';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// Предпросмотр: латиница и кириллица вперемешку — сразу видно, что получилось.
class _FontPreview extends StatelessWidget {
  const _FontPreview();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        'Съешь ещё этих мягких французских булок,\n'
        'да выпей чаю. 0123456789 — mOps',
        style: theme.textTheme.bodyMedium?.copyWith(
          fontFamily: kCustomFontFamily,
          fontFamilyFallback: const <String>['Montserrat'],
          height: 1.4,
        ),
      ),
    );
  }
}
