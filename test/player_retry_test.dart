// Повторы открытия потока при плавающих отказах googlevideo.
//
// Сеть не нужна: резолвер и движок подменены. Проверяется главное поведение —
// сбой транспорта повторяется со свежей ссылкой, а явная недоступность,
// третий отказ и повторное засчитывание прослушивания остаются под контролем.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mops/core/audio/audio_engine.dart';
import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/data/local/app_settings.dart';
import 'package:mops/data/local/downloads.dart';
import 'package:mops/data/local/listening_stats.dart';
import 'package:mops/data/models/models.dart';
import 'package:mops/data/sources/stream_resolver.dart';
import 'package:mops/state/player_controller.dart';
import 'package:mops/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Заглушка аудиодвижка: платформенные каналы в тестах недоступны.
class _FakeEngine implements AudioEngine {
  final StreamController<PlaybackState> _states =
      StreamController<PlaybackState>.broadcast();
  final ValueNotifier<String?> _effectIssue = ValueNotifier<String?>(null);

  PlaybackState _state = PlaybackState.initial;

  /// Источники в порядке открытия — по ним видно число попыток.
  final List<String> loaded = <String>[];

  /// Что движок делает после открытия: номер попытки, начиная с единицы.
  void Function(int attempt)? onLoad;

  @override
  Stream<PlaybackState> get stateStream => _states.stream;

  @override
  PlaybackState get state => _state;

