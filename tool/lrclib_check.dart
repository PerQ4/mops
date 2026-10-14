// Проверка LRCLIB: приходит ли синхронизированный текст.
import 'package:mops/data/sources/lrclib_source.dart';

Future<void> main() async {
  final LrclibSource source = LrclibSource();
  for (final (String artist, String title) in <(String, String)>[
    ('Rick Astley', 'Never Gonna Give You Up'),
    ('Radiohead', 'Creep'),
    ('Кино', 'Группа крови'),
  ]) {
    final lyrics = await source.fetch(title: title, artist: artist);
    final timed = lyrics.timed;
    print('$artist — $title: синхронно=${lyrics.isSynced}, '
        'строк=${timed?.length ?? 0}, источник=${lyrics.source}');
    if (timed != null && timed.isNotEmpty) {
      print('  первая: [${timed.first.time.inSeconds}s] ${timed.first.text}');
      print('  вторая: [${timed[1].time.inSeconds}s] ${timed[1].text}');
    }
  }
  source.dispose();
}
