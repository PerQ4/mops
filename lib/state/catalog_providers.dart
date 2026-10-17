import '../data/local/app_settings.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/lyrics_cache.dart';
import '../data/models/models.dart';
import '../data/sources/better_lyrics_source.dart';
import '../data/sources/catalog_source.dart';
import '../data/sources/library_source.dart';
import '../data/sources/kugou_source.dart';
import '../data/sources/lrclib_source.dart';
import '../data/sources/lyrics_match.dart';
import '../data/sources/paxsenix_source.dart';
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

/// Unison: поиск по метаданным и по id видео.
final unisonSourceProvider = Provider<UnisonSource>((ref) {
  final UnisonSource source = UnisonSource();
  ref.onDispose(source.dispose);
  return source;
});

/// Paxsenix: Apple Music (пословная разметка), Musixmatch и общий поиск —
/// всё по одному ключу из настроек.
final paxsenixSourceProvider = Provider<PaxsenixSource>((ref) {
  final PaxsenixSource source = PaxsenixSource();
  ref.onDispose(source.dispose);
  return source;
});

/// Дисковый кэш найденных текстов.
///
/// Один на приложение: записи держатся в памяти экземпляра, поэтому повторное
/// открытие трека не перечитывает файл заново.
final lyricsCacheProvider = Provider<LyricsCache>((ref) => LyricsCache());

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

/// Найденный трек (запись базы) — то, из чего пользователь выбирает текст.
///
/// Почему отдельный тип: обычный поиск отдаёт по одному варианту на источник,
/// и при ручном поиске выбрать другую запись было нельзя. Здесь храним
/// метаданные записи и то, как её скачать, а не сам текст: текст берётся
/// позже, ровно для выбранной записи (см. `fetchHit` у источников).
@immutable
class LyricsTrackHit {
  const LyricsTrackHit({
    required this.source,
    required this.id,
    this.accessKey,
    this.provider,
    this.title,
    this.artist,
    this.album,
    this.duration,
    this.hasSync,
  });

  /// База, из которой пришла запись.
  final LyricsSource source;

  /// Идентификатор записи внутри базы.
  final String id;

  /// Токен для скачивания текста (KuGou); у остальных баз не нужен.
  final String? accessKey;

  /// Подкаталог Paxsenix (`applemusic`/`spotify`) — какую базу спрашивать
  /// за текстом. `null` у остальных источников.
  final String? provider;

  final String? title;
  final String? artist;
  final String? album;
  final Duration? duration;

  /// Подсказка о синхронизации: `true` — есть, `false` — знаем, что нет,
  /// `null` — источник этого не сообщает.
  final bool? hasSync;

  /// Метаданные записи для оценки совместимости: по ним источник проставляет
  /// [LyricsMatch] найденному тексту.
  LyricsMatch get match => LyricsMatch(
        title: title,
        artist: artist,
        duration: duration,
      );

  /// Равенство по значению: семейства провайдеров кэшируются по ключу, и
  /// одинаковые записи должны считаться одним и тем же.
  @override
  bool operator ==(Object other) =>
      other is LyricsTrackHit &&
      other.source == source &&
      other.id == id &&
      other.accessKey == accessKey &&
      other.provider == provider &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.duration == duration &&
      other.hasSync == hasSync;

  @override
  int get hashCode => Object.hash(
        source,
        id,
        accessKey,
        provider,
        title,
        artist,
        album,
        duration,
        hasSync,
      );
}

/// Один найденный вариант текста вместе с оценкой совместимости.
///
/// Это результат работы одного источника: сам текст и балл, по которому он
/// занимает место в общем списке (см. [scoreLyrics]).
class LyricsCandidate {
  const LyricsCandidate({
    required this.source,
    required this.lyrics,
    required this.score,
    this.reasons = const <String>[],
    this.syncType = LyricsSyncType.unsynced,
    this.isWordSynced = false,
    this.isLineSynced = false,
    this.lineCount = 0,
    this.characterCount = 0,
    this.preview = '',
  });

