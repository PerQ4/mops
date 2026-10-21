import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/anti_dpi.dart';
import '../../core/net/diagnostics.dart';
import '../../core/net/local_proxy.dart';
import '../../data/local/app_settings.dart';
import '../../state/providers.dart';
import '../../widgets/app_progress.dart';

/// Настройки обхода блокировок провайдера.
///
/// Два способа, которые можно включать независимо:
///
///  * **Подмена хоста** — соединение идёт на разрешённый узел Google,
///    а настоящее имя передаётся в заголовке `Host`. Не требует ничего, кроме
///    самого приложения.
///  * **Прокси** — если есть свой SOCKS5 или HTTP-прокси.
class BypassScreen extends ConsumerStatefulWidget {
  const BypassScreen({super.key});

  @override
  ConsumerState<BypassScreen> createState() => _BypassScreenState();
}

class _BypassScreenState extends ConsumerState<BypassScreen> {
  final TextEditingController _frontHost = TextEditingController();
  final TextEditingController _proxyHost = TextEditingController();
  final TextEditingController _proxyPort = TextEditingController();
  final TextEditingController _proxyUser = TextEditingController();
  final TextEditingController _proxyPassword = TextEditingController();

  DiagnosticReport? _report;
  bool _checking = false;
  bool _searching = false;
  String? _proxyResult;

  @override
  void initState() {
    super.initState();
    final AntiDpiConfig config = ref.read(settingsControllerProvider).bypass;
    _frontHost.text = config.fronting.frontHost;
    _proxyHost.text = config.proxyHost;
    _proxyPort.text = config.proxyPort.toString();
    _proxyUser.text = config.proxyUsername;
    _proxyPassword.text = config.proxyPassword;
  }

