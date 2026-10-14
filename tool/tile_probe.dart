// Временный инструмент: смотрит, как парсятся «плитки» (musicTwoRowItemRenderer)
// и «лучший результат» (musicCardShelfRenderer), а также треки страниц альбомов.
//
// Запуск: dart run tool/tile_probe.dart
//
// Плитки — отдельный код-путь (BrowseParser.twoRowItem/cardShelf): он не ходит
// в flexColumns, а разбирает subtitle как текст. Одиночные треки и видео
// приходят именно так, поэтому проверяем и их.
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
  'композиция', 'song', 'песня', 'видео', 'video', 'трек', 'album',
  'альбом', 'single', 'сингл', 'ep', 'music video',
};

void _flag(String where, BrowseItem item) {
  final Track? track = item is TrackItem ? item.track : null;
  final bool nameService = track != null &&
      track.artists.isNotEmpty &&
      track.artists.every((ArtistRef a) => _service.contains(a.name.toLowerCase()));
  final bool noArtist = track != null && track.artists.isEmpty;
  if (!nameService && !noArtist) return;
  stdout.writeln('[$where] ${item.runtimeType} "${item.title}" '
      'artistLine=${track?.artistLine} '
      'artists=${track?.artists.map((ArtistRef a) => "${a.name}#${a.id}").join(" / ")} '
      '>>> nameService=$nameService noArtist=$noArtist');
}

void _dumpSubtitle(String where, dynamic renderer) {
  final List<dynamic> runs =
      traverseList(renderer, <String>['subtitle', 'runs']);
  for (final dynamic run in runs) {
    if (run is! Map) continue;
    final String text = (run['text'] ?? '').toString().trim();
    if (text.isEmpty) continue;
    final String? browseId = traverseString(run, <String>[
      'navigationEndpoint', 'browseEndpoint', 'browseId',
    ]);
    final String? pageType = traverseString(run, <String>[
      'navigationEndpoint', 'browseEndpoint',
      'browseEndpointContextSupportedConfigs',
      'browseEndpointContextMusicConfig', 'pageType',
    ]);
    stdout.writeln('    [$where] subtitle run "$text" browseId=$browseId pageType=$pageType');
  }
}

void _scanTwoRow(String where, dynamic renderer) {
  if (renderer is! Map) return;
  final BrowseItem? item = BrowseParser.twoRowItem(renderer);
  if (item == null) return;
  final String? watchId = traverseString(renderer, <String>[
    'navigationEndpoint', 'watchEndpoint', 'videoId',
  ]);
  if (item is TrackItem) {
    stdout.writeln('  [twoRow/$where] TrackItem "${item.title}" '
        'watch=$watchId artistLine="${item.track.artistLine}" '
        'artists=${item.track.artists.map((ArtistRef a) => "${a.name}#${a.id}").join(" / ")}');
    _dumpSubtitle('twoRow/$where', renderer);
  }
  _flag('twoRow/$where', item);
}

void _scanCard(String where, dynamic renderer) {
  if (renderer is! Map) return;
  final BrowseItem? item = BrowseParser.cardShelf(renderer);
  if (item == null) return;
  if (item is TrackItem) {
    stdout.writeln('  [card/$where] TrackItem "${item.title}" '
        'artistLine="${item.track.artistLine}"');
    _dumpSubtitle('card/$where', renderer);
  }
  _flag('card/$where', item);
}

Future<void> main() async {
  await BypassManager.instance.apply(const AntiDpiConfig());
  final String cookieString = (jsonDecode(
    File(_sessionPath).readAsStringSync(),
  ) as Map<String, dynamic>)['cookieString'] as String;
  final InnerTubeClient client = InnerTubeClient(
    auth: CookieAuth(cookieString), locale: 'ru', region: 'RU');

  Future<void> scan(String where, Map<String, dynamic> res) async {
    for (final dynamic r
        in traverseList(res, <String>['musicTwoRowItemRenderer'])) {
      _scanTwoRow(where, r);
    }
    for (final dynamic r
        in traverseList(res, <String>['musicCardShelfRenderer'])) {
      _scanCard(where, r);
    }
    // Альбомы: там треки лежат в musicShelfRenderer.
    final Album? album = null;
    for (final dynamic r
        in traverseList(res, <String>['musicShelfRenderer', 'contents'])) {
      if (r is! Map) continue;
      final dynamic resp = r['musicResponsiveListItemRenderer'];
      if (resp == null) continue;
      final Track? t = BrowseParser.responsiveItem(resp);
      if (t != null && t.artists.isEmpty) {
        stdout.writeln('  [shelf/$where] трек "${t.title}" без исполнителя');
      }
      // ignore: unused_local_variable
      final Album? _ = album;
    }
  }

  for (final String browse in <String>[
    'FEmusic_home', 'FEmusic_explore',
  ]) {
    stdout.writeln('\n========== browse $browse ==========');
    final Map<String, dynamic> res =
        await client.browse(browse, authenticated: true);
    await scan(browse, res);
  }

  for (final String q in <String>['shape of you', 'the weekend', 'king']) {
    for (final String? params in <String?>[null, 'Eg-KAQwIABABGAAgACgAMABqChAEEAMQCRAFEAo=']) {
      stdout.writeln('\n========== search "$q" params=$params ==========');
      final Map<String, dynamic> res = await client.search(q, params: params);
      await scan('search:$q', res);
    }
  }

  // Страницы альбомов: треки в них идут без исполнителя в байлайне.
  for (final String album in <String>[
    'MPREb_DciERiuADkS', // Pablo Honey
    'MPREb_bxJunypDpWa', // Снова вместе
  ]) {
    stdout.writeln('\n========== album $album (parseAlbumPage) ==========');
    final Map<String, dynamic> res = await client.browse(album);
    final Album parsed =
        BrowseParser.parseAlbumPage(res, albumId: album);
    stdout.writeln('  альбом="${parsed.title}" artists='
        '${parsed.artists.map((ArtistRef a) => "${a.name}#${a.id}").join(" / ")}');
    for (final Track t in parsed.tracks.take(4)) {
      stdout.writeln('    трек "${t.title}" artistLine="${t.artistLine}" '
          'navigable=${t.artists.any((ArtistRef a) => a.isNavigable)}');
    }
  }

  client.dispose();
  await BypassManager.instance.dispose();
  exit(0);
}
