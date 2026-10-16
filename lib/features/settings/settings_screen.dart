import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/anti_dpi.dart';
import '../../core/theme/seed_colors.dart';
import '../../core/theme/ui_scaler.dart';
import '../../data/local/app_settings.dart';
import '../../state/auth_controller.dart';
import '../../core/theme/layout.dart';
import '../../state/providers.dart';
import '../player/player_controls.dart';
import '../../state/ui_scale.dart';
import '../common/navigation.dart';
import 'settings_components.dart';

/// Настройки: внешний вид, воспроизведение, регион и аккаунт.
///
/// Разметка повторяет ArchiveTune: разделы разделены заголовками, а строки
/// лежат в карточке-группе со скруглением 16 (`SettingsGroupCard`,
/// `SettingsRow` — `ui/screens/settings/SettingsComponents.kt`).
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(settingsControllerProvider);
    final SettingsController controller =
        ref.read(settingsControllerProvider.notifier);
    final AuthState auth = ref.watch(authControllerProvider);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      // На широком экране список растягивался бы на всю ширину — ограничиваем
      // его, как и остальные экраны приложения.
      body: ContentWidth(
        child: ListView(
          padding: const EdgeInsets.only(
            bottom: SettingsDims.screenBottomPadding,
          ),
          children: <Widget>[
            // Акценты групп повторяют назначение из ArchiveTune
            // (`SettingsDataBuilders.kt`): внешний вид и текст песни —
            // secondary, воспроизведение и сеть — tertiary, остальное primary.
            SettingsGroup(
              title: 'Внешний вид',
              accent: scheme.secondary,
              children: <Widget>[
                SettingsSwitchRow(
                  icon: Icons.dark_mode_outlined,
                  title: 'Чистый чёрный фон',
                  subtitle:
                      'В тёмной теме фон и панели становятся абсолютно чёрными',
                  value: settings.pureBlack,
                  onChanged: controller.setPureBlack,
                ),
                SettingsRow(
                  icon: Icons.palette_outlined,
                  title: 'Тема',
                  subtitle: settings.themeMode.label,
                  onTap: () => _pickThemeMode(context, controller, settings),
                ),
                SettingsSwitchRow(
                  icon: Icons.auto_awesome,
                  title: 'Material 3 Expressive',
                  subtitle: 'Более сочная палитра и выразительные формы',
                  value: settings.useMaterialExpressive,
                  onChanged: controller.setUseMaterialExpressive,
                ),
                SettingsRow(
                  icon: Icons.gradient_outlined,
                  title: 'Стиль палитры',
                  subtitle: settings.paletteStyle.label,
                  onTap: () =>
                      _pickPaletteStyle(context, controller, settings),
                ),
                SettingsRow(
                  icon: Icons.format_paint_outlined,
                  title: 'Палитра',
                  subtitle: settings.colorSource.label,
                  onTap: () => _pickColorSource(context, controller, settings),
                ),
                // Выбор акцентного цвета — собственная настройка mOps,
                // показывается прямо под строкой «Палитра».
                if (settings.colorSource == ColorSource.seed)
                  _SeedColorPicker(
                    selectedIndex: settings.safeSeedIndex,
                    onSelected: controller.setSeedColorIndex,
                  ),
                SettingsRow(
                  icon: Icons.aspect_ratio,
                  title: 'Масштаб интерфейса',
                  subtitle: _uiScaleLabel(context, ref, settings),
                  onTap: () => _pickUiScale(context, controller, settings),
                ),
              ],
            ),
            const SizedBox(height: SettingsDims.sectionSpacing),

            SettingsGroup(
              title: 'Текст песни',
              accent: scheme.secondary,
              children: <Widget>[
                SettingsRow(
                  icon: Icons.lyrics_outlined,
                  title: 'Источник текста песни',
                  subtitle: settings.lyricsSource.label,
                  onTap: () =>
                      _pickLyricsSource(context, controller, settings),
                ),
                SettingsRow(
                  icon: Icons.vpn_key_outlined,
                  title: 'Ключ Musixmatch',
                  subtitle: settings.musixmatchApiKey.isEmpty
                      ? 'Не задан — источник Musixmatch выключен'
                      : 'Задан',
                  onTap: () =>
                      _editMusixmatchKey(context, controller, settings),
                ),
                SettingsSwitchRow(
                  icon: Icons.subtitles_outlined,
                  title: 'Показывать текст в плеере',
                  subtitle: 'Открывать текст по умолчанию, если он есть',
                  value: settings.showLyricsInPlayer,
                  onChanged: controller.setShowLyrics,
                ),
                SettingsRow(
                  icon: Icons.text_fields,
                  title: 'Размер текста песни',
                  subtitle: '${(settings.lyricsTextScale * 100).round()}%',
                  onTap: () =>
                      _pickLyricsTextScale(context, controller, settings),
                ),
              ],
            ),
            const SizedBox(height: SettingsDims.sectionSpacing),

            SettingsGroup(
              title: 'Воспроизведение',
              accent: scheme.tertiary,
              children: <Widget>[
                SettingsRow(
                  icon: Icons.graphic_eq,
                  title: 'Качество звука',
                  subtitle: settings.audioQuality.label,
                  onTap: () =>
                      _pickAudioQuality(context, controller, settings),
                ),
                SettingsRow(
                  icon: Icons.cloud_download_outlined,
                  title: 'Источник потока',
                  subtitle: settings.streamClient.description,
                  onTap: () =>
                      _pickStreamClient(context, controller, settings),
                ),
                SettingsSwitchRow(
                  icon: Icons.play_circle_outline,
                  title: 'Автовоспроизведение',
                  subtitle:
                      'Продолжать похожими треками, когда очередь закончилась',
                  value: settings.autoPlayNext,
                  onChanged: controller.setAutoPlayNext,
                ),
                SettingsRow(
                  icon: Icons.swipe,
                  title: 'Чувствительность свайпа',
                  subtitle: 'Свайп по мини-плееру: '
                      '${settings.miniSwipeSensitivity.label.toLowerCase()}',
                  onTap: () =>
                      _pickSwipeSensitivity(context, controller, settings),
                ),
                // Плеер стоит справа от навигации, поэтому и разворачивается в
                // правую панель — зеркально библиотеке слева. На телефоне
                // панели нет: там по нажатию открывается полный экран.
                SettingsSwitchRow(
                  icon: Icons.vertical_split,
                  title: 'Плеер справа',
                  subtitle: 'Разворачивать плеер в отдельную панель справа '
                      '(на широком экране)',
                  value: settings.playerPanelEnabled,
                  onChanged: controller.setPlayerPanelEnabled,
                ),
                SettingsRow(
                  icon: Icons.linear_scale,
                  title: 'Полоса перемотки',
                  subtitle: settings.progressBarStyle.label,
                  onTap: () =>
                      _pickProgressBarStyle(context, controller, settings),
                ),
              ],
            ),
            const SizedBox(height: SettingsDims.sectionSpacing),

            SettingsGroup(
              title: 'Поиск',
              accent: scheme.primary,
              children: <Widget>[
                SettingsRow(
                  icon: Icons.search,
                  title: 'Где искать',
                  subtitle: settings.searchSource.description,
                  onTap: () => _pickSearchSource(context, controller, settings),
                ),
              ],
            ),
            const SizedBox(height: SettingsDims.sectionSpacing),

            SettingsGroup(
              title: 'Регион и язык',
              accent: scheme.primary,
              children: <Widget>[
                SettingsRow(
                  icon: Icons.public,
                  title: 'Регион',
                  subtitle: settings.streamingRegion,
                  onTap: () => _pickRegion(context, controller, settings),
                ),
                SettingsRow(
                  icon: Icons.language,
                  title: 'Язык',
                  subtitle: settings.streamingLanguage,
                  onTap: () => _pickLanguage(context, controller, settings),
                ),
              ],
            ),
            const SizedBox(height: SettingsDims.sectionSpacing),

            SettingsGroup(
              title: 'Доступ к сети',
              accent: scheme.tertiary,
              children: <Widget>[
                SettingsRow(
                  icon: settings.bypass.isEnabled
                      ? Icons.shield
                      : Icons.shield_outlined,
                  title: 'Обход блокировок',
                  subtitle: _bypassLabel(settings),
                  onTap: () => AppRoutes.bypass(context),
                ),
              ],
            ),
            const SizedBox(height: SettingsDims.sectionSpacing),

            SettingsGroup(
              title: 'Аккаунт',
              accent: scheme.primary,
              children: <Widget>[
                SettingsRow(
                  icon: auth.isSignedIn
                      ? Icons.account_circle
                      : Icons.account_circle_outlined,
                  title: auth.isSignedIn ? 'Вошли' : 'Гость',
                  subtitle: auth.isSignedIn
                      ? auth.session!.displayName ?? auth.session!.method.label
                      : 'Нажмите, чтобы войти в YouTube Music',
                  onTap: () => AppRoutes.account(context),
                ),
                SettingsRow(
                  icon: Icons.swap_horiz,
                  title: 'Перенос из Spotify',
                  subtitle: 'Перенести плейлисты в YouTube Music',
                  onTap: () => AppRoutes.spotifyImport(context),
                ),
              ],
            ),
            const SizedBox(height: SettingsDims.sectionSpacing),

            SettingsGroup(
              title: 'О приложении',
              accent: scheme.secondary,
              children: <Widget>[
                // Информационная строка: без действия и без шеврона, а подпись
                // не обрезаем — текст лицензии должен читаться целиком.
                SettingsRow(
                  icon: Icons.info_outline,
                  title: 'mOps',
                  subtitle: 'Кросс-платформенный клиент YouTube Music\n'
                      'Material 3 Expressive · Flutter\n\n'
                      'Неофициальное приложение. Не связано с Google LLC '
                      'и YouTube. Используйте в рамках условий сервиса.',
                  subtitleMaxLines: null,
                ),
              ],
            ),
          ],
        ),
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

  Future<void> _pickLyricsSource(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final LyricsSource? result = await _showChoice<LyricsSource>(
      context,
      title: 'Источник текста песни',
      current: settings.lyricsSource,
      values: LyricsSource.values,
      label: (LyricsSource v) => v.label,
    );
    if (result != null) await controller.setLyricsSource(result);
  }

  /// Выбор стиля полосы — карточками с живым предпросмотром, как в
  /// ArchiveTune (`SliderStyleOptionCard`, `AppearanceSettings.kt:1195`):
  /// квадратные карточки по три в ряд, выбранная обведена акцентом.
  Future<void> _pickProgressBarStyle(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final ProgressBarStyle? result = await showDialog<ProgressBarStyle>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Полоса перемотки'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int row = 0;
                  row < (ProgressBarStyle.values.length / 3).ceil();
                  row++)
                Padding(
                  padding: EdgeInsets.only(top: row == 0 ? 0 : 8),
                  child: Row(
                    children: <Widget>[
                      for (final ProgressBarStyle style in ProgressBarStyle
                          .values
                          .skip(row * 3)
                          .take(3))
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: _SliderStyleCard(
                              style: style,
                              selected: settings.progressBarStyle == style,
                              onTap: () =>
                                  Navigator.of(dialogContext).pop(style),
                            ),
                          ),
                        ),
                      // Пустые места: без них карточки последнего ряда
                      // растянулись бы на всю ширину.
                      for (int i = ProgressBarStyle.values
                              .skip(row * 3)
                              .take(3)
                              .length;
                          i < 3;
                          i++)
                        const Expanded(child: SizedBox()),
                    ],
                  ),
                ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Отмена'),
            ),
          ],
        );
      },
    );
    if (result != null) await controller.setProgressBarStyle(result);
  }

  /// Ключ Paxsenix: через него работает источник Musixmatch.
  Future<void> _editMusixmatchKey(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final TextEditingController field =
        TextEditingController(text: settings.musixmatchApiKey);
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Ключ Paxsenix (Musixmatch)'),
        content: TextField(
          controller: field,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Bearer-ключ Paxsenix'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, field.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    field.dispose();
    if (result != null) await controller.setMusixmatchApiKey(result);
  }

  Future<void> _pickLyricsTextScale(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    // Множитель, а не абсолютный размер: так настройка не зависит от
    // системного масштаба и базовой типографики темы.
    const List<double> values = <double>[0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4];
    final double? result = await _showChoice<double>(
      context,
      title: 'Размер текста песни',
      current: settings.lyricsTextScale,
      values: values,
      label: (double v) => '${(v * 100).round()}%',
    );
    if (result != null) await controller.setLyricsTextScale(result);
  }

  Future<void> _pickSwipeSensitivity(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final SwipeSensitivity? result = await _showChoice<SwipeSensitivity>(
      context,
      title: 'Чувствительность свайпа',
      current: settings.miniSwipeSensitivity,
      values: SwipeSensitivity.values,
      label: (SwipeSensitivity v) => v.label,
    );
    if (result != null) await controller.setMiniSwipeSensitivity(result);
  }

  Future<void> _pickSearchSource(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final SearchSource? result = await _showChoice<SearchSource>(
      context,
      title: 'Где искать',
      current: settings.searchSource,
      values: SearchSource.values,
      label: (SearchSource v) => v.label,
    );
    if (result != null) await controller.setSearchSource(result);
  }

  Future<void> _pickPaletteStyle(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final PaletteStylePreference? result =
        await _showChoice<PaletteStylePreference>(
      context,
      title: 'Стиль палитры',
      current: settings.paletteStyle,
      values: PaletteStylePreference.values,
      label: (PaletteStylePreference v) => v.label,
    );
    if (result != null) await controller.setPaletteStyle(result);
  }

  Future<void> _pickStreamClient(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final StreamSource? result = await _showChoice<StreamSource>(
      context,
      title: 'Источник потока',
      current: settings.streamClient,
      values: StreamSource.values,
      label: (StreamSource v) => v.label,
    );
    if (result != null) await controller.setStreamClient(result);
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

  /// Подпись для пункта «Обход блокировок».
  String _bypassLabel(AppSettings settings) {
    final AntiDpiConfig config = settings.bypass;
    if (config.usesProxy) {
      return 'Прокси ${config.proxyKind.label} · '
          '${config.proxyHost}:${config.proxyPort}';
    }
    if (config.fronting.enabled) {
      return 'Включён автоматически · подмена хоста';
    }
    return 'Выключен';
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

    final DesktopScaleInfo desktop = ref.watch(desktopScaleProvider);
    if (desktop.isDefault) {
      return 'Автоматически · система масштаб не задаёт';
    }

    // Показываем не только источник, но и итог компенсации.
    final double effective = resolveUiScale(context, ref);
    final String note = (effective - 1.0).abs() < 0.05
        ? 'компенсация не нужна'
        : 'компенсация ${(effective * 100).round()}%';
    return 'Автоматически · ${desktop.source} · $note';
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

/// Карточка стиля полосы перемотки — `SliderStyleOptionCard` в ArchiveTune
/// (`AppearanceSettings.kt:1195`).
///
/// Квадрат со скруглением 16 и рамкой: акцентной у выбранной, приглушённой у
/// остальных. Внутри — живая полоса при 50 % и подпись под ней.
class _SliderStyleCard extends StatelessWidget {
  const _SliderStyleCard({
    required this.style,
    required this.selected,
    required this.onTap,
  });

  final ProgressBarStyle style;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 1,
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: <Widget>[
                Expanded(
                  child: Center(
                    // Полоса всегда показывается целиком: на узком диалоге
                    // карточка ужимается, а не выдаёт переполнение.
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: SizedBox(
                        width: 160,
                        height: 44,
                        child: SeekBarPreview(style: style),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  style.label,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
