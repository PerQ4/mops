import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

import '../data/local/playlist_tags.dart';
import '../data/models/models.dart';
import '../data/sources/library_source.dart';
import 'auth_controller.dart';
import 'catalog_providers.dart';

/// Разделы личной библиотеки.
///
/// Все они требуют входа. Если пользователь не авторизован, провайдер
/// возвращает пустой список, а экран показывает приглашение войти — это
/// проще и надёжнее, чем разбрасывать проверки по интерфейсу.
///
/// Ручной сброс не нужен: каждый провайдер `watch`-ит [authControllerProvider],
/// поэтому при входе и выходе Riverpod пересчитывает их автоматически.

/// Подписан ли пользователь.
///
/// Берём только флаг входа, а не всё состояние: `select` не даёт личным
/// спискам перезапрашиваться на каждое изменение [AuthState] (`busy`, имя
/// профиля, аватар). Иначе при запуске «Мне нравится» запрашивался по
/// несколько раз подряд, и сердце оставалось пустым, пока шёл очередной
/// запрос.
bool _signedIn(Ref ref) =>
    ref.watch(authControllerProvider.select((AuthState s) => s.isSignedIn));

/// Плейлисты пользователя.
final FutureProvider<List<Playlist>> likedPlaylistsProvider =
    FutureProvider<List<Playlist>>((ref) async {
  if (!_signedIn(ref)) return const <Playlist>[];
  return ref.watch(librarySourceProvider).likedPlaylists();
});

/// Альбомы, сохранённые в библиотеке.
///
/// Отдельный раздел YouTube Music (`FEmusic_liked_albums`): вместе с
/// [likedPlaylistsProvider] он и составляет список «сохранённого» — без него
/// сохранённый альбом не подтверждался бы сервером, и кнопка на его странице
/// считала бы, что альбома в библиотеке нет.
final FutureProvider<List<Album>> likedAlbumsProvider =
    FutureProvider<List<Album>>((ref) async {
  if (!_signedIn(ref)) return const <Album>[];
  return ref.watch(librarySourceProvider).likedAlbums();
});

/// Лайкнутые треки.
final FutureProvider<List<Track>> likedSongsProvider =
    FutureProvider<List<Track>>((ref) async {
  if (!_signedIn(ref)) return const <Track>[];
  return ref.watch(librarySourceProvider).likedSongs();
});

/// Плейлист «Мне нравится» целиком — для экрана плейлиста.
///
/// Экран плейлиста не может пользоваться общим `playlistProvider`: тот ходит
/// в каталог без авторизации, и гостю лайкнутый плейлист приходит пустым.
/// Поэтому у «Мне нравится» отдельный источник, который запрашивает список
/// авторизованно и сам подставляет понятное название.
final FutureProvider<Playlist> likedSongsPlaylistProvider =
    FutureProvider<Playlist>((ref) async {
  if (!_signedIn(ref)) {
    // Без входа запрос всё равно вернул бы пустоту — показываем пустой
    // плейлист с названием, а не сетевую ошибку.
    return const Playlist(id: 'VLLM', title: 'Мне нравится');
  }
  return ref.watch(librarySourceProvider).likedSongsPlaylist();
});

/// Множество id лайкнутых треков — единый источник правды для «сердца».
///
/// Раньше каждый экран сам сверялся с [likedSongsProvider] и держал локальный
/// флаг, а островок плеера вообще только добавлял лайк. Из-за этого лайк,
/// поставленный в одном месте, не был виден в другом, а повторное нажатие
/// ставило лайк ещё раз вместо снятия. Теперь состояние одно на всё
/// приложение, поэтому все кнопки показывают одно и то же.
class LikedIdsController extends Notifier<Set<String>> {
  /// Локальные правки, ещё не подтверждённые сервером: `id → лайк`.
  ///
  /// Накладываются поверх серверного списка, поэтому перезагрузка «Мне
  /// нравится» (в том числе сразу после нашего же лайка) не «съедает» только
  /// что нажатое сердце, пока сервер не согласится.
  final Map<String, bool> _overrides = <String, bool>{};

  /// Последний полученный серверный список — чтобы краткая ошибка или
  /// повторная загрузка не гасили уже показанные лайки.
  Set<String> _lastServer = <String>{};

