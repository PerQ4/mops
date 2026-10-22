import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/audio/audio_engine.dart';
import '../core/audio/audio_level_monitor.dart';
import '../core/audio/audioplayers_engine.dart';
import '../core/auth/token_store.dart';
import '../core/innertube/innertube_client.dart';
import '../core/net/anti_dpi.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/custom_font.dart';
import '../core/theme/seed_colors.dart';
import '../core/theme/ui_scaler.dart';
import '../core/updates/update_check.dart';
import '../core/utils/artwork_urls.dart';
import '../data/local/app_settings.dart';
import '../data/local/downloads.dart';
import '../data/local/listening_stats.dart';
import '../data/local/local_media.dart';
import '../data/models/models.dart';
import '../data/sources/catalog_source.dart';
import '../data/sources/paxsenix_source.dart';
import '../data/sources/range_downloader.dart';
import '../data/sources/romanization.dart';
import '../data/sources/sponsorblock.dart';
import '../data/sources/stream_downloader.dart';
import '../data/sources/stream_proxy.dart';
import '../data/sources/stream_resolver.dart';
import 'auth_controller.dart';
import 'library_providers.dart';

/// ---------------------------------------------------------------------------
/// Базовая инициализация.
///
/// Асинхронную работу (чтение настроек и сессии) выполняет `main()` до
/// `runApp`, а готовые значения передаются через `overrides`. Благодаря этому
/// тема и плеер доступны синхронно с первого кадра — без «мигания» интерфейса.
/// ---------------------------------------------------------------------------

/// Ключ, под которым настройки лежат в `shared_preferences`.
const String kSettingsKey = 'mops.settings.v1';

/// Куда складывается исходная строка настроек, если разобрать её не удалось.
///
/// Отдельный ключ, а не файл: настройки и так живут в `shared_preferences`,
/// и строка рядом переживёт перезапись настроек дефолтами. Она нужна, чтобы
/// ручную правку или битый импорт можно было восстановить, а не потерять.
const String kCorruptSettingsKey = 'mops.settings.corrupt';

final Provider<SharedPreferences> sharedPreferencesProvider =
    Provider<SharedPreferences>(
  (ref) => throw UnimplementedError(
    'sharedPreferencesProvider должен быть переопределён в main()',
  ),
);

/// Настройки, прочитанные из хранилища до первого кадра.
final Provider<AppSettings> initialSettingsProvider = Provider<AppSettings>(
  (ref) => const AppSettings(),
);

/// Сохранённая сессия, прочитанная до первого кадра.
final Provider<AuthSession?> initialSessionProvider = Provider<AuthSession?>(
  (ref) => null,
);

/// ---------------------------------------------------------------------------
/// Настройки
/// ---------------------------------------------------------------------------

/// Хранит настройки и пишет изменения на диск.
///
/// Запись намеренно не блокирует UI: сначала меняем состояние, затем сохраняем.
class SettingsController extends Notifier<AppSettings> {
  /// Сохранение копии исходной строки настроек, если её не удалось разобрать.
  /// Первая же запись должна дождаться её: иначе дефолты затрут файл раньше,
  /// чем сохранится копия.
  Future<void>? _archive;

  /// Настройки прочитались не полностью: в файле было что-то нечитаемое.
  bool get readFailed => _archive != null;

  @override
  AppSettings build() {
    final AppSettings settings = ref.watch(initialSettingsProvider);

    // `main()` разбирает настройки до `runApp`; здесь проверяем ту же строку,
    // потому что `AppSettings.decode` на ошибке молча отдаёт дефолты, а первая
    // же запись (например, громкость) затёрла бы исходник.
    //
    // Провайдер preferences в тестах может быть не переопределён — тогда
    // проверять нечего, и это не повод не собрать контроллер.
    String? raw;
    try {
      raw = ref.read(sharedPreferencesProvider).getString(kSettingsKey);
    } on Object catch (error) {
      debugPrint('[Settings] хранилище настроек недоступно: $error');
    }
    if (_looksUnreadable(raw)) {
      _archive = _saveCorrupt(raw!);
    }

    _publishContentFilter(settings);
    _publishLowDataMode(settings);
    _publishMotion(settings);
    _publishFont(settings);
    return settings;
  }

  /// Копирует исходную строку в [kCorruptSettingsKey] и пишет об этом в лог.
  ///
  /// Ошибка копирования не должна запрещать сохранять настройки навсегда:
  /// она только логируется. Но `_archive` завершается в любом случае, поэтому
  /// запись не обгоняет попытку сохранения.
  Future<void> _saveCorrupt(String raw) async {
    try {
      final SharedPreferences prefs = ref.read(sharedPreferencesProvider);
      await prefs.setString(kCorruptSettingsKey, raw);
      debugPrint(
        '[Settings] настройки не разобраны; исходная строка сохранена в '
        '$kCorruptSettingsKey (${raw.length} символов)',
      );
    } on Object catch (error) {
      debugPrint('[Settings] не удалось сохранить копию настроек: $error');
    }
  }

