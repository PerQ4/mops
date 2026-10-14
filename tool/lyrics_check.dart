// Инструмент для проверки: печать в консоль здесь уместна.
// ignore_for_file: avoid_print

// Временный инструмент: что реально отдаёт YouTube Music как текст песни.
//
// Запуск: dart run tool/lyrics_check.dart [videoId ...]
//
// Отвечает на вопрос, из-за которого не работает автопрокрутка: приходят ли
// времена у строк (синхронизированный текст) или только голый текст. Печатает
// для нескольких треков результат CatalogSource.lyrics() и
// CatalogSource.subtitleLyrics(), а для первого — ещё и сырую разметку, чтобы
// видеть настоящие имена полей.
import 'dart:convert';
import 'dart:io';

import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/innertube/renderer.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:mops/data/models/models.dart';
import 'package:mops/data/sources/catalog_source.dart';
import 'package:mops/data/sources/library_source.dart';
import 'package:mops/data/sources/lrclib_source.dart';

/// Профиль клиента YouTube — копия из `youtube_clients.dart`, но без импорта
/// Flutter: `dart run` не тянет `dart:ui`. Нужна, чтобы проверить, какой
/// клиент отдаёт `player` со субтитрами.
class _Profile {
  const _Profile({
    required this.label,
    required this.name,
    required this.version,
    required this.numericId,
    required this.userAgent,
    required this.extra,
  });

  final String label;
  final String name;
  final String version;
  final String numericId;
  final String userAgent;
  final Map<String, Object?> extra;

  Map<String, dynamic> context() => <String, dynamic>{
        'clientName': name,
        'clientVersion': version,
        'hl': 'ru',
        'gl': 'RU',
        'utcOffsetMinutes': 0,
        'userAgent': userAgent,
        ...extra,
      };

  Map<String, String> get headers => <String, String>{
        'X-Youtube-Client-Name': numericId,
        'X-Youtube-Client-Version': version,
        'User-Agent': userAgent,
      };
}

const _Profile _visionOs = _Profile(
  label: 'visionOS',
  name: 'VISIONOS',
  version: '1.02',
  numericId: '101',
  userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15',
  extra: <String, Object?>{
    'osName': 'visionOS',
    'osVersion': '26.5.23O471',
    'deviceMake': 'Apple',
    'deviceModel': 'RealityDevice17,1',
  },
);

const _Profile _androidVr = _Profile(
  label: 'Android VR',
  name: 'ANDROID_VR',
  version: '1.65.10',
  numericId: '28',
  userAgent: 'com.google.android.apps.youtube.vr.oculus/1.65.10 '
      '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
  extra: <String, Object?>{
    'osName': 'Android',
    'osVersion': '12L',
    'deviceMake': 'Oculus',
    'deviceModel': 'Quest 3',
    'androidSdkVersion': 32,
  },
);

const _Profile _ios = _Profile(
  label: 'iOS',
  name: 'IOS',
  version: '20.10.4',
  numericId: '5',
  userAgent: 'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 '
      'like Mac OS X;)',
  extra: <String, Object?>{
    'deviceMake': 'Apple',
    'deviceModel': 'iPhone16,2',
    'osName': 'IOS',
    'osVersion': '18.3.2.22B83',
  },
);

const String _sessionPath =
    '/home/perqa/.local/share/com.mops.mops/session.json';

