import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/seed_colors.dart';
import '../../data/local/app_settings.dart';
import '../../state/auth_controller.dart';
import '../../state/providers.dart';
import '../common/navigation.dart';

/// Настройки: внешний вид, воспроизведение, регион и аккаунт.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(settingsControllerProvider);
    final SettingsController controller =
        ref.read(settingsControllerProvider.notifier);
    final AuthState auth = ref.watch(authControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          // -------------------------------------------------------- внешний вид
          const _SectionHeader('Внешний вид'),

          ListTile(
            title: const Text('Тема'),
            subtitle: Text(settings.themeMode.label),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickThemeMode(context, controller, settings),
          ),

          SwitchListTile(
            title: const Text('Material 3 Expressive'),
            subtitle: const Text(
              'Более сочная палитра и выразительные формы',
            ),
            value: settings.useMaterialExpressive,
            onChanged: controller.setUseMaterialExpressive,
          ),

          ListTile(
            title: const Text('Масштаб интерфейса'),
            subtitle: Text(_uiScaleLabel(context, ref, settings)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickUiScale(context, controller, settings),
          ),

          ListTile(
            title: const Text('Палитра'),
            subtitle: Text(settings.colorSource.label),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickColorSource(context, controller, settings),
          ),

          if (settings.colorSource == ColorSource.seed)
            _SeedColorPicker(
              selectedIndex: settings.safeSeedIndex,
              onSelected: controller.setSeedColorIndex,
            ),

          ListTile(
            title: const Text('Вид плеера'),
            subtitle: Text(settings.playerLayout.label),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickPlayerLayout(context, controller, settings),
          ),

          SwitchListTile(
            title: const Text('Показывать текст в плеере'),
            subtitle: const Text('Открывать текст по умолчанию, если он есть'),
            value: settings.showLyricsInPlayer,
            onChanged: controller.setShowLyrics,
          ),

          const Divider(height: 24),

          // ------------------------------------------------------ воспроизведение
          const _SectionHeader('Воспроизведение'),

          ListTile(
            title: const Text('Качество звука'),
            subtitle: Text(settings.audioQuality.label),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickAudioQuality(context, controller, settings),
          ),

          SwitchListTile(
            title: const Text('Автовоспроизведение'),
            subtitle: const Text(
              'Продолжать похожими треками, когда очередь закончилась',
            ),
            value: settings.autoPlayNext,
            onChanged: controller.setAutoPlayNext,
          ),

          const Divider(height: 24),

          // ------------------------------------------------------------- регион
          const _SectionHeader('Регион и язык'),
          ListTile(
            title: const Text('Регион'),
            subtitle: Text(settings.streamingRegion),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickRegion(context, controller, settings),
          ),
          ListTile(
            title: const Text('Язык'),
            subtitle: Text(settings.streamingLanguage),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickLanguage(context, controller, settings),
          ),

          const Divider(height: 24),

          // ------------------------------------------------------------ аккаунт
          const _SectionHeader('Аккаунт'),
          ListTile(
            leading: Icon(
              auth.isSignedIn
                  ? Icons.account_circle
                  : Icons.account_circle_outlined,
            ),
            title: Text(auth.isSignedIn ? 'Вошли' : 'Гость'),
            subtitle: Text(
              auth.isSignedIn
                  ? auth.session!.displayName ?? auth.session!.method.label
                  : 'Нажмите, чтобы войти в YouTube Music',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => AppRoutes.account(context),
          ),

          const Divider(height: 24),

          const _SectionHeader('О приложении'),
          const ListTile(
            title: Text('mOps'),
            subtitle: Text(
              'Кросс-платформенный клиент YouTube Music\n'
              'Material 3 Expressive · Flutter\n\n'
              'Неофициальное приложение. Не связано с Google LLC '
              'и YouTube. Используйте в рамках условий сервиса.',
            ),
            isThreeLine: true,
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- диалоги

  Future<void> _pickThemeMode(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final ThemeModePreference? result =
        await _showChoice<ThemeModePreference>(
      context,
      title: 'Тема',
      current: settings.themeMode,
      values: ThemeModePreference.values,
      label: (ThemeModePreference v) => v.label,
    );
    if (result != null) await controller.setThemeMode(result);
  }

  Future<void> _pickColorSource(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final ColorSource? result = await _showChoice<ColorSource>(
      context,
      title: 'Источник палитры',
      current: settings.colorSource,
      values: ColorSource.values,
      label: (ColorSource v) => v.label,
    );
    if (result != null) await controller.setColorSource(result);
  }

  Future<void> _pickPlayerLayout(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final PlayerLayout? result = await _showChoice<PlayerLayout>(
      context,
      title: 'Вид плеера',
      current: settings.playerLayout,
      values: PlayerLayout.values,
      label: (PlayerLayout v) => v.label,
    );
    if (result != null) await controller.setPlayerLayout(result);
  }

  Future<void> _pickAudioQuality(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final AudioQuality? result = await _showChoice<AudioQuality>(
      context,
      title: 'Качество звука',
      current: settings.audioQuality,
      values: AudioQuality.values,
      label: (AudioQuality v) => v.label,
    );
    if (result != null) await controller.setAudioQuality(result);
  }

  Future<void> _pickRegion(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    const List<String> regions = <String>[
      'RU', 'US', 'GB', 'DE', 'FR', 'ES', 'IT', 'PL', 'TR', 'UA',
      'KZ', 'BY', 'NL', 'SE', 'JP', 'KR', 'BR', 'CA', 'AU', 'IN',
    ];
    final String? result = await _showChoice<String>(
      context,
      title: 'Регион',
      current: settings.streamingRegion,
      values: regions,
      label: (String v) => v,
    );
    if (result != null) await controller.setStreamingRegion(result);
  }

  Future<void> _pickLanguage(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    const Map<String, String> languages = <String, String>{
      'ru': 'Русский',
      'en': 'English',
      'uk': 'Українська',
      'de': 'Deutsch',
      'fr': 'Français',
      'es': 'Español',
      'tr': 'Türkçe',
      'pl': 'Polski',
      'ja': '日本語',
      'ko': '한국어',
    };
    final String? result = await _showChoice<String>(
      context,
      title: 'Язык',
      current: settings.streamingLanguage,
      values: languages.keys.toList(),
      label: (String v) => languages[v] ?? v,
    );
    if (result != null) await controller.setStreamingLanguage(result);
  }

  /// Подпись для пункта «Масштаб интерфейса».
  String _uiScaleLabel(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) {
    if (!settings.isUiScaleAuto) {
      return '${(settings.uiScale * 100).round()}%';
    }

    final double desktop = ref.watch(desktopScaleProvider);
    if (desktop <= 1.01) {
      return 'Автоматически · система масштаб не задаёт';
    }
    return 'Автоматически · система просит ${(desktop * 100).round()}%';
  }

  Future<void> _pickUiScale(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    // Ноль означает автоматический режим.
    final List<double> values = <double>[0, ...kUiScaleSteps];

    final double? result = await _showChoice<double>(
      context,
      title: 'Масштаб интерфейса',
      current: settings.isUiScaleAuto ? 0 : settings.uiScale,
      values: values,
      label: (double value) => value == 0
          ? 'Автоматически (как в системе)'
          : '${(value * 100).round()}%',
    );
    if (result != null) await controller.setUiScale(result);
  }

  Future<T?> _showChoice<T>(
    BuildContext context, {
    required String title,
    required T current,
    required List<T> values,
    required String Function(T value) label,
  }) {
    return showDialog<T>(
      context: context,
      builder: (BuildContext dialogContext) {
        final ColorScheme scheme = Theme.of(dialogContext).colorScheme;
        return SimpleDialog(
          title: Text(title),
          children: <Widget>[
            for (final T value in values)
              ListTile(
                title: Text(label(value)),
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
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
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

/// Выбор акцентного цвета.
class _SeedColorPicker extends StatelessWidget {
  const _SeedColorPicker({required this.selectedIndex, required this.onSelected});

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: <Widget>[
          for (int i = 0; i < kSeedColors.length; i++)
            Tooltip(
              message: kSeedColors[i].name,
              child: InkWell(
                onTap: () => onSelected(i),
                customBorder: const CircleBorder(),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: kSeedColors[i].color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: i == selectedIndex
                          ? scheme.onSurface
                          : Colors.transparent,
                      width: 3,
                    ),
                  ),
                  child: i == selectedIndex
                      ? const Icon(Icons.check, color: Colors.white, size: 22)
                      : null,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
