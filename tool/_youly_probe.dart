// Пробой YouLy+ по нескольким трекам: что отдают зеркала и как это разбирается.
// Запуск: dart run tool/_youly_probe.dart
import 'dart:convert';
import 'dart:io';

import 'package:mops/data/sources/lyrics_match.dart';
import 'package:mops/data/sources/youly_plus_source.dart';

/// Трек: название, исполнитель, длительность в секундах.
const List<(String, String, int)> tracks = <(String, String, int)>[
  ('Этой весной', 'nyan.mp3', 200),
  ('Shape of You', 'Ed Sheeran', 233),
  ('Дегенерат (DELUXE)', 'Джарахов, MORGENSHTERN', 200),
  ('Один', 'LEANRODE', 180),
  ('Городские', 'Борка, MellSher', 190),
  ('Konstrukt', 'Oxxximiron', 210),
  ('Pretender', 'Official HIGE DANdism', 260),
];

const List<String> mirrors = <String>[
  'https://lyricsplus.prjktla.my.id',
  'https://lyricsplus.binimum.org',
  'https://lyricsplus.prjktla.workers.dev',
];

/// Краткая подпись формы ответа: что за верхние ключи и что лежит в `lyrics`.
String shape(String body) {
  final String trimmed = body.trim();
  if (trimmed.startsWith('<')) return 'XML/TTML, длина ${trimmed.length}';
  dynamic decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    return 'не JSON, длина ${trimmed.length}: ${trimmed.substring(0, 60)}';
  }
  if (decoded is! Map) return 'JSON ${decoded.runtimeType}';
  final String keys = decoded.keys.take(8).join(',');
  final dynamic lyrics = decoded['lyrics'];
  final dynamic ttml = decoded['ttml'];
  final StringBuffer out = StringBuffer('keys=$keys');
  if (ttml != null) {
    out.write(' | ttml=${ttml.runtimeType}(${ttml is String ? ttml.length : '?'})');
  }
  if (lyrics is List) {
    out.write(' | lyrics=list[${lyrics.length}]');
    if (lyrics.isNotEmpty && lyrics.first is Map) {
      out.write(' itemKeys=${(lyrics.first as Map).keys.take(8).join(',')}');
      final dynamic t = (lyrics.first as Map)['time'];
      out.write(' time=${t.runtimeType}:$t');
    }
  } else if (lyrics is String) {
    out.write(' | lyrics=String(${lyrics.length}) начало: '
        '${lyrics.substring(0, lyrics.length < 50 ? lyrics.length : 50)}');
  }
  final dynamic type = decoded['type'];
  if (type != null) out.write(' | type=$type');
  return out.toString();
}

Future<void> main() async {
  for (final (String title, String artist, int seconds) in tracks) {
    stdout.writeln('\n=== $artist — $title ===');
    for (final String mirror in mirrors) {
      for (final String path in <String>['/v1/ttml/get', '/v2/lyrics/get']) {
        final Uri uri = Uri.parse('$mirror$path').replace(
          queryParameters: <String, String>{
            'title': title,
            'artist': artist,
            'duration': '$seconds',
          },
        );
        final HttpClient client = HttpClient();
        try {
          final HttpClientRequest request = await client.getUrl(uri);
          final HttpClientResponse response =
              await request.close().timeout(const Duration(seconds: 8));
          if (response.statusCode != 200) {
            await response.drain<void>();
            stdout.writeln('  $mirror$path -> ${response.statusCode}');
          } else {
            final String body = await response.transform(utf8.decoder).join();
            stdout.writeln('  $mirror$path -> ${shape(body)}');
          }
        } on Object catch (e) {
          stdout.writeln('  $mirror$path -> FAIL $e');
        } finally {
          client.close(force: true);
        }
      }
    }

    final YouLyPlusSource source = YouLyPlusSource();
    final dynamic lyrics =
        await source.fetch(title: title, artist: artist, duration: Duration(seconds: seconds));
    final int timed = (lyrics.timed as List?)?.length ?? -1;
    final int words = ((lyrics.timed as List?) ?? <dynamic>[])
        .where((dynamic line) => line.words != null)
        .length;
    stdout.writeln('  РАЗБОР: timed=$timed words=$words '
        'sync=${syncTypeOf(lyrics)} plain=${lyrics.plain?.length}');
    source.dispose();
    await stdout.flush();
  }
}
