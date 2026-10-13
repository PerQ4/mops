import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/audio/audio_engine.dart';
import '../core/audio/audioplayers_engine.dart';
import '../core/auth/token_store.dart';
import '../core/innertube/innertube_client.dart';
import '../data/local/app_settings.dart';
import '../data/sources/stream_resolver.dart';

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
  (Ref ref) => throw UnimplementedError(
    'sharedPreferencesProvider должен быть переопределён в main()',
  ),
);

/// Настройки, прочитанные из хранилища до первого кадра.
final Provider<AppSettings> initialSettingsProvider = Provider<AppSettings>(
  (Ref ref) => const AppSettings(),
);

/// Сохранённая сессия, прочитанная до первого кадра.
final Provider<AuthSession?> initialSessionProvider = Provider<AuthSession?>(
  (Ref ref) => null,
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

  Future<void> setAudioQuality(AudioQuality quality) =>
      update((AppSettings s) => s.copyWith(audioQuality: quality));

  Future<void> setPlayerLayout(PlayerLayout layout) =>
      update((AppSettings s) => s.copyWith(playerLayout: layout));

  Future<void> setShowLyrics(bool value) =>
      update((AppSettings s) => s.copyWith(showLyricsInPlayer: value));

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
}

final NotifierProvider<SettingsController, AppSettings> settingsControllerProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

/// ---------------------------------------------------------------------------
/// Сеть и аудио
/// ---------------------------------------------------------------------------

final Provider<TokenStore> tokenStoreProvider = Provider<TokenStore>(
  (Ref ref) => TokenStore(),
);

/// Клиент InnerTube (внутренний API YouTube Music).
///
/// Пересоздаётся только при смене региона/языка: `select` не даёт реагировать
/// на изменения остальных настроек.
final Provider<InnerTubeClient> innerTubeProvider = Provider<InnerTubeClient>(
  (Ref ref) {
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
final Provider<StreamResolver> streamResolverProvider =
    Provider<StreamResolver>((Ref ref) {
  final StreamResolver resolver = YoutubeExplodeResolver();
  ref.onDispose(resolver.dispose);
  return resolver;
});

/// Аудиодвижок. Один на всё приложение.
final Provider<AudioEngine> audioEngineProvider = Provider<AudioEngine>(
  (Ref ref) {
    final AudioEngine engine = AudioplayersEngine();
    ref.onDispose(engine.dispose);
    return engine;
  },
);
