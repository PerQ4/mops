// Проверка интерфейса без сети: подставляем фейковые данные и отрисовываем
// ключевые экраны. Тест ловит ошибки раскладки (overflow, «дёрганье»
// размеров) и сохраняет эталонные изображения.
//
// Запуск: flutter test --update-goldens test/ui_smoke_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mops/app.dart';
import 'package:mops/core/audio/audio_engine.dart';
import 'package:mops/core/theme/seed_colors.dart';
import 'package:mops/core/theme/ui_scaler.dart';
import 'package:mops/data/local/app_settings.dart';
import 'package:mops/data/models/models.dart';
import 'package:mops/features/player/floating_dock.dart';
import 'package:mops/features/player/now_playing_screen.dart';
import 'package:mops/features/settings/settings_screen.dart';
import 'package:mops/features/shell/app_shell.dart';
import 'package:mops/state/catalog_providers.dart';
import 'package:mops/state/player_controller.dart';
import 'package:mops/state/providers.dart';
import 'package:mops/state/theme_providers.dart';

/// ---------------------------------------------------------------- подпорки

/// Заглушка аудиодвижка: платформенные каналы в тестах недоступны.
class _FakeAudioEngine implements AudioEngine {
  final StreamController<PlaybackState> _controller =
      StreamController<PlaybackState>.broadcast();
  final PlaybackState _state = PlaybackState.initial;

  @override
  Stream<PlaybackState> get stateStream => _controller.stream;

  @override
  PlaybackState get state => _state;

  @override
  Future<void> load(
    String source, {
    bool autoplay = true,
    bool isLocal = false,
  }) async {}

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}

/// Нотификатор плеера с заранее заданным состоянием.
class _StubPlayer extends PlayerController {
  _StubPlayer(this._preset);

  final PlayerUiState _preset;

  @override
  PlayerUiState build() => _preset;
}

/// ------------------------------------------------------------- фейковые данные

const List<String> _artistNames = <String>[
  'Tame Impala',
  'Radiohead',
  'Khruangbin',
  'Men I Trust',
  'Beach House',
];

List<Track> _fakeTracks(int count) {
  return List<Track>.generate(count, (int i) {
    return Track(
      id: 'vid${i.toString().padLeft(11, '0')}',
      title: <String>[
        'Let It Happen',
        'Everything In Its Right Place',
        'August 10',
        'Show Me How',
        'Space Song',
        'Borderline',
        'Weird Fishes',
        'Time (You and I)',
      ][i % 8],
      artists: <ArtistRef>[
        ArtistRef(name: _artistNames[i % _artistNames.length]),
      ],
      album: AlbumRef(name: 'Currents'),
      duration: Duration(minutes: 3, seconds: 20 + i * 7),
    );
  });
}

List<BrowseSection> _fakeHome() {
  final List<Track> tracks = _fakeTracks(8);

  return <BrowseSection>[
    BrowseSection(
      title: 'Слушать снова',
      items: tracks
          .take(5)
          .map((Track t) => TrackItem(t))
          .toList(growable: false),
    ),
    BrowseSection(
      title: 'Новые релизы',
      items: <BrowseItem>[
        for (int i = 0; i < 5; i++)
          AlbumItem(Album(
            id: 'MPREb_$i',
            title: 'Album $i',
            artists: <ArtistRef>[ArtistRef(name: _artistNames[i % 5])],
            year: '2026',
          )),
      ],
    ),
    BrowseSection(
      title: 'Исполнители, которые вам нравятся',
      items: <BrowseItem>[
        for (int i = 0; i < 5; i++)
          ArtistItem(Artist(id: 'UC$i', name: _artistNames[i % 5])),
      ],
    ),
    BrowseSection(
      title: 'Плейлисты для вас',
      items: <BrowseItem>[
        for (int i = 0; i < 5; i++)
          PlaylistItem(Playlist(
            id: 'PL$i',
            title: 'Подборка $i',
            author: 'YouTube Music',
          )),
      ],
    ),
  ];
}

/// ------------------------------------------------------------------ шрифты

/// В тестовой среде системных шрифтов нет — текст рисуется «квадратиками».
/// Подгружаем Roboto и MaterialIcons с диска, чтобы эталоны были читаемыми.
Future<void> _loadFonts() async {
  await _loadFamily('Roboto', <String>[
    '/usr/share/fonts/TTF/Roboto-Regular.ttf',
    '/usr/share/fonts/TTF/Roboto-Medium.ttf',
    '/usr/share/fonts/TTF/Roboto-Bold.ttf',
  ]);

  await _loadFamily('MaterialIcons', <String>[
    '${_flutterRoot()}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
}

String _flutterRoot() {
  final String fromEnv = Platform.environment['FLUTTER_ROOT'] ?? '';
  if (fromEnv.isNotEmpty && Directory(fromEnv).existsSync()) return fromEnv;

  final List<String> parts =
      Platform.resolvedExecutable.split(Platform.pathSeparator);
  final int cacheIndex = parts.lastIndexOf('cache');
  if (cacheIndex > 1) {
    return parts.sublist(0, cacheIndex - 1).join(Platform.pathSeparator);
  }
  return '/home/perqa/flutter';
}

Future<void> _loadFamily(String family, List<String> paths) async {
  final FontLoader loader = FontLoader(family);
  bool any = false;
  for (final String path in paths) {
    final File file = File(path);
    if (!file.existsSync()) continue;
    final Uint8List bytes = await file.readAsBytes();
    loader.addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)));
    any = true;
  }
  if (any) await loader.load();
}