  /// Отправляет состояние подписчикам (тика позиции или ошибку).
  void emit(PlaybackState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  @override
  Future<void> load(
    String source, {
    bool autoplay = true,
    bool isLocal = false,
  }) async {
    loaded.add(source);
    _state = PlaybackState(status: PlaybackStatus.loading);
    onLoad?.call(loaded.length);
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {
    _state = PlaybackState.initial;
  }

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  bool get supportsPitch => false;

  @override
  Future<void> setPitch(double pitch) async {}

  @override
  List<AudioOutputDevice> get audioDevices => const <AudioOutputDevice>[];

  @override
  Stream<List<AudioOutputDevice>> get audioDevicesStream =>
      const Stream<List<AudioOutputDevice>>.empty();

  @override
  Future<void> setAudioDevice(String name) async {}

  @override
  Future<void> setEqualizer(List<double> bands) async {}

  @override
  Future<void> setSkipSilence(bool enabled) async {}

  @override
  Future<void> setAudioNormalization(bool enabled) async {}

  @override
  ValueListenable<String?> get audioEffectIssue => _effectIssue;

  @override
  Future<void> dispose() async {
    _effectIssue.dispose();
    await _states.close();
  }
}

/// Резолвер, который отдаёт заранее заданные ошибки, а потом ссылку.
class _FakeResolver implements StreamResolver, StreamCacheInvalidator {
  _FakeResolver([this.failures = const <Object>[]]);

  /// Ошибки по порядку: каждая следующая попытка забирает одну.
  final List<Object> failures;

  int resolveCalls = 0;

  /// Для каких видео ссылку забывали — по этому видно сброс кэша.
  final List<String> forgotten = <String>[];

  @override
  bool get isAvailable => true;

  @override
  Future<ResolvedStream> resolve(
    String videoId, {
    required AudioQuality quality,
    String? preferContainer,
  }) async {
    resolveCalls++;
    if (resolveCalls <= failures.length) throw failures[resolveCalls - 1];
    return ResolvedStream(
      url: Uri.parse('https://media.test/$videoId-$resolveCalls'),
      bitrateKbps: 128,
      container: 'm4a',
      mimeType: 'audio/mp4',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }

  @override
  void forget(String videoId) => forgotten.add(videoId);

  @override
  void dispose() {}
}

/// Журнал прослушиваний без диска.
class _MemoryListeningStore extends ListeningStatsStore {
  final List<ListenEvent> events = <ListenEvent>[];

  @override
  Future<List<ListenEvent>> readAll() async =>
      List<ListenEvent>.unmodifiable(events);

  @override
  Future<void> writeAll(List<ListenEvent> next) async {
    events
      ..clear()
      ..addAll(next);
  }

  @override
  Future<void> clear() async => events.clear();
}

const Track _kTrack = Track(
  id: '0s-yNUdAC8A',
  title: 'Нестабильный трек',
  duration: Duration(seconds: 10),
);

/// Ошибка сети: повтор уместен, «недоступен» ставить нельзя.
StreamResolutionException _networkFailure() => StreamResolutionException(
      'Не удалось получить поток: сети нет или соединение с YouTube '
      'блокируется.',
    );

/// Явный отказ площадки: повторов быть не должно.
StreamResolutionException _unavailableFailure() => StreamResolutionException(
      'Сервер не отдаёт этот трек (503) — возможно, он недоступен в регионе '
      'или удалён.',
      unavailable: true,
    );

Future<ProviderContainer> _container({
  required _FakeEngine engine,
  required _FakeResolver resolver,
  required _MemoryListeningStore store,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final Directory downloadsDir =
      Directory.systemTemp.createTempSync('mops-retry-downloads-');
  addTearDown(() {
    if (downloadsDir.existsSync()) downloadsDir.deleteSync(recursive: true);
  });

  final ProviderContainer container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      // Предзагрузка выключена: тест проверяет только текущий трек.
      initialSettingsProvider.overrideWithValue(
        const AppSettings(
          playback: PlaybackSettings(preloadNextTrack: false),
        ),
      ),
      initialSessionProvider.overrideWithValue(null),
      audioEngineProvider.overrideWithValue(engine),
      streamResolverProvider.overrideWithValue(resolver),
      listeningStatsStoreProvider.overrideWithValue(store),
      downloadsStoreProvider
          .overrideWithValue(DownloadsStore(directory: downloadsDir)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('сбой сети: повтор со свежей ссылкой, трек играет, зачёт один',
      () async {
    final _FakeEngine engine = _FakeEngine();
    final _FakeResolver resolver =
        _FakeResolver(<Object>[_networkFailure()]);
    final _MemoryListeningStore store = _MemoryListeningStore();
    final ProviderContainer container = await _container(
      engine: engine,
      resolver: resolver,
      store: store,
    );

    await container
        .read(playerControllerProvider.notifier)
        .playTrack(_kTrack);

    PlayerUiState player = container.read(playerControllerProvider);
    expect(resolver.resolveCalls, 2, reason: 'первая ошибка и повтор');
    expect(resolver.forgotten, <String>[_kTrack.id],
        reason: 'кэш ссылки сброшен перед повтором');
    expect(engine.loaded, hasLength(1), reason: 'плеер открыл только рабочую');
    expect(player.error, isNull);
    expect(player.resolving, isFalse);
    expect(player.unavailableIds, isEmpty);
    expect(player.queue, hasLength(1), reason: 'повтор не дублирует очередь');
    expect(player.index, 0);

    // Играем до порога засчитывания (половина десятисекундного трека).
    engine.emit(const PlaybackState(
      status: PlaybackStatus.playing,
      position: Duration(seconds: 1),
      duration: Duration(seconds: 10),
    ));
    for (int second = 2; second <= 8; second++) {
      engine.emit(PlaybackState(
        status: PlaybackStatus.playing,
        position: Duration(seconds: second),
        duration: const Duration(seconds: 10),
      ));
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));

    player = container.read(playerControllerProvider);
    expect(player.queue, hasLength(1));
    expect(container.read(listeningStatsProvider), hasLength(1),
        reason: 'повтор — то же проигрывание, а не второе');
  });

  test('три неудачи: ошибка, дальше повторов нет', () async {
    final _FakeEngine engine = _FakeEngine();
    final _FakeResolver resolver = _FakeResolver(<Object>[
      _networkFailure(),
      _networkFailure(),
      _networkFailure(),
    ]);
    final ProviderContainer container = await _container(
      engine: engine,
      resolver: resolver,
      store: _MemoryListeningStore(),
    );

    await container
        .read(playerControllerProvider.notifier)
        .playTrack(_kTrack);

    PlayerUiState player = container.read(playerControllerProvider);
    expect(resolver.resolveCalls, 3, reason: 'всего три попытки');
    expect(resolver.forgotten, hasLength(2), reason: 'два повтора');
    expect(engine.loaded, isEmpty, reason: 'ссылка так и не дошла до плеера');
    expect(player.error, isNotNull);
    expect(player.resolving, isFalse);

    // Никаких фоновых серий после третьей неудачи.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(resolver.resolveCalls, 3);
    expect(container.read(playerControllerProvider).error, player.error);
  });

  test('недоступность не повторяется', () async {
    final _FakeEngine engine = _FakeEngine();
    final _FakeResolver resolver =
        _FakeResolver(<Object>[_unavailableFailure()]);
    final ProviderContainer container = await _container(
      engine: engine,
      resolver: resolver,
      store: _MemoryListeningStore(),
    );

    await container
        .read(playerControllerProvider.notifier)
        .playTrack(_kTrack);

    final PlayerUiState player = container.read(playerControllerProvider);
    expect(resolver.resolveCalls, 1, reason: 'явный отказ не повторяем');
    expect(resolver.forgotten, isEmpty);
    expect(player.error, contains('недоступен'));
    expect(player.unavailableIds, contains(_kTrack.id));
  });

  test('mpv: 5xx при открытии повторяется, со второй попытки играет',
      () async {
    final _FakeEngine engine = _FakeEngine();
    final _FakeResolver resolver = _FakeResolver();
    final _MemoryListeningStore store = _MemoryListeningStore();
    final ProviderContainer container = await _container(
      engine: engine,
      resolver: resolver,
      store: store,
    );

    engine.onLoad = (int attempt) {
      if (attempt != 1) return;
      // mpv сообщает об отказе уже после открытия — так же приходит и живой
      // 503 от googlevideo.
      scheduleMicrotask(() {
        engine.emit(const PlaybackState(
          status: PlaybackStatus.error,
          error: 'Failed to open https://media.test/x (HTTP 503)',
        ));
      });
    };

    await container
        .read(playerControllerProvider.notifier)
        .playTrack(_kTrack);
    await Future<void>.delayed(const Duration(milliseconds: 700));

    PlayerUiState player = container.read(playerControllerProvider);
    expect(engine.loaded, hasLength(2), reason: 'сбой открытия повторён');
    expect(resolver.forgotten, <String>[_kTrack.id]);
    expect(player.error, isNull, reason: 'ошибка не показана пользователю');
    expect(player.resolving, isFalse);
    expect(player.unavailableIds, isEmpty);

    // Повтор не должен превратиться во второе проигрывание в журнале.
    engine.emit(const PlaybackState(
      status: PlaybackStatus.playing,
      position: Duration(seconds: 1),
      duration: Duration(seconds: 10),
    ));
    for (int second = 2; second <= 8; second++) {
      engine.emit(PlaybackState(
        status: PlaybackStatus.playing,
        position: Duration(seconds: second),
        duration: const Duration(seconds: 10),
      ));
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));

    player = container.read(playerControllerProvider);
    expect(player.queue, hasLength(1));
    expect(store.events, hasLength(1));
    expect(container.read(listeningStatsProvider), hasLength(1));
  });

  // Отдельная группа: проверка настоящего кэша резолвера.
  _cacheTests();
}

/// ------------------------------------------------- кэш резолвера

/// Медиасервер, который отдаёт по байту на короткий диапазон.
class _FakeMediaServer {
  _FakeMediaServer._(this._server);

  final HttpServer _server;
  final List<String> requested = <String>[];

  static Future<_FakeMediaServer> start() async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final _FakeMediaServer fake = _FakeMediaServer._(server);
    server.listen((HttpRequest request) async {
      fake.requested.add(request.uri.path);
      final HttpResponse response = request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.contentLength = 1
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/1024')
        ..add(<int>[0]);
      await response.close();
    });
    return fake;
  }

  Uri url(String path) => Uri.parse('http://127.0.0.1:${_server.port}$path');

  Future<void> close() => _server.close(force: true);
}

class _EmptyInnerTube extends InnerTubeClient {
  @override
  Future<Map<String, dynamic>> post(
    String endpoint, {
    Map<String, dynamic> body = const <String, dynamic>{},
    Map<String, String> query = const <String, String>{},
    bool authenticated = false,
    Map<String, String> extraHeaders = const <String, String>{},
  }) async =>
      <String, dynamic>{
        'playabilityStatus': <String, dynamic>{'status': 'OK'},
      };
}

void _cacheTests() {
  late _FakeMediaServer server;
  HttpOverrides? testOverrides;

  setUp(() async {
    // Тестовая привязка Flutter подменяет HttpClient ответом 400 на всё;
    // этому тесту нужен настоящий локальный сервер, поэтому подмену снимаем.
    testOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    server = await _FakeMediaServer.start();
  });

  tearDown(() async {
    await server.close();
    HttpOverrides.global = testOverrides;
  });

  test('forget снимает ссылку конкретного видео, другие остаются', () async {
    final YoutubeStreamResolver resolver = YoutubeStreamResolver(
      innerTube: _EmptyInnerTube(),
      locale: 'ru',
      region: 'RU',
      clientChoice: StreamSource.visionOs,
      fallbackLinks: (String videoId) async => <ResolvedStream>[
        ResolvedStream(
          url: server.url('/$videoId'),
          bitrateKbps: 128,
          container: 'm4a',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        ),
      ],
    );
    addTearDown(resolver.dispose);

    await resolver.resolve('one', quality: AudioQuality.high);
    await resolver.resolve('two', quality: AudioQuality.high);
    // Обе ссылки уже в кэше: повторный запрос не ходит на сервер.
    await resolver.resolve('one', quality: AudioQuality.high);
    expect(server.requested, <String>['/one', '/two']);

    resolver.forget('one');
    await resolver.resolve('one', quality: AudioQuality.high);
    await resolver.resolve('two', quality: AudioQuality.high);
    expect(
      server.requested,
      <String>['/one', '/two', '/one'],
      reason: 'забытая ссылка запрошена заново, чужая осталась в кэше',
    );
  });
}