  @override
  void dispose() {
    _frontHost.dispose();
    _proxyHost.dispose();
    _proxyPort.dispose();
    _proxyUser.dispose();
    _proxyPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = ref.watch(settingsControllerProvider);
    final SettingsController controller =
        ref.read(settingsControllerProvider.notifier);
    final AntiDpiConfig config = settings.bypass;

    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Обход блокировок')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          // --------------------------------------------------------- статус
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Card(
              color: config.isEnabled
                  ? scheme.secondaryContainer
                  : scheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: <Widget>[
                    Icon(
                      config.isEnabled ? Icons.shield : Icons.shield_outlined,
                      color: config.isEnabled
                          ? scheme.onSecondaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            config.isEnabled
                                ? 'Обход работает — настраивать ничего не нужно'
                                : 'Обход выключен',
                            style: text.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: config.isEnabled
                                  ? scheme.onSecondaryContainer
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _statusLine(config),
                            style: text.bodySmall?.copyWith(
                              color: config.isEnabled
                                  ? scheme.onSecondaryContainer
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ------------------------------------------------------------- звук
          const Divider(height: 24),
          const _SectionHeader('Звук'),
          SwitchListTile(
            title: const Text('Искать локальный прокси автоматически'),
            subtitle: const Text(
              'Провайдер блокирует медиасерверы отдельно, и подмена хоста '
              'их не обходит. Приложение само найдёт запущенный прокси '
              '(v2rayA, v2rayN, Clash, Tor…) и включит звук',
            ),
            value: settings.autoDetectProxy,
            onChanged: controller.setAutoDetectProxy,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: _searching ? null : () => _searchProxy(controller),
                icon: _searching
                    ? const AppProgress(size: 24)
                    : const Icon(Icons.search),
                label: Text(_searching ? 'Ищем…' : 'Найти прокси сейчас'),
              ),
            ),
          ),
          if (_proxyResult != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                _proxyResult!,
                style: text.bodyMedium?.copyWith(
                  color: config.usesProxy
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),

          // ---------------------------------------------------- подмена хоста
          const Divider(height: 24),
          const _SectionHeader('Подмена хоста (обход SNI)'),
          SwitchListTile(
            title: const Text('Включена'),
            subtitle: const Text(
              'Провайдер видит только имя разрешённого узла Google, '
              'а нужный домен передаётся в заголовке Host',
            ),
            value: config.fronting.enabled,
            onChanged: controller.setFrontingEnabled,
          ),

          if (config.fronting.enabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _frontHost,
                decoration: const InputDecoration(
                  labelText: 'Узел подмены',
                  helperText: 'Должен быть доступен без блокировки',
                ),
                onSubmitted: controller.setFrontHost,
                onEditingComplete: () => controller.setFrontHost(_frontHost.text),
              ),
            ),

          // ------------------------------------------------------------- прокси
          const Divider(height: 24),
          const _SectionHeader('Фрагментация TLS'),
          ListTile(
            title: const Text('Дробить первый пакет'),
            subtitle: Text(config.fragmentation.label),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickFragmentation(controller),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Помогает не везде: если оборудование провайдера собирает поток '
              'обратно, приём не сработает — тогда нужен прокси или системный '
              'обход (zapret, GoodbyeDPI, VPN).',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),

          // ------------------------------------------------------------- прокси
          const Divider(height: 24),
          const _SectionHeader('Прокси (даёт всё, включая звук)'),
          for (final ProxyKind kind in ProxyKind.values)
            RadioListTile<ProxyKind>(
              value: kind,
              // ignore: deprecated_member_use
              groupValue: config.proxyKind,
              title: Text(kind.label),
              // ignore: deprecated_member_use
              onChanged: (ProxyKind? value) {
                if (value != null) controller.setProxy(kind: value);
              },
            ),

          if (config.usesProxy || config.proxyKind != ProxyKind.none)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: _proxyHost,
                          decoration: const InputDecoration(
                            labelText: 'Адрес прокси',
                            hintText: '127.0.0.1',
                          ),
                          onEditingComplete: () => _saveProxy(controller),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _proxyPort,
                          keyboardType: TextInputType.number,
                          inputFormatters: <TextInputFormatter>[
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Порт',
                            hintText: '1080',
                          ),
                          onEditingComplete: () => _saveProxy(controller),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _proxyUser,
                    decoration: const InputDecoration(labelText: 'Логин'),
                    onEditingComplete: () => _saveProxy(controller),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _proxyPassword,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Пароль'),
                    onEditingComplete: () => _saveProxy(controller),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonal(
                      onPressed: () => _saveProxy(controller),
                      child: const Text('Сохранить прокси'),
                    ),
                  ),
                ],
              ),
            ),

          // --------------------------------------------------------- проверка
          const Divider(height: 24),
          const _SectionHeader('Проверка'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              onPressed: _checking ? null : _runCheck,
              icon: _checking
                  ? const AppProgress(size: 24)
                  : const Icon(Icons.network_check),
              label: Text(_checking ? 'Проверяем…' : 'Проверить соединение'),
            ),
          ),

          if (_report != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: _ReportCard(report: _report!),
            ),

          const Divider(height: 24),
          const _SectionHeader('Как это работает'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              'Провайдер обрывает соединение, увидев в первом пакете TLS имя '
              'youtube.com. Подмена хоста подключается к другому узлу Google, '
              'который не блокируется, и передаёт нужное имя в заголовке Host — '
              'Google обслуживает такой запрос как обычно.\n\n'
              'Сертификат проверяется по имени узла подмены, поэтому в качестве '
              'него подходят только домены Google.\n\n'
              'Звук при включённом обходе скачивается самим приложением и '
              'проигрывается из кэша: GStreamer ходит в сеть напрямую и про '
              'обход не знает.',
              style: text.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Выбор уровня дробления первого пакета.
  Future<void> _pickFragmentation(SettingsController controller) async {
    final FragmentationLevel current =
        ref.read(settingsControllerProvider).bypass.fragmentation;

    final FragmentationLevel? level = await showDialog<FragmentationLevel>(
      context: context,
      builder: (BuildContext dialogContext) {
        final ColorScheme scheme = Theme.of(dialogContext).colorScheme;
        return SimpleDialog(
          title: const Text('Дробление первого пакета'),
          children: <Widget>[
            for (final FragmentationLevel value in FragmentationLevel.values)
              ListTile(
                title: Text(value.label),
                selected: value == current,
                trailing: value == current
                    ? Icon(Icons.check, color: scheme.primary)
                    : null,
                onTap: () => Navigator.pop(dialogContext, value),
              ),
          ],
        );
      },
    );
    if (level == null) return;

    final AntiDpiConfig config =
        ref.read(settingsControllerProvider).bypass;
    await controller.setBypass(config.copyWith(fragmentation: level));
  }

  void _saveProxy(SettingsController controller) {
    controller.setProxy(
      host: _proxyHost.text.trim(),
      port: int.tryParse(_proxyPort.text.trim()) ?? 1080,
      username: _proxyUser.text.trim(),
      password: _proxyPassword.text,
    );
  }

  /// Короткая строка о том, что происходит сейчас.
  String _statusLine(AntiDpiConfig config) {
    if (config.usesProxy) {
      return 'Прокси ${config.proxyKind.label} · ${config.proxyHost}:${config.proxyPort}';
    }
    if (config.fronting.enabled) {
      return 'Включена по умолчанию. Данные идут через ${config.fronting.frontHost}. '
          'Для звука нужен прокси или системный обход.';
    }
    return 'Ничего не используется: приложение ходит в сеть напрямую.';
  }

  /// Ищет локальный прокси прямо сейчас и сразу включает его.
  Future<void> _searchProxy(SettingsController controller) async {
    setState(() {
      _searching = true;
      _proxyResult = null;
    });

    final LocalProxy? proxy = await LocalProxyDetector.find();
    if (!mounted) return;

    if (proxy == null) {
      setState(() {
        _searching = false;
        _proxyResult =
            'Прокси не найден. Запустите свой прокси-клиент (v2rayA, v2rayN, '
            'Clash, Tor…) и нажмите ещё раз — либо укажите адрес вручную ниже.';
      });
      return;
    }

    await controller.setProxy(
      kind: proxy.kind,
      host: proxy.host,
      port: proxy.port,
    );
    await controller.setFrontingEnabled(false);
    if (!mounted) return;

    setState(() {
      _searching = false;
      _proxyResult = 'Найден и включён: ${proxy.kind.label} '
          '${proxy.label}${proxy.note == null ? "" : " · ${proxy.note}"}. '
          'Звук должен заработать.';
    });
  }

  Future<void> _runCheck() async {
    setState(() {
      _checking = true;
      _report = null;
    });

    // Настройки могли измениться — сначала применяем их, чтобы проверка
    // отражала текущий обход, а не прежний.
    await ref
        .read(settingsControllerProvider.notifier)
        .setBypass(ref.read(settingsControllerProvider).bypass);

    final DiagnosticReport report = await ConnectionDiagnostics.run();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _report = report;
    });
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
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

/// Карточка с пошаговым отчётом диагностики.
class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.report});

  final DiagnosticReport report;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color foreground =
        report.ok ? scheme.onSecondaryContainer : scheme.onErrorContainer;

    return Card(
      color: report.ok ? scheme.secondaryContainer : scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  report.ok ? Icons.check_circle_outline : Icons.error_outline,
                  color: foreground,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    report.summary,
                    style: text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: foreground,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (final DiagnosticStep step in report.steps)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      _statusIcon(step.status),
                      size: 18,
                      color: foreground,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            step.title,
                            style: text.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: foreground,
                            ),
                          ),
                          Text(
                            step.detail,
                            style: text.bodySmall?.copyWith(color: foreground),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (report.advice.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final String line in report.advice)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Icon(
                              Icons.lightbulb_outline,
                              size: 18,
                              color: foreground,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                line,
                                style: text.bodySmall?.copyWith(
                                  color: foreground,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  IconData _statusIcon(DiagnosticStatus status) => switch (status) {
        DiagnosticStatus.ok => Icons.check_circle,
        DiagnosticStatus.failed => Icons.cancel,
        DiagnosticStatus.unknown => Icons.help_outline,
      };
}
