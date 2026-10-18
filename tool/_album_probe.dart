// Временный инструмент: что отдаёт InnerTube про альбом конкретного трека.
//
// Запуск: dart run tool/_album_probe.dart
//
// Зачем: жалоба «клик по названию трека в карточке должен открывать альбом».
// Сейчас у карточек трека альбома почти нет, поэтому нажатие запускает трек.
// Здесь смотрим, где в ответе `next` реально лежит идентификатор альбома
// (`MPREb_…`) и что наш разбор достаёт из карточек главной.
import 'dart:io';

import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/innertube/renderer.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:mops/data/models/models.dart';
import 'package:mops/data/sources/catalog_source.dart';

/// Собирает все идентификаторы альбомов (`MPRE…`) из ответа вместе с путём,
/// по которому они найдены.
///
/// Идём по всему дереву: у разных разметок альбом лежит то в
/// `musicTwoRowItemRenderer`, то в обычной строке — фиксированный путь
/// ненадёжен, а нам нужно и «есть ли альбом», и «где именно».
List<({String id, String path})> _albumIds(dynamic node) {
  final List<({String id, String path})> found =
      <({String id, String path})>[];
  void walk(dynamic current, String path) {
    if (current is List) {
      for (int i = 0; i < current.length; i++) {
        walk(current[i], '$path[$i]');
      }
      return;
    }
    if (current is! Map) return;

    final dynamic endpoint = current['browseEndpoint'];
    if (endpoint is Map) {
      final String? id = endpoint['browseId']?.toString();
      if (id != null && id.startsWith('MPRE')) {
        final bool known = found.any((({String id, String path}) e) =>
            e.id == id && e.path == path);
        if (!known) found.add((id: id, path: '$path.browseEndpoint'));
      }
    }
    for (final dynamic entry in current.entries) {
      walk(entry.value, '$path.${entry.key}');
    }
  }

  walk(node, r'$');
  return found;
}

/// Печатает двухрядные карточки главной: что за элемент и что дал разбор.
void _printCard(BrowseItem item) {
  if (item is TrackItem) {
    final AlbumRef? album = item.track.album;
    stdout.writeln('  • ТРЕК "${item.track.title}" videoId=${item.track.id}');
    stdout.writeln('      артисты: '
        '${item.track.artists.map((ArtistRef a) => "${a.name}#${a.id}").join(" / ")}');
    stdout.writeln('      альбом из карточки: '
        '${album == null ? "нет" : "\"${album.name}\" id=${album.id}"}');
  } else if (item is AlbumItem) {
    stdout.writeln('  • АЛЬБОМ "${item.album.title}" id=${item.album.id}');
  } else if (item is ArtistItem) {
    stdout.writeln('  • ИСПОЛНИТЕЛЬ "${item.artist.name}" id=${item.artist.id}');
  } else if (item is PlaylistItem) {
    stdout.writeln('  • ПЛЕЙЛИСТ "${item.playlist.title}" id=${item.playlist.id}');
  }
}