  @override
  Set<String> build() {
    // Выход из аккаунта очищает множество: иначе на экране входа остались бы
    // чужие лайки. `watch` заодно пересобирает состояние при входе.
    if (!_signedIn(ref)) {
      _overrides.clear();
      _lastServer = <String>{};
      return <String>{};
    }

    // Именно `watch`, а не `read` + `listen`: так новые данные списка
    // пересобирают множество через обычный `build`, и подписчики интерфейса
    // гарантированно получают новое значение. Прежний вариант заполнял
    // состояние из слушателя; если тот не срабатывал, уже лайкнутый трек
    // оставался «нелайкнутым» до перезапуска.
    final List<Track>? songs = ref.watch(likedSongsProvider).value;

    if (songs != null) {
      _lastServer = songs.map((Track t) => t.id).toSet();
    }

    // Правки, которые сервер уже подтвердил, больше не нужны.
    _overrides.removeWhere(
      (String id, bool liked) => _lastServer.contains(id) == liked,
    );

    final Set<String> ids = <String>{..._lastServer};
    _overrides.forEach((String id, bool liked) {
      if (liked) {
        ids.add(id);
      } else {
        ids.remove(id);
      }
    });
    return ids;
  }

  /// Ставит или снимает лайк, меняя множество оптимистично.
  ///
  /// Сердце реагирует на нажатие сразу, не дожидаясь сети; при ошибке
  /// состояние откатывается, а ошибка пробрасывается наверх — интерфейс
  /// показывает сообщение.
  Future<void> toggle(String videoId) async {
    final Set<String> before = state;
    final bool liked = !before.contains(videoId);

    _overrides[videoId] = liked;
    state = liked
        ? <String>{...before, videoId}
        : <String>{...before}..remove(videoId);

    try {
      await ref.read(librarySourceProvider).setLiked(videoId, liked: liked);
      // Список «Мне нравится» устарел: перечитываем его, чтобы вкладка
      // «Мне нравится» и подборки увидели правку.
      ref.invalidate(likedSongsProvider);
    } on Object {
      // Не вышло — возвращаем как было, иначе сердце соврёт.
      _overrides.remove(videoId);
      state = before;
      rethrow;
    }
  }
}

final NotifierProvider<LikedIdsController, Set<String>> likedIdsProvider =
    NotifierProvider<LikedIdsController, Set<String>>(LikedIdsController.new);

/// Каналы, на которые оформлена подписка: одно состояние на всё приложение.
///
/// Подписка уже была в слое данных (`LibrarySource.setSubscribed`) и отдельной
/// вкладкой в библиотеке, но кнопки не существовало — подписаться можно было
/// только из YouTube Music. Держим множество id с локальными правками, как у
/// лайков: кнопка реагирует сразу и показывает одно и то же на странице
/// исполнителя и в библиотеке.
class SubscribedIdsController extends Notifier<Set<String>> {
  /// Локальные правки, ещё не подтверждённые сервером: `id → подписка`.
  final Map<String, bool> _overrides = <String, bool>{};

  /// Последний серверный список — чтобы повторная загрузка не гасила уже
  /// показанную подписку.
  Set<String> _lastServer = <String>{};

  @override
  Set<String> build() {
    if (!_signedIn(ref)) {
      _overrides.clear();
      _lastServer = <String>{};
      return <String>{};
    }

    final List<Artist>? artists = ref.watch(subscriptionsProvider).value;
    if (artists != null) {
      _lastServer = artists.map((Artist a) => a.id).toSet();
    }

    _overrides.removeWhere(
      (String id, bool subscribed) => _lastServer.contains(id) == subscribed,
    );

    final Set<String> ids = <String>{..._lastServer};
    _overrides.forEach((String id, bool subscribed) {
      if (subscribed) {
        ids.add(id);
      } else {
        ids.remove(id);
      }
    });
    return ids;
  }

  /// Подписывает или отписывает, меняя состояние оптимистично.
  Future<void> toggle(String channelId) async {
    final Set<String> before = state;
    final bool subscribed = !before.contains(channelId);

    _overrides[channelId] = subscribed;
    state = subscribed
        ? <String>{...before, channelId}
        : <String>{...before}..remove(channelId);

    try {
      await ref
          .read(librarySourceProvider)
          .setSubscribed(channelId, subscribed: subscribed);
      // Вкладка «Подписки» устарела: перечитываем, чтобы список совпал.
      ref.invalidate(subscriptionsProvider);
    } on Object {
      // Не вышло — возвращаем как было, иначе кнопка соврёт.
      _overrides.remove(channelId);
      state = before;
      rethrow;
    }
  }
}

