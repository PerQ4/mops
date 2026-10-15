// Временный инструмент: показывает, что приходит в треках альбома.
//
// Запуск: dart run tool/album_probe.dart [запрос]
//
// Зачем: жалоба «включаешь альбом — у каждого трека исполнитель Неизвестный».
// Нужно увидеть, приходит ли исполнитель в строках альбома вообще, и что из
// них делает наш парсер вместе с подстановкой из шапки.
import 'dart:convert';
import 'dart:io';

import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/innertube/renderer.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:mops/data/models/models.dart';
import 'package:mops/data/sources/browse_parser.dart';
import 'package:mops/data/sources/catalog_source.dart';

const String _sessionPath =
    '/home/perqa/.local/share/com.mops.mops/session.json';

/// Ищет в ответе поиска идентификатор альбома.
///
/// Двухрядных элементов (`musicTwoRowItemRenderer`) поиск сейчас почти не
/// отдаёт — альбомы приходят обычными строками, а ссылка на альбом лежит
/// внутри `browseEndpoint` с типом страницы `MUSIC_PAGE_TYPE_ALBUM`.
/// Поэтому обходим дерево целиком, а не ищем по одному пути.
String? _findAlbumId(dynamic node) {
  String? found;
  void walk(dynamic current) {
    if (found != null) return;
    if (current is List) {
      for (final dynamic item in current) {
        walk(item);
      }
      return;
    }
    if (current is! Map) return;

    final dynamic endpoint = current['browseEndpoint'];
    if (endpoint is Map) {
      final String? pageType = traverseString(endpoint, <String>[
        'browseEndpointContextSupportedConfigs',
        'browseEndpointContextMusicConfig',
        'pageType',
      ]);
      final String? id = endpoint['browseId']?.toString();
      if (pageType == 'MUSIC_PAGE_TYPE_ALBUM' &&
          id != null &&
          id.startsWith('MPRE')) {
        found = id;
        return;
      }
    }
    for (final dynamic value in current.values) {
      walk(value);
    }
  }

  walk(node);
  return found;
}

/// Печатает runs одной колонки строки трека.
void _printColumn(dynamic column, int index) {
  final List<dynamic> runs = traverseList(column, <String>[
    'musicResponsiveListItemFlexColumnRenderer',
    'text',
    'runs',
  ]);
  final List<String> parts = <String>[];
  for (final dynamic run in runs) {
    if (run is! Map) continue;
    final String text = (run['text'] ?? '').toString().trim();
    final String? browseId = traverseString(run, <String>[
      'navigationEndpoint',
      'browseEndpoint',
      'browseId',
    ]);
    parts.add(browseId == null ? '"$text"' : '"$text"→$browseId');
  }
  stdout.writeln('    колонка[$index]: ${parts.join('  ')}');
}

Future<void> main(List<String> args) async {
  await BypassManager.instance.apply(const AntiDpiConfig());

  final String cookieString = (jsonDecode(
    File(_sessionPath).readAsStringSync(),
  ) as Map<String, dynamic>)['cookieString'] as String;
  final CookieAuth auth = CookieAuth(cookieString);
  final InnerTubeClient client = InnerTubeClient(
    auth: auth,
    locale: 'ru',
    region: 'RU',
  );
  final CatalogSource catalog = CatalogSource(client);

  final String query = args.isEmpty ? 'SQWOZ BAB' : args.join(' ');

  try {
    stdout.writeln('========== ПОИСК АЛЬБОМА: "$query" ==========');
    Map<String, dynamic> search = await client.search(query);
    if (_findAlbumId(search) == null) {
      // Без фильтра двухрядных элементов больше — там и попадаются альбомы.
      search = await client.search(query);
    }
    stdout.writeln('двухрядных элементов: '
        '${traverseList(search, <String>['musicTwoRowItemRenderer']).length}');
    stdout.writeln('строк-списков: '
        '${traverseList(search, <String>['musicResponsiveListItemRenderer']).length}');
    final String? albumId = _findAlbumId(search);
    stdout.writeln('browseId альбома: $albumId');
    if (albumId == null) {
      stdout.writeln('альбом не найден — попробуйте другой запрос');
      exitCode = 1;
      return;
    }

    stdout.writeln('\n========== СЫРОЙ ОТВЕТ СТРАНИЦЫ ==========');
    final Map<String, dynamic> raw = await client.browse(albumId);
    final List<dynamic> rows =
        traverseList(raw, <String>['musicResponsiveListItemRenderer']);
    stdout.writeln('строк треков в ответе: ${rows.length}');
    stdout.writeln('подзаголовок страницы: '
        '"${BrowseParser.pageSubtitle(raw)}"');
    for (final dynamic row in rows.take(3)) {
      if (row is! Map) continue;
      final List<dynamic> columns =
          traverseList(row, <String>['flexColumns']).whereType<Map>().toList();
      for (int i = 0; i < columns.length; i++) {
        _printColumn(columns[i], i);
      }
    }

    stdout.writeln('\n========== ШАПКА СТРАНИЦЫ ==========');
    for (final String key in <String>[
      'musicDetailHeaderRenderer',
      'musicResponsiveHeaderRenderer',
      'musicImmersiveHeaderRenderer',
      'musicEditablePlaylistDetailHeaderRenderer',
    ]) {
      final List<dynamic> headers =
          traverseList(raw, <String>[key]).whereType<Map>().toList();
      if (headers.isEmpty) continue;
      stdout.writeln('  найден $key: ${headers.length}');
      for (final Map header in headers.take(1)) {
        for (final String field in <String>[
          'title',
          'subtitle',
          'straplineTextOne',
          'secondSubtitle',
        ]) {
          final List<dynamic> runs = traverseList(header, <String>[
            field,
            'runs',
          ]);
          final String text = runs
              .whereType<Map>()
              .map((dynamic r) => (r['text'] ?? '').toString())
              .join('');
          stdout.writeln('    $field: "$text" (runs: ${runs.length})');
        }
      }
    }
    stdout.writeln('  pageTitle=${BrowseParser.pageTitle(raw)}');
    stdout.writeln('  pageSubtitle=${BrowseParser.pageSubtitle(raw)}');

    stdout.writeln('\n========== ЧТО ОТДАЁТ CatalogSource.album() ==========');
    final Album album = await catalog.album(albumId);
    stdout.writeln('название: ${album.title}');
    stdout.writeln('исполнители шапки: '
        '${album.artists.map((ArtistRef a) => "${a.name}#${a.id}").join(" / ")}');
    stdout.writeln('треков: ${album.tracks.length}');
    for (final Track t in album.tracks.take(8)) {
      stdout.writeln('  • ${t.title} — artistLine="${t.artistLine}" '
          '| artists=${t.artists.map((ArtistRef a) => "${a.name}#${a.id}").join(" / ")}');
    }
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
