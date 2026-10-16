// Пробой источников текста: по каждому — время ответа и результат.
// Запуск: dart run tool/_lyrics_probe.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mops/data/sources/better_lyrics_source.dart';
import 'package:mops/data/sources/kugou_source.dart';
import 'package:mops/data/sources/lrclib_source.dart';
import 'package:mops/data/sources/lyrics_match.dart';
import 'package:mops/data/sources/megalobiz_source.dart';
import 'package:mops/data/sources/simpmusic_source.dart';
import 'package:mops/data/sources/unison_source.dart';
import 'package:mops/data/sources/youly_plus_source.dart';

const String title = 'Shape of You';
const String artist = 'Ed Sheeran';
const String videoId = 'JGwWNGJdvx8';
const Duration duration = Duration(seconds: 233);

Future<void> timed(String name, Future<dynamic> Function() f) async {
  final Stopwatch sw = Stopwatch()..start();
  try {
    final dynamic l = await f().timeout(const Duration(seconds: 12));
    final int t = (l.timed as List?)?.length ?? -1;
    final int p = (l.plain as String?)?.length ?? -1;
    final int words = ((l.timed as List?) ?? <dynamic>[])
        .where((dynamic line) => line.words != null)
        .length;
    stdout.writeln('$name: ${sw.elapsedMilliseconds}ms timed=$t '
        'plain=$p words=$words sync=${syncTypeOf(l)} empty=${l.isEmpty}');
  } on Object catch (e) {
    stdout.writeln('$name: ${sw.elapsedMilliseconds}ms ERROR $e');
  }
  await stdout.flush();
}

/// Прямая проверка зеркала YouLyPlus: статус и время.
Future<void> probeMirror(String mirror, String path) async {
  final Uri uri = Uri.parse('$mirror$path').replace(
    queryParameters: <String, String>{
      'title': title,
      'artist': artist,
      'duration': '${duration.inSeconds}',
    },
  );
  final Stopwatch sw = Stopwatch()..start();
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.getUrl(uri);
    final HttpClientResponse response =
        await request.close().timeout(const Duration(seconds: 6));
    final String body = await response.transform(utf8.decoder).join();
    stdout.writeln('  $mirror$path -> ${response.statusCode} '
        '${sw.elapsedMilliseconds}ms len=${body.length}');
  } on Object catch (e) {
    stdout.writeln('  $mirror$path -> FAIL ${sw.elapsedMilliseconds}ms $e');
  } finally {
    client.close(force: true);
  }
  await stdout.flush();
}

Future<void> main() async {
  const List<String> mirrors = <String>[
    'https://lyricsplus.binimum.org',
    'https://lyricsplus.prjktla.my.id',
    'https://lyricsplus.prjktla.workers.dev',
    'https://lyricsplus.atomix.one',
    'https://lyricsplus-seven.vercel.app',
  ];

  stdout.writeln('=== зеркала YouLyPlus ===');
  for (final String mirror in mirrors) {
    await probeMirror(mirror, '/v1/ttml/get');
  }

  stdout.writeln('=== источники ===');
  await timed('betterLyrics',
      () => BetterLyricsSource().fetch(title: title, artist: artist, duration: duration));
  await timed('youlyPlus',
      () => YouLyPlusSource().fetch(title: title, artist: artist, duration: duration));
  await timed('lrclib',
      () => LrclibSource().fetch(title: title, artist: artist, duration: duration));
  await timed('kugou',
      () => KugouSource().fetch(title: title, artist: artist, duration: duration));
  await timed('megalobiz', () => MegalobizSource().fetch(title: title, artist: artist));
  await timed('simpmusic',
      () => SimpMusicSource().fetch(videoId: videoId, duration: duration));
  await timed('unison',
      () => UnisonSource().fetch(videoId: videoId, title: title, artist: artist, duration: duration));

  stdout.writeln('=== готово ===');
}
