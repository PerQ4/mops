import 'package:flutter/material.dart';

import '../../core/theme/motion.dart';
import '../../data/models/models.dart';
import '../album/album_screen.dart';
import '../artist/artist_screen.dart';
import '../player/clip_screen.dart';
import '../player/now_playing_screen.dart';
import '../playlist/playlist_screen.dart';
import '../search/search_results_screen.dart';
import '../settings/about_screen.dart';
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

    // Переход берём из словаря движений: он же задаёт обратный ход.
    final MotionTransition motion = AppMotion.pageEnter;

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
        transitionDuration: motion.duration,
        reverseTransitionDuration: motion.reverseDuration ?? motion.duration,
        transitionsBuilder: (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child,
        ) {
          // Пока идёт жест «назад», верхний экран едет за пальцем и
          // темнеет — как в системной анимации Android. Без этого жест
          // срабатывал «молча»: экран просто исчезал в конце.
          return motion.routeTransition(
            animation: animation,
            begin: const Offset(0, 0.02),
            child: PredictiveBack(child: child),
          );
        },
      ),
    );
  }

  static Future<void> album(BuildContext context, String albumId) =>
      _push<void>(context, AlbumScreen(albumId: albumId));

  static Future<void> artist(BuildContext context, String artistId) =>
      _push<void>(context, ArtistScreen(artistId: artistId));

  /// Исполнитель из меню трека.
  ///
  /// Меню открывают и в списках, и в полноэкранном плеере, поэтому переход
  /// идёт через [_openInMainWindow]: из плеера страница должна открыться после
  /// его сворачивания.
  static Future<void> artistFromMenu(BuildContext context, String artistId) =>
      _openInMainWindow(context, ArtistScreen(artistId: artistId));

  /// Альбом из меню трека — см. [artistFromMenu].
  static Future<void> albumFromMenu(BuildContext context, String albumId) =>
      _openInMainWindow(context, AlbumScreen(albumId: albumId));

  /// Открывает страницу основного окна, свернув полноэкранный маршрут.
  ///
  /// Полноэкранный плеер лежит в корневом навигаторе поверх оболочки: открытая
  /// во вложенном навигаторе страница осталась бы под ним, а открытая в
  /// корневом — легла бы сверху вторым слоем. Поэтому сначала сворачиваем
  /// верхний маршрут корневого навигатора, и только потом открываем страницу —
  /// так же, как сворачивается плеер при нажатии на имя исполнителя в нём.
  static Future<void> _openInMainWindow(
    BuildContext context,
    Widget page,
  ) async {
    // Признак — сам стек: маршрут над оболочкой есть только у полноэкранных
    // экранов (плеер, клип). Флаг `rootNavigator` у меню ненадёжен: очередь
    // внутри плеера открывает то же меню, не зная, что она в плеере.
    final NavigatorState? root = rootNavigatorKey.currentState;
    if (root != null && root.canPop()) {
      await root.maybePop();
    }
    if (!context.mounted) return;
    await _push<void>(context, page);
  }

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

  /// «О приложении»: версия, ссылка на репозиторий, лицензии и проекты.
  static Future<void> about(BuildContext context) =>
      _push<void>(context, const AboutScreen());

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
