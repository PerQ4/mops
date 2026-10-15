// Инструмент для проверки: печать в консоль здесь уместна.
// ignore_for_file: avoid_print

// Временный инструмент: как разбирается карточка и куда ведёт нажатие.
//
// Запуск: dart run tool/card_kind_check.dart "запрос"
//
// Зачем: жалоба «нажимаю на подпись карточки — открывается страница
// музыканта вместо альбома». Нужно видеть сырые данные YouTube и то, что из
// них делает наш разбор.
import 'dart:convert';
import 'dart:io';

import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/innertube/renderer.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:mops/data/models/models.dart';
import 'package:mops/data/sources/browse_parser.dart';

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

  try {
    final String query = args.join(' ');
    print(query.isEmpty ? '=== карточки главной ===' : '=== поиск "$query" ===');
    final Map<String, dynamic> raw = query.isEmpty
        ? await client.browse('FEmusic_home')
        : await client.search(query);
    final List<dynamic> rows =
        traverseList(raw, <String>['musicTwoRowItemRenderer']);
    print('двухрядных карточек: ${rows.length}');
    for (final dynamic row in rows.take(60)) {
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
      final String? videoId = traverseString(row, <String>[
        'navigationEndpoint', 'watchEndpoint', 'videoId',
      ]);
      final BrowseItem? parsed = BrowseParser.twoRowItem(row);
      // Печатаем только то, где тип расходится с тем, что ждём по pageType.
      final bool looksArtist = pageType != null && pageType.contains('ARTIST');
      final bool looksAlbum = pageType != null && pageType.contains('ALBUM');
      if (!looksArtist && !looksAlbum && videoId == null) continue;
      print('  "$title" | pageType=$pageType | browseId=$browseId | videoId=$videoId');
      print('     наш разбор: ${parsed.runtimeType}'
          '${parsed is TrackItem ? " | альбом=${parsed.track.album?.name} (${parsed.track.album?.id}) | артисты=${parsed.track.artists.map((ArtistRef a) => a.name).join(", ")}" : ""}');
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
