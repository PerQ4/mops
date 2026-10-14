import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/audio/audio_engine.dart';
import '../core/audio/audioplayers_engine.dart';
import '../core/auth/token_store.dart';
import '../core/innertube/innertube_client.dart';
import '../core/net/anti_dpi.dart';
import '../core/theme/seed_colors.dart';
import '../core/theme/ui_scaler.dart';
import '../data/local/app_settings.dart';
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
  AppSettings build() => ref.watch(initialSettingsProvider);

  Future<void> _persist(AppSettings next) async {
    state = next;
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

  Future<void> setSidebarWidth(double width) =>
      update((AppSettings s) => s.copyWith(sidebarWidth: width));

  Future<void> setPlayerPanelWidth(double width) =>
      update((AppSettings s) => s.copyWith(playerPanelWidth: width));

  Future<void> setPaletteStyle(PaletteStylePreference style) =>
      update((AppSettings s) => s.copyWith(paletteStyle: style));

  Future<void> setPureBlack(bool value) =>
      update((AppSettings s) => s.copyWith(pureBlack: value));

  Future<void> setAudioQuality(AudioQuality quality) =>
      update((AppSettings s) => s.copyWith(audioQuality: quality));

  Future<void> setStreamClient(StreamSource client) =>
      update((AppSettings s) => s.copyWith(streamClient: client));

  Future<void> setShowLyrics(bool value) =>
      update((AppSettings s) => s.copyWith(showLyricsInPlayer: value));

  /// Включает или выключает разворот плеера в правую панель.
  Future<void> setPlayerPanelEnabled(bool value) =>
      update((AppSettings s) => s.copyWith(playerPanelEnabled: value));

  Future<void> setAutoPlayNext(bool value) =>
      update((AppSettings s) => s.copyWith(autoPlayNext: value));

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

/// Аудиодвижок. Один на всё приложение.
final Provider<AudioEngine> audioEngineProvider = Provider<AudioEngine>(
  (ref) {
    final AudioEngine engine = AudioplayersEngine();
    ref.onDispose(engine.dispose);
    return engine;
  },
);