  /// Строка не пустая, но не даёт настроек: битый JSON, не объект или
  /// значение неверного типа (последнее бросает `TypeError` из доменных
  /// `fromJson`).
  static bool _looksUnreadable(String? raw) {
    if (raw == null || raw.isEmpty) return false;
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return true;
      AppSettings.decode(raw);
      return false;
    } on Object {
      return true;
    }
  }

  Future<void> _persist(AppSettings next) async {
    state = next;
    _publishContentFilter(next);
    _publishLowDataMode(next);
    _publishMotion(next);
    _publishFont(next);
    // Сначала копия нечитаемого исходника (если он был), только потом запись:
    // так дефолты не успевают стереть то, что не удалось прочитать.
    await _archive;
    final SharedPreferences prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(kSettingsKey, next.encode());
  }

  Future<void> update(AppSettings Function(AppSettings current) change) =>
      _persist(change(state));

  Future<void> setThemeMode(ThemeModePreference mode) =>
      update((AppSettings s) => s.copyWith(themeMode: mode));

  Future<void> setColorSource(ColorSource source) =>
      update((AppSettings s) => s.copyWith(colorSource: source));

  Future<void> setSeedColorIndex(int index) =>
      update((AppSettings s) => s.copyWith(seedColorIndex: index));

  Future<void> setUseMaterialExpressive(bool value) =>
      update((AppSettings s) => s.copyWith(useMaterialExpressive: value));

  /// Отключить анимации: все длительности из словаря движений станут нулевыми.
  Future<void> setDisableAnimations(bool value) =>
      update((AppSettings s) => s.copyWith(disableAnimations: value));

  /// Запрос высокой частоты обновления — платформа решает, может ли его
  /// выполнить (на десктопе такой возможности нет, см. `AppSettings`).
  Future<void> setForceHighRefreshRate(bool value) =>
      update((AppSettings s) => s.copyWith(forceHighRefreshRate: value));

  /// Шрифт интерфейса (задача 7.4): Poppins, системный или свой файл.
  ///
  /// Путь и выбор меняются вместе: сохранение диалога шрифта присылает оба
  /// значения, и раздельные записи заставляли бы тему пересобираться дважды.
  Future<void> setFont({
    required FontPreference preference,
    String? customPath,
  }) =>
      update((AppSettings s) => s.copyWith(
            fontPreference: preference,
            customFontPath: customPath?.trim() ?? s.customFontPath,
          ));

  Future<void> setLyricsSource(LyricsSource source) =>
      update((AppSettings s) => s.copyWith(lyricsSource: source));

  /// Включает или выключает источник текста — как `providerPreferenceKeys`
  /// в ArchiveTune. Выключенный источник не спрашивается вовсе.
  Future<void> setLyricsProviderEnabled(LyricsSource source, bool enabled) =>
      update((AppSettings s) {
        final List<LyricsSource> disabled =
            List<LyricsSource>.of(s.lyricsDisabledProviders);
        if (enabled) {
          disabled.remove(source);
        } else if (!disabled.contains(source)) {
          disabled.add(source);
        }
        return s.copyWith(lyricsDisabledProviders: disabled);
      });

  /// Каталоги Paxsenix: Apple Music, Spotify, Musixmatch — по отдельности.
  Future<void> setPaxsenixOptions(PaxsenixOptions options) =>
      update((AppSettings s) => s.copyWith(
            paxsenixAppleMusic: options.appleMusic,
            paxsenixSpotify: options.spotify,
            paxsenixMusixmatch: options.musixmatch,
          ));

  Future<void> setSidebarWidth(double width) =>
      update((AppSettings s) => s.copyWith(sidebarWidth: width));

  /// Навигация в левой панели вместо плавающего островка.
  Future<void> setSidebarNavigation(bool value) =>
      update((AppSettings s) => s.copyWith(sidebarNavigation: value));

  Future<void> setPlayerPanelWidth(double width) =>
      update((AppSettings s) => s.copyWith(playerPanelWidth: width));

  Future<void> setPaletteStyle(PaletteStylePreference style) =>
      update((AppSettings s) => s.copyWith(paletteStyle: style));

  Future<void> setPureBlack(bool value) =>
      update((AppSettings s) => s.copyWith(pureBlack: value));

  Future<void> setAudioQuality(AudioQuality quality) =>
      update((AppSettings s) => s.copyWith(audioQuality: quality));

  /// Режим низкого расхода трафика: меньше обложек и никаких превью.
  Future<void> setLowDataMode(bool value) =>
      update((AppSettings s) => s.copyWith(lowDataMode: value));

  Future<void> setStreamClient(StreamSource client) =>
      update((AppSettings s) => s.copyWith(streamClient: client));

  Future<void> setShowLyrics(bool value) =>
      update((AppSettings s) => s.copyWith(showLyricsInPlayer: value));

  /// Множитель размера текста песни.
  Future<void> setLyricsTextScale(double scale) =>
      update((AppSettings s) => s.copyWith(lyricsTextScale: scale));

  /// Где искать: онлайн или только в библиотеке.
  Future<void> setSearchSource(SearchSource source) =>
      update((AppSettings s) => s.copyWith(searchSource: source));

  /// Прятать explicit-треки в выдаче каталога и поиска.
  Future<void> setHideExplicit(bool value) =>
      update((AppSettings s) => s.copyWith(hideExplicit: value));

  /// Прятать клипы в выдаче каталога и поиска.
  Future<void> setHideVideo(bool value) =>
      update((AppSettings s) => s.copyWith(hideVideo: value));

  /// Длина топов и чартов.
  Future<void> setTopSize(TopSize size) =>
      update((AppSettings s) => s.copyWith(topSize: size));

  /// Чувствительность свайпа по островку плеера.
  Future<void> setMiniSwipeSensitivity(SwipeSensitivity value) =>
      update((AppSettings s) => s.copyWith(miniSwipeSensitivity: value));

  /// Что делает свайп по строке трека.
  Future<void> setTrackSwipeAction(TrackSwipeAction action) =>
      update((AppSettings s) => s.copyWith(trackSwipeAction: action));

  /// Включает или выключает разворот плеера в правую панель.
  Future<void> setPlayerPanelEnabled(bool value) =>
      update((AppSettings s) => s.copyWith(playerPanelEnabled: value));

  /// Режим правой панели: плеер с крупной обложкой или очередь.
  Future<void> setRightPanelMode(RightPanelMode mode) =>
      update((AppSettings s) => s.copyWith(playerPanelMode: mode));

  /// Стиль полосы перемотки в плеере.
  Future<void> setProgressBarStyle(ProgressBarStyle style) =>
      update((AppSettings s) => s.copyWith(progressBarStyle: style));

  /// Ключ Paxsenix — через него работает источник Musixmatch.
  Future<void> setMusixmatchApiKey(String value) =>
      update((AppSettings s) => s.copyWith(musixmatchApiKey: value.trim()));

  /// Включает или выключает Discord Rich Presence.
  Future<void> setDiscordRichPresence(bool value) =>
      update((AppSettings s) => s.copyWith(discordRichPresence: value));

  /// Application ID приложения Discord из Developer Portal.
  Future<void> setDiscordApplicationId(String value) =>
      update((AppSettings s) => s.copyWith(discordApplicationId: value.trim()));

  /// Фон полноэкранного плеера — стиль из ArchiveTune.
  Future<void> setPlayerBackgroundStyle(PlayerBackgroundStyle style) =>
      update((AppSettings s) => s.copyWith(playerBackgroundStyle: style));

  /// «Жидкость»: скорость течения.
  Future<void> setLiquidSpeed(double value) =>
      update((AppSettings s) => s.copyWith(liquidSpeed: value));

  /// «Жидкость»: масштаб пятен.
  Future<void> setLiquidScale(double value) =>
      update((AppSettings s) => s.copyWith(liquidScale: value));

  /// «Жидкость»: насыщенность цвета.
  Future<void> setLiquidSaturation(double value) =>
      update((AppSettings s) => s.copyWith(liquidSaturation: value));

  /// «Жидкость»: откуда брать цвета — из обложки или из темы.
  Future<void> setLiquidColorSource(LiquidColorSource source) =>
      update((AppSettings s) => s.copyWith(liquidColorSource: source));

  /// Отключить размытие фона.
  Future<void> setDisableBlur(bool value) =>
      update((AppSettings s) => s.copyWith(disableBlur: value));

  /// Сила размытия фона.
  Future<void> setBlurRadius(double value) =>
      update((AppSettings s) => s.copyWith(blurRadius: value));

  /// «Гало» вокруг обложки по уровню звука.
  Future<void> setVisualizerEnabled(bool value) =>
      update((AppSettings s) => s.copyWith(visualizerEnabled: value));

  /// Вид визуализатора: гало или спектр полос (задача 10.8).
  Future<void> setVisualizerStyle(VisualizerStyle style) =>
      update((AppSettings s) => s.copyWith(visualizerStyle: style));

  /// «Живая обложка» полноэкранного плеера (задача 8.2).
  Future<void> setLiveCoverEnabled(bool value) =>
      update((AppSettings s) => s.copyWith(liveCoverEnabled: value));

  /// Запись статистики прослушиваний (задача 8.1). Выключение не стирает уже
  /// собранное — стереть можно на экране статистики.
  Future<void> setListeningStatsEnabled(bool value) =>
      update((AppSettings s) => s.copyWith(listeningStatsEnabled: value));

  /// Эквалайзер одним изменением: включение, полосы и имя пресета.
  ///
  /// Полосы и пресет меняются вместе: пользователь либо выбирает готовый набор,
  /// либо двигает полосы (тогда пресет становится «своим»).
  Future<void> setEqualizer({
    required bool enabled,
    required List<double> bands,
    required String presetId,
  }) =>
      update((AppSettings s) => s.copyWith(
            equalizerEnabled: enabled,
            // Копия, а не ссылка: диалог двигает свой список на месте, и без
            // копии он менял бы состояние настроек в обход уведомления.
            equalizerBands: List<double>.of(bands),
            equalizerPresetId: presetId,
          ));

  /// Убирать паузы из потока.
  Future<void> setSkipSilence(bool value) =>
      update((AppSettings s) => s.copyWith(skipSilence: value));

  /// Выравнивать громкость между тихими и громкими местами.
  Future<void> setAudioNormalization(bool value) =>
      update((AppSettings s) => s.copyWith(audioNormalization: value));

  /// Ставить на паузу, когда пропадает устройство вывода.
  Future<void> setPauseOnDeviceMute(bool value) =>
      update((AppSettings s) => s.copyWith(pauseOnDeviceMute: value));

  /// Пропускать вставки, размеченные на SponsorBlock.
  Future<void> setSponsorBlockEnabled(bool value) =>
      update((AppSettings s) => s.copyWith(sponsorBlockEnabled: value));

  /// Заменяет набор пропускаемых категорий целиком.
  ///
  /// Одним обновлением, а не по категории: диалог сохраняется одной кнопкой, и
  /// писать настройки несколько раз подряд незачем.
  Future<void> setSponsorBlockCategories(
    List<SponsorBlockCategory> categories,
  ) =>
      update(
        (AppSettings s) => s.copyWith(
          sponsorBlockCategories:
              List<SponsorBlockCategory>.unmodifiable(categories),
        ),
      );

  /// Фон мини-плеера: тема, градиент или свечение.
  Future<void> setMiniPlayerBackgroundStyle(MiniPlayerBackgroundStyle style) =>
      update((AppSettings s) => s.copyWith(miniPlayerBackgroundStyle: style));

  /// Стиль ползунка громкости.
  Future<void> setVolumeSliderStyle(ProgressBarStyle style) =>
      update((AppSettings s) => s.copyWith(volumeSliderStyle: style));

  /// Заголовок окна по центру (иначе — слева).
  Future<void> setTitleBarCentered(bool value) =>
      update((AppSettings s) => s.copyWith(titleBarCentered: value));

  /// Красить шапку окна в цвет фона приложения.
  Future<void> setTitleBarMatchesBackground(bool value) =>
      update((AppSettings s) => s.copyWith(titleBarMatchesBackground: value));

  /// Межстрочный интервал текста песни.
  Future<void> setLyricsLineSpacing(double value) =>
      update((AppSettings s) => s.copyWith(lyricsLineSpacing: value));

  /// Размывать неактивные строки текста песни.
  Future<void> setLyricsLineBlur(bool value) =>
      update((AppSettings s) => s.copyWith(lyricsLineBlur: value));

  /// Вид текста песни: классический, V2 или Enhanced (задача 3.1).
  Future<void> setLyricsMode(LyricsMode mode) =>
      update((AppSettings s) => s.copyWith(lyricsMode: mode));

  /// Стиль анимации строки и подсветки слов (задача 3.2).
  Future<void> setLyricsAnimationStyle(LyricsAnimationStyle style) =>
      update((AppSettings s) => s.copyWith(lyricsAnimationStyle: style));

  /// Крупность активной строки. Ноль — «как в выбранном виде».
  Future<void> setLyricsActiveLineScale(double value) =>
      update((AppSettings s) => s.copyWith(lyricsActiveLineScale: value));

  /// Прозрачность неактивных строк (1 — как в выбранном виде).
  Future<void> setLyricsInactiveOpacity(double value) =>
      update((AppSettings s) => s.copyWith(lyricsInactiveOpacity: value));

  /// Выравнивание строк текста песни.
  Future<void> setLyricsTextAlign(LyricsTextAlign align) =>
      update((AppSettings s) => s.copyWith(lyricsTextAlign: align));

  /// Ширина колонки текста песни.
  Future<void> setLyricsColumnWidth(LyricsColumnWidth width) =>
      update((AppSettings s) => s.copyWith(lyricsColumnWidth: width));

  /// Следует ли список за поющейся строкой сам.
  Future<void> setLyricsAutoScroll(bool value) =>
      update((AppSettings s) => s.copyWith(lyricsAutoScroll: value));

  /// Порядок источников текста (первый — приоритетный).
  Future<void> setLyricsProviderOrder(List<LyricsSource> order) =>
      update((AppSettings s) => s.copyWith(lyricsProviderOrder: order));

  /// Романизация текста: латиница под оригинальной строкой. Пять отдельных
  /// переключателей как `LyricsRomanize*Key` в ArchiveTune — язык определяется
  /// по самому тексту, поэтому выбирать его вручную не нужно.
  Future<void> setRomanizeJapanese(bool value) =>
      update((AppSettings s) => s.copyWith(romanizeJapanese: value));

  Future<void> setRomanizeKorean(bool value) =>
      update((AppSettings s) => s.copyWith(romanizeKorean: value));

  Future<void> setRomanizeChinese(bool value) =>
      update((AppSettings s) => s.copyWith(romanizeChinese: value));

  Future<void> setRomanizeHindi(bool value) =>
      update((AppSettings s) => s.copyWith(romanizeHindi: value));

  Future<void> setRomanizeOther(bool value) =>
      update((AppSettings s) => s.copyWith(romanizeOther: value));

  Future<void> setAutoPlayNext(bool value) =>
      update((AppSettings s) => s.copyWith(autoPlayNext: value));

  /// Предзагрузка следующего трека (задача 2.4).
  Future<void> setPreloadNextTrack(bool value) =>
      update((AppSettings s) => s.copyWith(preloadNextTrack: value));

  /// Папка с локальной музыкой. Путь нормализуется только по краям: менять
  /// разделители на Windows нельзя — путь может быть сетевым (`\\server\…`).
  Future<void> setLocalMediaFolder(String path) =>
      update((AppSettings s) => s.copyWith(localMediaFolder: path.trim()));

  /// Восстанавливать очередь и позицию прошлой сессии при запуске.
  Future<void> setRestoreQueue(bool value) =>
      update((AppSettings s) => s.copyWith(restoreQueue: value));

  Future<void> setStreamingRegion(String region) =>
      update((AppSettings s) => s.copyWith(streamingRegion: region));

  Future<void> setStreamingLanguage(String language) =>
      update((AppSettings s) => s.copyWith(streamingLanguage: language));

  Future<void> setOAuthCredentials({
    required String clientId,
    required String clientSecret,
  }) =>
      update((AppSettings s) => s.copyWith(
            oauthClientId: clientId,
            oauthClientSecret: clientSecret,
          ));

  Future<void> setLastVolume(double volume) =>
      update((AppSettings s) => s.copyWith(lastVolume: volume));

  Future<void> setLastSpeed(double speed) =>
      update((AppSettings s) => s.copyWith(lastSpeed: speed));

  /// `scale` — множитель или `0`, чтобы вернуть автоматический режим.
  Future<void> setUiScale(double scale) =>
      update((AppSettings s) => s.copyWith(uiScale: scale));

  /// Плотные строки треков и библиотеки (пункт 11.2).
  Future<void> setCompactRows(bool value) =>
      update((AppSettings s) => s.copyWith(compactRows: value));

  // ------------------------------------------------- обход блокировок

  Future<void> setBypass(AntiDpiConfig config) =>
      update((AppSettings s) => s.copyWith(bypass: config));

  Future<void> setFrontingEnabled(bool enabled) => update(
        (AppSettings s) =>
            s.copyWith(bypass: s.bypass.copyWith(
              fronting: s.bypass.fronting.copyWith(enabled: enabled),
            )),
      );

  Future<void> setFrontHost(String host) => update(
        (AppSettings s) => s.copyWith(
          bypass: s.bypass.copyWith(
            fronting: s.bypass.fronting.copyWith(frontHost: host.trim()),
          ),
        ),
      );

  /// Включает или выключает автопоиск локального прокси.
  Future<void> setAutoDetectProxy(bool value) =>
      update((AppSettings s) => s.copyWith(autoDetectProxy: value));

  Future<void> setProxy({
    ProxyKind? kind,
    String? host,
    int? port,
    String? username,
    String? password,
  }) =>
      update(
        (AppSettings s) => s.copyWith(
          bypass: s.bypass.copyWith(
            proxyKind: kind ?? s.bypass.proxyKind,
            proxyHost: host ?? s.bypass.proxyHost,
            proxyPort: port ?? s.bypass.proxyPort,
            proxyUsername: username ?? s.bypass.proxyUsername,
            proxyPassword: password ?? s.bypass.proxyPassword,
          ),
        ),
      );
}

