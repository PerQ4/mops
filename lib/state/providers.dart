import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
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
import '../data/sources/catalog_source.dart';
import '../data/sources/paxsenix_source.dart';
import '../data/sources/romanization.dart';
import '../data/sources/stream_downloader.dart';
import '../data/sources/stream_proxy.dart';
import '../data/sources/stream_resolver.dart';
import 'auth_controller.dart';

/// ---------------------------------------------------------------------------
/// Базовая инициализация.
///
/// Асинхронную работу (чтение настроек и сессии) выполняет `main()` до
/// `runApp`, а готовые значения передаются через `overrides`. Благодаря этому
/// тема и плеер доступны синхронно с первого кадра — без «мигания» интерфейса.
/// ---------------------------------------------------------------------------

/// Ключ, под которым настройки лежат в `shared_preferences`.
const String kSettingsKey = 'mops.settings.v1';

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
  @override
  AppSettings build() {
    final AppSettings settings = ref.watch(initialSettingsProvider);
    _publishContentFilter(settings);
    _publishLowDataMode(settings);
    _publishMotion(settings);
    _publishFont(settings);
    return settings;
  }

  Future<void> _persist(AppSettings next) async {
    state = next;
    _publishContentFilter(next);
    _publishLowDataMode(next);
    _publishMotion(next);
    _publishFont(next);
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
