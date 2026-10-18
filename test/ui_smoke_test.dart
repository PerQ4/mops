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
import 'package:mops/features/player/lyrics_actions.dart';
import 'package:mops/features/player/lyrics_view.dart';
import 'package:mops/features/player/now_playing_screen.dart';
import 'package:mops/features/search/search_screen.dart';
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

  // У заглушки независимого питча нет — как у любого движка без scaletempo.
  @override
  bool get supportsPitch => false;

  @override
  Future<void> setPitch(double pitch) async {}

  // Устройств вывода в тестовой среде нет — поток пустой, выбор ни на что
  // не влияет.
  @override
  List<AudioOutputDevice> get audioDevices => const <AudioOutputDevice>[];

  @override
  Stream<List<AudioOutputDevice>> get audioDevicesStream =>
      const Stream<List<AudioOutputDevice>>.empty();

  @override
  Future<void> setAudioDevice(String name) async {}

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
    // Полки, которые главная вынимает из ленты: «Слушать снова» и «Быстрый
    // выбор». Без них в эталоне не было бы новых блоков.
    BrowseSection(
      title: 'Слушать снова',
      items: tracks
          .take(5)
          .map((Track t) => TrackItem(t))
          .toList(growable: false),
    ),
    BrowseSection(
      title: 'Быстрый выбор',
      items: <BrowseItem>[
        for (int i = 0; i < 4; i++)
          AlbumItem(Album(
            id: 'MPREq_$i',
            title: 'Подборка $i',
            artists: <ArtistRef>[ArtistRef(name: _artistNames[i % 5])],
            year: '2026',
          )),
      ],
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

  // Шрифты темы: основной и фоллбек для кириллицы. Без них в эталонах
  // вместо текста «квадратики»: тестовая среда подставляет свой шрифт
  // только для известных семейств.
  await _loadFamily('Poppins', <String>[
    'assets/fonts/Poppins-400.ttf',
    'assets/fonts/Poppins-500.ttf',
    'assets/fonts/Poppins-600.ttf',
    'assets/fonts/Poppins-700.ttf',
  ]);
  await _loadFamily('Montserrat', <String>[
    'assets/fonts/Montserrat-400.ttf',
    'assets/fonts/Montserrat-500.ttf',
    'assets/fonts/Montserrat-600.ttf',
    'assets/fonts/Montserrat-700.ttf',
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

/// ------------------------------------------------------------------ тексты

/// Строки для эталона экрана поиска — обычная песня, строка на строку.
const List<String> _lyricsLines = <String>[
  'Город тонет в синем свете фонарей',
  'Я иду по краю, не считая дней',
  'Ты сказала: «стой», и я остановился',
  'Ветер в проводах, как будто бы напился',
  'Мы молчим о том, о чём нельзя молчать',
  'И не можем просто взять и перестать',
  'Полночь на часах, и радио молчит',
  'Только этот город всё ещё не спит',
  'Я запомню всё: и холод, и огни',
  'И как мы потерялись в эти дни',
  'Утро придёт, и всё пойдёт не так',
  'Но пока играет этот медленный закат',
];

Lyrics _plainLyrics() => Lyrics(plain: _lyricsLines.join('\n'));

Lyrics _lineSyncedLyrics() => Lyrics(
      timed: <TimedLyric>[
        for (int i = 0; i < _lyricsLines.length; i++)
          TimedLyric(
            time: Duration(seconds: 14 + i * 5),
            text: _lyricsLines[i],
          ),
      ],
    );

Lyrics _wordSyncedLyrics() => Lyrics(
      timed: <TimedLyric>[
        for (int i = 0; i < _lyricsLines.length; i++)
          TimedLyric(
            time: Duration(seconds: 14 + i * 5),
            text: _lyricsLines[i],
            words: <TimedWord>[
              for (final String word in _lyricsLines[i].split(' '))
                TimedWord(
                  time: Duration(seconds: 14 + i * 5),
                  text: word,
                ),
            ],
          ),
      ],
    );

/// Четыре варианта: у LRCLIB их два — проверить, что карточки одного источника
/// различаются по ключу, а не по названию базы.
LyricsSearchState _fakeLyricsSearch() => LyricsSearchState(
      loading: false,
      candidates: <LyricsCandidate>[
        LyricsCandidate.from(
          source: LyricsSource.youlyPlus,
          lyrics: _wordSyncedLyrics(),
          score: 40,
        ),
        LyricsCandidate.from(
          source: LyricsSource.betterLyrics,
          lyrics: _lineSyncedLyrics(),
          score: 30,
        ),
        LyricsCandidate.from(
          source: LyricsSource.lrclib,
          lyrics: _plainLyrics(),
          score: 20,
        ),
        LyricsCandidate.from(
          source: LyricsSource.lrclib,
          lyrics: _otherPlainLyrics(),
          score: 19,
        ),
      ],
    );

/// Второе совпадение той же базы: другой текст, тот же источник.
Lyrics _otherPlainLyrics() => Lyrics(
      plain: <String>[
        'Город тонет в синем свете фонарей',
        'Я иду по краю, не считая дней',
        'Это другая запись той же песни — с другого концерта',
        'И слова в ней чуть-чуть не те',
      ].join('\n'),
    );

/// Открывает экран поиска текста — для эталона.
class _SearchLauncher extends StatelessWidget {
  const _SearchLauncher();

  static const LyricsRequest request = LyricsRequest(
    videoId: 'vid00000000001',
    title: 'Ночной город',
    artist: 'Пример',
    album: 'Первый',
    duration: Duration(minutes: 3, seconds: 42),
  );

  @override
  Widget build(BuildContext context) {
    // Без Scaffold: этот виджет ставится и как «домашний» экран, и внутрь
    // колонки рядом с плеером — Scaffold в колонке требует ограниченной высоты.
    return Center(
      child: FilledButton(
        onPressed: () => showLyricsSearchDialog(
          context,
          request,
          startInInput: false,
        ),
        child: const Text('Поиск текста'),
      ),
    );
  }
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
  ///
  /// `extra` — дополнительные подмены провайдеров для отдельного теста. Тип
  /// элемента не называем: `Override` из riverpod 3 не экспортируется
  /// `flutter_riverpod`, а список подмен собирается и так.
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    required Size size,
    PlayerUiState? player,
    List<dynamic> extra = const <dynamic>[],
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
          // Чипы категорий на главной берутся из сети — в тесте задаём их
          // заранее, иначе блок не нарисуется и эталон потеряет ряд чипов.
          moodCategoriesProvider.overrideWith(
            (ref) async => <String>['Поп', 'Рок', 'Джаз', 'Классика'],
          ),
          if (player != null)
            playerControllerProvider.overrideWith(() => _StubPlayer(player)),
          ...extra,
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
    // Навигация переехала вниз в островок, боковой колонки нет.
    expect(find.byType(NavigationRail), findsNothing);
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
    // На узком экране навигация — тот же плавающий док, что и на широком:
    // стандартной нижней панели Material больше нет (как в ArchiveTune).
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(NavigationRail), findsNothing);
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
    // Ищем иконку именно в островке: такие же есть в карточках.
    await tester.tap(
      find.descendant(
        of: find.byType(FloatingDock),
        matching: find.byIcon(Icons.queue_music),
      ),
    );
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

  testWidgets('Поиск текста: список найденных вариантов и раскрытие',
      (WidgetTester tester) async {
    await pump(
      tester,
      const _Harness(child: _SearchLauncher()),
      size: const Size(900, 900),
      extra: <dynamic>[
        // Источники в тесте не спрашиваем: варианты заданы заранее — эталон
        // должен быть одинаковым при любом состоянии сети. Обычный поиск
        // (по нему экран понимает, что показывает плеер) отдаёт тот же ответ.
        lyricsVariantsProvider.overrideWith(
          (ref, LyricsRequest request) =>
              Stream<LyricsSearchState>.value(_fakeLyricsSearch()),
        ),
        lyricsProvider.overrideWith(
          (ref, LyricsRequest request) =>
              Stream<LyricsSearchState>.value(_fakeLyricsSearch()),
        ),
      ],
    );

    await tester.tap(find.text('Поиск текста'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Счётчик в шапке — как «3 results» в ArchiveTune.
    expect(find.text('Найдено: 4 варианта'), findsOneWidget);
    // Типы синхронизации подписаны, а не показаны одной иконкой.
    expect(find.text('Пословная синхронизация'), findsWidgets);
    expect(find.text('Построчная синхронизация'), findsWidgets);
    expect(find.text('Без синхронизации'), findsWidgets);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/08_lyrics_search.png'),
    );

    // Раскрытие карточки: у свёрнутых превью две строки, у раскрытой — восемь.
    await tester.tap(find.byIcon(Icons.expand_more).first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.expand_less), findsOneWidget);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/09_lyrics_search_expanded.png'),
    );
  });

  testWidgets('Поиск текста: форма ручного ввода', (WidgetTester tester) async {
    await pump(
      tester,
      const _Harness(child: _SearchLauncher()),
      size: const Size(900, 900),
      extra: <dynamic>[
        lyricsVariantsProvider.overrideWith(
          (ref, LyricsRequest request) =>
              Stream<LyricsSearchState>.value(_fakeLyricsSearch()),
        ),
        lyricsProvider.overrideWith(
          (ref, LyricsRequest request) =>
              Stream<LyricsSearchState>.value(_fakeLyricsSearch()),
        ),
      ],
    );

    await tester.tap(find.text('Поиск текста'));
    await tester.pumpAndSettle();
    // Стрелка «назад» в шапке возвращает к правке метаданных.
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Искать в интернете'), findsOneWidget);
    expect(find.text('Искать'), findsOneWidget);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/10_lyrics_search_input.png'),
    );
  });

  testWidgets('Настройки: источники текста включаются по отдельности',
      (WidgetTester tester) async {
    await pump(
      tester,
      const _Harness(child: SettingsScreen()),
      size: const Size(720, 900),
    );

    final Finder row = find.text('Источники текста');
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Каталоги Paxsenix включаются внутри той же формы.
    expect(find.text('Каталоги Paxsenix'), findsOneWidget);
    expect(find.text('Apple Music'), findsOneWidget);
    expect(find.text('Spotify'), findsOneWidget);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/11_lyrics_providers.png'),
    );
  });

  testWidgets('Выбранный вариант показывается в плеере, даже когда обычный поиск пуст',
      (WidgetTester tester) async {
    const String videoId = 'vid00000000042';

    await pump(
      tester,
      const _Harness(child: LyricsView(videoId: videoId)),
      size: const Size(720, 700),
      extra: <dynamic>[
        // Обычный поиск ничего не нашёл — так и бывает, когда вариант пришёл
        // только из «всех совпадений».
        lyricsProvider.overrideWith(
          (ref, LyricsRequest request) => Stream<LyricsSearchState>.value(
            const LyricsSearchState(loading: false),
          ),
        ),
      ],
    );

    final BuildContext context = tester.element(find.byType(LyricsView));
    final ProviderContainer container = ProviderScope.containerOf(context);
    // Выбираем вариант ровно так, как это делает карточка экрана поиска.
    container.read(lyricsPickProvider.notifier).set(
          videoId,
          LyricsPick(
            id: 'lrclib_x',
            source: LyricsSource.lrclib,
            lyrics: _plainLyrics(),
          ),
        );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Текст выбранного варианта виден, а не «Текста нет».
    expect(find.text(_lyricsLines.first), findsWidgets);
    expect(find.text('Текста нет'), findsNothing);
  });

  testWidgets('Тап по карточке поиска: плеер показывает этот же текст',
      (WidgetTester tester) async {
    // Один и тот же трек в плеере и в поиске — как в жизни.
    const String videoId = 'vid00000000001';

    await pump(
      tester,
      const _Harness(
        child: Column(
          children: <Widget>[
            Expanded(child: LyricsView(videoId: videoId)),
            _SearchLauncher(),
          ],
        ),
      ),
      size: const Size(900, 900),
      extra: <dynamic>[
        // Обычный поиск пуст: вариант приходит только из «всех совпадений».
        lyricsProvider.overrideWith(
          (ref, LyricsRequest request) => Stream<LyricsSearchState>.value(
            const LyricsSearchState(loading: false),
          ),
        ),
        lyricsVariantsProvider.overrideWith(
          (ref, LyricsRequest request) =>
              Stream<LyricsSearchState>.value(_fakeLyricsSearch()),
        ),
      ],
    );

    await tester.tap(find.text('Поиск текста'));
    await tester.pumpAndSettle();

    // Берём карточку LRCLIB — ту, что с обычным текстом, как выбрал бы
    // пользователь.
    await tester.tap(find.text('LRCLIB').first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Текста нет'), findsNothing);
    expect(find.text(_lyricsLines.first), findsWidgets);
  });

  testWidgets('Поиск: настроения и жанры не обрезают подписи',
      (WidgetTester tester) async {
    await pump(
      tester,
      const _Harness(child: SearchScreen()),
      size: const Size(1600, 900),
    );

    expect(tester.takeException(), isNull);
    // Подписи в плитках видны целиком, а не «Хоро…»: сетка на десктопе шире,
    // чем мобильные 180 пикселей.
    expect(find.text('Хорошее настроение'), findsOneWidget);
    expect(find.text('Для тренировки'), findsOneWidget);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/12_search_moods.png'),
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