final NotifierProvider<SettingsController, AppSettings> settingsControllerProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

/// Передаёт источнику каталога настройки содержимого: что прятать и какой длины
/// отдавать топы.
///
/// Источник каталога создаётся в `catalog_providers.dart` без настроек, а
/// `catalog_source.dart` импортируют консольные инструменты, поэтому настройки
/// туда не тянутся: значение кладётся в одно поле класса при каждом изменении.
void _publishContentFilter(AppSettings settings) {
  CatalogSource.contentFilter = ContentFilter(
    hideExplicit: settings.hideExplicit,
    hideVideo: settings.hideVideo,
    topSize: settings.topSize.value,
  );
}

/// Передаёт режим низкого трафика в утилиты обложек.
///
/// URL обложек строятся в обычных функциях и виджетах, у которых нет доступа
/// к `ref` (модели треков, карточки, фоны плеера), поэтому, как и у фильтра
/// содержимого, значение кладётся в общую переменную при каждой смене настроек.
void _publishLowDataMode(AppSettings settings) {
  artworkLowDataMode.value = settings.lowDataMode;
}

/// Передаёт настройку анимаций в словарь движений.
///
/// Длительности читаются из мест без `ref` (переходы навигатора,
/// `Scrollable.ensureVisible`), поэтому флаг, как и два выше, живёт в общей
/// переменной и обновляется при каждой смене настроек.
void _publishMotion(AppSettings settings) {
  AppMotion.animationsDisabled = settings.disableAnimations;
}