final NotifierProvider<SubscribedIdsController, Set<String>>
    subscribedIdsProvider =
    NotifierProvider<SubscribedIdsController, Set<String>>(
  SubscribedIdsController.new,
);

/// Сохранённые в библиотеке плейлисты и альбомы: одно состояние на приложение.
///
/// «Добавить в библиотеку» и у плейлиста, и у альбома — одна мутация
/// (`like/like` с `target.playlistId`), поэтому и состояние одно: кнопка на
/// обеих страницах показывает одно и то же и реагирует сразу, как у подписок.
///
/// Серверный список собирается из двух разделов библиотеки: плейлисты лежат
/// в `FEmusic_liked_playlists`, альбомы — в `FEmusic_liked_albums`. Смотрим
/// оба: если учесть только плейлисты, сохранённый альбом не подтверждался бы
/// сервером и кнопка «слетала» бы обратно после перезагрузки списка.
///
/// Ключ состояния — browse-id страницы (у альбома `MPREb_…`, у плейлиста его
/// собственный id): он есть и на странице, и в списке библиотеки. Для самой
/// мутации у альбома нужен другой id — звуковой (`OLAK5uy_…`), поэтому
/// [toggle] принимает его отдельно.
class SavedIdsController extends Notifier<Set<String>> {
  /// Локальные правки, ещё не подтверждённые сервером: `id → сохранён`.
  final Map<String, bool> _overrides = <String, bool>{};

  /// Последний серверный список — чтобы повторная загрузка не гасила уже
  /// показанное «в библиотеке».
  Set<String> _lastServer = <String>{};

  @override
  Set<String> build() {
    if (!_signedIn(ref)) {
      _overrides.clear();
      _lastServer = <String>{};
      return <String>{};
    }

    final List<Playlist>? playlists = ref.watch(likedPlaylistsProvider).value;
    final List<Album>? albums = ref.watch(likedAlbumsProvider).value;

    // Ждём оба раздела: пока хоть один не загружен, прошлый список остаётся,
    // иначе подтверждённое «в библиотеке» мигало бы пустым на каждой загрузке.
    if (playlists != null && albums != null) {
      _lastServer = <String>{
        ...playlists.map((Playlist p) => p.id),
        ...albums.map((Album a) => a.id),
      };
    }

    _overrides.removeWhere(
      (String id, bool saved) => _lastServer.contains(id) == saved,
    );

    final Set<String> ids = <String>{..._lastServer};
    _overrides.forEach((String id, bool saved) {
      if (saved) {
        ids.add(id);
      } else {
        ids.remove(id);
      }
    });
    return ids;
  }

  /// Сохраняет в библиотеку или убирает из неё, меняя состояние оптимистично.
  ///
  /// [id] — ключ состояния (browse-id страницы), [playlistId] — то, что
  /// принимает сервер (у альбома это звуковой id плейлиста).
  Future<void> toggle({
    required String id,
    required String playlistId,
  }) async {
    final Set<String> before = state;
    final bool saved = !before.contains(id);

    _overrides[id] = saved;
    state = saved
        ? <String>{...before, id}
        : <String>{...before}..remove(id);

    try {
      await ref
          .read(librarySourceProvider)
          .setSaved(playlistId: playlistId, saved: saved);
      // Оба раздела библиотеки устарели: перечитываем, чтобы списки совпали.
      ref.invalidate(likedPlaylistsProvider);
      ref.invalidate(likedAlbumsProvider);
    } on Object {
      // Не вышло — возвращаем как было, иначе кнопка соврёт.
      _overrides.remove(id);
      state = before;
      rethrow;
    }
  }
}

final NotifierProvider<SavedIdsController, Set<String>> savedIdsProvider =
    NotifierProvider<SavedIdsController, Set<String>>(SavedIdsController.new);

/// Все сохранённые треки (включая добавленные вручную).
final FutureProvider<List<Track>> librarySongsProvider =
    FutureProvider<List<Track>>((ref) async {
  if (!_signedIn(ref)) return const <Track>[];
  return ref.watch(librarySourceProvider).librarySongs();
});

/// Исполнители, чьи треки сохранены.
final FutureProvider<List<Artist>> libraryArtistsProvider =
    FutureProvider<List<Artist>>((ref) async {
  if (!_signedIn(ref)) return const <Artist>[];
  return ref.watch(librarySourceProvider).libraryArtists();
});