Future<void> main(List<String> args) async {
  await BypassManager.instance.apply(const AntiDpiConfig());

  final String cookieString = (jsonDecode(
    File(_sessionPath).readAsStringSync(),
  ) as Map<String, dynamic>)['cookieString'] as String;
  final CookieAuth auth = CookieAuth(cookieString);
  stdout.writeln('Cookie пригодна: ${auth.isUsable}');

  final InnerTubeClient client =
      InnerTubeClient(auth: auth, locale: 'ru', region: 'RU');
  final CatalogSource catalog = CatalogSource(client);

  try {
    // Список треков: явные аргументы, иначе — из «Мне нравится».
    final List<Track> tracks = <Track>[];
    if (args.isNotEmpty) {
      for (final String id in args) {
        tracks.add(Track(id: id, title: id));
      }
    } else {
      stdout.writeln('\nБеру треки из «Мне нравится»…');
      final LibrarySource library = LibrarySource(client);
      try {
        final List<Track> liked = await library.likedSongs();
        tracks.addAll(liked.take(6));
        stdout.writeln('  лайкнутых треков: ${liked.length}');
      } on Object catch (e) {
        stdout.writeln('  «Мне нравится» не сработало: $e');
      }
      if (tracks.isEmpty) {
        stdout.writeln('  беру из поиска «music»…');
        final List<BrowseSection> sections =
            await catalog.search('music', filter: SearchFilter.songs);
        for (final BrowseSection s in sections) {
          for (final BrowseItem item in s.items) {
            if (item is TrackItem) tracks.add(item.track);
          }
        }
      }
    }

    if (tracks.isEmpty) {
      stdout.writeln('Не нашёл ни одного трека — передайте videoId аргументом.');
      return;
    }

    for (final Track track in tracks.take(6)) {
      stdout.writeln('\n============================================================');
      stdout.writeln('Трек: ${track.title} [${track.id}]');
      await _probeLrclib(track);
      await _probeOne(catalog, client, track.id);
    }
  } on Object catch (error, stack) {
    stdout.writeln('ОШИБКА: $error');
    stdout.writeln(stack.toString().split('\n').take(10).join('\n'));
    exitCode = 1;
  } finally {
    client.dispose();
    await BypassManager.instance.dispose();
  }
  exit(exitCode);
}

/// Проверяет LRCLIB — открытую базу синхронизированных текстов.
Future<void> _probeLrclib(Track track) async {
  if (track.artists.isEmpty || track.title == track.id) {
    stdout.writeln('  LRCLIB: пропущено (нет метаданных)');
    return;
  }
  final LrclibSource source = LrclibSource();
  try {
    final Lyrics lyrics = await source.fetch(
      title: track.title,
      artist: track.artists.first.name,
      album: track.album?.name,
      duration: track.duration,
    );
    _describe('  LRCLIB', lyrics);
  } on Object catch (e) {
    stdout.writeln('  LRCLIB: ошибка $e');
  } finally {
    source.dispose();
  }
}