void main() {
  setUpAll(() async {
    envReaderOverride = (String name) => null;
    await _loadFonts();
  });

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  const AppSettings settings = AppSettings(
    themeMode: ThemeModePreference.dark,
    colorSource: ColorSource.seed,
    seedColorIndex: 1,
    useMaterialExpressive: true,
  );

  /// Собирает приложение с подставными данными и указанным размером окна.
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    required Size size,
    PlayerUiState? player,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          initialSettingsProvider.overrideWithValue(settings),
          initialSessionProvider.overrideWithValue(null),
          desktopScaleProvider.overrideWithValue(DesktopScaleInfo.none),
          bypassAutoVerifyProvider.overrideWithValue(false),
          audioEngineProvider.overrideWithValue(_FakeAudioEngine()),
          homeSectionsProvider.overrideWith((ref) => _fakeHome()),
          exploreSectionsProvider.overrideWith((ref) => _fakeHome()),
          if (player != null)
            playerControllerProvider.overrideWith(() => _StubPlayer(player)),
        ],
        child: child,
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  PlayerUiState playingState() {
    final List<Track> tracks = _fakeTracks(6);
    return PlayerUiState(
      queue: tracks,
      index: 1,
      playback: const PlaybackState(
        status: PlaybackStatus.playing,
        position: Duration(minutes: 1, seconds: 24),
        duration: Duration(minutes: 4, seconds: 12),
        volume: 0.8,
      ),
      streamNote: 'WEBM 147',
    );
  }

  testWidgets('Главная, широкий экран: рейл и панель плеера', (WidgetTester tester) async {
    await pump(tester, const MopsApp(), size: const Size(1600, 1000));

    expect(tester.takeException(), isNull);
    // Заголовок — название приложения, а не «Главная»: раздел виден в рейле.
    expect(find.text('mOps'), findsWidgets);
    expect(find.byType(NavigationRail), findsOneWidget);
    // На широком экране нижней навигации нет — её заменяет боковая.
    expect(find.byType(NavigationBar), findsNothing);
    // Островок есть всегда, но без трека он ничего не показывает.
    expect(find.byType(FloatingDock), findsOneWidget);
    // Треки идут списком, а не каруселью.
    expect(find.text('Let It Happen'), findsWidgets);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/01_home_desktop.png'),
    );
  });

  testWidgets('Главная, узкий экран (телефон)', (WidgetTester tester) async {
    await pump(tester, const MopsApp(), size: const Size(412, 880));

    expect(tester.takeException(), isNull);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    // Островок парит над нижней навигацией.
    expect(find.byType(FloatingDock), findsOneWidget);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/02_home_mobile.png'),
    );
  });

  testWidgets('Островок показывает трек и раскрывает очередь',
      (WidgetTester tester) async {
    await pump(
      tester,
      const MopsApp(),
      size: const Size(1600, 1000),
      player: playingState(),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(FloatingDock), findsOneWidget);
    expect(find.text('Everything In Its Right Place'), findsWidgets);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/03_dock.png'),
    );

    // Панель очереди растёт вверх из островка и не сдвигает содержимое.
    await tester.tap(find.byIcon(Icons.queue_music));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/04_dock_queue.png'),
    );
  });

  testWidgets('Настройки доступны с телефона', (WidgetTester tester) async {
    await pump(tester, const MopsApp(), size: const Size(412, 880));
    await tester.tap(find.byIcon(Icons.settings_outlined).first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Material 3 Expressive'), findsOneWidget);
    // Дублирующего пункта «Вид плеера» больше нет.
    expect(find.text('Вид плеера'), findsNothing);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/05_settings.png'),
    );
  });

  testWidgets('Полноэкранный плеер на телефоне', (WidgetTester tester) async {
    await pump(
      tester,
      const _Harness(child: NowPlayingScreen()),
      size: const Size(412, 880),
      player: playingState(),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Everything In Its Right Place'), findsOneWidget);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/06_now_playing.png'),
    );
  });

  testWidgets('Настройки напрямую', (WidgetTester tester) async {
    await pump(
      tester,
      const _Harness(child: SettingsScreen()),
      size: const Size(720, 900),
    );

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/07_settings_wide.png'),
    );
  });

  testWidgets('Масштаб интерфейса меняется с клавиатуры', (WidgetTester tester) async {
    await pump(tester, const MopsApp(), size: const Size(1600, 1000));

    final BuildContext context = tester.element(find.byType(AppShell));
    final ProviderContainer container = ProviderScope.containerOf(context);

    expect(container.read(settingsControllerProvider).uiScale, 0.0);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(container.read(settingsControllerProvider).uiScale, 1.1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(container.read(settingsControllerProvider).uiScale, 0.0);
  });
}

/// Обёртка для одиночных экранов: та же тема и локали, что в приложении.
class _Harness extends ConsumerWidget {
  const _Harness({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ({ThemeData light, ThemeData dark}) themes =
        ref.watch(themeDataProvider);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: themes.light,
      darkTheme: themes.dark,
      themeMode: ThemeMode.dark,
      home: child,
    );
  }
}
