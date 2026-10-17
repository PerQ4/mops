import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';
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
  ref.invalidate(likedSongsProvider);
  ref.invalidate(likedSongsPlaylistProvider);
  ref.invalidate(librarySongsProvider);
  ref.invalidate(libraryArtistsProvider);
  ref.invalidate(subscriptionsProvider);
}
