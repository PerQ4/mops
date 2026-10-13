// Проверка интерфейса без сети: подставляем фейковые данные и отрисовываем
// ключевые экраны. Тест ловит ошибки раскладки (overflow) и сохраняет
// эталонные изображения.
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
  Future<void> load(String url, {bool autoplay = true}) async {}

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

/// Нотификатор плеера с заранее заданным состоянием — очередь и трек.
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
      artists: <ArtistRef>[ArtistRef(name: _artistNames[i % _artistNames.length])],
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
    BrowseSection(
      title: 'Чарты',
      items: tracks
          .skip(3)
          .map((Track t) => TrackItem(t))
          .toList(growable: false),
    ),
  ];
}

/// ------------------------------------------------------------------ загрузка шрифтов

/// В тестовой среде системных шрифтов нет — текст рисуется «квадратиками».
/// Подгружаем Roboto и MaterialIcons с диска, чтобы эталоны были читаемыми.
Future<void> _loadFonts() async {
  // Roboto — семейство по умолчанию в Material.
  await _loadFamily('Roboto', <String>[
    '/usr/share/fonts/TTF/Roboto-Regular.ttf',
    '/usr/share/fonts/TTF/Roboto-Medium.ttf',
    '/usr/share/fonts/TTF/Roboto-Bold.ttf',
  ]);

  // Без этого шрифта иконки выглядят как пустые квадраты.
  await _loadFamily('MaterialIcons', <String>[
    '${_flutterRoot()}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
}

String _flutterRoot() {
  // Тест запускается из корня проекта, а SDK лежит рядом.
  final String fromEnv = Platform.environment['FLUTTER_ROOT'] ?? '';
  if (fromEnv.isNotEmpty && Directory(fromEnv).existsSync()) return fromEnv;

  final String executable = Platform.resolvedExecutable;
  // …/flutter/bin/cache/dart-sdk/bin/dart → …/flutter
  final List<String> parts = executable.split(Platform.pathSeparator);
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
    // В тестах окружение не читаем: масштаб задаём явно.
    envReaderOverride = (String name) => null;
    await _loadFonts();
  });

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  // Тёмная тема лучше показывает Expressive-палитру.
  const AppSettings settings = AppSettings(
    themeMode: ThemeModePreference.dark,
    colorSource: ColorSource.seed,
    seedColorIndex: 1,
    useMaterialExpressive: true,
  );

  /// Собирает приложение с подставными данными и указанным размером окна.
  ///
  /// Тип списка overrides не пишем явно: класс `Override` в Riverpod 3
  /// не экспортируется, но вывод типов справляется сам.
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

  testWidgets('Главная, широкий экран', (WidgetTester tester) async {
    await pump(tester, const MopsApp(), size: const Size(1440, 900));

    expect(tester.takeException(), isNull);
    // «Главная» встречается и в заголовке страницы, и в боковой навигации.
    expect(find.text('Главная'), findsWidgets);
    expect(find.text('Слушать снова'), findsOneWidget);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

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

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/02_home_mobile.png'),
    );
  });

  testWidgets('Настройки', (WidgetTester tester) async {
    await pump(tester, const MopsApp(), size: const Size(412, 880));
    // Открываем настройки через иконку в AppBar.
    await tester.tap(find.byIcon(Icons.settings_outlined).first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Material 3 Expressive'), findsOneWidget);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/03_settings.png'),
    );
  });

  testWidgets('Полноэкранный плеер', (WidgetTester tester) async {
    final List<Track> tracks = _fakeTracks(6);
    final PlayerUiState state = PlayerUiState(
      queue: tracks,
      index: 1,
      playback: PlaybackState(
        status: PlaybackStatus.playing,
        position: const Duration(minutes: 1, seconds: 24),
        duration: const Duration(minutes: 4, seconds: 12),
        volume: 0.8,
      ),
    );

    await pump(
      tester,
      const _Harness(child: NowPlayingScreen()),
      size: const Size(900, 1000),
      player: state,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Everything In Its Right Place'), findsOneWidget);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/04_now_playing.png'),
    );
  });

  testWidgets('Масштаб интерфейса меняется с клавиатуры', (WidgetTester tester) async {
    await pump(tester, const MopsApp(), size: const Size(1440, 900));

    final BuildContext context = tester.element(find.byType(AppShell));
    final ProviderContainer container = ProviderScope.containerOf(context);

    // По умолчанию — автоматический режим (0).
    expect(container.read(settingsControllerProvider).uiScale, 0.0);

    // Ctrl + должен увеличить масштаб до 1.1.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(container.read(settingsControllerProvider).uiScale, 1.1);

    // Ctrl - возвращает к 1.0.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.minus);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(container.read(settingsControllerProvider).uiScale, 1.0);

    // Ctrl 0 включает автоматический режим.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(container.read(settingsControllerProvider).uiScale, 0.0);
  });

  testWidgets('Настройки напрямую', (WidgetTester tester) async {
    await pump(
      tester,
      const _Harness(child: SettingsScreen()),
      size: const Size(600, 900),
    );

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/05_settings_direct.png'),
    );
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