/// Передаёт выбор шрифта в тему и загружает свой шрифт с диска.
///
/// Тема собирается провайдером, у которого нет `ref` на настройки шрифта,
/// поэтому выбор живёт рядом с темой — так же, как флаг движений. Тема
/// пересобирается в `MopsApp`, когда выбор меняется.
void _publishFont(AppSettings settings) {
  AppTheme.font = AppFont.forPreference(settings.fontPreference);
  if (settings.fontPreference != FontPreference.custom) return;

  final String path = settings.customFontPath.trim();
  if (path.isEmpty) return;
  // Регистрация шрифта в движке асинхронна, ждать её в настройках нечего:
  // до её окончания текст рисуется фоллбеком, а затем движок перерисовывает
  // его сам, без пересборки темы.
  unawaited(CustomFonts.load(path));
}

/// ---------------------------------------------------------------------------
/// Обновления
/// ---------------------------------------------------------------------------

/// Проверка обновлений по GitHub Releases.
///
/// Один экземпляр на приложение: у него свой HTTP-клиент, и он же закрывается
/// при выходе. Запрос делается один раз за сеанс — `updateCheckProvider` не
/// `autoDispose`, поэтому повторное открытие настроек сеть не дёргает.
final Provider<UpdateChecker> updateCheckerProvider = Provider<UpdateChecker>(
  (ref) {
    final UpdateChecker checker = UpdateChecker();
    ref.onDispose(checker.dispose);
    return checker;
  },
);

/// Последний найденный релиз и то, новее ли он установленной версии.
///
/// `null` — проверить не удалось (нет сети, нет версии для сравнения). Это не
/// ошибка интерфейса: бейдж просто не показывается, а экран обновлений
/// говорит об этом одной спокойной строкой.
final FutureProvider<UpdateCheck?> updateCheckProvider =
    FutureProvider<UpdateCheck?>(
  (ref) => ref.watch(updateCheckerProvider).check(),
);

/// ---------------------------------------------------------------------------
/// Проверка ключа Paxsenix
/// ---------------------------------------------------------------------------

/// Отдельный источник для проверки ключа: у проверки свой HTTP-клиент, чтобы
/// не мешать источнику текста, который занят поиском по треку.
final Provider<PaxsenixSource> paxsenixKeyCheckerProvider =
    Provider<PaxsenixSource>((ref) {
  final PaxsenixSource source = PaxsenixSource();
  ref.onDispose(source.dispose);
  return source;
});

/// Статус ключа Paxsenix для введённого значения.
///
/// Без `autoDispose`: результат нужен целиком, пока открыт диалог, иначе
/// отменённый при закрытии запрос показал бы «сервис недоступен» на пустом месте.
final paxsenixKeyCheckProvider =
    FutureProvider.family<PaxsenixKeyStatus, String>(
  (ref, key) => ref.watch(paxsenixKeyCheckerProvider).checkKey(key),
);

/// ---------------------------------------------------------------------------
/// Романизация текста
/// ---------------------------------------------------------------------------

/// Сервис романизации: один на приложение — держит HTTP-клиент и кэш по
/// трекам, чтобы не дёргать сервис на каждую перерисовку.
final Provider<RomanizationService> romanizationServiceProvider =
    Provider<RomanizationService>((ref) {
  final RomanizationService service = RomanizationService();
  ref.onDispose(service.dispose);
  return service;
});

/// Запрос романизации: трек, включённые языки и строки текста.
///
/// Строки входят в ключ, чтобы результат пересчитался при смене текста
/// (например, выбран другой источник) и не смешался со старым.
class RomanizationQuery {
  const RomanizationQuery({
    required this.videoId,
    required this.options,
    required this.lines,
  });

  final String videoId;
  final RomanizationOptions options;
  final List<String> lines;

  @override
  bool operator ==(Object other) =>
      other is RomanizationQuery &&
      other.videoId == videoId &&
      other.options == options &&
      _sameLines(other.lines, lines);

  @override
  int get hashCode => Object.hash(videoId, options, Object.hashAll(lines));

