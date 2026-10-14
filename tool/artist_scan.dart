// Временный инструмент: ищет случаи, где парсер теряет исполнителя.
//
// Запуск: dart run tool/artist_scan.dart
//
// Проходит по разным источникам (главная, поиск, страницы исполнителя/альбома,
// библиотека, авторадио) и для каждого трека сравнивает:
//  * «настоящих» исполнителей — runs с pageType MUSIC_PAGE_TYPE_ARTIST;
//  * то, что вернул BrowseParser (имена и id).
// Печатает расхождения: где есть исполнитель со ссылкой, но парсер его не взял,
// и где вместо автора подставилось служебное слово.
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

const Set<String> _service = <String>{
  'композиция',
  'song',
  'песня',
  'видео',
  'video',
  'трек',
  'album',
  'альбом',
  'single',
  'сингл',
  'ep',
  'и',
  '·',
};

/// «Настоящие» исполнители из ЛЮБОГО столбца: run со ссылкой на артиста.
/// Заодно собираем все текстовые runs байлайна — для диагностики.
({List<ArtistRef> trueArtists, List<String> allRuns}) _truth(Map renderer) {
  final List<ArtistRef> artists = <ArtistRef>[];
  final List<String> runs = <String>[];
  for (final dynamic column
      in traverseList(renderer, <String>['flexColumns']).whereType<Map>()) {
    for (final dynamic run in traverseList(column, <String>[
      'musicResponsiveListItemFlexColumnRenderer',
      'text',
      'runs',
    ])) {
      if (run is! Map) continue;
      final String text = (run['text'] ?? '').toString().trim();
      if (text.isEmpty) continue;
      runs.add(text);
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
      final bool looksArtist = (pageType ?? '').contains('ARTIST') ||
          (browseId != null &&
              browseId.startsWith('UC') &&
              !(pageType ?? '').contains('PLAYLIST'));
      if (looksArtist && browseId != null) {
        artists.add(ArtistRef(name: text, id: browseId));
      }
    }
  }
  return (trueArtists: artists, allRuns: runs);
}

int _flagged = 0;

void _check(String source, dynamic renderer) {
  if (renderer is! Map) return;
  final Track? track = BrowseParser.responsiveItem(renderer);
  if (track == null) return;
  final bool hasNavigable = track.artists.any((ArtistRef a) => a.isNavigable);
  final bool nameIsService = track.artists.isNotEmpty &&
      track.artists.every((ArtistRef a) => _service.contains(a.name.toLowerCase()));

  // Тревога, если у трека нет исполнителя со ссылкой, но в сыром ответе он есть.
  final ({List<ArtistRef> trueArtists, List<String> allRuns}) truth = _truth(renderer);
  final bool lostArtist = !hasNavigable && truth.trueArtists.isNotEmpty;
  final bool serviceShown = nameIsService;

  if (!lostArtist && !serviceShown) return;

  _flagged++;
  stdout.writeln('\n[$source] "${track.title}" [${track.id}]');
  stdout.writeln('  все runs байлайна: ${truth.allRuns.join(" | ")}');
  stdout.writeln('  настоящие исполнители: '
      '${truth.trueArtists.map((ArtistRef a) => "${a.name}#${a.id}").join(" / ")}');
  stdout.writeln('  парсер: artistLine="${track.artistLine}" '
      '| ${track.artists.map((ArtistRef a) => "${a.name}#${a.id}").join(" / ")}');
  stdout.writeln('  >>> lostArtist=$lostArtist serviceShown=$serviceShown');
}

Future<void> main() async {
  await BypassManager.instance.apply(const AntiDpiConfig());
  final String cookieString = (jsonDecode(
    File(_sessionPath).readAsStringSync(),
  ) as Map<String, dynamic>)['cookieString'] as String;
  final InnerTubeClient client = InnerTubeClient(
    auth: CookieAuth(cookieString),
    locale: 'ru',
    region: 'RU',
  );

  Future<void> scanBrowse(String label, String browseId,
      {bool auth = false}) async {
    try {
      final Map<String, dynamic> res =
          await client.browse(browseId, authenticated: auth);
      final List<dynamic> items =
          traverseList(res, <String>['musicResponsiveListItemRenderer']);
      for (final dynamic item in items) {
        _check('$label ($browseId)', item);
      }
      stdout.writeln('  [$label] responsiv: ${items.length}');
    } on Object catch (e) {
      stdout.writeln('  [$label] ошибка: $e');
    }
  }

  Future<void> scanSearch(String label, String query, String? params) async {
    try {
      final Map<String, dynamic> res = await client.search(query, params: params);
      final List<dynamic> items =
          traverseList(res, <String>['musicResponsiveListItemRenderer']);
      for (final dynamic item in items) {
        _check('поиск "$query" ($label)', item);
      }
      stdout.writeln('  [поиск "$query" $label] responsiv: ${items.length}');
    } on Object catch (e) {
      stdout.writeln('  [поиск "$query" $label] ошибка: $e');
    }
  }

  await scanBrowse('главная', 'FEmusic_home', auth: true);
  await scanBrowse('обзор', 'FEmusic_explore');
  await scanBrowse('лайкнутые треки', 'VLLM', auth: true);
  await scanBrowse('сохранённые треки', 'FEmusic_liked_videos', auth: true);

  await scanSearch('Всё', 'shape of you', null);
  await scanSearch('Треки', 'shape of you',
      'Eg-KAQwIARAAGAAgACgAMABqChAEEAMQCRAFEAo=');
  await scanSearch('Видео', 'shape of you',
      'Eg-KAQwIABABGAAgACgAMABqChAEEAMQCRAFEAo=');
  await scanSearch('Всё', 'мираж', null);

  // Страницы исполнителя: там «Популярные треки» могут прийти без альбома.
  for (final String artist in <String>[
    'UCr_iyUANcn9OX_yy9piYoLw', // Radiohead
    'UCoUlFsQqUW8pavTeGrvJaUg', // ssshhhiiittt!
  ]) {
    await scanBrowse('исполнитель', artist);
  }

  // Авторадио (очередь) — здесь другой рендерер, но проверим и его.
  try {
    final Map<String, dynamic> res = await client.next('dQw4w9WgXcQ');
    final List<dynamic> panel =
        traverseList(res, <String>['playlistPanelVideoRenderer']);
    stdout.writeln('  [авторадио] playlistPanelVideoRenderer: ${panel.length}');
    for (final dynamic item in panel) {
      if (item is! Map) continue;
      final List<dynamic> byline = traverseList(item, <String>['longBylineText', 'runs']);
      final List<String> names = byline
          .whereType<Map>()
          .map((Map r) => (r['text'] ?? '').toString())
          .where((String s) => s.trim().isNotEmpty)
          .toList();
      final bool anyId = byline.whereType<Map>().any((Map r) =>
          traverseString(r, <String>[
            'navigationEndpoint',
            'browseEndpoint',
            'browseId',
          ]) !=
          null);
      if (names.isNotEmpty && !anyId) {
        stdout.writeln('    панель: byline=${names.join(" | ")} '
            'anyArtistId=$anyId');
      }
    }
  } on Object catch (e) {
    stdout.writeln('  [авторадио] ошибка: $e');
  }

  stdout.writeln('\nВСЕГО ПОМЕЧЕНО: $_flagged');
  client.dispose();
  await BypassManager.instance.dispose();
  exit(0);
}