  /// Собирает результат из текста: считает тип синхронизации, объём и превью —
  /// как карточка результата в ArchiveTune.
  factory LyricsCandidate.from({
    required LyricsSource source,
    required Lyrics lyrics,
    required int score,
    List<String> reasons = const <String>[],
  }) {
    final List<TimedLyric> timed = lyrics.timed ?? const <TimedLyric>[];
    final bool wordSynced = timed.any((TimedLyric l) => l.hasWords);
    final List<String> lines = timed.isNotEmpty
        ? timed.map((TimedLyric l) => l.text).toList()
        : (lyrics.plain ?? '').split('\n');
    final List<String> nonEmpty =
        lines.where((String l) => l.trim().isNotEmpty).toList();
    return LyricsCandidate(
      source: source,
      lyrics: lyrics,
      score: score,
      reasons: reasons,
      syncType: syncTypeOf(lyrics),
      isWordSynced: wordSynced,
      isLineSynced: timed.isNotEmpty && !wordSynced,
      lineCount: nonEmpty.length,
      characterCount: lyrics.plain?.length ??
          lines.fold<int>(0, (int sum, String l) => sum + l.length),
      preview: nonEmpty.take(2).join('\n'),
    );
  }

  final LyricsSource source;
  final Lyrics lyrics;

  /// Балл совместимости (см. [scoreLyrics]).
  final int score;

  /// Человекочитаемые причины оценки — показываются в меню.
  final List<String> reasons;

  /// Тип синхронизации — по нему «Авто» выбирает лучший текст
  /// (см. [kLyricsSyncPriority]).
  final LyricsSyncType syncType;

  /// Пословная синхронизация (караоке).
  final bool isWordSynced;

  /// Строчная синхронизация (без слов).
  final bool isLineSynced;

  /// Число непустых строк.
  final int lineCount;

  /// Число символов текста.
  final int characterCount;

  /// Первые строки — превью в карточке результата.
  final String preview;
}

/// Состояние поиска текста: найденные варианты и признак незавершённости.
@immutable
class LyricsSearchState {
  const LyricsSearchState({
    this.candidates = const <LyricsCandidate>[],
    this.loading = true,
  });

  /// Варианты, отсортированные по убыванию совместимости.
  final List<LyricsCandidate> candidates;

  /// Поиск ещё идёт: в меню это показывается индикатором.
  final bool loading;

  LyricsCandidate? get best => candidates.isEmpty ? null : candidates.first;

  /// Лучший текст по механизму приоритета — как `PROVIDER_CONFIGS` в
  /// BetterLyrics: сначала сравнивается **тип синхронизации** (караоке важнее
  /// построчного, построчный важнее текста без времён), и только внутри одного
  /// типа — порядок источников из настроек.
  ///
  /// Так «Авто» не отдаёт чужой текст с верными временами только потому, что
  /// он пришёл раньше: побеждает тот, у кого разметка подробнее.
  LyricsCandidate? bestByOrder(List<LyricsSource> order) {
    if (candidates.isEmpty) return null;

    for (final LyricsSyncType tier in kLyricsSyncPriority) {
      for (final LyricsSource source in order) {
        for (final LyricsCandidate candidate in candidates) {
          if (candidate.source == source && candidate.syncType == tier) {
            return candidate;
          }
        }
      }
      // Источники вне списка (тексты и субтитры YouTube) — в конце своего
      // типа: у них нет метаданных, поэтому внешняя база предпочтительнее.
      for (final LyricsCandidate candidate in candidates) {
        if (candidate.syncType == tier) return candidate;
      }
    }
    return candidates.first;
  }

  bool get isEmpty => candidates.isEmpty && !loading;

  LyricsCandidate? candidateFor(LyricsSource source) {
    for (final LyricsCandidate candidate in candidates) {
      if (candidate.source == source) return candidate;
    }
    return null;
  }
}

/// Порядок источников для «Авто» и для тай-брейка совместимости.
///
/// Повторяет приоритет ArchiveTune: сначала сервисы, отдающие пословную или
/// строчную синхронизацию, затем обычные базы. Тексты YouTube Music и субтитры
/// добавляются последними — у них нет метаданных для оценки, поэтому внешняя
/// база с той же синхронизацией всегда выигрывает.
const List<LyricsSource> lyricsAutoOrder = kDefaultLyricsOrder;

/// Ручной поиск текста: пользователь вводит свои метаданные для трека.
///
/// Нужен, когда данные трека из YouTube врут (каверы, «Topic»-каналы, пустой
/// исполнитель) — тогда поиск идёт по введённым названию/исполнителю/альбому.
class ManualLyricsRequests extends Notifier<Map<String, LyricsRequest>> {
  @override
  Map<String, LyricsRequest> build() => const <String, LyricsRequest>{};

