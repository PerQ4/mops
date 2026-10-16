import 'package:mops/data/sources/better_lyrics_source.dart';
import 'package:mops/data/sources/kugou_source.dart';
import 'package:mops/data/sources/lrclib_source.dart';
import 'package:mops/data/sources/megalobiz_source.dart';
import 'package:mops/data/sources/simpmusic_source.dart';
import 'package:mops/data/sources/unison_source.dart';
import 'package:mops/data/sources/youly_plus_source.dart';

Future<void> main() async {
  const String title = 'Shape of You';
  const String artist = 'Ed Sheeran';
  const String videoId = 'JGwWNGJdvx8';
  const Duration duration = Duration(seconds: 233);

  Future<void> run(String name, Future<dynamic> Function() f) async {
    try {
      final dynamic l = await f();
      final int timed = (l.timed as List?)?.length ?? -1;
      final int plain = (l.plain as String?)?.length ?? -1;
      print('$name: timed=$timed plain=$plain empty=${l.isEmpty}');
    } on Object catch (e) {
      print('$name: ERROR $e');
    }
  }

  await run('betterLyrics',
      () => BetterLyricsSource().fetch(title: title, artist: artist, duration: duration));
  await run('youlyPlus',
      () => YouLyPlusSource().fetch(title: title, artist: artist, duration: duration));
  await run('lrclib',
      () => LrclibSource().fetch(title: title, artist: artist, duration: duration));
  await run('kugou',
      () => KugouSource().fetch(title: title, artist: artist, duration: duration));
  await run('megalobiz', () => MegalobizSource().fetch(title: title, artist: artist));
  await run('simpmusic', () => SimpMusicSource().fetch(videoId: videoId, duration: duration));
  await run('unison',
      () => UnisonSource().fetch(videoId: videoId, title: title, artist: artist, duration: duration));
}