  static bool _sameLines(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Романизация строк текста: `Map` «номер строки → латиница».
///
/// Провайдер кэширует будущее по аргументам, а сервис — по треку: пока текст
/// не сменился, в сеть уходит ровно один запрос на язык. `autoDispose` — чтобы
/// после ухода с трека будущее не висело в памяти: повторный запрос всё равно
/// возьмётся из кэша сервиса.
final romanizationProvider =
    FutureProvider.autoDispose.family<Map<int, String>?, RomanizationQuery>(
  (ref, query) => ref.watch(romanizationServiceProvider).romanize(
        videoId: query.videoId,
        options: query.options,
        lines: query.lines,
      ),
);

/// ---------------------------------------------------------------------------
/// Масштаб интерфейса
/// ---------------------------------------------------------------------------

/// Масштаб, который просит оконная система. Переопределяется в `main()`.
///
/// Значение `1.0` означает «система не просит масштабировать».
final Provider<DesktopScaleInfo> desktopScaleProvider =
    Provider<DesktopScaleInfo>((ref) => DesktopScaleInfo.none);

/// Стандартные ступени масштаба для интерфейса настроек.
/// Мелкие значения нужны для компенсации: GTK3 на дробном масштабе отдаёт
/// завышенный DPR, и интерфейс приходится уменьшать.
const List<double> kUiScaleSteps = <double>[
  0.5, 0.625, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0,
];

/// ---------------------------------------------------------------------------
/// Обход блокировок
/// ---------------------------------------------------------------------------

/// Текущая конфигурация обхода. Отдельный провайдер нужен, чтобы слушать
/// изменения одним `listen` и переприменять сетевые настройки.
final Provider<AntiDpiConfig> bypassProvider = Provider<AntiDpiConfig>(
  (ref) => ref.watch(
    settingsControllerProvider.select((AppSettings s) => s.bypass),
  ),
);

/// Активен ли сейчас какой-либо обход.
///
/// От этого зависит способ воспроизведения: при обходе поток скачивается
/// через Dart (где обход и работает), а не отдаётся напрямую GStreamer.
final Provider<bool> bypassActiveProvider = Provider<bool>(
  (ref) => ref.watch(bypassProvider).isEnabled,
);

/// Нужно ли при запуске проверять работоспособность обхода.
///
/// В тестах выключается: проверка ходит в сеть, а тестам нужна предсказуемость.
final Provider<bool> bypassAutoVerifyProvider = Provider<bool>((ref) => true);

/// ---------------------------------------------------------------------------
/// Сеть и аудио
/// ---------------------------------------------------------------------------

final Provider<TokenStore> tokenStoreProvider = Provider<TokenStore>(
  (ref) => TokenStore(),
);

/// Клиент InnerTube (внутренний API YouTube Music).
///
/// Пересоздаётся только при смене региона/языка: `select` не даёт реагировать
/// на изменения остальных настроек.
final Provider<InnerTubeClient> innerTubeProvider = Provider<InnerTubeClient>(
  (ref) {
    // Список заблокированных исполнителей читается с диска: поднимаем его до
    // первого запроса каталога, иначе стартовая главная пришла бы
    // нефильтрованной. Запросы каталога ждут готовности сами
    // (`CatalogSource.blockedArtistsReady`).
    ref.read(blockedArtistsProvider);

    final String region = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.streamingRegion),
    );
    final String locale = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.streamingLanguage),
    );

    final InnerTubeClient client = InnerTubeClient(
      locale: locale,
      region: region,
    );
    ref.onDispose(client.dispose);
    return client;
  },
);

/// Клиент SponsorBlock.
///
/// Один на приложение: держит кэш ответов, чтобы повторный запуск трека не
/// ходил в сеть заново. Сеть здесь вспомогательная: ошибки клиент глотает сам,
/// поэтому провайдер не зависит от входа и настроек.
final Provider<SponsorBlockClient> sponsorBlockClientProvider =
    Provider<SponsorBlockClient>((Ref ref) {
  final SponsorBlockClient client = SponsorBlockClient();
  ref.onDispose(client.dispose);
  return client;
});

/// Получение ссылок на аудиопотоки.
///
/// Пересоздаётся при смене авторизации, клиента и региона: и заголовки, и
/// профиль клиента вшиваются в резолвер при создании.
final Provider<StreamResolver> streamResolverProvider =
    Provider<StreamResolver>((ref) {
  final AuthSession? session =
      ref.watch(authControllerProvider.select((AuthState s) => s.session));

  // Смена клиента в настройках должна пересоздать резолвер: профиль
  // вшивается в него при создании.
  final StreamSource clientChoice = ref.watch(
    settingsControllerProvider.select((AppSettings s) => s.streamClient),
  );
  final String locale = ref.watch(
    settingsControllerProvider.select((AppSettings s) => s.streamingLanguage),
  );
  final String region = ref.watch(
    settingsControllerProvider.select((AppSettings s) => s.streamingRegion),
  );

  // Тот же клиент InnerTube, что и у каталога: так запрос потока идёт теми же
  // cookie и тем же соединением.
  final InnerTubeClient client = ref.watch(innerTubeProvider);

  final Map<String, String> authHeaders =
      AuthenticatedYoutubeClient.headersForSession(
    cookieString: session?.cookieString,
    bearerToken: session?.tokens?.accessToken,
  );

  final StreamResolver resolver = YoutubeStreamResolver(
    innerTube: client,
    locale: locale,
    region: region,
    clientChoice: clientChoice,
    authHeaders: authHeaders,
    // Локальный файл проверяется при каждом запросе, а не кэшируется вместе с
    // резолвером: загрузку могли удалить, и тогда нужен обычный сетевой путь.
    localFile: ref.read(downloadsStoreProvider).localPath,
  );
  ref.onDispose(resolver.dispose);
  return resolver;
});

/// Локальный посредник: через него плеер играет поток, а данные у YouTube
/// качает приложение запросами с диапазоном.
final Provider<StreamProxy> streamProxyProvider = Provider<StreamProxy>((ref) {
  final StreamProxy proxy = StreamProxy();
  ref.onDispose(proxy.dispose);
  return proxy;
});

/// Загрузка потока на диск — нужна при обходе блокировок, когда звук качает
/// приложение, а не GStreamer.
final Provider<StreamDownloader> streamDownloaderProvider =
    Provider<StreamDownloader>((ref) {
  final StreamDownloader downloader = StreamDownloader();
  ref.onDispose(downloader.dispose);
  return downloader;
});

/// Плеер libmpv — один на приложение и общий с движком.
///
/// Создаётся здесь, а не внутри [MediaKitEngine], потому что того же самого
/// экземпляра libmpv требуют уровни звука для визуализатора: `af` и
/// `af-metadata` — свойства конкретного плеера, а второго плеера у них нет.
/// Освобождает плеер движок (он владеет им) — здесь только отдаём.
final Provider<Player> mediaKitPlayerProvider = Provider<Player>((ref) {
  // `pitch: true` включает независимый сдвиг высоты тона: без него `setPitch`
  // бросает ArgumentError (см. `media_kit_engine.dart`).
  return Player(configuration: const PlayerConfiguration(pitch: true));
});

/// Аудиодвижок. Один на всё приложение.
final Provider<AudioEngine> audioEngineProvider = Provider<AudioEngine>(
  (ref) {
    final MediaKitEngine engine =
        AudioplayersEngine(player: ref.watch(mediaKitPlayerProvider));
    ref.onDispose(engine.dispose);

    // Аудиоэффекты из настроек применяются к живому движку здесь: движок не
    // должен знать про AppSettings, а эквалайзер, пропуск тишины и нормализация
    // — свойства одной звуковой цепочки, поэтому тянуть их нужно из одного
    // места, а не из экранов.
    void applyEffects(AppSettings settings) {
      unawaited(
        engine.setEqualizer(
          settings.equalizerEnabled ? settings.equalizerBands : const <double>[],
        ),
      );
      unawaited(engine.setSkipSilence(settings.skipSilence));
      unawaited(engine.setAudioNormalization(settings.audioNormalization));
    }

    // `fireImmediately` применяет сохранённые настройки при первом запуске.
    ref.listen<AppSettings>(
      settingsControllerProvider,
      (AppSettings? _, AppSettings next) => applyEffects(next),
      fireImmediately: true,
    );
    return engine;
  },
);

