import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/local/app_settings.dart';
import '../../state/providers.dart';

/// Версия формата резервной копии.
///
/// Растёт, когда в файл добавляется то, чего старые версии приложения не
/// поймут: тогда импорт честно откажется, а не применит настройки наполовину.
const int _backupFormat = 1;

/// Метка приложения в файле — чтобы чужой JSON не приняли за свою копию.
const String _backupApp = 'mOps';

/// Ключи настроек, по которым узнаётся копия mOps.
///
/// Нужны, чтобы отличить свой файл от произвольного JSON: без этой проверки
/// любой объект молча превратился бы в настройки по умолчанию, то есть импорт
/// «успешно» сбросил бы всё, ничего не сообщив.
final Set<String> _knownSettingsKeys = AppSettings().toJson().keys.toSet();

/// Резервная копия настроек: сохранить их в файл и загрузить обратно.
///
/// Экран переносит настройки между компьютерами и позволяет откатиться после
/// неудачного эксперимента. Копируется именно `AppSettings` — тема, порядок
/// источников текста, обход блокировок и всё остальное; дисковый кэш текстов
/// сюда намеренно не входит (см. отчёт).
class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  final TextEditingController _exportPath = TextEditingController();
  final TextEditingController _importPath = TextEditingController();

  /// Ключи и пароли по умолчанию не выносятся в файл: копия может уехать
  /// в облако или чужую папку, а секреты в ней никому не нужны.
  bool _includeSecrets = false;

  bool _busy = false;
  String? _message;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fillDefaultPath();
  }

  @override
  void dispose() {
    _exportPath.dispose();
    _importPath.dispose();
    super.dispose();
  }

  /// Подставляет путь по умолчанию — «Загрузки», а если системы не отдали её,
  /// папку документов приложения. Оба поля получают один и тот же путь: чаще
  /// всего сохраняют и загружают из одного места.
  Future<void> _fillDefaultPath() async {
    final String path = await _defaultBackupPath();
    if (!mounted) return;
    setState(() {
      if (_exportPath.text.isEmpty) _exportPath.text = path;
      if (_importPath.text.isEmpty) _importPath.text = path;
    });
  }

  Future<String> _defaultBackupPath() async {
    Directory? dir;
    try {
      dir = await getDownloadsDirectory();
    } on Object {
      // На части платформ «Загрузок» нет — не повод не предложить путь.
    }
    dir ??= await getApplicationDocumentsDirectory();
    final String name = 'mops-settings-${_dateStamp(DateTime.now())}.json';
    return '${dir.path}${Platform.pathSeparator}$name';
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Резервная копия')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: <Widget>[
          Text(
            'Настройки сохраняются в один файл JSON: его можно перенести на '
            'другой компьютер или оставить как точку возврата. При загрузке '
            'настройки применяются целиком — текущие значения заменяются.',
            style: text.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Включать ключи и пароли'),
            subtitle: const Text(
              'Ключ Musixmatch, секрет OAuth и пароль прокси. Без этого они '
              'в копию не попадут, и после загрузки их придётся задать заново',
            ),
            value: _includeSecrets,
            onChanged: _busy
                ? null
                : (bool value) => setState(() => _includeSecrets = value),
          ),

          const Divider(height: 32),
          const _SectionHeader('Сохранить настройки в файл'),
          TextField(
            controller: _exportPath,
            decoration: const InputDecoration(
              labelText: 'Путь к файлу',
              helperText: 'Существующий файл будет перезаписан',
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _busy ? null : _export,
              icon: const Icon(Icons.save_alt),
              label: const Text('Сохранить'),
            ),
          ),

          const Divider(height: 32),
          const _SectionHeader('Загрузить настройки из файла'),
          TextField(
            controller: _importPath,
            decoration: const InputDecoration(
              labelText: 'Путь к файлу',
              helperText: 'Файл, созданный «Сохранить настройки в файл»',
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: _busy ? null : _import,
              icon: const Icon(Icons.restore),
              label: const Text('Загрузить'),
            ),
          ),

          if (_message != null) ...<Widget>[
            const SizedBox(height: 20),
            _ResultLine(
              icon: Icons.check_circle_outline,
              text: _message!,
              color: scheme.primary,
            ),
          ],
          if (_error != null) ...<Widget>[
            const SizedBox(height: 20),
            _ResultLine(
              icon: Icons.error_outline,
              text: _error!,
              color: scheme.error,
            ),
          ],
        ],
      ),
    );
  }

  /// Собирает файл копии и пишет его на диск.
  Future<void> _export() async {
    final String path = _exportPath.text.trim();
    if (path.isEmpty) {
      setState(() => _error = 'Укажите путь к файлу.');
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
      _error = null;
    });

    try {
      final AppSettings settings = ref.read(settingsControllerProvider);
      final Map<String, dynamic> payload = _buildPayload(
        settings,
        includeSecrets: _includeSecrets,
      );
      final File file = File(path);
      // Родительский каталог может не существовать — создаём, иначе запись
      // упадёт с «путь не найден» на ровном месте.
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
        flush: true,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = 'Настройки сохранены: $path';
      });
    } on FileSystemException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Не удалось записать файл: ${error.message}';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Не удалось сохранить настройки: $error';
      });
    }
  }

  /// Читает файл, проверяет его и — после подтверждения — применяет настройки.
  Future<void> _import() async {
    final String path = _importPath.text.trim();
    if (path.isEmpty) {
      setState(() => _error = 'Укажите путь к файлу.');
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
      _error = null;
    });

    final File file = File(path);
    if (!file.existsSync()) {
      setState(() {
        _busy = false;
        _error = 'Файл не найден: $path';
      });
      return;
    }

    final _BackupFile parsed;
    try {
      parsed = _parseBackup(await file.readAsString());
    } on FileSystemException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Не удалось прочитать файл: ${error.message}';
      });
      return;
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Не удалось прочитать файл: $error';
      });
      return;
    }

    if (!mounted) return;
    if (parsed.error != null) {
      setState(() {
        _busy = false;
        _error = parsed.error;
      });
      return;
    }

    final AppSettings imported = parsed.settings!;
    final bool confirmed = await _confirmImport(imported, parsed.exportedAt) ?? false;
    if (!mounted) return;
    if (!confirmed) {
      setState(() => _busy = false);
      return;
    }

    // Применяем целиком: `update` меняет состояние и сразу пишет его на диск,
    // то есть все подписчики настроек получат новые значения одним разом.
    await ref
        .read(settingsControllerProvider.notifier)
        .update((AppSettings _) => imported);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = 'Настройки загружены: $path';
    });
  }

  /// Показывает, что именно будет применено: слепой импорт мог бы затереть
  /// удачную конфигурацию без единого шанса заметить подмену.
  Future<bool?> _confirmImport(AppSettings imported, DateTime? exportedAt) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Загрузить настройки?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Текущие настройки будут заменены настройками из файла.',
              style: text.bodyMedium,
            ),
            const SizedBox(height: 12),
            Text(
              'Тема: ${imported.themeMode.label}\n'
              'Качество звука: ${imported.audioQuality.label}\n'
              'Источник текста: ${imported.lyricsSource.label}',
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (exportedAt != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                'Файл создан: ${_formatMoment(exportedAt)}',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Загрузить'),
          ),
        ],
      ),
    );
  }
}

