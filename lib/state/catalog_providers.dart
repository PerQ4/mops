import '../data/local/app_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';
import '../data/sources/better_lyrics_source.dart';
import '../data/sources/catalog_source.dart';
import '../data/sources/library_source.dart';
import '../data/sources/kugou_source.dart';
import '../data/sources/lrclib_source.dart';
import '../data/sources/megalobiz_source.dart';
import '../data/sources/musixmatch_source.dart';
import '../data/sources/simpmusic_source.dart';
import '../data/sources/unison_source.dart';
import '../data/sources/youly_plus_source.dart';
import '../core/utils/format.dart';
import 'providers.dart';

/// Провайдеры доступа к каталогу YouTube Music.
///
/// `FutureProvider`/`family` дают бесплатно кэширование, состояния загрузки
/// и ошибок — в UI не нужно писать ни одной ручной проверки «а загрузилось ли».
///
/// Умышленно нет аннотаций типа: у семейств в Riverpod меняется имя класса
/// между мажорными версиями, а вывод типов даёт то же самое и не ломается.

final catalogSourceProvider = Provider<CatalogSource>(
  (ref) => CatalogSource(ref.watch(innerTubeProvider)),
);

final librarySourceProvider = Provider<LibrarySource>(
  (ref) => LibrarySource(ref.watch(innerTubeProvider)),
);

/// Курсор ленты главной: токен следующей порции после первого запроса.
///
/// Нужен, чтобы не запрашивать главную дважды: `FutureProvider` отдаёт только
/// одно значение, а токен продолжения лежит рядом с секциями в том же ответе.
/// Это обычный объект, а не состояние провайдера: менять состояние другого
/// провайдера во время сборки Riverpod не разрешает, а записать поле — можно.
class HomeCursor {
  String? continuation;
}

final homeCursorProvider = Provider<HomeCursor>((ref) => HomeCursor());

/// Главная страница: первая порция секций.
///
/// Тип намеренно оставлен прежним (`FutureProvider<List<BrowseSection>>`):
/// на него смотрит не только экран, но и тесты, переопределяющие провайдер.
/// Токен продолжения первой порции при этом кладётся в [homeCursorProvider].
final homeSectionsProvider = FutureProvider<List<BrowseSection>>((ref) async {
  final ({List<BrowseSection> sections, String? continuation}) page =
      await ref.watch(catalogSourceProvider).homePage();
  ref.read(homeCursorProvider).continuation = page.continuation;
  // Видно в логе: если секций нет, проблема в доступе к сети, а не в вёрстке.
  debugPrint('[Home] секций получено: ${page.sections.length}, '
      'продолжение: ${page.continuation == null ? "нет" : "есть"}');
  return page.sections;
});

/// Состояние докрутки главной.
@immutable
class HomeFeedState {
  const HomeFeedState({
    this.sections = const <BrowseSection>[],
    this.loadingMore = false,
    this.finished = false,
  });

  /// Секции, догруженные после первой порции.
  final List<BrowseSection> sections;

  /// Идёт догрузка — внизу показывается индикатор.
  final bool loadingMore;

  /// Продолжения больше нет: докручивать нечего.
  final bool finished;

  HomeFeedState copyWith({
    List<BrowseSection>? sections,
    bool? loadingMore,
    bool? finished,
  }) {
    return HomeFeedState(
      sections: sections ?? this.sections,
      loadingMore: loadingMore ?? this.loadingMore,
      finished: finished ?? this.finished,
    );
  }
}

/// Докрутка главной: держит токен продолжения и добавляет новые секции.
///
/// Первую порцию отдаёт [homeSectionsProvider] (его слушает экран), а этот
/// контроллер ждёт её, забирает токен из [homeCursorProvider] и умеет
/// подгружать следующие порции. Так сохраняются и прежнее поведение главной,
/// и тип провайдера первой порции, который переопределяют тесты.
class HomeFeedController extends AsyncNotifier<HomeFeedState> {
  /// Текущий токен; `null` — лента кончилась.
  String? _continuation;