  void set(String videoId, LyricsRequest? request) {
    final Map<String, LyricsRequest> next =
        Map<String, LyricsRequest>.of(state);
    if (request == null) {
      next.remove(videoId);
    } else {
      next[videoId] = request;
    }
    state = next;
  }
}

final NotifierProvider<ManualLyricsRequests, Map<String, LyricsRequest>>
    manualLyricsRequestsProvider =
    NotifierProvider<ManualLyricsRequests, Map<String, LyricsRequest>>(
  ManualLyricsRequests.new,
);

/// Запись базы, выбранная вручную для конкретного трека.
///
/// Пока запись выбрана, [lyricsProvider] не перебирает все источники, а берёт
/// текст ровно этой записи — так пользователь исправляет «не тот» текст,
/// который нашёлся автоматически.
class ManualLyricsSelection extends Notifier<Map<String, LyricsTrackHit>> {
  @override
  Map<String, LyricsTrackHit> build() => const <String, LyricsTrackHit>{};

  void set(String videoId, LyricsTrackHit? hit) {
    final Map<String, LyricsTrackHit> next =
        Map<String, LyricsTrackHit>.of(state);
    if (hit == null) {
      next.remove(videoId);
    } else {
      next[videoId] = hit;
    }
    state = next;
  }
}

final NotifierProvider<ManualLyricsSelection, Map<String, LyricsTrackHit>>
    manualLyricsSelectionProvider =
    NotifierProvider<ManualLyricsSelection, Map<String, LyricsTrackHit>>(
  ManualLyricsSelection.new,
);

/// Результаты ручного поиска: список найденных записей из всех баз.
///
/// Спрашиваем только те базы, что умеют искать списком. YouLy+ и BetterLyrics
/// такого поиска не отдают — они ищут текст сразу по метаданным, поэтому в
/// списке их нет (в интерфейсе это написано). Ошибки и недоступность сервиса
/// дают пустой список, а не исключение.
final manualLyricsHitsProvider =
    FutureProvider.family<List<LyricsTrackHit>, LyricsRequest>(
        (ref, request) async {
  final String? title = request.title?.trim();
  final String? artist = request.artist?.trim();
  if (title == null || title.isEmpty) {
    return const <LyricsTrackHit>[];
  }

  final LrclibSource lrclib = ref.watch(lrclibSourceProvider);
  final KugouSource kugou = ref.watch(kugouSourceProvider);
  final UnisonSource unison = ref.watch(unisonSourceProvider);
  final PaxsenixSource paxsenix = ref.watch(paxsenixSourceProvider);
  final String musixmatchKey = ref.watch(
    settingsControllerProvider.select((AppSettings s) => s.musixmatchApiKey),
  );

  // У каждой базы свой бюджет: молчащая база не должна задерживать список.
  Future<List<LyricsTrackHit>> bounded(
    Future<List<LyricsTrackHit>> future,
  ) =>
      future.timeout(
        _lyricsSourceBudget,
        onTimeout: () => const <LyricsTrackHit>[],
      );

  final List<List<LyricsTrackHit>> groups =
      await Future.wait(<Future<List<LyricsTrackHit>>>[
    bounded(lrclib.search(
      title: title,
      artist: artist ?? '',
      album: request.album,
      duration: request.duration,
    )),
    bounded(kugou.search(
      title: title,
      artist: artist ?? '',
      duration: request.duration,
    )),
    bounded(unison.search(
      title: title,
      artist: artist ?? '',
      album: request.album,
      duration: request.duration,
    )),
    // Paxsenix без ключа не работает — не спрашиваем его зря.
    if (musixmatchKey.trim().isNotEmpty)
      bounded(paxsenix.search(
        title: title,
        artist: artist ?? '',
        duration: request.duration,
        apiKey: musixmatchKey,
      )),
  ]);

  final List<LyricsTrackHit> hits = <LyricsTrackHit>[];
  for (final List<LyricsTrackHit> group in groups) {
    hits.addAll(group);
  }
  // Порядок — по похожести на запрос: сначала название, затем исполнитель,
  // затем близость длительности. Лучшее совпадение оказывается сверху.
  hits.sort((LyricsTrackHit a, LyricsTrackHit b) => _hitScore(
        b,
        title: title,
        artist: artist,
        duration: request.duration,
      ).compareTo(_hitScore(
        a,
        title: title,
        artist: artist,
        duration: request.duration,
      )));
  return hits;
});

