// Временный инструмент: показывает, как СЫРОЙ ответ YouTube Music отдаёт
// исполнителя трека — текстом и/или ссылкой на страницу.
//
// Запуск: dart run tool/artist_probe.dart
//
// Зачем: жалобы «нет перехода к исполнителю» и «вместо автора — Композиция»
// имеют общий корень. Нужно увидеть живые runs flexColumns: где настоящее имя,
// где browseId исполнителя, а где служебная подпись («Композиция», «Song»).
// Печатаются и сырые runs, и то, что из них делает текущий парсер.
import 'dart:convert';
import 'dart:io';

import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/innertube/renderer.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:mops/data/models/models.dart';
import 'package:mops/data/sources/browse_parser.dart';
import 'package:mops/data/sources/library_source.dart';

const String _sessionPath =
    '/home/perqa/.local/share/com.mops.mops/session.json';

/// Печатает runs одного flexColumn: текст, browseId и pageType каждого run.
void _printColumn(dynamic column, int index) {
  final List<dynamic> runs = traverseList(column, <String>[
    'musicResponsiveListItemFlexColumnRenderer',
    'text',
    'runs',
  ]);
  stdout.writeln('    flexColumn[$index] (runs: ${runs.length}):');
  for (final dynamic run in runs) {
    if (run is! Map) continue;
    final String text = (run['text'] ?? '').toString();
    final String? browseId = traverseString(run, <String>[
      'navigationEndpoint',
      'browseEndpoint',
      'browseId',
    ]);
    final String? pageType = traverseString(run, <String>[
      'navigationEndpoint',
      'browseEndpoint',
      'browseEndpointContextSupportedConfigs',
      'browseEndpointContextMusicConfig',
      'pageType',
    ]);
    final String? watchId = traverseString(run, <String>[
      'navigationEndpoint',
      'watchEndpoint',
      'videoId',
    ]);
    stdout.writeln('      • text="${text.trim()}" '
        '| browseId=$browseId | pageType=$pageType | watchId=$watchId');
  }
}

/// Разбирает один `musicResponsiveListItemRenderer` и печатает:
/// сырые runs, результат текущего парсера и строку исполнителя.
void _dumpResponsive(Map renderer, {String? fallbackPlaylistId}) {
  final String title =
      traverseString(renderer, <String>[
            'flexColumns',
            'musicResponsiveListItemFlexColumnRenderer',
            'text',
            'runs',
            'text',
          ]) ??
          '?';
  final String? videoId = traverseString(renderer, <String>['videoId']) ??
      traverseString(renderer, <String>[
        'playlistItemData',
        'videoId',
      ]) ??
      traverseString(renderer, <String>[
        'overlay',
        'musicItemThumbnailOverlayRenderer',
        'content',
        'musicPlayButtonRenderer',
        'playNavigationEndpoint',
        'watchEndpoint',
        'videoId',
      ]);
  stdout.writeln('\n  ── ТРЕК: "$title" [videoId=$videoId]');

  final List<dynamic> columns =
      traverseList(renderer, <String>['flexColumns']).whereType<Map>().toList();
  for (int i = 0; i < columns.length; i++) {
    _printColumn(columns[i], i);
  }

  final Track? parsed = BrowseParser.responsiveItem(
    renderer,
    fallbackPlaylistId: fallbackPlaylistId,
  );
  if (parsed != null) {
    stdout.writeln('    → парсер: artistLine="${parsed.artistLine}" '
        '| artists=${parsed.artists.map((ArtistRef a) => "${a.name}#${a.id}").join(" / ")}');
  } else {
    stdout.writeln('    → парсер: null (не трек)');
  }
}

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

  try {
    // 1. Лайкнутые треки: там наверняка есть одиночные треки из релизов.
    stdout.writeln('\n========== ЛАЙКНУТЫЕ ТРЕКИ (browse VLLM) ==========');
    final Map<String, dynamic> liked = await client.browse(
      'VLLM',
      authenticated: true,
    );
    final List<dynamic> likedItems =
        traverseList(liked, <String>['musicResponsiveListItemRenderer']);
    stdout.writeln('responsiv-строк: ${likedItems.length}');
    for (final dynamic item in likedItems.take(6)) {
      if (item is Map) _dumpResponsive(item, fallbackPlaylistId: 'LM');
    }

    // 2. Поиск — там чаще всего всплывают одиночные треки («Композиция»).
    for (final String query in <String>['queen', 'radiohead', 'мираж']) {
      stdout.writeln('\n========== ПОИСК: "$query" (фильтр Треки) ==========');
      final Map<String, dynamic> res = await client.search(
        query,
        params: 'Eg-KAQwIARAAGAAgACgAMABqChAEEAMQCRAFEAo=',
      );
      final List<dynamic> items =
          traverseList(res, <String>['musicResponsiveListItemRenderer']);
      stdout.writeln('responsiv-строк: ${items.length}');
      for (final dynamic item in items.take(6)) {
        if (item is Map) _dumpResponsive(item);
      }
    }

    // 3. Итог по всему пути: что видит LibrarySource.
    stdout.writeln('\n========== ИТОГ LibrarySource.likedSongs() ==========');
    final List<Track> tracks = await LibrarySource(client).likedSongs();
    stdout.writeln('треков: ${tracks.length}');
    for (final Track t in tracks.take(10)) {
      stdout.writeln('  • ${t.title} — "${t.artistLine}" '
          '| navigable=${t.artists.any((ArtistRef a) => a.isNavigable)}');
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