  @override
  Future<HomeFeedState> build() async {
    // Ждём первую порцию: пока её нет, токен продолжения неизвестен.
    // `watch` заодно пересобирает контроллер при входе в аккаунт и
    // pull-to-refresh — оба инвалидируют homeSectionsProvider.
    await ref.watch(homeSectionsProvider.future);
    _continuation = ref.read(homeCursorProvider).continuation;
    return HomeFeedState(finished: _continuation == null);
  }

  /// Догружает следующую порцию секций.
  ///
  /// Защита от повторных запросов: если догрузка уже идёт или продолжения
  /// нет — выходим сразу. Ошибка догрузки не стирает уже показанную ленту.
  Future<void> loadMore() async {
    final HomeFeedState current = state.value ?? const HomeFeedState();
    final String? token = _continuation;
    if (current.loadingMore || token == null) return;

    state = AsyncData<HomeFeedState>(current.copyWith(loadingMore: true));
    try {
      final ({List<BrowseSection> sections, String? continuation}) page =
          await ref.read(catalogSourceProvider).homePage(continuation: token);

      // Токен не сдвинулся — сервер вернул ту же страницу. Считаем ленту
      // законченной, иначе прокрутка зациклилась бы на одном и том же.
      _continuation = page.continuation == token ? null : page.continuation;

      state = AsyncData<HomeFeedState>(current.copyWith(
        sections: <BrowseSection>[
          ...current.sections,
          // Новые секции добавляем в конец и не пересортируем всю ленту:
          // секция с высоким приоритетом иначе вставилась бы в середину и
          // список дёрнулся бы у пользователя под руками.
          ...page.sections,
        ],
        loadingMore: false,
        finished: _continuation == null,
      ));
    } on Object catch (error) {
      debugPrint('[Home] ошибка догрузки: $error');
      state = AsyncData<HomeFeedState>(current.copyWith(loadingMore: false));
    }
  }
}

final AsyncNotifierProvider<HomeFeedController, HomeFeedState> homeFeedProvider =
    AsyncNotifierProvider<HomeFeedController, HomeFeedState>(
  HomeFeedController.new,
);

/// Раздел «Обзор».
final exploreSectionsProvider =
    FutureProvider<List<BrowseSection>>((ref) async {
  return ref.watch(catalogSourceProvider).explore();
});

/// Произвольный публичный раздел (чарты, настроения, подкасты).
final browseSectionProvider =
    FutureProvider.family<List<BrowseSection>, String>((ref, browseId) async {
  return ref.watch(catalogSourceProvider).browseSection(browseId);
});

/// Страница альбома.
final albumProvider = FutureProvider.family<Album, String>((ref, albumId) async {
  return ref.watch(catalogSourceProvider).album(albumId);
});

/// Страница исполнителя.
final artistProvider =
    FutureProvider.family<Artist, String>((ref, artistId) async {
  return ref.watch(catalogSourceProvider).artist(artistId);
});

/// Страница плейлиста.
final playlistProvider =
    FutureProvider.family<Playlist, String>((ref, playlistId) async {
  return ref.watch(catalogSourceProvider).playlist(playlistId);
});

/// Результаты поиска с учётом фильтра.
///
/// В ключ входит и запрос, и фильтр, поэтому переключение вкладок
/// не сбрасывает уже загруженные результаты.
final searchResultsProvider =
    FutureProvider.family<List<BrowseSection>, SearchQuery>((ref, query) async {
  if (query.text.trim().isEmpty) return const <BrowseSection>[];
  final SearchSource source = ref.watch(
    settingsControllerProvider.select((AppSettings s) => s.searchSource),
  );
  if (source == SearchSource.libraryOnly) {
    return _searchLibrary(ref, query.text);
  }
  return ref
      .watch(catalogSourceProvider)
      .search(query.text, filter: query.filter);
});

