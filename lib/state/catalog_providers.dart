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

/// Главная страница.
final homeSectionsProvider = FutureProvider<List<BrowseSection>>((ref) async {
  final List<BrowseSection> sections =
      await ref.watch(catalogSourceProvider).home();
  // Видно в логе: если секций нет, проблема в доступе к сети, а не в вёрстке.
  debugPrint('[Home] секций получено: ${sections.length}');
  return sections;
});

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