Future<void> main() async {
  await BypassManager.instance.apply(const AntiDpiConfig());
  final InnerTubeClient client = InnerTubeClient(locale: 'ru', region: 'RU');
  final CatalogSource catalog = CatalogSource(client);

  try {
    // 1. Берём карточки треков с главной — на живом ответе, как в приложении.
    stdout.writeln('========== КАРТОЧКИ ГЛАВНОЙ ==========');
    final List<BrowseSection> sections = await catalog.home();
    final List<TrackItem> trackCards = <TrackItem>[
      for (final BrowseSection s in sections)
        ...s.items.whereType<TrackItem>(),
    ];
    stdout.writeln('секций: ${sections.length}, карточек-треков: '
        '${trackCards.length}');
    for (final TrackItem card in trackCards.take(5)) {
      _printCard(card);
    }

    // 2. Для нескольких треков смотрим ответ `next` и ищем альбом.
    final List<String> videoIds = trackCards
        .map((TrackItem t) => t.track.id)
        .toSet()
        .toList();

    if (videoIds.isEmpty) {
      // Фолбэк: главная не дала карточек треков — берём треки альбома.
      stdout.writeln('карточек-треков нет, ищем через поиск…');
      final List<BrowseSection> found = await catalog.search('кровосток');
      for (final BrowseSection s in found) {
        for (final BrowseItem item in s.items) {
          if (item is TrackItem) videoIds.add(item.track.id);
        }
      }
    }

    stdout.writeln('\n========== ОТВЕТ next ДЛЯ ТРЕКОВ ==========');
    for (final String videoId in videoIds.take(3)) {
      final Map<String, dynamic> next = await client.next(videoId);
      final List<({String id, String path})> albums = _albumIds(next);
      final List<dynamic> twoRow =
          traverseList(next, <String>['musicTwoRowItemRenderer']);

      stdout.writeln('\n— videoId=$videoId');
      stdout.writeln('  musicTwoRowItemRenderer в next: ${twoRow.length}');
      for (final dynamic row in twoRow.take(8)) {
        if (row is! Map) continue;
        final String title =
            traverseString(row, <String>['title', 'runs', 'text']) ??
                traverseString(row, <String>['title', 'simpleText']) ??
                '?';
        final String? browseId = traverseString(row, <String>[
          'navigationEndpoint', 'browseEndpoint', 'browseId',
        ]);
        final String? pageType = traverseString(row, <String>[
          'navigationEndpoint', 'browseEndpoint',
          'browseEndpointContextSupportedConfigs',
          'browseEndpointContextMusicConfig', 'pageType',
        ]);
        stdout.writeln('    "$title" | browseId=$browseId | pageType=$pageType');
      }
      for (final ({String id, String path}) album in albums) {
        stdout.writeln('  MPRE-id: ${album.id}');
        stdout.writeln('    путь: ${album.path}');
      }
      if (albums.isEmpty) stdout.writeln('  MPRE-id: нет');

      // Печатаем байлайн именно того panel-элемента, что соответствует
      // запрошенному треку: там рядом с исполнителями лежит ссылка на альбом.
      // По pageType видно, что альбом — это ALBUM, а не ARTIST.
      for (final dynamic panel
          in traverseList(next, <String>['playlistPanelVideoRenderer'])) {
        if (panel is! Map) continue;
        if ('${panel['videoId']}' != videoId) continue;
        final List<dynamic> runs =
            traverseList(panel, <String>['longBylineText', 'runs']);
        for (final dynamic run in runs) {
          if (run is! Map) continue;
          final String text = (run['text'] ?? '').toString().trim();
          final String? browseId = traverseString(run, <String>[
            'navigationEndpoint', 'browseEndpoint', 'browseId',
          ]);
          final String? pageType = traverseString(run, <String>[
            'navigationEndpoint', 'browseEndpoint',
            'browseEndpointContextSupportedConfigs',
            'browseEndpointContextMusicConfig', 'pageType',
          ]);
          stdout.writeln('    run "$text" | browseId=$browseId | '
              'pageType=$pageType');
        }
        break;
      }

      // 3. Проверяем, что первый найденный id — действительно альбом:
      // у него должно быть название и треки.
      if (albums.isNotEmpty) {
        final Album album = await catalog.album(albums.first.id);
        stdout.writeln('  проверка album(${albums.first.id}): '
            '"${album.title}" треков=${album.tracks.length}');
      }

      // 4. Тот же путь, что теперь использует клик по названию трека.
      final AlbumRef? resolved = await catalog.trackAlbum(videoId);
      stdout.writeln('  CatalogSource.trackAlbum → '
          '${resolved == null ? "null (запустим трек)" : "\"${resolved.name}\" id=${resolved.id}"}');
    }

    stdout.writeln('\nИТОГ: см. строки «найденные MPRE-id» выше.');
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