/// Уровень звука для визуализатора (задача 10.3).
///
/// Провайдер отдельный и ленивый: его читают только тогда, когда визуализатор
/// включён в настройках. Пока он выключен, плеер для уровней не поднимается и
/// никакого опроса `af-metadata` не идёт — в том числе в тестах, где движок
/// подменён заглушкой и настоящего libmpv нет.
final Provider<AudioLevelMonitor> audioLevelMonitorProvider =
    Provider<AudioLevelMonitor>((ref) {
  final AudioLevelMonitor monitor =
      AudioLevelMonitor(ref.watch(mediaKitPlayerProvider));
  ref.onDispose(monitor.dispose);
  return monitor;
});

/// Хранилище статистики прослушиваний — одно на приложение.
final Provider<ListeningStatsStore> listeningStatsStoreProvider =
    Provider<ListeningStatsStore>((Ref ref) => ListeningStatsStore());

/// Журнал зачтённых прослушиваний (задача 8.1).
///
/// События читаются с диска один раз и дальше живут в памяти. Запись идёт
/// очередью в хранилище, поэтому зачёты на границе трека не теряются. Провайдер
/// ленивый: пока контроллер плеера не зачтёт первое прослушивание, файл не
/// читается — в тестах с заглушкой движка этого не происходит вовсе.
class ListeningStats extends Notifier<List<ListenEvent>> {
  Future<void>? _ready;

  @override
  List<ListenEvent> build() {
    _ready = _load(ref.watch(listeningStatsStoreProvider));
    return const <ListenEvent>[];
  }

  Future<void> _load(ListeningStatsStore store) async {
    List<ListenEvent> loaded = const <ListenEvent>[];
    try {
      loaded = await store.readAll();
    } on Object catch (error) {
      debugPrint('Статистика: журнал не прочитан — $error');
    }
    if (!ref.mounted) return;
    state = List<ListenEvent>.unmodifiable(loaded);
  }

  /// Записывает зачётное прослушивание и сохраняет его на диск.
  ///
  /// Ждём загрузку: иначе первая же запись перетёрла бы прочитанный журнал.
  Future<void> add(ListenEvent event) async {
    final Future<void>? ready = _ready;
    if (ready != null) await ready;
    if (!ref.mounted) return;
    final List<ListenEvent> next = <ListenEvent>[...state, event];
    state = List<ListenEvent>.unmodifiable(next);
    await ref.read(listeningStatsStoreProvider).writeAll(next);
  }

  /// Стирает журнал целиком — и в памяти, и на диске.
  Future<void> clear() async {
    final Future<void>? ready = _ready;
    if (ready != null) await ready;
    if (!ref.mounted) return;
    state = const <ListenEvent>[];
    await ref.read(listeningStatsStoreProvider).clear();
  }
}

final NotifierProvider<ListeningStats, List<ListenEvent>>
    listeningStatsProvider =
    NotifierProvider<ListeningStats, List<ListenEvent>>(ListeningStats.new);

/// ---------------------------------------------------------------------------
/// Загрузки для офлайн-прослушивания (задача 2.1)
/// ---------------------------------------------------------------------------

/// Каталог загрузок и метаданные — одно хранилище на приложение.
final Provider<DownloadsStore> downloadsStoreProvider =
    Provider<DownloadsStore>((Ref ref) => DownloadsStore());

/// Загрузчик диапазонов для скачивания треков.
///
/// Отдельный от кэша потоков: у кэша свои правила (временный каталог, лимит
/// размера), а загрузка — постоянная и управляется пользователем.
final Provider<RangeDownloader> rangeDownloaderProvider =
    Provider<RangeDownloader>((Ref ref) {
  final RangeDownloader downloader = RangeDownloader();
  ref.onDispose(downloader.dispose);
  return downloader;
});

/// Идущая загрузка: что качается, сколько уже получено и чем кончилось.
@immutable
class DownloadTask {
  const DownloadTask({
    required this.track,
    this.progress = 0,
    this.received = 0,
    this.total,
    this.error,
  });

  final Track track;
  final double progress;
  final int received;
  final int? total;

  /// Текст ошибки; `null` — загрузка идёт или завершилась успешно.
  final String? error;

  bool get failed => error != null;
}

/// Состояние экрана «Загрузки» и пунктов меню трека.
@immutable
class DownloadsState {
  const DownloadsState({
    this.loaded = false,
    this.items = const <DownloadedTrack>[],
    this.active = const <String, DownloadTask>{},
  });

  /// Список прочитан с диска; до этого показывать «пусто» нельзя.
  final bool loaded;

  /// Завершённые загрузки, новые сверху.
  final List<DownloadedTrack> items;

  /// Загрузки в работе и неудавшиеся — по id трека.
  final Map<String, DownloadTask> active;

  bool isDownloaded(String id) =>
      items.any((DownloadedTrack item) => item.id == id);

  DownloadTask? taskFor(String id) => active[id];

  int get totalBytes => items.fold<int>(
        0,
        (int sum, DownloadedTrack item) => sum + item.bytes,
      );

  /// Сколько загрузок идёт прямо сейчас (без учёта ошибок).
  int get workingCount =>
      active.values.where((DownloadTask task) => !task.failed).length;

  DownloadsState copyWith({
    bool? loaded,
    List<DownloadedTrack>? items,
    Map<String, DownloadTask>? active,
  }) =>
      DownloadsState(
        loaded: loaded ?? this.loaded,
        items: items ?? this.items,
        active: active ?? this.active,
      );
}

/// Скачивание треков и управление ими.
///
/// Загрузки идут строго по одной: они проходят через тот же резолвер, что и
/// воспроизведение, и пачка параллельных запросов только мешала бы музыке.
/// Ограничение живёт здесь, а не в вызывающих: меню трека и экран «Загрузки»
/// зовут [download] независимо друг от друга.
///
/// Докачка продолжается с места обрыва — остаток лежит в `<id>.m4a.part`,
/// а ожидаемый размер хранится в метаданных.
class DownloadsController extends Notifier<DownloadsState> {
  Future<void>? _ready;

  /// Хвост очереди: каждый вызов [download] дожидается предыдущего.
  Future<void> _queue = Future<void>.value();

  /// Отмена текущей попытки по id трека.
  final Map<String, DownloadCancelToken> _cancel =
      <String, DownloadCancelToken>{};

  /// Выполняющиеся загрузки — чтобы [remove] дождался закрытия файла.
  final Map<String, Future<String?>> _running = <String, Future<String?>>{};

  /// Поставленные в очередь, но ещё не начатые треки.
  final Set<String> _queued = <String>{};

  /// Отменённые до старта: очередь должна молча пропустить их.
  final Set<String> _cancelled = <String>{};

  @override
  DownloadsState build() {
    _ready = _load();
    ref.onDispose(() {
      // Закрытие экрана не должно оставлять задачи «в работе» навсегда:
      // токены рвут начатые чтения, очередь пропускает неначатые.
      for (final DownloadCancelToken token in _cancel.values) {
        token.cancel();
      }
      _cancelled.addAll(_queued);
    });
    return const DownloadsState();
  }

