// Инструмент для проверки: печать в консоль здесь уместна.
// ignore_for_file: avoid_print

// Временный инструмент: что приходит в альбомах и синглах исполнителя.
//
// Запуск: dart run tool/artist_singles_check.dart [browseId]
//
// Зачем: жалоба «сингл открывает страницу музыканта вместо своей». Нужно
// увидеть идентификаторы и тип страницы, который отдаёт YouTube.
import 'dart:convert';
import 'dart:io';

import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/innertube/renderer.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:mops/data/models/models.dart';
import 'package:mops/data/sources/catalog_source.dart';

const String _sessionPath =
    '/home/perqa/.local/share/com.mops.mops/session.json';

Future<void> main(List<String> args) async {
  await BypassManager.instance.apply(const AntiDpiConfig());

  final String cookieString = (jsonDecode(
    File(_sessionPath).readAsStringSync(),
  ) as Map<String, dynamic>)['cookieString'] as String;
  final InnerTubeClient client = InnerTubeClient(
    auth: CookieAuth(cookieString),
    locale: 'ru',
    region: 'RU',
  );
  final CatalogSource catalog = CatalogSource(client);

  final String artistId =
      args.isNotEmpty ? args[0] : 'UCp9Fe4ua2fjStOfvUCRHm1w';

  try {
    print('=== исполнитель $artistId ===');
    final Artist artist = await catalog.artist(artistId);
    print('имя: ${artist.name}');
    print('id исполнителя: ${artist.id}');
    print('альбомов: ${artist.albums.length}, '
        'синглов: ${artist.singles.length}');

    void dump(String label, List<Album> albums) {
      for (final Album album in albums.take(4)) {
        print('  [$label] "${album.title}" id=${album.id} '
            '| артистов=${album.artists.map((ArtistRef a) => "${a.name}#${a.id}").join(" / ")} '
            '| треков=${album.tracks.length}');
      }
    }

    dump('альбом', artist.albums);
    dump('сингл', artist.singles);

    // Что лежит в сыром ответе: тип страницы у элементов.
    final Map<String, dynamic> raw = await client.browse(artistId);
    final List<dynamic> rows =
        traverseList(raw, <String>['musicTwoRowItemRenderer']);
    print('двухрядных элементов в ответе: ${rows.length}');
    for (final dynamic row in rows.take(8)) {
      if (row is! Map) continue;
      final String? title = traverseString(row, <String>['title', 'runs', 'text']);
      final String? browseId = traverseString(row, <String>[
        'navigationEndpoint', 'browseEndpoint', 'browseId',
      ]);
      final String? pageType = traverseString(row, <String>[
        'navigationEndpoint',
        'browseEndpoint',
        'browseEndpointContextSupportedConfigs',
        'browseEndpointContextMusicConfig',
        'pageType',
      ]);
      print('  "$title" -> $browseId (pageType=$pageType)');
    }
  } on Object catch (error, stack) {
    print('ОШИБКА: $error');
    print(stack.toString().split('\n').take(6).join('\n'));
    exitCode = 1;
  } finally {
    client.dispose();
    await BypassManager.instance.dispose();
  }
  exit(exitCode);
}