/// Оценка похожести записи на запрос — для сортировки результатов ручного
/// поиска. Веса задают приоритет: название важнее исполнителя, исполнитель
/// важнее длительности.
int _hitScore(
  LyricsTrackHit hit, {
  required String? title,
  required String? artist,
  required Duration? duration,
}) {
  int score = 0;

  final String hitTitle = normalizeMatchText(hit.title ?? '');
  final String wantTitle = normalizeMatchText(title ?? '');
  if (hitTitle.isNotEmpty && wantTitle.isNotEmpty) {
    if (hitTitle == wantTitle) {
      score += 60;
    } else if (hitTitle.contains(wantTitle) || wantTitle.contains(hitTitle)) {
      score += 30;
    }
  }

  final String hitArtist = normalizeMatchText(hit.artist ?? '');
  final String wantArtist = normalizeMatchText(artist ?? '');
  if (hitArtist.isNotEmpty && wantArtist.isNotEmpty) {
    if (hitArtist == wantArtist) {
      score += 30;
    } else if (hitArtist.contains(wantArtist) ||
        wantArtist.contains(hitArtist)) {
      score += 15;
    }
  }

  final Duration? hitDuration = hit.duration;
  if (hitDuration != null &&
      hitDuration > Duration.zero &&
      duration != null &&
      duration > Duration.zero) {
    final int diff = (hitDuration - duration).inSeconds.abs();
    if (diff <= 3) {
      score += 20;
    } else if (diff <= 10) {
      score += 10;
    } else if (diff > 30) {
      // Совсем другая длительность — скорее всего, чужая запись.
      score -= 10;
    }
  }

  // При равных баллах выше та запись, у которой точно есть синхронизация.
  if (hit.hasSync == true) score += 1;
  return score;
}

/// Текст ровно выбранной записи — общий путь и для применения выбора, и для
/// предпросмотра в списке. Источники передаются явно: у вызывающих они уже
/// прочитаны из ref, а читать ref вне его времени жизни нельзя.
Future<Lyrics> _fetchHit(
  LyricsTrackHit hit, {
  required LrclibSource lrclib,
  required KugouSource kugou,
  required UnisonSource unison,
  required PaxsenixSource paxsenix,
  required String musixmatchKey,
}) {
  switch (hit.source) {
    case LyricsSource.lrclib:
      return lrclib.fetchHit(hit);
    case LyricsSource.kugou:
      return kugou.fetchHit(hit);
    case LyricsSource.unison:
      return unison.fetchHit(hit);
    case LyricsSource.musixmatch:
      return paxsenix.fetchHit(hit, apiKey: musixmatchKey);
    case LyricsSource.auto:
    case LyricsSource.music:
    case LyricsSource.subtitles:
    case LyricsSource.betterLyrics:
    case LyricsSource.youlyPlus:
      // Эти источники списком не ищут — выбранной записи у них не бывает.
      return Future<Lyrics>.value(Lyrics.none);
  }
}

/// Предпросмотр текста найденной записи — первые строки прямо в карточке.
///
/// `autoDispose` обязателен: записей в списке бывает 10–20, и грузить текст
/// для всех сразу — это столько же сетевых запросов впустую. С `autoDispose`
/// и `ListView.builder` запрос уходит только за теми карточками, что реально
/// построены (то есть видны на экране).
final lyricsHitPreviewProvider =
    FutureProvider.autoDispose.family<Lyrics, LyricsTrackHit>((ref, hit) async {
  final LrclibSource lrclib = ref.watch(lrclibSourceProvider);
  final KugouSource kugou = ref.watch(kugouSourceProvider);
  final UnisonSource unison = ref.watch(unisonSourceProvider);
  final PaxsenixSource paxsenix = ref.watch(paxsenixSourceProvider);
  final String musixmatchKey = ref.watch(
    settingsControllerProvider.select((AppSettings s) => s.musixmatchApiKey),
  );

  try {
    // Бюджет тот же, что у поиска: молчащая база не должна держать карточку
    // в «загрузке». Ошибка и пустой ответ одинаково означают «текста нет» —
    // карточка покажет это подписью, а не исключением.
    return await _fetchHit(
      hit,
      lrclib: lrclib,
      kugou: kugou,
      unison: unison,
      paxsenix: paxsenix,
      musixmatchKey: musixmatchKey,
    ).timeout(_lyricsSourceBudget, onTimeout: () => Lyrics.none);
  } on Object {
    return Lyrics.none;
  }
});

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