/// Поиск только по своей библиотеке.
///
/// YouTube не умеет искать внутри аккаунта, поэтому лайкнутые и сохранённые
/// треки забираем целиком и фильтруем сами по названию и исполнителю.
/// Выдача — одна секция: разделение по типам здесь не нужно, пользователь
/// искал среди того, что уже сохранил.
Future<List<BrowseSection>> _searchLibrary(Ref ref, String text) async {
  final String needle = text.trim().toLowerCase();
  if (needle.isEmpty) return const <BrowseSection>[];

  try {
    final LibrarySource library = ref.watch(librarySourceProvider);
    final List<Track> liked = await library.likedSongs();
    final List<Track> saved = await library.librarySongs();

    // Один трек может лежать и в лайках, и в сохранённых — убираем дубли
    // по id, иначе он показался бы дважды.
    final Map<String, Track> unique = <String, Track>{};
    for (final Track track in <Track>[...liked, ...saved]) {
      unique.putIfAbsent(track.id, () => track);
    }

    final List<Track> matches = unique.values
        .where((Track t) =>
            t.title.toLowerCase().contains(needle) ||
            t.artistLine.toLowerCase().contains(needle))
        .toList();
    if (matches.isEmpty) return const <BrowseSection>[];

    return <BrowseSection>[
      BrowseSection(
        title: 'В библиотеке — ${matches.length}',
        items: matches.map((Track t) => TrackItem(t)).toList(),
      ),
    ];
  } on Object {
    // Без входа библиотека недоступна — это не ошибка поиска.
    return const <BrowseSection>[];
  }
}

/// Подсказки при вводе.
final searchSuggestionsProvider =
    FutureProvider.family<List<String>, String>((ref, query) async {
  return ref.watch(catalogSourceProvider).searchSuggestions(query);
});

/// Открытая база синхронизированных текстов (LRCLIB).
///
/// YouTube Music отдаёт текст без времён, поэтому подсветить и прокрутить его
/// нельзя. LRCLIB хранит LRC — по нему и работает автопрокрутка.
/// Клиент KuGou: внешняя база текстов. Из этой сети LRCLIB отвечает
/// заглушкой, а KuGou отдаёт настоящий LRC — с временами строк.
final kugouSourceProvider = Provider<KugouSource>((ref) {
  final KugouSource source = KugouSource();
  ref.onDispose(source.dispose);
  return source;
});

final lrclibSourceProvider = Provider<LrclibSource>((ref) {
  final LrclibSource source = LrclibSource();
  ref.onDispose(source.dispose);
  return source;
});

/// BetterLyrics: TTML (формат Apple Music) с пословной синхронизацией.
final betterLyricsSourceProvider = Provider<BetterLyricsSource>((ref) {
  final BetterLyricsSource source = BetterLyricsSource();
  ref.onDispose(source.dispose);
  return source;
});

/// YouLy+: несколько зеркал с TTML/LRC.
final youlyPlusSourceProvider = Provider<YouLyPlusSource>((ref) {
  final YouLyPlusSource source = YouLyPlusSource();
  ref.onDispose(source.dispose);
  return source;
});

/// Megalobiz: текст с временами разбирается прямо из HTML.
final megalobizSourceProvider = Provider<MegalobizSource>((ref) {
  final MegalobizSource source = MegalobizSource();
  ref.onDispose(source.dispose);
  return source;
});

/// SimpMusic: база индексируется по id видео YouTube.
final simpmusicSourceProvider = Provider<SimpMusicSource>((ref) {
  final SimpMusicSource source = SimpMusicSource();
  ref.onDispose(source.dispose);
  return source;
});

/// Unison: поиск по метаданным и по id видео.
final unisonSourceProvider = Provider<UnisonSource>((ref) {
  final UnisonSource source = UnisonSource();
  ref.onDispose(source.dispose);
  return source;
});

final musixmatchSourceProvider = Provider<MusixmatchSource>((ref) {
  final MusixmatchSource source = MusixmatchSource();
  ref.onDispose(source.dispose);
  return source;
});

/// Запрос текста: id трека плюс метаданные.
///
/// Метаданные нужны внешней базе (LRCLIB), а не YouTube: она ищет по названию,
/// исполнителю, альбому и длительности. Если их нет — источник просто
/// пропускается.
@immutable
class LyricsRequest {
  const LyricsRequest({
    required this.videoId,
    this.title,
    this.artist,
    this.album,
    this.duration,
  });

  final String videoId;
  final String? title;
  final String? artist;
  final String? album;
  final Duration? duration;

  /// Хватает ли данных, чтобы спросить внешнюю базу.
  bool get canQueryExternal =>
      (title?.trim().isNotEmpty ?? false) &&
      (artist?.trim().isNotEmpty ?? false);

