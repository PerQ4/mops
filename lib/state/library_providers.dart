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
