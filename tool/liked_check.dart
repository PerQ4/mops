// Временный инструмент: проверяет, что реально отдаёт YouTube Music на
// раздел «Мне нравится» и достаёт ли из этого ответа LibrarySource.likedSongs().
//
// Запуск: dart run tool/liked_check.dart
//
// Проходит ровно тот путь, что и экран «Треки» (лайкнутые):
//   session.json → CookieAuth → InnerTubeClient.browse('VLLM') →
//   LibrarySource.likedSongs() → BrowseParser.playlistShelf().
// Печатает количество треков и первые названия, а также разметку ответа —
// так видно, приходят ли данные вообще и каким рендерером.
import 'dart:convert';
import 'dart:io';

import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:mops/data/models/models.dart';
import 'package:mops/data/sources/browse_parser.dart';
import 'package:mops/data/sources/catalog_source.dart';
import 'package:mops/data/sources/library_source.dart';
import 'package:mops/core/innertube/renderer.dart';

const String _sessionPath =
    '/home/perqa/.local/share/com.mops.mops/session.json';

Future<void> main() async {
  await BypassManager.instance.apply(const AntiDpiConfig());

  final String cookieString = (jsonDecode(
    File(_sessionPath).readAsStringSync(),
  ) as Map<String, dynamic>)['cookieString'] as String;
  final CookieAuth auth = CookieAuth(cookieString);
  stdout.writeln('SAPISID найден: ${auth.isUsable}');

  final InnerTubeClient client = InnerTubeClient(
    auth: auth,
    locale: 'ru',
    region: 'RU',
  );
  final LibrarySource library = LibrarySource(client);

  try {
    // 1. Путь приложения целиком.
    stdout.writeln('\n=== LibrarySource.likedSongs() ===');
    final List<Track> tracks = await library.likedSongs();
    stdout.writeln('  треков: ${tracks.length}');
    for (final Track t in tracks.take(10)) {
      stdout.writeln('    • ${t.title} — '
          '${t.artists.map((ArtistRef a) => a.name).join(", ")} '
          '[${t.id}]');
    }

    // 2. Сырой ответ — смотрим, какими рендерерами он пришёл.
    stdout.writeln('\n=== разбор сырого ответа browse("VLLM") ===');
    final Map<String, dynamic> raw = await client.browse(
      'VLLM',
      authenticated: true,
    );
    stdout.writeln('  ключей верхнего уровня: ${raw.keys.length}');
    stdout.writeln('  musicShelfRenderer: '
        '${traverseList(raw, <String>["musicShelfRenderer"]).length}');
    stdout.writeln('  musicPlaylistShelfRenderer: '
        '${traverseList(raw, <String>["musicPlaylistShelfRenderer"]).length}');
    stdout.writeln('  musicResponsiveListItemRenderer: '
        '${traverseList(raw, <String>["musicResponsiveListItemRenderer"]).length}');
    stdout.writeln('  musicTwoRowItemRenderer: '
        '${traverseList(raw, <String>["musicTwoRowItemRenderer"]).length}');
    stdout.writeln('  logged_in: '
        '${traverseString(raw, <String>["responseContext", "loggedIn"]) ?? "нет ключа"}');

    // Первый музыкальный рендерер — его форму и печатаем для разбора.
    final List<dynamic> shelves =
        traverseList(raw, <String>['musicShelfRenderer']);
    if (shelves.isNotEmpty) {
      stdout.writeln('\n  музыкальная полка найдена, ключи: '
          '${(shelves.first as Map).keys.join(", ")}');
    }
    final List<dynamic> playlistShelves =
        traverseList(raw, <String>['musicPlaylistShelfRenderer']);
    if (playlistShelves.isNotEmpty) {
      stdout.writeln('  playlist-полка найдена, ключи: '
          '${(playlistShelves.first as Map).keys.join(", ")}');
    }

    // 2b. Тот же запрос БЕЗ авторизации — так его делает CatalogSource.playlist.
    final Map<String, dynamic> guest = await client.browse('VLLM');
    stdout.writeln('\n=== browse("VLLM") БЕЗ авторизации (как CatalogSource.playlist) ===');
    stdout.writeln('  musicPlaylistShelfRenderer: '
        '${traverseList(guest, <String>["musicPlaylistShelfRenderer"]).length}');
    stdout.writeln('  musicResponsiveListItemRenderer: '
        '${traverseList(guest, <String>["musicResponsiveListItemRenderer"]).length}');

    // 3. Запасные browseId + список «Мне нравится» среди лайкнутых плейлистов.
    stdout.writeln('\n=== likedPlaylists() (ищем плейлист «Мне нравится») ===');
    try {
      final List<Playlist> likedPl = await library.likedPlaylists();
      stdout.writeln('  плейлистов: ${likedPl.length}');
      for (final Playlist p in likedPl) {
        stdout.writeln('    • "${p.title}" id=${p.id}');
      }
    } on Object catch (e) {
      stdout.writeln('  ошибка: $e');
    }

    for (final String browseId in <String>[
      'FEmusic_liked_videos',
      'FEmusic_liked_songs',
      'LM',
    ]) {
      stdout.writeln('\n=== browse("$browseId") ===');
      try {
        final Map<String, dynamic> other = await client.browse(
          browseId,
          authenticated: true,
        );
        stdout.writeln('  musicResponsiveListItemRenderer: '
            '${traverseList(other, <String>["musicResponsiveListItemRenderer"]).length}');
        stdout.writeln('  musicTwoRowItemRenderer: '
            '${traverseList(other, <String>["musicTwoRowItemRenderer"]).length}');
      } on Object catch (e) {
        stdout.writeln('  ошибка: $e');
      }
    }

    stdout.writeln('\n=== BrowseParser.parsePlaylistPage(raw VLLM) ===');
    final dynamic header = raw['header'];
    if (header is Map) {
      stdout.writeln('  тип header: ${header.keys.join(", ")}');
    }
    final Playlist parsed = BrowseParser.parsePlaylistPage(raw, playlistId: 'VLLM');
    stdout.writeln('  title: ${parsed.title}');
    stdout.writeln('  author: ${parsed.author}');
    stdout.writeln('  треков: ${parsed.tracks.length}');

    // 4. Путь «плейлист Мне нравится»: экран открывается с id VLLM/LM и
    //    теперь берёт данные из LibrarySource.likedSongsPlaylist().
    stdout.writeln('\n=== LibrarySource.likedSongsPlaylist() ===');
    try {
      final Playlist lp = await library.likedSongsPlaylist();
      stdout.writeln('  title: ${lp.title}');
      stdout.writeln('  треков: ${lp.tracks.length}');
      if (lp.tracks.isNotEmpty) {
        stdout.writeln('    • ${lp.tracks.first.title}');
      }
    } on Object catch (e) {
      stdout.writeln('  ошибка: $e');
    }

    // Для сравнения: старый общий путь каталога (ходит без авторизации).
    stdout.writeln('\n=== CatalogSource.playlist("LM") (для сравнения) ===');
    try {
      final Playlist lm = await CatalogSource(client).playlist('LM');
      stdout.writeln('  title: ${lm.title}');
      stdout.writeln('  author: ${lm.author}');
      stdout.writeln('  треков: ${lm.tracks.length}');
      if (lm.tracks.isNotEmpty) {
        stdout.writeln('    • ${lm.tracks.first.title}');
      }
    } on Object catch (e) {
      stdout.writeln('  ошибка: $e');
    }

    stdout.writeln('\nИТОГ: likedSongs() вернул ${tracks.length} треков.');
  } on Object catch (error, stack) {
    stdout.writeln('ОШИБКА: $error');
    stdout.writeln(stack.toString().split('\n').take(8).join('\n'));
    exitCode = 1;
  } finally {
    client.dispose();
    await BypassManager.instance.dispose();
  }
  exit(exitCode);
}