  /// Собирает запрос из трека, приводя имя исполнителя к «чистому» виду:
  /// YouTube добавляет авто-каналам суффикс « - Topic», и по нему внешняя
  /// база ничего не находит.
  factory LyricsRequest.fromTrack(Track track) => LyricsRequest(
        videoId: track.id,
        title: track.title,
        artist: track.artists.isEmpty
            ? null
            : cleanArtistName(track.artists.first.name),
        album: track.album?.name,
        duration: track.duration,
      );

  @override
  bool operator ==(Object other) =>
      other is LyricsRequest &&
      other.videoId == videoId &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(videoId, title, artist, album, duration);
}

/// Источник текста, выбранный вручную для конкретного трека.
///
/// Отдельно от настройки: пользователь может для одного клипа включить
/// субтитры кнопкой в плеере, не меняя источник по умолчанию для остальных.
class LyricsSourceOverride extends Notifier<Map<String, LyricsSource>> {
  @override
  Map<String, LyricsSource> build() => const <String, LyricsSource>{};

  void setSource(String videoId, LyricsSource source) =>
      state = <String, LyricsSource>{...state, videoId: source};
}

final NotifierProvider<LyricsSourceOverride, Map<String, LyricsSource>>
    lyricsSourceOverrideProvider =
    NotifierProvider<LyricsSourceOverride, Map<String, LyricsSource>>(
  LyricsSourceOverride.new,
);

/// Текст песни.
///
/// Выбранный источник авторитетен: если пользователь указал конкретную базу,
/// возвращаем ровно её результат, а пустота остаётся пустотой — тихого ухода
/// на текст YouTube Music больше нет. «Текст YouTube Music» и «Субтитры
/// видео» тоже честные: каждый отдаёт только своё.
///
/// Единственное исключение — режим «Авто»: он перебирает реальные базы, а
/// тексты YouTube берёт только в самом конце, когда ни одна база не ответила.
/// Приоритет в «Авто» отдан синхронизированным текстам — они дают подсветку
/// и автопрокрутку.
/// id треков, для которых текст уже найден.
///
/// Отметка в списках появляется только после того, как текст реально получен
/// (например, трек играл): спрашивать базы для каждой строки списка слишком
/// дорого, а так видно, у чего текст уже точно есть.
class LyricsAvailability extends Notifier<Set<String>> {
  @override
  Set<String> build() => <String>{};

  void mark(String videoId) {
    if (state.contains(videoId)) return;
    state = <String>{...state, videoId};
  }
}

final NotifierProvider<LyricsAvailability, Set<String>>
    lyricsAvailabilityProvider =
    NotifierProvider<LyricsAvailability, Set<String>>(LyricsAvailability.new);