/// Строит содержимое файла резервной копии.
Map<String, dynamic> _buildPayload(
  AppSettings settings, {
  required bool includeSecrets,
}) {
  final Map<String, dynamic> json = settings.toJson();
  if (!includeSecrets) {
    json.remove('oauthClientSecret');
    json.remove('musixmatchApiKey');
    final dynamic bypass = json['bypass'];
    if (bypass is Map<String, dynamic>) bypass.remove('proxyPassword');
  }
  return <String, dynamic>{
    'app': _backupApp,
    'format': _backupFormat,
    'exportedAt': DateTime.now().toIso8601String(),
    'settings': json,
  };
}

/// Разобранный файл: либо готовые настройки, либо причина отказа.
class _BackupFile {
  const _BackupFile.settings(this.settings, this.exportedAt) : error = null;
  const _BackupFile.failure(this.error)
      : settings = null,
        exportedAt = null;

  final AppSettings? settings;
  final DateTime? exportedAt;
  final String? error;
}

/// Разбирает и проверяет файл копии.
///
/// Понимает и файл с оболочкой (`app`/`format`/`settings`), и «голый» объект
/// настроек: без этого копия, сделанная ранней сборкой, не загрузилась бы.
_BackupFile _parseBackup(String raw) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const _BackupFile.failure(
      'Файл не является JSON — это не резервная копия mOps.',
    );
  }
  if (decoded is! Map<String, dynamic>) {
    return const _BackupFile.failure('В файле не объект настроек.');
  }

  final dynamic app = decoded['app'];
  if (app is String && app != _backupApp) {
    return const _BackupFile.failure(
      'Это резервная копия другого приложения.',
    );
  }

  final dynamic format = decoded['format'];
  if (format is num && format.toInt() > _backupFormat) {
    return const _BackupFile.failure(
      'Копия создана более новой версией mOps — обновите приложение.',
    );
  }

  final dynamic settingsRaw = decoded['settings'];
  final Map<String, dynamic> settingsJson;
  if (settingsRaw is Map<String, dynamic>) {
    settingsJson = settingsRaw;
  } else if (decoded.keys.any(_knownSettingsKeys.contains)) {
    settingsJson = decoded;
  } else {
    return const _BackupFile.failure('В файле нет настроек mOps.');
  }

  if (!settingsJson.keys.any(_knownSettingsKeys.contains)) {
    return const _BackupFile.failure('Настройки в файле не распознаны.');
  }

  final dynamic exportedRaw = decoded['exportedAt'];
  final DateTime? exportedAt =
      exportedRaw is String ? DateTime.tryParse(exportedRaw) : null;

  try {
    return _BackupFile.settings(AppSettings.fromJson(settingsJson), exportedAt);
  } on Object catch (error) {
    return _BackupFile.failure('Настройки в файле повреждены: $error');
  }
}

String _dateStamp(DateTime moment) {
  final String month = moment.month.toString().padLeft(2, '0');
  final String day = moment.day.toString().padLeft(2, '0');
  return '${moment.year}-$month-$day';
}

String _formatMoment(DateTime moment) {
  final DateTime local = moment.toLocal();
  final String month = local.month.toString().padLeft(2, '0');
  final String day = local.day.toString().padLeft(2, '0');
  final String hour = local.hour.toString().padLeft(2, '0');
  final String minute = local.minute.toString().padLeft(2, '0');
  return '$day.$month.${local.year} $hour:$minute';
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _ResultLine extends StatelessWidget {
  const _ResultLine({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