  Future<void> _load() async {
    List<DownloadedTrack> items = const <DownloadedTrack>[];
    try {
      items = await ref.read(downloadsStoreProvider).readAll();
    } on Object catch (error) {
      debugPrint('[Downloads] не удалось прочитать список: $error');
    }
    if (!ref.mounted) return;
    state = state.copyWith(loaded: true, items: items);
  }

  /// Скачивает трек. Возвращает текст ошибки или `null`, если всё хорошо
  /// (в том числе когда трек уже скачан или загрузку отменили).
  ///
  /// Вызовы складываются в очередь: параллельный вызов не начнёт вторую
  /// загрузку, а дождётся своей очереди.
  Future<String?> download(Track track) async {
    await _ready;
    if (!ref.mounted) return null;
    if (state.isDownloaded(track.id)) return null;
    final DownloadTask? running = state.taskFor(track.id);
    if (running != null && !running.failed) return null;
    // Повторный вызов, пока трек уже ждёт в очереди, — не вторая загрузка.
    if (_queued.contains(track.id) || _running.containsKey(track.id)) {
      return null;
    }

    final Completer<String?> done = Completer<String?>();
    _queued.add(track.id);
    _queue = _queue.then((_) async {
      try {
        _queued.remove(track.id);
        if (_cancelled.remove(track.id)) {
          done.complete(null);
          return;
        }
        if (!ref.mounted || state.isDownloaded(track.id)) {
          done.complete(null);
          return;
        }
        final Future<String?> future = _downloadOne(track);
        _running[track.id] = future;
        try {
          done.complete(await future);
        } finally {
          _running.remove(track.id);
        }
      } on Object catch (error) {
        if (!done.isCompleted) {
          done.complete('Не удалось скачать трек: $error');
        }
      }
    });
    return done.future;
  }

  /// Одна загрузка: здесь создаётся токен отмены.
  Future<String?> _downloadOne(Track track) async {
    if (_cancelled.remove(track.id)) {
      _dropTask(track.id);
      return null;
    }
    final DownloadCancelToken token = DownloadCancelToken();
    _cancel[track.id] = token;
    try {
      return await _downloadTrack(track, token);
    } on DownloadCancelledException {
      // Отмена — не ошибка: пользователь сам этого хотел.
      _dropTask(track.id);
      return null;
    } finally {
      _cancel.remove(track.id);
      _cancelled.remove(track.id);
    }
  }

  Future<String?> _downloadTrack(
    Track track,
    DownloadCancelToken token,
  ) async {
    final DownloadsStore store = ref.read(downloadsStoreProvider);
    File? part;
    int? expected;
    // Сколько байт уже лежит в недокачанном файле — показываем сразу, чтобы
    // докачка не начиналась с нуля и на экране.
    int received = 0;
    _setTask(DownloadTask(track: track));

    try {
      final ResolvedStream stream =
          await ref.read(streamResolverProvider).resolve(
                track.id,
                quality: ref.read(settingsControllerProvider).audioQuality,
                // Файл называется `<videoId>.m4a` — просим m4a, чтобы имя не
                // расходилось с содержимым. Если такого потока нет, резолвер
                // отдаст любой: плеер играет по содержимому.
                preferContainer: DownloadsStore.audioExtension,
              );
      token.throwIfCancelled();

      // Прямой эфир не заканчивается — «скачать» его нельзя, и притворяться,
      // что файл полный, было бы обманом.
      if (stream.isLive) {
        throw DownloadsException(
          'Прямые трансляции не скачиваются: у них нет конца файла.',
        );
      }
      // Резолвер нашёл локальный файл — значит, трек уже скачан, и качать
      // заново нечего.
      if (stream.isLocal) {
        _dropTask(track.id);
        return null;
      }

      part = await store.partialFile(track.id);
      expected = await store.partialExpected(track.id);
      final int already = part.existsSync() ? await part.length() : 0;
      received = already;
      if (already > 0) {
        _setTask(DownloadTask(
          track: track,
          progress: expected == null || expected <= 0
              ? 0
              : (already / expected).clamp(0.0, 1.0),
          received: already,
          total: expected,
        ));
      }

      // Раньше файл с `already >= expected` считался готовым без сервера — так
      // и появлялись обрезанные и склеенные файлы. Теперь решение принимает
      // загрузчик: он сверяет `Content-Range` с сохранённым размером и при
      // расхождении начинает файл заново.
      int? serverTotal;
      final DownloadResult result =
          await ref.read(rangeDownloaderProvider).download(
                stream.url,
                part,
                resume: true,
                expectedBytes: expected,
                cancel: token,
                onBytes: (int got, int? total) {
                  received = got;
                  if (total != null && total != serverTotal) {
                    serverTotal = total;
                    // Запоминаем размер, чтобы после перезапуска не начинать
                    // с нуля и не считать оборванный файл целым.
                    unawaited(store.markPartial(track.id, total));
                  }
                  _progress(track, got, total);
                },
              );
      token.throwIfCancelled();

      // «Поток получен» — это не только код ответа: сверяем размер, который
      // назвал сервер, с тем, что лежит на диске, и смотрим сигнатуру
      // контейнера. Сохранённому expected здесь верить нельзя.
      final String? problem = await verifyDownloadedAudio(
        part,
        expectedBytes: serverTotal ?? result.total,
      );
      if (problem != null) {
        await store.discardPartial(track.id);
        throw DownloadsException(problem);
      }
      token.throwIfCancelled();

      final DownloadedTrack item = await store.complete(
        track: track,
        bytes: result.bytes,
        container: stream.container,
      );
      _finish(item);
      return null;
    } on DownloadsException catch (error) {
      _fail(track, error.message);
      return error.message;
    } on StreamDownloadException catch (error) {
      _fail(track, error.message);
      return error.message;
    } on StreamResolutionException catch (error) {
      _fail(track, error.message);
      return error.message;
    } on DownloadCancelledException {
      rethrow;
    } on FileSystemException catch (error) {
      final String message = _describeFileError(error, received);
      _fail(track, message);
      return message;
    } on Object catch (error) {
      final String message = 'Не удалось скачать трек: $error';
      _fail(track, message);
      return message;
    }
  }

  /// Скачивает пачку треков по очереди.
  ///
  /// Ошибка одного не останавливает остальные: пользователь должен получить
  /// всё, что отдаётся, а не первое же «не получилось».
  Future<({int done, int failed})> downloadMany(
    Iterable<Track> tracks,
  ) async {
    int done = 0;
    int failed = 0;
    final Set<String> seen = <String>{};
    for (final Track track in tracks) {
      if (!seen.add(track.id)) continue;
      if (state.isDownloaded(track.id)) continue;
      final String? error = await download(track);
      if (error == null && state.isDownloaded(track.id)) {
        done++;
      } else if (error != null) {
        failed++;
      }
    }
    return (done: done, failed: failed);
  }

  /// Удаляет загрузку. Возвращает текст ошибки или `null`.
  Future<String?> remove(String videoId) async {
    await _ready;
    if (!ref.mounted) return null;
    // Сначала останавливаем загрузку и ждём, пока она закроет файл: на Windows
    // удаление открытого файла падает, а задача осталась бы «в работе».
    cancel(videoId);
    final Future<String?>? running = _running[videoId];
    if (running != null) {
      try {
        await running;
      } on Object {
        // Ошибку загрузки уже показали; для удаления она не важна.
      }
    }
    if (!ref.mounted) return null;
    try {
      await ref.read(downloadsStoreProvider).remove(videoId);
      if (!ref.mounted) return null;
      state = state.copyWith(
        items: state.items
            .where((DownloadedTrack item) => item.id != videoId)
            .toList(growable: false),
        active: <String, DownloadTask>{...state.active}..remove(videoId),
      );
      return null;
    } on DownloadsException catch (error) {
      return error.message;
    } on Object catch (error) {
      debugPrint('[Downloads] не удалось удалить $videoId: $error');
      return 'Не удалось удалить загрузку: $error';
    }
  }