Future<void> _probeOne(  CatalogSource catalog,
  InnerTubeClient client,
  String videoId,
) async {
  // 1. Какая вкладка текста нашлась в next.
  final Map<String, dynamic> next = await client.next(videoId);
  final List<dynamic> tabs = traverseList(next, <String>['tabs', 'tabRenderer']);
  final List<String> pageTypes = <String>[];
  for (final dynamic tab in tabs) {
    pageTypes.add(traverseString(tab, <String>[
          'endpoint',
          'browseEndpoint',
          'browseEndpointContextSupportedConfigs',
          'browseEndpointContextMusicConfig',
          'pageType',
        ]) ??
        '?');
  }
  stdout.writeln('  вкладки next: $pageTypes');

  // 2. Основной источник.
  final Lyrics music = await catalog.lyrics(videoId);
  _describe('  lyrics()', music);

  // 3. Субтитры.
  final Lyrics subs = await catalog.subtitleLyrics(videoId);
  _describe('  subtitleLyrics()', subs);

  // 4. Сырая разметка страницы текста: ищем настоящие имена полей.
  String? lyricsBrowseId;
  for (final dynamic tab in tabs) {
    final String? pageType = traverseString(tab, <String>[
      'endpoint',
      'browseEndpoint',
      'browseEndpointContextSupportedConfigs',
      'browseEndpointContextMusicConfig',
      'pageType',
    ]);
    if (pageType == 'MUSIC_PAGE_TYPE_TRACK_LYRICS') {
      lyricsBrowseId = traverseString(tab, <String>['browseId']);
      break;
    }
  }
  lyricsBrowseId ??= tabs.length > 1
      ? traverseString(tabs[1], <String>['browseId'])
      : null;

  if (lyricsBrowseId != null) {
    final Map<String, dynamic> res = await client.browse(lyricsBrowseId);
    // Ищем по всему дереву ответа, где вообще лежат времена и синхронный текст:
    // текущий разбор смотрит в `contents.type.lyricsData`, и если путь не тот,
    // времена теряются молча.
    final List<String> paths = <String>[];
    _findKeyPaths(res, const <String>{
      'timedLyricsData',
      'lyricLineStartTimeMs',
      'lyricsData',
      'text',
      'description',
    }, '', paths);
    stdout.writeln('  пути с интересными ключами:');
    for (final String p in paths.take(40)) {
      stdout.writeln('    $p');
    }

    final dynamic data =
        traverse(res, <String>['contents', 'type', 'lyricsData']);
    stdout.writeln('  старый путь contents.type.lyricsData: ${data.runtimeType}');
  } else {
    stdout.writeln('  browseId текста не найден');
  }

  // Субтитры: смотрим, что вернул player — есть ли дорожки вообще.
  final Map<String, dynamic> player = await client.post(
    'player',
    body: <String, dynamic>{
      'videoId': videoId,
      'contentCheckOk': true,
      'racyCheckOk': true,
    },
  );
  final List<dynamic> capTracks = traverseList(player, <String>[
    'captions',
    'playerCaptionsTracklistRenderer',
    'captionTracks',
  ]);
  stdout.writeln('  player captionTracks (WEB_REMIX): ${capTracks.length}');
  final dynamic playability = traverse(
    player,
    <String>['playabilityStatus', 'status'],
  );
  stdout.writeln('  playabilityStatus (WEB_REMIX): $playability');

  // Пробуем профили клиентов, которыми приложение получает поток: у WEB_REMIX
  // player отвечает UNPLAYABLE и субтитров нет.
  for (final _Profile profile in <_Profile>[_androidVr, _visionOs, _ios]) {
    try {
      final Map<String, dynamic> res = await client.post(
        'player',
        body: <String, dynamic>{
          'context': <String, dynamic>{
            'client': profile.context(),
          },
          'videoId': videoId,
          'contentCheckOk': true,
          'racyCheckOk': true,
        },
        extraHeaders: profile.headers,
      );
      final List<dynamic> ct = traverseList(res, <String>[
        'captions',
        'playerCaptionsTracklistRenderer',
        'captionTracks',
      ]);
      final dynamic st = traverse(res, <String>['playabilityStatus', 'status']);
      stdout.writeln('  player ${profile.label}: status=$st '
          'captionTracks=${ct.length}');
      if (ct.isNotEmpty) {
        stdout.writeln('    ${jsonEncode(ct.first)}');
      }
    } on Object catch (e) {
      stdout.writeln('  player ${profile.label}: ошибка $e');
    }
  }
}

/// Рекурсивно собирает пути до ключей из [needles].
void _findKeyPaths(
  dynamic node,
  Set<String> needles,
  String prefix,
  List<String> out,
) {
  if (out.length > 400) return;
  if (node is Map) {
    for (final MapEntry<dynamic, dynamic> e in node.entries) {
      final String key = '${e.key}';
      final String path = '$prefix.$key';
      if (needles.contains(key)) out.add(path);
      _findKeyPaths(e.value, needles, path, out);
    }
  } else if (node is List) {
    for (int i = 0; i < node.length && i < 5; i++) {
      _findKeyPaths(node[i], needles, '$prefix[$i]', out);
    }
  }
}

void _describe(String label, Lyrics lyrics) {
  final List<TimedLyric>? timed = lyrics.timed;
  stdout.writeln('$label источник=${lyrics.source ?? "—"} '
      'синхр=${lyrics.isSynced} '
      'строк timed=${timed?.length ?? 0} '
      'plain=${lyrics.plain?.length ?? 0}');
  if (timed != null && timed.isNotEmpty) {
    final List<Object> times =
        timed.map((TimedLyric l) => l.time.inMilliseconds).toList();
    final Object first = times.first;
    final Object last = times.last;
    final Set<Object> unique = times.toSet();
    stdout.writeln('    время: первое=$first мс, последнее=$last мс, '
        'уникальных=${unique.length}');
    for (final TimedLyric l in timed.take(4)) {
      stdout.writeln('      [${l.time.inMilliseconds} мс] ${l.text}');
    }
  }
}
