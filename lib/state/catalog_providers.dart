import '../data/local/app_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';
import '../data/sources/catalog_source.dart';
import '../data/sources/library_source.dart';
import '../data/sources/kugou_source.dart';
import '../data/sources/lrclib_source.dart';
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
/// Источников три. «Текст YouTube Music» отдаёт слова без времён; чтобы
/// подсветка и автопрокрутка всё-таки работали, к нему параллельно
/// запрашивается LRCLIB (синхронизированный LRC). «LRCLIB» и «Субтитры» —
/// явный выбор пользователя; если там пусто, не оставляем пустоту и падаем
/// на обычный текст YouTube Music.
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

  Future<Lyrics> fetchLrclib() {
    if (!request.canQueryExternal) return Future<Lyrics>.value(Lyrics.none);
    return ref
        .watch(lrclibSourceProvider)
        .fetch(
          title: request.title!.trim(),
          artist: request.artist!.trim(),
          album: request.album,
          duration: request.duration,
        )
        // Ограничиваем ожидание: если база недоступна (бывает за
        // блокировками), не заставляем пользователя ждать её таймаут.
        .timeout(const Duration(seconds: 6), onTimeout: () => Lyrics.none);
  }

  Future<Lyrics> fetchKugou() {
    if (!request.canQueryExternal) return Future<Lyrics>.value(Lyrics.none);
    return ref
        .watch(kugouSourceProvider)
        .fetch(
          title: request.title!.trim(),
          artist: request.artist!.trim(),
          duration: request.duration,
        )
        .timeout(const Duration(seconds: 8), onTimeout: () => Lyrics.none);
  }

  // Явно выбранная база KuGou.
  if (source == LyricsSource.kugou) {
    final Lyrics fromKugou = await fetchKugou();
    if (!fromKugou.isEmpty) return fromKugou;
  }

  // Явно выбранная открытая база: она и есть ответ, YouTube не трогаем.
  if (source == LyricsSource.lrclib) {
    final Lyrics fromLrclib = await fetchLrclib();
    if (!fromLrclib.isEmpty) return fromLrclib;
    // База не нашла — не оставляем пустоту, идём обычным путём.
  }

  if (source == LyricsSource.subtitles) {
    final Lyrics fromSubtitles = await catalog.subtitleLyrics(request.videoId);
    // Если субтитров нет, не оставляем пустоту — пробуем обычный источник.
    if (!fromSubtitles.isEmpty) return fromSubtitles;
  }

  // Обычный текст YouTube запускаем сразу, а для основного источника рядом
  // запрашиваем LRCLIB — он отдаёт LRC, то есть синхронизацию строк, ради
  // которой и существует подсветка. Запросы идут параллельно, поэтому
  // внешняя база не добавляет к ожиданию время YouTube.
  final Future<Lyrics> fromMusicFuture = catalog.lyrics(request.videoId);
  // Для основного источника рядом спрашиваем KuGou: только он отдаёт
  // времена строк, ради которых и существует подсветка.
  final Future<Lyrics>? fromLrclibFuture =
      (source == LyricsSource.music && request.canQueryExternal)
          ? fetchKugou()
          : null;

  final Lyrics fromMusic = await fromMusicFuture;
  if (fromMusic.isSynced) return fromMusic;

  if (fromLrclibFuture != null) {
    final Lyrics fromLrclib = await fromLrclibFuture;
    if (fromLrclib.isSynced) return fromLrclib;
    if (fromMusic.isEmpty && !fromLrclib.isEmpty) return fromLrclib;
  }

  return fromMusic;
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