  /// Удаляет все загрузки; возвращает число неудачных удалений.
  Future<int> removeAll() async {
    int failed = 0;
    for (final DownloadedTrack item in List<DownloadedTrack>.of(state.items)) {
      if (await remove(item.id) != null) failed++;
    }
    return failed;
  }

  /// Убирает из списка сообщение о неудачной загрузке.
  void dismiss(String videoId) {
    final DownloadTask? task = state.active[videoId];
    if (task == null || !task.failed) return;
    state = state.copyWith(
      active: <String, DownloadTask>{...state.active}..remove(videoId),
    );
  }

  /// Отменяет загрузку трека: и начатую, и ещё стоящую в очереди.
  ///
  /// Начатая завершится молча (без ошибки), неначатая будет пропущена
  /// очередью — задача не остаётся «в работе» навсегда.
  void cancel(String videoId) {
    if (videoId.isEmpty) return;
    final bool queued = _queued.contains(videoId);
    final DownloadTask? task = state.active[videoId];
    final bool working = _running.containsKey(videoId) ||
        _cancel.containsKey(videoId) ||
        (task != null && !task.failed);
    if (!queued && !working) return;
    _cancelled.add(videoId);
    _cancel[videoId]?.cancel();
  }

  /// Отменяет всё, что качается или ждёт очереди.
  void cancelAll() {
    final Set<String> ids = <String>{
      ..._queued,
      ..._cancel.keys,
      ..._running.keys,
      for (final MapEntry<String, DownloadTask> entry in state.active.entries)
        if (!entry.value.failed) entry.key,
    };
    for (final String id in ids) {
      cancel(id);
    }
  }

  void _setTask(DownloadTask task) {
    if (!ref.mounted) return;
    state = state.copyWith(
      active: <String, DownloadTask>{...state.active, task.track.id: task},
    );
  }

  void _dropTask(String videoId) {
    if (!ref.mounted) return;
    state = state.copyWith(
      active: <String, DownloadTask>{...state.active}..remove(videoId),
    );
  }

  void _progress(Track track, int received, int? total) {
    _setTask(DownloadTask(
      track: track,
      progress: total == null || total <= 0
          ? 0
          : (received / total).clamp(0.0, 1.0),
      received: received,
      total: total,
    ));
  }

  void _fail(Track track, String message) {
    debugPrint('[Downloads] ${track.id}: $message');
    _setTask(DownloadTask(track: track, error: message));
  }

  void _finish(DownloadedTrack item) {
    if (!ref.mounted) return;
    state = state.copyWith(
      items: <DownloadedTrack>[
        item,
        for (final DownloadedTrack existing in state.items)
          if (existing.id != item.id) existing,
      ],
      active: <String, DownloadTask>{...state.active}..remove(item.id),
    );
  }

  /// Понятная причина, по которой файл не записался.
  String _describeFileError(FileSystemException error, int received) {
    final int? code = error.osError?.errorCode;
    final String text =
        '${error.osError?.message ?? ''} ${error.message}'.toLowerCase();
    if (code == 112 ||
        text.contains('not enough space') ||
        text.contains('нет места') ||
        text.contains('disk full')) {
      return 'На диске не хватило места. Освободите немного места и '
          'повторите — докачка продолжится с этого места.';
    }
    return 'Не удалось записать файл (получено $received байт): '
        '${error.osError?.message ?? error.message}.';
  }
}

final NotifierProvider<DownloadsController, DownloadsState>
    downloadsControllerProvider =
    NotifierProvider<DownloadsController, DownloadsState>(
  DownloadsController.new,
);

// ---------------------------------------------------------------------------
// Локальная музыка (задача 8.3)
// ---------------------------------------------------------------------------

/// Состояние раздела «Локальные файлы».
@immutable
class LocalMediaState {
  const LocalMediaState({
    this.folder = '',
    this.scanning = false,
    this.files = const <LocalMediaFile>[],
    this.error,
  });

  /// Папка, выбранная в настройках.
  final String folder;

  /// Сканирование идёт прямо сейчас.
  final bool scanning;

  /// Найденные файлы — в порядке путей.
  final List<LocalMediaFile> files;

  /// Текст ошибки чтения папки.
  final String? error;

  bool get hasFolder => folder.trim().isNotEmpty;
  bool get hasFiles => files.isNotEmpty;

  LocalMediaState copyWith({
    String? folder,
    bool? scanning,
    List<LocalMediaFile>? files,
    String? error,
    bool clearError = false,
  }) =>
      LocalMediaState(
        folder: folder ?? this.folder,
        scanning: scanning ?? this.scanning,
        files: files ?? this.files,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Сканирует выбранную папку и отдаёт список локальных файлов.
///
/// Провайдер создаётся лениво — когда раздел открыли или нажали
/// «Пересканировать». Сканирование на старте приложения было бы лишней
/// работой для тех, кто локальными файлами не пользуется.
class LocalMediaController extends Notifier<LocalMediaState> {
  final LocalMediaScanner _scanner = const LocalMediaScanner();

  /// Номер текущего сканирования: результат устаревшего запуска (папку
  /// успели сменить) отбрасывается.
  int _generation = 0;

  @override
  LocalMediaState build() {
    final String folder = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.localMediaFolder),
    );
    // Смена или очистка папки отменяет результат прошлого сканирования:
    // иначе оно могло бы записать файлы уже невыбранной папки.
    _generation++;
    final LocalMediaState initial = LocalMediaState(folder: folder);
    if (folder.trim().isNotEmpty) {
      // Сканирование не может начаться внутри build: state ещё не готов.
      Future<void>.microtask(() => _scan(folder));
    }
    return initial;
  }

  /// Перечитывает папку заново.
  Future<int> rescan() async {
    final String folder = state.folder.trim();
    if (folder.isEmpty) return 0;
    await _scan(folder);
    return state.files.length;
  }

  Future<void> _scan(String folder) async {
    final int generation = ++_generation;
    if (!ref.mounted) return;
    state = state.copyWith(scanning: true, clearError: true, folder: folder);
    try {
      final List<LocalMediaFile> files = await _scanner.scan(
        folder,
        cancelled: () => generation != _generation,
      );
      if (!ref.mounted || generation != _generation) return;
      state = state.copyWith(scanning: false, files: files);
    } on LocalMediaException catch (error) {
      if (!ref.mounted || generation != _generation) return;
      state = state.copyWith(
        scanning: false,
        files: const <LocalMediaFile>[],
        error: error.message,
      );
    } on Object catch (error) {
      if (!ref.mounted || generation != _generation) return;
      state = state.copyWith(
        scanning: false,
        files: const <LocalMediaFile>[],
        error: 'Не удалось прочитать папку: $error',
      );
    }
  }
}

final NotifierProvider<LocalMediaController, LocalMediaState>
    localMediaControllerProvider =
    NotifierProvider<LocalMediaController, LocalMediaState>(
  LocalMediaController.new,
);
