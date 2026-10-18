import 'package:flutter/material.dart';

import '../../data/models/models.dart';
import '../album/album_screen.dart';
import '../artist/artist_screen.dart';
import '../player/clip_screen.dart';
import '../player/now_playing_screen.dart';
import '../playlist/playlist_screen.dart';
import '../search/search_results_screen.dart';
import '../settings/account_screen.dart';
import '../settings/backup_screen.dart';
import '../settings/spotify_import_screen.dart';
import '../settings/bypass_screen.dart';
import '../settings/settings_screen.dart';
import '../settings/storage_screen.dart';
import '../shell/content_navigator.dart';
import '../../widgets/back_gesture.dart';

/// Единая точка переходов.
///
/// Приложение не использует URL-роутинг: для десктопного плеера важнее
/// простота и предсказуемость, чем deep links, поэтому навигация идёт
/// через [Navigator] с «пружинным» переходом, характерным для Expressive.
///
/// Стек подэкранов живёт во вложенном навигаторе оболочки (см.
/// [contentNavigatorKey]): так плавающий док, нарисованный поверх области
/// содержимого, не перекрывается открытым подэкраном. Исключение —
/// полноэкранный плеер: он открывается в корневом навигаторе и накрывает
/// весь интерфейс.
abstract final class AppRoutes {
  static Future<T?> _push<T>(
    BuildContext context,
    Widget page, {
    bool root = false,
  }) {
    // Полноэкранный плеер — поверх всего; остальные подэкраны — во вложенный
    // навигатор, если оболочка его уже построила (иначе запасной корневой).
    final NavigatorState navigator = root
        ? Navigator.of(context, rootNavigator: true)
        : (contentNavigatorKey.currentState ?? Navigator.of(context));

    return navigator.push<T>(
      PageRouteBuilder<T>(
        // barrierDismissible включает штатное закрытие маршрута по Escape:
        // для непрозрачной страницы визуальной преграды нет, поэтому тап по
        // фону ничего не перехватывает — сменить поведение это не может.
        barrierDismissible: true,
        pageBuilder: (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) =>
            page,
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        transitionsBuilder: (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child,
        ) {
          final CurvedAnimation curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.02),
                end: Offset.zero,
              ).animate(curved),
              // Пока идёт жест «назад», верхний экран едет за пальцем и
              // темнеет — как в системной анимации Android. Без этого жест
              // срабатывал «молча»: экран просто исчезал в конце.
              child: PredictiveBack(child: child),
            ),
          );
        },
      ),
    );
  }

  /// [root] — открыть поверх всего. Нужно полноэкранному плееру: он сам
  /// лежит в корневом навигаторе, и подэкран во вложенном навигаторе остался
  /// бы у него «под» экраном (см. `showTrackMenu`).
  static Future<void> album(
    BuildContext context,
    String albumId, {
    bool root = false,
  }) =>
      _push<void>(context, AlbumScreen(albumId: albumId), root: root);

  static Future<void> artist(
    BuildContext context,
    String artistId, {
    bool root = false,
  }) =>
      _push<void>(context, ArtistScreen(artistId: artistId), root: root);

  static Future<void> playlist(BuildContext context, String playlistId) =>
      _push<void>(context, PlaylistScreen(playlistId: playlistId));

  static Future<void> nowPlaying(BuildContext context) =>
      _push<void>(context, const NowPlayingScreen(), root: true);

  /// Клип трека — во встроенном браузере. Как и плеер, открывается в корневом
  /// навигаторе: он должен накрывать весь интерфейс.
  static Future<void> clip(BuildContext context, Track track) =>
      _push<void>(context, ClipScreen(track: track), root: true);

  /// Результаты поиска по готовому запросу (переходы «настроение → выдача»).
  static Future<void> searchWithQuery(BuildContext context, String query) =>
      _push<void>(context, SearchResultsScreen(query: query));

  static Future<void> settings(BuildContext context) =>
      _push<void>(context, const SettingsScreen());

  static Future<void> account(BuildContext context) =>
      _push<void>(context, const AccountScreen());

  /// Перенос библиотеки из Spotify.
  static Future<void> spotifyImport(BuildContext context) =>
      _push<void>(context, const SpotifyImportScreen());

  static Future<void> bypass(BuildContext context) =>
      _push<void>(context, const BypassScreen());

  /// Резервная копия настроек: сохранить в файл или загрузить из файла.
  static Future<void> backup(BuildContext context) =>
      _push<void>(context, const BackupScreen());

  /// Хранилище: сколько занимают данные приложения и очистка кэша текстов.
  static Future<void> storage(BuildContext context) =>
      _push<void>(context, const StorageScreen());
}