/// Каналы, на которые оформлена подписка.
final FutureProvider<List<Artist>> subscriptionsProvider =
    FutureProvider<List<Artist>>((ref) async {
  if (!_signedIn(ref)) return const <Artist>[];
  return ref.watch(librarySourceProvider).subscriptions();
});

/// Перечитывает всю библиотеку.
///
/// Данные кэшируются на время работы приложения, поэтому без явного сброса
/// списки («Мне нравится», плейлисты, исполнители) оставались устаревшими —
/// изменения на других устройствах подтягивались только после перезапуска.
void refreshLibrary(WidgetRef ref) {
  ref.invalidate(likedPlaylistsProvider);
  ref.invalidate(likedAlbumsProvider);
  ref.invalidate(likedSongsProvider);
  ref.invalidate(likedSongsPlaylistProvider);
  ref.invalidate(librarySongsProvider);
  ref.invalidate(libraryArtistsProvider);
  ref.invalidate(subscriptionsProvider);
}

/// Изменения состава плейлистов: добавление трека и создание плейлиста.
///
/// Мутации лежат в [LibrarySource], но после них кэш списка плейлистов
/// устаревает. Сброс держим рядом с мутацией, чтобы вызывающий не мог его
/// забыть: без него ни новый плейлист, ни добавленный трек не появились бы
/// до перезапуска.
class PlaylistEditor {
  PlaylistEditor(this._ref);

  final Ref _ref;

  /// Добавляет трек в плейлист и сбрасывает кэш затронутых списков.
  Future<void> addTrack({
    required String playlistId,
    required String videoId,
  }) async {
    await _ref
        .read(librarySourceProvider)
        .addToPlaylist(playlistId, <String>[videoId]);

    _ref.invalidate(likedPlaylistsProvider);
    // «Мне нравится» — тот же плейлист, но с отдельным экраном и отдельным
    // кэшем (`likedSongsPlaylistProvider`): без сброса добавленный трек не
    // появился бы на нём, пока приложение не перезапустят.
    if (LibrarySource.isLikedPlaylist(playlistId)) {
      _ref.invalidate(likedSongsPlaylistProvider);
      _ref.invalidate(likedSongsProvider);
    }
  }

  /// Создаёт плейлист сразу с треком.
  ///
  /// Трек передаём в `videoIds` при создании, а не отдельным запросом: иначе
  /// обрыв сети между двумя вызовами оставил бы пустой плейлист, а
  /// пользователь считал бы, что трек внутри.
  Future<void> createWithTrack({
    required String title,
    required String videoId,
  }) async {
    await _ref.read(librarySourceProvider).createPlaylist(
          title: title,
          videoIds: <String>[videoId],
        );
    _ref.invalidate(likedPlaylistsProvider);
  }
}

final Provider<PlaylistEditor> playlistEditorProvider =
    Provider<PlaylistEditor>((Ref ref) => PlaylistEditor(ref));

/// Хранилище локальных тегов — одно на приложение: держит файл и очередь
/// записи.
final Provider<PlaylistTagsStore> playlistTagsStoreProvider =
    Provider<PlaylistTagsStore>((Ref ref) => PlaylistTagsStore());

/// Теги плейлистов: «id плейлиста → набор ярлыков».
///
/// Теги локальные: в YouTube Music их нет, поэтому состоянием владеет только
/// диск, а не сервер. Чтение файла асинхронное, а состояние нужно синхронно:
/// первый кадр показывается без тегов, и они поднимаются, как только файл
/// прочитан.
class PlaylistTags extends Notifier<Map<String, Set<String>>> {
  @override
  Map<String, Set<String>> build() {
    final PlaylistTagsStore store = ref.watch(playlistTagsStoreProvider);
    unawaited(
      store.readAll().then((Map<String, Set<String>> loaded) {
        if (!ref.mounted) return;
        // Теги, назначенные в этой сессии, важнее прочитанных: они появились
        // позже и уже лежат на диске.
        state = <String, Set<String>>{...loaded, ...state};
      }),
    );
    return const <String, Set<String>>{};
  }

  /// Заменяет набор тегов плейлиста. Пустой набор означает «снять все теги» —
  /// тогда запись удаляется целиком.
  Future<void> setTags(String playlistId, Set<String> tags) async {
    if (playlistId.isEmpty) return;
    final PlaylistTagsStore store = ref.read(playlistTagsStoreProvider);

    final Set<String> clean = <String>{};
    for (final String raw in tags) {
      final String? tag = normalizePlaylistTag(raw);
      if (tag != null) clean.add(tag);
    }

    final Map<String, Set<String>> next =
        Map<String, Set<String>>.of(state);
    if (clean.isEmpty) {
      next.remove(playlistId);
      await store.remove(playlistId);
    } else {
      next[playlistId] = clean;
      await store.write(playlistId, clean);
    }
    state = next;
  }
}