final lyricsProvider =
    FutureProvider.family<Lyrics, LyricsRequest>((ref, request) async {
  final LyricsSource defaultSource = ref.watch(
    settingsControllerProvider.select((AppSettings s) => s.lyricsSource),
  );
  final LyricsSource? override = ref.watch(
    lyricsSourceOverrideProvider
        .select((Map<String, LyricsSource> m) => m[request.videoId]),
  );
  final LyricsSource source = override ?? defaultSource;

  final CatalogSource catalog = ref.watch(catalogSourceProvider);

  // Порядок «Авто» повторяет приоритет ArchiveTune: сначала сервисы, которые
  // отдают пословную или строчную синхронизацию, затем обычные базы.
  const List<LyricsSource> autoOrder = <LyricsSource>[
    LyricsSource.betterLyrics,
    LyricsSource.youlyPlus,
    LyricsSource.lrclib,
    LyricsSource.kugou,
    LyricsSource.megalobiz,
    LyricsSource.simpmusic,
    LyricsSource.unison,
    LyricsSource.musixmatch,
  ];

  // Ограничиваем ожидание каждой базы: если она недоступна (бывает за
  // блокировками), не заставляем пользователя ждать её таймаут.
  Future<Lyrics> bounded(Future<Lyrics> future) =>
      future.timeout(const Duration(seconds: 8), onTimeout: () => Lyrics.none);

  // Внешние базы, которым нужны название и исполнитель.
  Future<Lyrics> fetchMetadataSource(LyricsSource target) {
    if (!request.canQueryExternal) return Future<Lyrics>.value(Lyrics.none);
    final String title = request.title!.trim();
    final String artist = request.artist!.trim();
    switch (target) {
      case LyricsSource.betterLyrics:
        return bounded(ref.watch(betterLyricsSourceProvider).fetch(
          title: title,
          artist: artist,
          album: request.album,
          duration: request.duration,
        ));
      case LyricsSource.youlyPlus:
        return bounded(ref.watch(youlyPlusSourceProvider).fetch(
          title: title,
          artist: artist,
          album: request.album,
          duration: request.duration,
        ));
      case LyricsSource.lrclib:
        return bounded(ref.watch(lrclibSourceProvider).fetch(
          title: title,
          artist: artist,
          album: request.album,
          duration: request.duration,
        ));
      case LyricsSource.kugou:
        return bounded(ref.watch(kugouSourceProvider).fetch(
          title: title,
          artist: artist,
          duration: request.duration,
        ));
      case LyricsSource.megalobiz:
        return bounded(ref.watch(megalobizSourceProvider).fetch(
          title: title,
          artist: artist,
        ));
      case LyricsSource.musixmatch:
        // Musixmatch идёт через Paxsenix и требует ключ; без него — пропуск.
        final String key = ref.watch(
          settingsControllerProvider.select(
            (AppSettings s) => s.musixmatchApiKey,
          ),
        );
        if (key.isEmpty) return Future<Lyrics>.value(Lyrics.none);
        return bounded(ref.watch(musixmatchSourceProvider).fetch(
          title: title,
          artist: artist,
          apiKey: key,
          duration: request.duration,
        ));
      default:
        return Future<Lyrics>.value(Lyrics.none);
    }
  }

  // Один источник — ровно его результат. Пусто остаётся пустым: ни YouTube,
  // ни другие базы не подставляются.
  Future<Lyrics> fetchDirect(LyricsSource target) {
    switch (target) {
      case LyricsSource.music:
        return catalog.lyrics(request.videoId);
      case LyricsSource.subtitles:
        return bounded(catalog.subtitleLyrics(request.videoId));
      case LyricsSource.simpmusic:
        return bounded(ref.watch(simpmusicSourceProvider).fetch(
          videoId: request.videoId,
          duration: request.duration,
        ));
      case LyricsSource.unison:
        return bounded(ref.watch(unisonSourceProvider).fetch(
          videoId: request.videoId,
          title: request.title,
          artist: request.artist,
          album: request.album,
          duration: request.duration,
        ));
      default:
        return fetchMetadataSource(target);
    }
  }

  // «Авто»: базы опрашиваются параллельно, чтобы ожидание не складывалось.
  // Синхронизированный текст приоритетнее обычного, при равном качестве
  // выигрывает источник, стоящий в списке выше.
  Future<Lyrics> fetchAuto() async {
    final List<Lyrics> results =
        await Future.wait(autoOrder.map(fetchDirect).toList());

    Lyrics best = Lyrics.none;
    for (final Lyrics lyrics in results) {
      if (lyrics.isEmpty) continue;
      if (best.isEmpty || (lyrics.isSynced && !best.isSynced)) {
        best = lyrics;
      }
    }
    if (!best.isEmpty) return best;

    // Ни одна база не ответила — только теперь тексты YouTube.
    final Lyrics subtitles =
        await bounded(catalog.subtitleLyrics(request.videoId));
    if (!subtitles.isEmpty) return subtitles;
    return catalog.lyrics(request.videoId);
  }

  final Lyrics resolved = source == LyricsSource.auto
      ? await fetchAuto()
      : await fetchDirect(source);

  // Отмечаем трек как «с текстом» — по этой отметке в списках появляется
  // значок, поэтому она ставится только для непустого результата.
  if (!resolved.isEmpty) {
    ref.read(lyricsAvailabilityProvider.notifier).mark(request.videoId);
  }
  return resolved;
});

/// Пара «поисковый запрос + фильтр» — ключ кэша поиска.
class SearchQuery {
  const SearchQuery(this.text, this.filter);

  final String text;
  final SearchFilter filter;

  @override
  bool operator ==(Object other) =>
      other is SearchQuery && other.text == text && other.filter == filter;

  @override
  int get hashCode => Object.hash(text, filter);
}
