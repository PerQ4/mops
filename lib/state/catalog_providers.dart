import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';
import '../data/sources/catalog_source.dart';
import '../data/sources/library_source.dart';
import 'providers.dart';

/// Провайдеры доступа к каталогу YouTube Music.
///
/// `FutureProvider`/`family` дают бесплатно кэширование, состояния загрузки
/// и ошибок — в UI не нужно писать ни одной ручной проверки «а загрузилось ли».

final Provider<CatalogSource> catalogSourceProvider = Provider<CatalogSource>(
  (Ref ref) => CatalogSource(ref.watch(innerTubeProvider)),
);

final Provider<LibrarySource> librarySourceProvider = Provider<LibrarySource>(
  (Ref ref) => LibrarySource(ref.watch(innerTubeProvider)),
);

/// Главная страница.
final FutureProvider<List<BrowseSection>> homeSectionsProvider =
    FutureProvider<List<BrowseSection>>((Ref ref) async {
  return ref.watch(catalogSourceProvider).home();
});

/// Раздел «Обзор».
final FutureProvider<List<BrowseSection>> exploreSectionsProvider =
    FutureProvider<List<BrowseSection>>((Ref ref) async {
  return ref.watch(catalogSourceProvider).explore();
});

/// Произвольный публичный раздел (чарты, настроения, подкасты).
final FutureProviderFamily<List<BrowseSection>, String> browseSectionProvider =
    FutureProvider.family<List<BrowseSection>, String>(
  (Ref ref, String browseId) async {
    return ref.watch(catalogSourceProvider).browseSection(browseId);
  },
);

/// Страница альбома.
final FutureProviderFamily<Album, String> albumProvider =
    FutureProvider.family<Album, String>((Ref ref, String albumId) async {
  return ref.watch(catalogSourceProvider).album(albumId);
});

/// Страница исполнителя.
final FutureProviderFamily<Artist, String> artistProvider =
    FutureProvider.family<Artist, String>((Ref ref, String artistId) async {
  return ref.watch(catalogSourceProvider).artist(artistId);
});

/// Страница плейлиста.
final FutureProviderFamily<Playlist, String> playlistProvider =
    FutureProvider.family<Playlist, String>((Ref ref, String playlistId) async {
  return ref.watch(catalogSourceProvider).playlist(playlistId);
});

/// Результаты поиска с учётом фильтра.
///
/// В ключ входит и запрос, и фильтр, поэтому переключение вкладок
/// не сбрасывает уже загруженные результаты.
final FutureProviderFamily<List<BrowseSection>, SearchQuery>
    searchResultsProvider =
    FutureProvider.family<List<BrowseSection>, SearchQuery>(
  (Ref ref, SearchQuery query) async {
    if (query.text.trim().isEmpty) return const <BrowseSection>[];
    return ref.watch(catalogSourceProvider).search(
          query.text,
          filter: query.filter,
        );
  },
);

/// Подсказки при вводе.
final FutureProviderFamily<List<String>, String> searchSuggestionsProvider =
    FutureProvider.family<List<String>, String>((Ref ref, String query) async {
  return ref.watch(catalogSourceProvider).searchSuggestions(query);
});

/// Текст песни.
final FutureProviderFamily<Lyrics, String> lyricsProvider =
    FutureProvider.family<Lyrics, String>((Ref ref, String videoId) async {
  return ref.watch(catalogSourceProvider).lyrics(videoId);
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