final NotifierProvider<PlaylistTags, Map<String, Set<String>>>
    playlistTagsProvider =
    NotifierProvider<PlaylistTags, Map<String, Set<String>>>(PlaylistTags.new);

/// Все теги, назначенные хотя бы одному плейлисту, — для чипов-фильтров.
///
/// Список отсортирован: порядок не должен «прыгать» между кадрами, а по
/// алфавиту тег легче найти глазами, чем в порядке появления.
final Provider<List<String>> playlistTagsListProvider =
    Provider<List<String>>((Ref ref) {
  final Map<String, Set<String>> byPlaylist = ref.watch(playlistTagsProvider);
  final Set<String> all = <String>{};
  for (final Set<String> tags in byPlaylist.values) {
    all.addAll(tags);
  }
  return all.toList()..sort();
});

// ------------------------------------------------------------ боковая колонка

/// Разделы боковой библиотеки: что показывает её список.
///
/// Значки намеренно не здесь: это слой состояния, а не интерфейс, — иконки
/// подбирает панель. Так файл остаётся без зависимости от `material`.
enum LibrarySection {
  playlists('Плейлисты'),
  albums('Альбомы'),
  artists('Исполнители');

  const LibrarySection(this.label);

  final String label;
}

/// Порядок элементов списка библиотеки.
///
/// «По дате добавления» — это исходный порядок ответа YouTube, а не отдельное
/// поле: разделы библиотеки приходят от недавно добавленных к старым, но
/// отметки времени в разметке нет. Сортировка лишь сохраняет этот порядок и
/// ничего не выдумывает.
enum LibrarySort {
  recent('По дате добавления'),
  title('По названию'),
  owner('По владельцу');

  const LibrarySort(this.label);

  final String label;
}

/// Состояние боковой библиотеки: выбранный раздел, порядок и строка поиска.
///
/// Сессионное, между запусками не сохраняется: держать его в настройках
/// значило бы писать на диск на каждую букву в строке поиска.
@immutable
class LibrarySidebarState {
  const LibrarySidebarState({
    this.section = LibrarySection.playlists,
    this.sort = LibrarySort.recent,
    this.query = '',
  });

  final LibrarySection section;
  final LibrarySort sort;
  final String query;

  LibrarySidebarState copyWith({
    LibrarySection? section,
    LibrarySort? sort,
    String? query,
  }) =>
      LibrarySidebarState(
        section: section ?? this.section,
        sort: sort ?? this.sort,
        query: query ?? this.query,
      );
}

/// Управляет состоянием боковой библиотеки: раздел, порядок, поиск.
class LibrarySidebarController extends Notifier<LibrarySidebarState> {
  @override
  LibrarySidebarState build() => const LibrarySidebarState();

  void selectSection(LibrarySection section) =>
      state = state.copyWith(section: section);

  void setSort(LibrarySort sort) => state = state.copyWith(sort: sort);

  /// Строка поиска. Пустая — фильтра нет.
  void setQuery(String query) => state = state.copyWith(query: query);
}

final NotifierProvider<LibrarySidebarController, LibrarySidebarState>
    librarySidebarProvider =
    NotifierProvider<LibrarySidebarController, LibrarySidebarState>(
  LibrarySidebarController.new,
);

/// Свёрнута ли панель библиотеки — выбор пользователя в текущем сеансе.
///
/// Отдельно от настройки `sidebarCollapsed`: на среднем окне панель по
/// умолчанию свёрнута, и если бы свёрнутость выводилась только из ширины окна,
/// клик по кнопке тут же сворачивал бы панель обратно — раскрыть её стало бы
/// невозможно. `null` означает «пользователь ещё не трогал кнопку», и панель
/// берёт умолчание раскладки (см. `AppLayout.sidebarCollapsedByDefault`).
class SidebarCollapseController extends Notifier<bool?> {
  @override
  bool? build() => null;

  void set(bool collapsed) => state = collapsed;
}

final NotifierProvider<SidebarCollapseController, bool?>
    sidebarCollapseOverrideProvider =
    NotifierProvider<SidebarCollapseController, bool?>(
  SidebarCollapseController.new,
);
