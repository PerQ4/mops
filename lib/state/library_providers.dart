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

/// Плейлисты пользователя.
final FutureProvider<List<Playlist>> likedPlaylistsProvider =
    FutureProvider<List<Playlist>>((ref) async {
  if (!ref.watch(authControllerProvider).isSignedIn) return const <Playlist>[];
  return ref.watch(librarySourceProvider).likedPlaylists();
});

/// Лайкнутые треки.
final FutureProvider<List<Track>> likedSongsProvider =
    FutureProvider<List<Track>>((ref) async {
  if (!ref.watch(authControllerProvider).isSignedIn) return const <Track>[];
  return ref.watch(librarySourceProvider).likedSongs();
});

/// Множество id лайкнутых треков — единый источник правды для «сердца».
///
/// Раньше каждый экран сам сверялся с [likedSongsProvider] и держал локальный
/// флаг, а островок плеера вообще только добавлял лайк. Из-за этого лайк,
/// поставленный в одном месте, не был виден в другом, а повторное нажатие
/// ставило лайк ещё раз вместо снятия. Теперь состояние одно на всё
/// приложение, поэтому все кнопки показывают одно и то же.
class LikedIdsController extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    // Стартовое значение берём из уже загруженного списка (если успел прийти):
    // в отличие от `watch`, `read` не подписывает нотификатор, поэтому
    // перезагрузка списка не пересоздаёт его и не сбрасывает оптимистичный
    // лайк. Дальнейшие обновления ловим через `listen` ниже.
    final List<Track>? loaded = ref.read(likedSongsProvider).asData?.value;

    // Выход из аккаунта очищает множество: иначе на экране входа остались бы
    // чужие лайки.
    ref.listen(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
      (bool? _, bool signedIn) {
        if (!signedIn) state = <String>{};
      },
    );

    // Серверная правда — список «Мне нравится». Когда он загрузился или
    // перезагрузился, приводим множество к нему.
    ref.listen<AsyncValue<List<Track>>>(
      likedSongsProvider,
      (AsyncValue<List<Track>>? _, AsyncValue<List<Track>> next) {
        final List<Track>? songs = next.asData?.value;
        // Пока идёт загрузка, значение не трогаем: иначе только что
        // поставленный лайк мигнул бы и пропал.
        if (songs == null) return;
        state = songs.map((Track t) => t.id).toSet();
      },
    );

    return loaded?.map((Track t) => t.id).toSet() ?? <String>{};
  }

  /// Ставит или снимает лайк, меняя множество оптимистично.
  ///
  /// Сердце реагирует на нажатие сразу, не дожидаясь сети; при ошибке
  /// состояние откатывается, а ошибка пробрасывается наверх — интерфейс
  /// показывает сообщение.
  Future<void> toggle(String videoId) async {
    final Set<String> before = state;
    final bool liked = !before.contains(videoId);

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
      state = before;
      rethrow;
    }
  }
}

final NotifierProvider<LikedIdsController, Set<String>> likedIdsProvider =
    NotifierProvider<LikedIdsController, Set<String>>(LikedIdsController.new);

/// Все сохранённые треки (включая добавленные вручную).
final FutureProvider<List<Track>> librarySongsProvider =
    FutureProvider<List<Track>>((ref) async {
  if (!ref.watch(authControllerProvider).isSignedIn) return const <Track>[];
  return ref.watch(librarySourceProvider).librarySongs();
});

/// Исполнители, чьи треки сохранены.
final FutureProvider<List<Artist>> libraryArtistsProvider =
    FutureProvider<List<Artist>>((ref) async {
  if (!ref.watch(authControllerProvider).isSignedIn) return const <Artist>[];
  return ref.watch(librarySourceProvider).libraryArtists();
});

/// Каналы, на которые оформлена подписка.
final FutureProvider<List<Artist>> subscriptionsProvider =
    FutureProvider<List<Artist>>((ref) async {
  if (!ref.watch(authControllerProvider).isSignedIn) return const <Artist>[];
  return ref.watch(librarySourceProvider).subscriptions();
});
