import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/net/anti_dpi.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/custom_font.dart';
import '../../core/theme/seed_colors.dart';
import '../../core/theme/ui_scaler.dart';
import '../../core/updates/update_check.dart';
import '../../data/local/app_settings.dart';
import '../../data/sources/paxsenix_source.dart';
import '../../state/auth_controller.dart';
import '../../core/theme/layout.dart';
import '../../state/player_controller.dart';
import '../../state/providers.dart';
import '../../state/theme_providers.dart';
import '../player/equalizer.dart';
import '../player/player_controls.dart';
import '../player/sleep_timer.dart';
import '../../state/ui_scale.dart';
import '../../widgets/liquid_backdrop.dart';
import '../common/navigation.dart';
import 'font_settings.dart';
import 'lyrics_animation_screen.dart';
import 'settings_components.dart';
import 'updates_screen.dart';

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
    // Таймер сна — состояние сессии в контроллере плеера, а не настройка:
    // в строке показываем, сколько ещё осталось, поэтому подписка нужна.
    final int sleepTimer = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.sleepTimer),
    );
    // Бейдж «есть обновление»: проверка одна на сеанс, поэтому открытие
    // настроек второй раз в сеть не ходит (`updateCheckProvider` не
    // `autoDispose`).
    final UpdateCheck? update = ref.watch(updateCheckProvider).value;
    final bool hasUpdate = update?.updateAvailable ?? false;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      // На широком экране список растягивался бы на всю ширину — ограничиваем
      // его, как и остальные экраны приложения.
      body: ContentWidth(
        child: _SettingsList(
          // Отступ снизу — не только «воздух» экрана: под списком плавает
          // островок плеера, и без его запаса последняя строка оказывалась под
          // ним. Так же сделано на остальных экранах (`AppLayout`).
          padding: const EdgeInsets.only(
            bottom: SettingsDims.screenBottomPadding +
                AppLayout.floatingDockClearance,
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
                // Шрифт — рядом с масштабом: обе настройки про то, как читается
                // текст, и обе меняют вид всего интерфейса сразу.
                SettingsRow(
                  icon: Icons.font_download_outlined,
                  title: 'Шрифт',
                  subtitle: _fontLabel(settings),
                  onTap: () => showFontDialog(context),
                ),
                // Навигация переезжает в левую панель — как боковая панель
                // swiftify. На компактном окне панели нет, поэтому там
                // переключатель ни на что не влияет: разделы остаются в островке.
                SettingsSwitchRow(
                  icon: Icons.view_sidebar_outlined,
                  title: 'Панель вместо островка',
                  subtitle: 'Навигация по разделам переезжает в левую панель '
                      '(на широком экране)',
                  value: settings.sidebarNavigation,
                  onChanged: controller.setSidebarNavigation,
                ),
                // Вид плеера живёт здесь, а не в «Воспроизведении»: это
                // оформление, а не поведение звука. Порядок — от раскладки
                // плеера к его деталям: панель, полоса, фон, гало, размытие,
                // громкость, затем оформление окна.
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
                SettingsRow(
                  icon: Icons.blur_on,
                  title: 'Фон плеера',
                  subtitle: settings.playerBackgroundStyle.label,
                  onTap: () => _pickPlayerBackgroundStyle(
                    context,
                    controller,
                    settings,
                  ),
                ),
                // Стиль «Жидкость» настраивается в отдельном диалоге: четыре
                // параметра в строках растягивали группу, а места им нужно
                // мало. Строка — точка входа, как у прочих настроек.
                if (settings.playerBackgroundStyle ==
                    PlayerBackgroundStyle.liquid)
                  SettingsRow(
                    icon: Icons.water,
                    title: 'Настройки жидкости',
                    subtitle: _liquidSummary(settings),
                    onTap: () => _editLiquidSettings(context, settings),
                  ),
                // Фон мини-плеера — отдельная от полноэкранного настройка:
                // островок виден всегда, и его вид не обязан повторять фон
                // большого плеера.
                SettingsRow(
                  icon: Icons.crop_16_9,
                  title: 'Фон мини-плеера',
                  subtitle: settings.miniPlayerBackgroundStyle.label,
                  onTap: () => _pickMiniPlayerBackgroundStyle(
                    context,
                    controller,
                    settings,
                  ),
                ),
                // Визуализатор — отдельная настройка, а не часть стиля фона:
                // гало живёт поверх любой подложки. Уровень берётся у libmpv,
                // поэтому там, где такого фильтра нет, гало честно скажет,
                // что данных нет.
                SettingsSwitchRow(
                  icon: Icons.equalizer,
                  title: 'Визуализатор',
                  subtitle: 'Гало вокруг обложки дышит по уровню звука',
                  value: settings.visualizerEnabled,
                  onChanged: controller.setVisualizerEnabled,
                ),
                SettingsSwitchRow(
                  icon: Icons.blur_off,
                  title: 'Отключить размытие',
                  subtitle: 'Фон плеера рисуется без размытия',
                  value: settings.disableBlur,
                  onChanged: controller.setDisableBlur,
                ),
                SettingsRow(
                  icon: Icons.blur_circular,
                  title: 'Интенсивность размытия',
                  subtitle: '${settings.blurRadius.round()}',
                  onTap: () => _pickBlurRadius(context, controller, settings),
                ),
                SettingsRow(
                  icon: Icons.volume_up,
                  title: 'Ползунок громкости',
                  subtitle: settings.volumeSliderStyle.label,
                  onTap: () => _pickVolumeSliderStyle(
                    context,
                    controller,
                    settings,
                  ),
                ),
                SettingsSwitchRow(
                  icon: Icons.web_asset,
                  title: 'Заголовок окна по центру',
                  subtitle: 'Иначе заголовок слева, у логотипа (Windows)',
                  value: settings.titleBarCentered,
                  onChanged: controller.setTitleBarCentered,
                ),
                SettingsSwitchRow(
                  icon: Icons.format_color_fill,
                  title: 'Шапка в цвет фона',
                  subtitle: 'Иначе шапка темнее фона — как рамка окна (Windows)',
                  value: settings.titleBarMatchesBackground,
                  onChanged: controller.setTitleBarMatchesBackground,
                ),
                // Анимации — настройка доступности, поэтому стоят рядом с
                // оформлением, а не отдельной группой.
                SettingsSwitchRow(
                  icon: Icons.animation,
                  title: 'Отключить анимации',
                  subtitle: 'Переходы и раскрытия происходят мгновенно',
                  value: settings.disableAnimations,
                  onChanged: controller.setDisableAnimations,
                ),
                // Высокая частота обновления: на десктопе приложение уже рисует
                // с частотой экрана, а API попросить больше у Flutter нет.
                // Пункт показан неактивным с пояснением, а не выключенным
                // «насовсем»: флаг остаётся в настройках для платформ, где
                // запрос появится.
                SettingsSwitchRow(
                  icon: Icons.speed,
                  title: 'Высокая частота обновления',
                  subtitle: _refreshRateSubtitle(context),
                  value: settings.forceHighRefreshRate,
                  onChanged: controller.setForceHighRefreshRate,
                  enabled: false,
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
                  onTap: () => _editMusixmatchKey(context, ref, controller, settings),
                ),
                SettingsRow(
                  icon: Icons.reorder,
                  title: 'Порядок источников текста',
                  subtitle: settings.lyricsProviderOrder.first.label,
                  onTap: () => _pickLyricsOrder(context, controller, settings),
                ),
                SettingsRow(
                  icon: Icons.checklist,
                  title: 'Источники текста',
                  subtitle: _enabledSourcesLabel(settings),
                  onTap: () =>
                      _pickLyricsProviders(context, controller, settings),
                ),
                SettingsSwitchRow(
                  icon: Icons.subtitles_outlined,
                  title: 'Показывать текст в плеере',
                  subtitle: 'Открывать текст по умолчанию, если он есть',
                  value: settings.showLyricsInPlayer,
                  onChanged: controller.setShowLyrics,
                ),
                // Вид текста — до размера и анимации: сначала выбирают, как
                // строка выглядит, затем уже её кегль и движение.
                SettingsRow(
                  icon: Icons.format_align_left,
                  title: 'Вид текста песни',
                  subtitle: settings.lyricsMode.label,
                  onTap: () => _pickLyricsMode(context, controller, settings),
                ),
                SettingsRow(
                  icon: Icons.animation,
                  title: 'Анимация текста',
                  subtitle: settings.lyricsAnimationStyle.label,
                  onTap: () => _openLyricsAnimation(context),
                ),
                SettingsRow(
                  icon: Icons.text_fields,
                  title: 'Размер текста песни',
                  subtitle: '${(settings.lyricsTextScale * 100).round()}%',
                  onTap: () =>
                      _pickLyricsTextScale(context, controller, settings),
                ),
                // Пять отдельных переключателей как группа `romanization`
                // в ArchiveTune: язык определяется по тексту сам, поэтому
                // ручного выбора языка больше нет. Подряд они занимали почти
                // весь экран, поэтому свёрнуты в одну строку со счётчиком.
                _RomanizationBlock(
                  settings: settings,
                  controller: controller,
                  accent: scheme.secondary,
                ),
              ],
            ),
            const SizedBox(height: SettingsDims.sectionSpacing),

            // Группу слушаем: движок сообщает об отказе фильтра асинхронно, и
            // честная подпись должна появиться сама, без пересборки экрана.
            ListenableBuilder(
              listenable: ref.read(audioEngineProvider).audioEffectIssue,
              builder: (BuildContext context, Widget? _) {
                final String? effectIssue =
                    ref.read(audioEngineProvider).audioEffectIssue.value;
                return SettingsGroup(
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
                    // Эквалайзер настраивается отдельным диалогом: десять полос
                    // в строке не уместить, а строка — лишь точка входа.
                    SettingsRow(
                      icon: Icons.equalizer,
                      title: 'Эквалайзер',
                      subtitle: equalizerSummary(settings),
                      onTap: () => showEqualizerDialog(context, ref),
                    ),
                    SettingsRow(
                      icon: Icons.cloud_download_outlined,
                      title: 'Источник потока',
                      subtitle: settings.streamClient.description,
                      onTap: () =>
                          _pickStreamClient(context, controller, settings),
                    ),
                    // Честно про эффект: это не «улучшение», а вырезание пауз.
                    SettingsSwitchRow(
                      icon: Icons.fast_forward,
                      title: 'Пропуск тишины',
                      subtitle: 'Срезать паузы длиннее полусекунды — трек '
                          'короче, но могут пропасть тихие места',
                      subtitleMaxLines: 2,
                      value: settings.skipSilence,
                      onChanged: controller.setSkipSilence,
                    ),
                    // И это тоже вмешательство: ровная громкость ценой динамики.
                    SettingsSwitchRow(
                      icon: Icons.multitrack_audio,
                      title: 'Нормализация громкости',
                      subtitle: 'Подтягивать тихие места и придерживать громкие '
                          '(dynaudnorm) — ровнее, но уже не так выразительно',
                      subtitleMaxLines: 2,
                      value: settings.audioNormalization,
                      onChanged: controller.setAudioNormalization,
                    ),
                    // Выдернутые наушники и пропавший Bluetooth — звук не
                    // должен продолжаться «в тишину».
                    SettingsSwitchRow(
                      icon: Icons.headphones_outlined,
                      title: 'Пауза при отключении устройства',
                      subtitle: 'Останавливать трек, если пропало устройство, '
                          'в которое шёл звук',
                      subtitleMaxLines: 2,
                      value: settings.pauseOnDeviceMute,
                      onChanged: controller.setPauseOnDeviceMute,
                    ),
                    SettingsSwitchRow(
                      icon: Icons.play_circle_outline,
                      title: 'Автовоспроизведение',
                      subtitle:
                          'Продолжать похожими треками, когда очередь закончилась',
                      value: settings.autoPlayNext,
                      onChanged: controller.setAutoPlayNext,
                    ),
                    // Очередь прошлой сессии возвращается без автозапуска: звук
                    // пойдёт только после нажатия «играть».
                    SettingsSwitchRow(
                      icon: Icons.restore,
                      title: 'Восстанавливать очередь при запуске',
                      subtitle: 'Возвращать очередь и позицию прошлой сессии',
                      value: settings.restoreQueue,
                      onChanged: controller.setRestoreQueue,
                    ),
                    // Таймер сна: та же точка входа, что и кнопка в плеере, —
                    // общий выбор вариантов (`showSleepTimerMenu`).
                    SettingsRow(
                      icon: Icons.bedtime_outlined,
                      title: 'Таймер сна',
                      subtitle: sleepTimerLabel(sleepTimer),
                      onTap: () => showSleepTimerMenu(context, ref),
                    ),
                    SettingsRow(
                      icon: Icons.swipe,
                      title: 'Чувствительность свайпа',
                      subtitle: 'Свайп по мини-плееру: '
                          '${settings.miniSwipeSensitivity.label.toLowerCase()}',
                      onTap: () =>
                          _pickSwipeSensitivity(context, controller, settings),
                    ),
                    // Появляется только когда фильтр отвергнут — причина словами
                    // mpv, а не молчание.
                    if (effectIssue != null)
                      SettingsRow(
                        icon: Icons.error_outline,
                        title: 'Аудиофильтры недоступны',
                        subtitle: effectIssue,
                        subtitleMaxLines: 3,
                      ),
                  ],
                );
              },
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
                SettingsSwitchRow(
                  icon: Icons.explicit,
                  title: 'Скрыть explicit',
                  subtitle: 'Не показывать треки с пометкой «мат»',
                  value: settings.hideExplicit,
                  onChanged: controller.setHideExplicit,
                ),
                SettingsSwitchRow(
                  icon: Icons.slow_motion_video,
                  title: 'Скрыть видео',
                  subtitle: 'Не показывать клипы в выдаче и поиске',
                  value: settings.hideVideo,
                  onChanged: controller.setHideVideo,
                ),
                SettingsRow(
                  icon: Icons.trending_up,
                  title: 'Длина топа',
                  subtitle: '${settings.topSize.label} элементов в чартах и топах',
                  onTap: () => _pickTopSize(context, controller, settings),
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
                SettingsSwitchRow(
                  icon: Icons.data_saver_on,
                  title: 'Низкий расход трафика',
                  subtitle: 'Обложки меньшего размера, крупные кадры видео '
                      'не запрашиваются',
                  value: settings.lowDataMode,
                  onChanged: controller.setLowDataMode,
                ),
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
              title: 'Интеграции',
              accent: scheme.tertiary,
              children: <Widget>[
                SettingsSwitchRow(
                  icon: Icons.forum_outlined,
                  title: 'Discord Rich Presence',
                  subtitle: 'Показывать текущий трек в профиле Discord',
                  value: settings.discordRichPresence,
                  onChanged: controller.setDiscordRichPresence,
                ),
                SettingsRow(
                  icon: Icons.app_registration,
                  title: 'Application ID',
                  subtitle: settings.discordApplicationId.isEmpty
                      ? 'Не задан — трек в Discord не отправляется'
                      : settings.discordApplicationId,
                  onTap: () =>
                      _editDiscordApplicationId(context, controller, settings),
                ),
              ],
            ),
            const SizedBox(height: SettingsDims.sectionSpacing),

            SettingsGroup(
              title: 'Данные',
              accent: scheme.primary,
              children: <Widget>[
                // Резервная копия: перенос настроек на другой компьютер и
                // откат после неудачного эксперимента.
                SettingsRow(
                  icon: Icons.backup_outlined,
                  title: 'Резервная копия',
                  subtitle: 'Сохранить настройки в файл или загрузить из файла',
                  onTap: () => AppRoutes.backup(context),
                ),
                // Хранилище: рядом с копией — обе строки про данные
                // приложения, а не про его поведение.
                SettingsRow(
                  icon: Icons.storage_outlined,
                  title: 'Хранилище',
                  subtitle: 'Занятое место и очистка кэша текстов',
                  onTap: () => AppRoutes.storage(context),
                ),
              ],
            ),
            const SizedBox(height: SettingsDims.sectionSpacing),

            SettingsGroup(
              title: 'О приложении',
              accent: scheme.secondary,
              children: <Widget>[
                // Обновления — первой строкой группы: это единственное, что
                // здесь требует действия, остальное — справка.
                SettingsRow(
                  icon: Icons.system_update_alt,
                  title: 'Обновления',
                  subtitle: hasUpdate
                      ? 'Доступна версия ${update!.latest!.tagName}'
                      : 'Проверить обновления на GitHub',
                  trailing: hasUpdate
                      ? const Badge(label: Text('Есть обновление'))
                      : null,
                  onTap: () => _openUpdates(context),
                ),
                // Строка открывает отдельный экран: версия, ссылки, лицензии и
                // проекты не помещаются в подпись и не относятся к настройкам.
                SettingsRow(
                  icon: Icons.info_outline,
                  title: 'О приложении',
                  subtitle: 'Версия, лицензии и использованные проекты',
                  onTap: () => AppRoutes.about(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- диалоги

  /// «Обновления» открываются прямо отсюда, а не через `AppRoutes`: экран
  /// относится только к настройкам, а общий словарь переходов расширять ради
  /// одной строки незачем. Переход — из словаря движений, как и везде.
  void _openUpdates(BuildContext context) {
    final MotionTransition motion = AppMotion.pageEnter;
    Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        transitionDuration: motion.duration,
        reverseTransitionDuration: motion.reverseDuration ?? motion.duration,
        pageBuilder: (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) =>
            const UpdatesScreen(),
        transitionsBuilder: (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child,
        ) =>
            motion.routeTransition(
          animation: animation,
          begin: const Offset(0, 0.02),
          child: child,
        ),
      ),
    );
  }

  /// Экран анимации текста открывается так же, как «Обновления»: он относится
  /// только к настройкам, поэтому общий словарь маршрутов не расширяем.
  void _openLyricsAnimation(BuildContext context) {
    final MotionTransition motion = AppMotion.pageEnter;
    Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        transitionDuration: motion.duration,
        reverseTransitionDuration: motion.reverseDuration ?? motion.duration,
        pageBuilder: (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) =>
            const LyricsAnimationScreen(),
        transitionsBuilder: (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child,
        ) =>
            motion.routeTransition(
          animation: animation,
          begin: const Offset(0, 0.02),
          child: child,
        ),
      ),
    );
  }

  /// Подпись строки «Шрифт»: выбранный вариант, а у своего — имя файла и
  /// напоминание, что кириллица идёт из фоллбека.
  String _fontLabel(AppSettings settings) {
    switch (settings.fontPreference) {
      case FontPreference.poppins:
        return FontPreference.poppins.label;
      case FontPreference.system:
        return FontPreference.system.label;
      case FontPreference.custom:
        final String path = settings.customFontPath.trim();
        if (path.isEmpty) return 'Свой — файл не выбран';
        final String fileName = path.split(RegExp(r'[\\/]')).last;
        final CustomFontStatus? status = CustomFonts.lastStatus;
        final bool noCyrillic = status != null &&
            status.path == path &&
            status.hasCyrillic == false;
        return noCyrillic
            ? 'Свой — $fileName · кириллица из Montserrat'
            : 'Свой — $fileName';
    }
  }

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

  /// Фон полноэкранного плеера — стиль из ArchiveTune.
  Future<void> _pickPlayerBackgroundStyle(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final PlayerBackgroundStyle? result =
        await _showChoice<PlayerBackgroundStyle>(
      context,
      title: 'Фон плеера',
      current: settings.playerBackgroundStyle,
      values: PlayerBackgroundStyle.values,
      label: (PlayerBackgroundStyle v) => v.label,
      // Подпись объясняет, чем стиль отличается, — по названию это неочевидно.
      description: (PlayerBackgroundStyle v) => v.description,
    );
    if (result != null) await controller.setPlayerBackgroundStyle(result);
  }

  /// Фон мини-плеера — только островок, не полноэкранный плеер.
  Future<void> _pickMiniPlayerBackgroundStyle(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final MiniPlayerBackgroundStyle? result =
        await _showChoice<MiniPlayerBackgroundStyle>(
      context,
      title: 'Фон мини-плеера',
      current: settings.miniPlayerBackgroundStyle,
      values: MiniPlayerBackgroundStyle.values,
      label: (MiniPlayerBackgroundStyle v) => v.label,
      description: (MiniPlayerBackgroundStyle v) => v.description,
    );
    if (result != null) {
      await controller.setMiniPlayerBackgroundStyle(result);
    }
  }

  /// Подпись строки «Настройки жидкости»: текущие значения всех четырёх
  /// параметров, чтобы их было видно, не открывая диалог.
  String _liquidSummary(AppSettings settings) =>
      'Скорость ${settings.liquidSpeed.toStringAsFixed(1)}× · '
      'масштаб ${settings.liquidScale.toStringAsFixed(1)}× · '
      'насыщенность ${(settings.liquidSaturation * 100).round()}% · '
      '${settings.liquidColorSource.label.toLowerCase()}';

  /// Подпись строки высокой частоты обновления: называем текущую частоту
  /// экрана, а не обещаем ускорить отрисовку.
  ///
  /// `Display.refreshRate` есть не на всех платформах: при нуле или исключении
  /// просто не называем число, но причину недоступности говорим всегда.
  String _refreshRateSubtitle(BuildContext context) {
    double rate = 0;
    try {
      rate = View.of(context).display.refreshRate;
    } on Object {
      rate = 0;
    }
    final String current = rate > 0 ? ' (${rate.round()} Гц)' : '';
    return 'Недоступно на десктопе: приложение уже рисует с частотой '
        'экрана$current';
  }

  /// Диалог настроек «Жидкости»: все параметры сразу и живой предпросмотр.
  Future<void> _editLiquidSettings(
    BuildContext context,
    AppSettings settings,
  ) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _LiquidSettingsDialog(initial: settings),
    );
  }

  /// Интенсивность размытия фона (0–64) — слайдер в диалоге.
  Future<void> _pickBlurRadius(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    double value = settings.blurRadius;
    final double? result = await showDialog<double>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) => AlertDialog(
          title: const Text('Интенсивность размытия'),
          content: Slider(
            value: value,
            min: 0,
            max: 64,
            divisions: 64,
            label: '${value.round()}',
            onChanged: (double v) => setState(() => value = v),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(value),
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (result != null) await controller.setBlurRadius(result);
  }

  /// Стиль ползунка громкости — тот же набор, что у полосы перемотки.
  Future<void> _pickVolumeSliderStyle(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final ProgressBarStyle? result = await _showChoice<ProgressBarStyle>(
      context,
      title: 'Ползунок громкости',
      current: settings.volumeSliderStyle,
      values: ProgressBarStyle.values,
      label: (ProgressBarStyle v) => v.label,
    );
    if (result != null) await controller.setVolumeSliderStyle(result);
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
    WidgetRef ref,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final TextEditingController field =
        TextEditingController(text: settings.musixmatchApiKey);
    // Состояние проверки живёт внутри диалога: он не закрывается и не теряет
    // введённый ключ, пока пользователь не нажмёт «Сохранить»/«Отмена».
    PaxsenixKeyStatus? status;
    bool checking = false;

    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) {
          final ColorScheme scheme = Theme.of(context).colorScheme;

          Future<void> runCheck() async {
            final String key = field.text;
            setState(() {
              checking = true;
              status = null;
            });
            // Сбрасываем кэш, чтобы повторное нажатие снова сходило в сеть.
            ref.invalidate(paxsenixKeyCheckProvider(key));
            final PaxsenixKeyStatus value =
                await ref.read(paxsenixKeyCheckProvider(key).future);
            if (!dialogContext.mounted) return;
            setState(() {
              checking = false;
              status = value;
            });
          }

          return AlertDialog(
            title: const Text('Ключ Paxsenix (Musixmatch)'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TextField(
                  controller: field,
                  autofocus: true,
                  decoration:
                      const InputDecoration(hintText: 'Bearer-ключ Paxsenix'),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Ключ выдаётся на lyrics.paxsenix.org — как в ArchiveTune. '
                  'Без ключа источник Musixmatch пропускается.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: checking ? null : runCheck,
                      icon: checking
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.verified_outlined, size: 18),
                      label: Text(checking ? 'Проверка…' : 'Проверить ключ'),
                    ),
                  ],
                ),
                if (status != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          status!.ok
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          size: 18,
                          color: status!.ok ? scheme.tertiary : scheme.error,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          status!.title,
                          style: TextStyle(
                            fontSize: 12,
                            color: status!.ok ? scheme.tertiary : scheme.error,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => launchUrl(
                  Uri.parse('https://lyrics.paxsenix.org/'),
                  mode: LaunchMode.externalApplication,
                ),
                child: const Text('Получить ключ'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, field.text),
                child: const Text('Сохранить'),
              ),
            ],
          );
        },
      ),
    );
    field.dispose();
    if (result != null) await controller.setMusixmatchApiKey(result);
  }

  /// Порядок источников текста: первый — приоритетный (как в ArchiveTune).
  Future<void> _pickLyricsOrder(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final List<LyricsSource> order =
        List<LyricsSource>.of(settings.lyricsProviderOrder);
    final List<LyricsSource>? result = await showDialog<List<LyricsSource>>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) => AlertDialog(
          title: const Text('Порядок источников текста'),
          content: SizedBox(
            width: 360,
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                for (int i = 0; i < order.length; i++)
                  ListTile(
                    dense: true,
                    leading: Text('${i + 1}'),
                    title: Text(order[i].label),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        IconButton(
                          tooltip: 'Выше',
                          icon: const Icon(Icons.keyboard_arrow_up),
                          onPressed: i == 0
                              ? null
                              : () => setState(() {
                                    final LyricsSource moved = order.removeAt(i);
                                    order.insert(i - 1, moved);
                                  }),
                        ),
                        IconButton(
                          tooltip: 'Ниже',
                          icon: const Icon(Icons.keyboard_arrow_down),
                          onPressed: i == order.length - 1
                              ? null
                              : () => setState(() {
                                    final LyricsSource moved = order.removeAt(i);
                                    order.insert(i + 1, moved);
                                  }),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(order),
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (result != null) await controller.setLyricsProviderOrder(result);
  }

  /// Включение и выключение источников текста — как `providerPreferenceKeys`
  /// в ArchiveTune. Выключенный источник не спрашивается вовсе, поэтому
  /// выключение — это ещё и экономия времени поиска.
  ///
  /// Каталоги Paxsenix включаются внутри этой же формы: ключ у Paxsenix один,
  /// а каталогов за ним три, и они независимы.
  Future<void> _pickLyricsProviders(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final List<LyricsSource> disabled =
        List<LyricsSource>.of(settings.lyricsDisabledProviders);
    PaxsenixOptions paxsenix = settings.paxsenixOptions;

    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) {
          void toggle(LyricsSource source, bool enabled) {
            if (enabled) {
              disabled.remove(source);
            } else if (!disabled.contains(source)) {
              disabled.add(source);
            }
          }

          return AlertDialog(
            title: const Text('Источники текста'),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final LyricsSource source
                        in AppSettings.toggleableLyricsSources)
                      SwitchListTile(
                        dense: true,
                        value: !disabled.contains(source),
                        onChanged: (bool on) =>
                            setState(() => toggle(source, on)),
                        title: Text(source.label),
                        subtitle: Text(
                          source.description,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    // Каталоги Paxsenix нужны, только когда включён сам
                    // источник: иначе это выключенные переключатели.
                    if (!disabled.contains(LyricsSource.musixmatch)) ...<Widget>[
                      const Divider(height: 24),
                      Padding(
                        padding: const EdgeInsets.only(left: 16, bottom: 4),
                        child: Text(
                          'Каталоги Paxsenix',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ),
                      SwitchListTile(
                        dense: true,
                        value: paxsenix.appleMusic,
                        onChanged: (bool on) => setState(
                          () => paxsenix = PaxsenixOptions(
                            appleMusic: on,
                            spotify: paxsenix.spotify,
                            musixmatch: paxsenix.musixmatch,
                          ),
                        ),
                        title: const Text('Apple Music'),
                        subtitle: const Text(
                          'TTML с временем каждого слова — караоке',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      SwitchListTile(
                        dense: true,
                        value: paxsenix.spotify,
                        onChanged: (bool on) => setState(
                          () => paxsenix = PaxsenixOptions(
                            appleMusic: paxsenix.appleMusic,
                            spotify: on,
                            musixmatch: paxsenix.musixmatch,
                          ),
                        ),
                        title: const Text('Spotify'),
                        subtitle: const Text(
                          'Обычный текст или LRC',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      SwitchListTile(
                        dense: true,
                        value: paxsenix.musixmatch,
                        onChanged: (bool on) => setState(
                          () => paxsenix = PaxsenixOptions(
                            appleMusic: paxsenix.appleMusic,
                            spotify: paxsenix.spotify,
                            musixmatch: on,
                          ),
                        ),
                        title: const Text('Musixmatch'),
                        subtitle: const Text(
                          'Текст с временами строк',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Сохранить'),
              ),
            ],
          );
        },
      ),
    );

    if (saved != true) return;
    await controller.update(
      (AppSettings s) => s.copyWith(
        lyricsDisabledProviders: disabled,
        paxsenixAppleMusic: paxsenix.appleMusic,
        paxsenixSpotify: paxsenix.spotify,
        paxsenixMusixmatch: paxsenix.musixmatch,
      ),
    );
  }

  /// Подпись к строке «Источники текста»: сколько из них включено.
  String _enabledSourcesLabel(AppSettings settings) {
    final List<LyricsSource> all = AppSettings.toggleableLyricsSources;
    final int on = all.where(settings.isLyricsSourceEnabled).length;
    if (on == 0) return 'Все выключены — текст не ищется';
    if (on == all.length) return 'Включены все';
    return 'Включено $on из ${all.length}';
  }

  /// Application ID приложения Discord: без него presence не отправляется.
  Future<void> _editDiscordApplicationId(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final TextEditingController field =
        TextEditingController(text: settings.discordApplicationId);
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Application ID'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: field,
              autofocus: true,
              decoration:
                  const InputDecoration(hintText: 'Например, 123456789012345678'),
            ),
            const SizedBox(height: 12),
            const Text(
              'Создайте приложение на discord.com/developers/applications '
              'и скопируйте его Application ID. Без него трек в Discord '
              'не отправляется.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => launchUrl(
              Uri.parse('https://discord.com/developers/applications'),
              mode: LaunchMode.externalApplication,
            ),
            child: const Text('Открыть портал'),
          ),
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
    if (result != null) await controller.setDiscordApplicationId(result);
  }

  Future<void> _pickLyricsMode(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final LyricsMode? result = await _showChoice<LyricsMode>(
      context,
      title: 'Вид текста песни',
      current: settings.lyricsMode,
      values: LyricsMode.values,
      label: (LyricsMode v) => v.label,
      description: (LyricsMode v) => v.description,
    );
    if (result != null) await controller.setLyricsMode(result);
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

  Future<void> _pickTopSize(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final TopSize? result = await _showChoice<TopSize>(
      context,
      title: 'Длина топа',
      current: settings.topSize,
      values: TopSize.values,
      label: (TopSize v) => v.label,
    );
    if (result != null) await controller.setTopSize(result);
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
    String Function(T value)? description,
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
                // Описание — только там, где сам выбор неочевиден по названию
                // (например, стили фона). Остальным спискам вторая строка не
                // нужна.
                subtitle: description == null ? null : Text(description(value)),
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

/// Список настроек: строк фиксированный набор и немного, поэтому Column
/// строит их все сразу — прокрутка не пересоздаёт карточки.
class _SettingsList extends StatelessWidget {
  const _SettingsList({
    required this.padding,
    required this.children,
  });

  final EdgeInsetsGeometry padding;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// Свёрнутая группа романизации: одна строка со счётчиком и пять
/// переключателей под ней.
///
/// Заголовок повторяет геометрию `SettingsRow`, но с вращающимся шевроном:
/// `SettingsRow` умеет только шеврон перехода, а здесь он означает раскрытие.
class _RomanizationBlock extends StatefulWidget {
  const _RomanizationBlock({
    required this.settings,
    required this.controller,
    required this.accent,
  });

  final AppSettings settings;
  final SettingsController controller;
  final Color accent;

  @override
  State<_RomanizationBlock> createState() => _RomanizationBlockState();
}

class _RomanizationBlockState extends State<_RomanizationBlock> {
  // Раскрытие — состояние экрана, а не настройка: запоминать его между
  // запусками незачем.
  bool _expanded = false;

  String _summary(AppSettings settings) {
    final List<bool> values = <bool>[
      settings.romanizeJapanese,
      settings.romanizeKorean,
      settings.romanizeChinese,
      settings.romanizeHindi,
      settings.romanizeOther,
    ];
    final int enabled = values.where((bool value) => value).length;
    if (enabled == 0) return 'Все выключены';
    return 'Включено $enabled из ${values.length}';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppSettings settings = widget.settings;
    final SettingsController controller = widget.controller;

    // Те же строки, что были в группе: подписи и порядок не менялись.
    final List<Widget> switches = <Widget>[
      SettingsSwitchRow(
        icon: Icons.translate,
        title: 'Романизация: японский',
        subtitle: 'Латиница под японским текстом',
        value: settings.romanizeJapanese,
        onChanged: controller.setRomanizeJapanese,
      ),
      SettingsSwitchRow(
        icon: Icons.translate,
        title: 'Романизация: корейский',
        subtitle: 'Латиница под корейским текстом',
        value: settings.romanizeKorean,
        onChanged: controller.setRomanizeKorean,
      ),
      SettingsSwitchRow(
        icon: Icons.translate,
        title: 'Романизация: китайский',
        subtitle: 'Латиница под китайским текстом',
        value: settings.romanizeChinese,
        onChanged: controller.setRomanizeChinese,
      ),
      SettingsSwitchRow(
        icon: Icons.translate,
        title: 'Романизация: хинди',
        subtitle: 'Латиница под текстом на хинди',
        value: settings.romanizeHindi,
        onChanged: controller.setRomanizeHindi,
      ),
      SettingsSwitchRow(
        icon: Icons.translate,
        title: 'Романизация: прочие языки',
        subtitle: 'Латиница для остальных нелатинских языков',
        value: settings.romanizeOther,
        onChanged: controller.setRomanizeOther,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Semantics(
          button: true,
          expanded: _expanded,
          child: InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: SettingsDims.rowHorizontalPadding,
                vertical: SettingsDims.rowVerticalPadding,
              ),
              child: Row(
                children: <Widget>[
                  Container(
                    width: SettingsDims.rowIconSize,
                    height: SettingsDims.rowIconSize,
                    decoration: BoxDecoration(
                      color: widget.accent.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.translate,
                      size: SettingsDims.rowIconInnerSize,
                      color: widget.accent,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          'Романизация',
                          style: theme.textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          _summary(settings),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: AppMotion.fast,
                    curve: AppMotion.snappy,
                    child: Icon(
                      Icons.expand_more,
                      size: SettingsDims.chevronSize,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.3),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_expanded)
          for (int i = 0; i < switches.length; i++) ...<Widget>[
            switches[i],
            if (i < switches.length - 1) const SettingsDivider(),
          ],
      ],
    );
  }
}

/// Диалог настроек «Жидкости»: все четыре параметра и живой предпросмотр.
///
/// Правки копятся здесь и уходят в настройки одной записью по «Сохранить»:
/// так «Отмена» ничего не меняет, а фон плеера не перерисовывается и не
/// сохраняется на диск на каждое движение ползунка. Предпросмотр при этом
/// реагирует сразу — он собран из тех же значений, что и настройки.
class _LiquidSettingsDialog extends ConsumerStatefulWidget {
  const _LiquidSettingsDialog({required this.initial});

  /// Настройки на момент открытия — из них берутся начальные значения.
  final AppSettings initial;

  @override
  ConsumerState<_LiquidSettingsDialog> createState() =>
      _LiquidSettingsDialogState();
}

class _LiquidSettingsDialogState extends ConsumerState<_LiquidSettingsDialog> {
  late double _speed = widget.initial.liquidSpeed;
  late double _scale = widget.initial.liquidScale;
  late double _saturation = widget.initial.liquidSaturation;
  late LiquidColorSource _source = widget.initial.liquidColorSource;

  /// Три цвета предпросмотра для выбранного источника.
  ///
  /// «Из темы» — роли палитры приложения, ровно как у самого фона. «Из
  /// обложки» — контейнеры текущего трека, если тема уже собрана из его
  /// обложки (`artworkSchemesProvider`); иначе берём те же цвета палитры: фон
  /// плеера до разбора обложки тоже рисуется ими, так что предпросмотр честно
  /// показывает запасной вариант, а не выдуманный.
  List<Color> _previewColors(ColorScheme scheme) {
    if (_source == LiquidColorSource.theme) return liquidThemeColors(scheme);
    final AppSchemes? artwork = ref.watch(artworkSchemesProvider).value;
    if (artwork == null) return liquidThemeColors(scheme);
    final ColorScheme palette = scheme.brightness == Brightness.dark
        ? artwork.dark
        : artwork.light;
    return <Color>[
      palette.primaryContainer,
      palette.secondaryContainer,
      palette.tertiaryContainer,
    ];
  }

  Future<void> _save() async {
    final SettingsController controller =
        ref.read(settingsControllerProvider.notifier);
    // Закрываем сразу: запись на диск — дело контроллера, ждать её в диалоге
    // незачем.
    Navigator.of(context).pop();
    await controller.update(
      (AppSettings s) => s.copyWith(
        liquidSpeed: _speed,
        liquidScale: _scale,
        liquidSaturation: _saturation,
        liquidColorSource: _source,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return AlertDialog(
      title: const Text('Настройки жидкости'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  height: 140,
                  child: LiquidPreview(
                    colors: _previewColors(scheme),
                    speed: _speed,
                    scale: _scale,
                    saturation: _saturation,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text('Источник цвета', style: theme.textTheme.bodyLarge),
              const SizedBox(height: 8),
              SegmentedButton<LiquidColorSource>(
                showSelectedIcon: false,
                // Кнопки делят ширину диалога поровну: подписи не распирают
                // его на узком окне.
                expandedInsets: EdgeInsets.zero,
                segments: <ButtonSegment<LiquidColorSource>>[
                  for (final LiquidColorSource source
                      in LiquidColorSource.values)
                    ButtonSegment<LiquidColorSource>(
                      value: source,
                      label: Text(
                        source == LiquidColorSource.theme ? 'Тема' : 'Обложка',
                      ),
                    ),
                ],
                selected: <LiquidColorSource>{_source},
                onSelectionChanged: (Set<LiquidColorSource> selection) =>
                    setState(() => _source = selection.first),
              ),
              const SizedBox(height: 12),
              _LiquidSliderField(
                label: 'Скорость течения',
                valueText: '${_speed.toStringAsFixed(1)}×',
                value: _speed,
                min: 0.2,
                max: 3,
                divisions: 28,
                onChanged: (double v) => setState(() => _speed = v),
              ),
              _LiquidSliderField(
                label: 'Масштаб пятен',
                valueText: '${_scale.toStringAsFixed(1)}×',
                value: _scale,
                min: 0.5,
                max: 2.5,
                divisions: 20,
                onChanged: (double v) => setState(() => _scale = v),
              ),
              _LiquidSliderField(
                label: 'Насыщенность цвета',
                valueText: '${(_saturation * 100).round()}%',
                value: _saturation,
                min: 0,
                max: 1.5,
                divisions: 30,
                onChanged: (double v) => setState(() => _saturation = v),
              ),
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
          onPressed: _save,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

/// Строка диалога «Жидкости»: подпись с текущим значением и сам ползунок.
class _LiquidSliderField extends StatelessWidget {
  const _LiquidSliderField({
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(label, style: theme.textTheme.bodyLarge),
            ),
            Text(
              valueText,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: valueText,
          onChanged: onChanged,
        ),
      ],
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
