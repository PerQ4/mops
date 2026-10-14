import '../data/local/app_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';
import '../data/sources/catalog_source.dart';
import '../data/sources/library_source.dart';
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
  return ref
      .watch(catalogSourceProvider)
      .search(query.text, filter: query.filter);
});

/// Подсказки при вводе.
final searchSuggestionsProvider =
    FutureProvider.family<List<String>, String>((ref, query) async {
  return ref.watch(catalogSourceProvider).searchSuggestions(query);
});

/// Текст песни.
final lyricsProvider = FutureProvider.family<Lyrics, String>((ref, videoId) async {
  // Источник текста выбирается в настройках: вкладка «Текст» или субтитры.
  final LyricsSource source = ref.watch(
    settingsControllerProvider.select((AppSettings s) => s.lyricsSource),
  );
  final CatalogSource catalog = ref.watch(catalogSourceProvider);
  if (source == LyricsSource.subtitles) {
    final Lyrics fromSubtitles = await catalog.subtitleLyrics(videoId);
    // Если субтитров нет, не оставляем пустоту — пробуем обычный источник.
    if (!fromSubtitles.isEmpty) return fromSubtitles;
  }
  return catalog.lyrics(videoId);
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
