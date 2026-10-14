// Проверка источника KuGou из кода приложения.
import 'package:mops/data/sources/kugou_source.dart';

Future<void> main() async {
  final KugouSource source = KugouSource();
  for (final (String artist, String title) in <(String, String)>[
    ('Кино', 'Группа крови'),
    ('Rick Astley', 'Never Gonna Give You Up'),
  ]) {
    final lyrics = await source.fetch(title: title, artist: artist);
    print('$artist — $title: синхронно=${lyrics.isSynced}, '
        'строк=${lyrics.timed?.length ?? 0}, источник=${lyrics.source}');
    if (lyrics.timed != null && lyrics.timed!.isNotEmpty) {
      print('  первая: [${lyrics.timed!.first.time.inSeconds}s] ${lyrics.timed!.first.text}');
    }
  }
  source.dispose();
}