/// Бюджет одного источника: дольше ждать базу бессмысленно — она либо
/// недоступна, либо не нашла текст, а пользователь всё это время видит
/// «идёт поиск».
const Duration _lyricsSourceBudget = Duration(seconds: 5);

/// Дедлайн всего поиска: терминальное состояние выставляется не позже него,
/// даже если какая-то база всё ещё молчит. Бюджет источника короче дедлайна,
/// поэтому в норме сюда попадают уже все ответы.
const Duration _lyricsSearchDeadline = Duration(seconds: 6);

/// Читает кэш текстов, не задерживая поиск дольше ~300 мс.
///
/// Недоступный или медленный файл — это просто отсутствие кэша: поиск идёт
/// дальше по сети, а не ждёт диск.
Future<Map<LyricsSource, Lyrics>> _readCachedLyrics(
  LyricsCache cache,
  String videoId,
) async {
  try {
    return await cache.read(videoId).timeout(const Duration(milliseconds: 300));
  } on TimeoutException {
    return const <LyricsSource, Lyrics>{};
  } on Object catch (error) {
    debugPrint('[Lyrics] кэш недоступен: $error');
    return const <LyricsSource, Lyrics>{};
  }
}

/// Текст песни: асинхронный параллельный поиск по всем источникам.
///
/// Почему переписано: раньше источники опрашивались последовательно, поэтому
/// ожидание складывалось из времени самого медленного, а текст появлялся только
/// в самом конце. Теперь все базы запускаются одновременно (как
/// `LyricsHelper.getAllLyrics` в ArchiveTune), а результат приходит потоком:
/// каждый ответ сразу попадает в список вариантов, отсортированный по
/// совместимости. Лучший виден ещё до того, как ответят все.
///
/// Выбранный вручную источник остаётся авторитетным: показываем ровно его
/// результат, а пустота остаётся пустотой. Режим «Авто» показывает лучший по
/// оценке [scoreLyrics].
///
/// Если для трека выбрана конкретная запись ([manualLyricsSelectionProvider]),
/// перебора источников нет вовсе: берём текст ровно этой записи и отдаём его
/// единственным вариантом.
///
/// Перед сетевыми запросами отдаются уже найденные тексты из дискового кэша
/// ([lyricsCacheProvider]) — они видны сразу, а сеть лишь уточняет и пополняет
/// кэш. Поиск завершается по дедлайну, а не по самой медленной базе.
final lyricsProvider =
    StreamProvider.family<LyricsSearchState, LyricsRequest>((ref, request) {
  final StreamController<LyricsSearchState> controller =
      StreamController<LyricsSearchState>();
  bool disposed = false;
  ref.onDispose(() {
    disposed = true;
    controller.close();
  });

  // Все зависимости читаем синхронно, пока ref жив: дальше идут сетевые
  // ожидания, а обращаться к ref после dispose нельзя.
  final CatalogSource catalog = ref.watch(catalogSourceProvider);
  final BetterLyricsSource betterLyrics =
      ref.watch(betterLyricsSourceProvider);
  final YouLyPlusSource youlyPlus = ref.watch(youlyPlusSourceProvider);
  final LrclibSource lrclib = ref.watch(lrclibSourceProvider);
  final KugouSource kugou = ref.watch(kugouSourceProvider);
  final UnisonSource unison = ref.watch(unisonSourceProvider);
  final PaxsenixSource paxsenix = ref.watch(paxsenixSourceProvider);
  final LyricsCache cache = ref.watch(lyricsCacheProvider);
  final String musixmatchKey = ref.watch(
    settingsControllerProvider.select((AppSettings s) => s.musixmatchApiKey),
  );

  // Выбранная вручную запись важнее обычного поиска: если она есть, берём
  // текст ровно её, а не перебираем источники.
  final LyricsTrackHit? selectedHit = ref.watch(
    manualLyricsSelectionProvider.select(
      (Map<String, LyricsTrackHit> m) => m[request.videoId],
    ),
  );

  final bool externalOk = request.canQueryExternal;
  final String? title = request.title?.trim();
  final String? artist = request.artist?.trim();
  final String? album = request.album;
  final Duration? duration = request.duration;

  // Ограничиваем ожидание каждой базы: если она недоступна (бывает за
  // блокировками), не заставляем пользователя ждать её таймаут — вариант
  // просто не попадёт в список.
  Future<Lyrics> bounded(Future<Lyrics> future) =>
      future.timeout(_lyricsSourceBudget, onTimeout: () => Lyrics.none);

  Future<Lyrics> fetchSource(LyricsSource target) {
    switch (target) {
      case LyricsSource.music:
        return bounded(catalog.lyrics(request.videoId));
      case LyricsSource.subtitles:
        return bounded(catalog.subtitleLyrics(request.videoId));
      // Unison индексируется по id видео и в метаданных не нуждается —
      // его пробуем всегда.
      case LyricsSource.unison:
        return bounded(unison.fetch(
          videoId: request.videoId,
          title: title,
          artist: artist,
          album: album,
          duration: duration,
        ));
      // Остальные базы ищут по названию и исполнителю: без них — пропуск.
      case LyricsSource.betterLyrics:
        if (!externalOk) return Future<Lyrics>.value(Lyrics.none);
        return bounded(betterLyrics.fetch(
          title: title!,
          artist: artist!,
          album: album,
          duration: duration,
          // Сервис привязывает песню к видео — передаём идентификатор.
          videoId: request.videoId,
        ));
      case LyricsSource.youlyPlus:
        if (!externalOk) return Future<Lyrics>.value(Lyrics.none);
        return bounded(youlyPlus.fetch(
          title: title!,
          artist: artist!,
          album: album,
          duration: duration,
        ));
      case LyricsSource.lrclib:
        if (!externalOk) return Future<Lyrics>.value(Lyrics.none);
        return bounded(lrclib.fetch(
          title: title!,
          artist: artist!,
          album: album,
          duration: duration,
        ));
      case LyricsSource.kugou:
        if (!externalOk) return Future<Lyrics>.value(Lyrics.none);
        return bounded(kugou.fetch(
          title: title!,
          artist: artist!,
          duration: duration,
        ));
      case LyricsSource.musixmatch:
        // Paxsenix требует ключ; без ключа — пропуск.
        if (!externalOk || musixmatchKey.isEmpty) {
          return Future<Lyrics>.value(Lyrics.none);
        }
        return bounded(paxsenix.fetch(
          title: title!,
          artist: artist!,
          apiKey: musixmatchKey,
          duration: duration,
        ));
      case LyricsSource.auto:
        return Future<Lyrics>.value(Lyrics.none);
    }
  }

  // Текст ровно выбранной записи: источник знает, как её скачать.
  Future<Lyrics> fetchHit(LyricsTrackHit hit) => bounded(_fetchHit(
        hit,
        lrclib: lrclib,
        kugou: kugou,
        unison: unison,
        paxsenix: paxsenix,
        musixmatchKey: musixmatchKey,
      ));

  controller.add(const LyricsSearchState(loading: true));

  // Порядок источников — из настроек (как в ArchiveTune): первый в списке
  // приоритетнее. Влияет на тай-брейк при равном качестве текста.
  final List<LyricsSource> order = ref.read(
    settingsControllerProvider.select(
      (AppSettings s) => s.lyricsProviderOrder,
    ),
  );

  unawaited(() async {
    final List<LyricsCandidate> found = <LyricsCandidate>[];

    // Ранг источника в общем порядке: нужен и сетевым ответам, и закэшированным,
    // чтобы тай-брейк совместимости (см. scoreLyrics) у них совпадал. Тексты
    // YouTube — в самом низу: у них нет метаданных для оценки.
    final Map<LyricsSource, int> ranks = <LyricsSource, int>{
      for (int i = 0; i < order.length; i++) order[i]: i,
      LyricsSource.subtitles: order.length,
      LyricsSource.music: order.length + 1,
    };
    int rankOf(LyricsSource source) => ranks[source] ?? order.length + 2;

    // Терминальное состояние выставляется один раз: ответы, пришедшие после
    // дедлайна, не должны снова включать «идёт поиск».
    bool terminal = false;

    void accept(LyricsSource source, int rank, Lyrics lyrics) {
      if (disposed || terminal || lyrics.isEmpty) return;
      final LyricsScore score = scoreLyrics(
        lyrics: lyrics,
        rank: rank,
        requestTitle: title,
        requestArtist: artist,
        requestDuration: duration,
      );
      // Один источник — один вариант: свежий сетевой ответ заменяет
      // закэшированный, а не показывается рядом с ним.
      found.removeWhere((LyricsCandidate c) => c.source == source);
      found.add(LyricsCandidate.from(
        source: source,
        lyrics: lyrics,
        score: score.value,
        reasons: score.reasons,
      ));
      // Балл уже включает тай-брейк по приоритету источника (см. scoreLyrics),
      // поэтому равных баллов у разных рангов не бывает и порядок стабилен.
      found.sort((LyricsCandidate a, LyricsCandidate b) =>
          b.score.compareTo(a.score));
      if (disposed) return;
      // Отмечаем трек как «с текстом» — по этой отметке в списках появляется
      // значок, поэтому она ставится только для непустого результата.
      ref.read(lyricsAvailabilityProvider.notifier).mark(request.videoId);
      controller.add(LyricsSearchState(
        candidates: List<LyricsCandidate>.of(found),
        loading: true,
      ));
    }

    final List<Future<void>> tasks = <Future<void>>[];

    // Запуск источника: синхронная ошибка (маловероятна, но возможна) не
    // должна ронять весь поиск — просто пропускаем этот источник.
    void spawn(LyricsSource source) {
      final int rank = rankOf(source);
      try {
        tasks.add(fetchSource(source).then<void>(
          (Lyrics lyrics) {
            // В кэш — только непустой ответ: пустым нельзя затирать уже
            // найденный текст. Запись не ждём: на показ она не влияет.
            if (!lyrics.isEmpty) {
              unawaited(cache.write(request.videoId, source, lyrics));
            }
            accept(source, rank, lyrics);
          },
          // Асинхронная ошибка одной базы тоже не роняет поиск.
          onError: (Object _, StackTrace _) {},
        ));
      } on Object catch (error) {
        debugPrint('[Lyrics] источник ${source.name} пропущен: $error');
      }
    }

    try {
      if (selectedHit != null) {
        // Выбрана конкретная запись: не перебираем источники, а берём её
        // текст. Пустой ответ остаётся пустым — подмены нет.
        final Lyrics lyrics = await fetchHit(selectedHit);
        if (!lyrics.isEmpty) {
          unawaited(cache.write(request.videoId, selectedHit.source, lyrics));
        }
        accept(selectedHit.source, rankOf(selectedHit.source), lyrics);
        return;
      }

      // Сначала кэш: пользователь видит уже найденный текст сразу, не ожидая
      // ни одной базы. Чтение ограничено ~300 мс, поэтому недоступный диск не
      // задерживает поиск.
      final Map<LyricsSource, Lyrics> cached =
          await _readCachedLyrics(cache, request.videoId);
      for (final MapEntry<LyricsSource, Lyrics> item in cached.entries) {
        accept(item.key, rankOf(item.key), item.value);
      }

      for (final LyricsSource source in order) {
        spawn(source);
      }

      // Тексты YouTube — последними и в самом низу списка: у них нет
      // метаданных, поэтому при равной синхронизации внешняя база
      // всегда предпочтительнее.
      spawn(LyricsSource.subtitles);
      spawn(LyricsSource.music);

      // Завершаемся по дедлайну, а не по самой медленной базе: иначе меню
      // крутилось бы, пока кто-то молчит. Уже полученные варианты остаются
      // в `found`, так что досрочное завершение их не теряет.
      await Future.any<void>(<Future<void>>[
        Future.wait(tasks),
        Future<void>.delayed(_lyricsSearchDeadline),
      ]);
    } on Object catch (error) {
      debugPrint('[Lyrics] поиск прерван: $error');
    } finally {
      // Терминальное состояние выставляем всегда, иначе интерфейс навсегда
      // остался бы в «идёт поиск».
      if (!disposed) {
        terminal = true;
        controller.add(LyricsSearchState(
          candidates: List<LyricsCandidate>.of(found),
          loading: false,
        ));
      }
    }
  }());

  return controller.stream;
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
