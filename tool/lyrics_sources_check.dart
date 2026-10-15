// Инструмент для проверки: печать в консоль здесь уместна.
// ignore_for_file: avoid_print

// Временный инструмент: что отдаёт КАЖДЫЙ источник текста и есть ли в нём
// пословная синхронизация.
//
// Запуск: dart run tool/lyrics_sources_check.dart "Название" "Исполнитель"
//
// Зачем: жалоба «нет ни одного текста с пословной разметкой». Нужно видеть
// не только «нашёлся/не нашёлся», но и сколько в ответе слов с таймкодами,
// сколько занял запрос и что именно ответил сервис.
import 'dart:io';

import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:mops/data/models/models.dart';
import 'package:mops/data/sources/better_lyrics_source.dart';
import 'package:mops/data/sources/kugou_source.dart';
import 'package:mops/data/sources/lrclib_source.dart';
import 'package:mops/data/sources/youly_plus_source.dart';

Future<void> _probe(
  String label,
  Future<Lyrics> Function() run,
) async {
  final Stopwatch watch = Stopwatch()..start();
  try {
    final Lyrics lyrics = await run();
    watch.stop();
    final List<TimedLyric> timed = lyrics.timed ?? const <TimedLyric>[];
    final int words = timed.fold<int>(
      0,
      (int acc, TimedLyric line) => acc + (line.words?.length ?? 0),
    );
    print('  $label: ${watch.elapsedMilliseconds} мс | '
        'строк=${timed.length} plain=${(lyrics.plain ?? '').length} '
        '| синхр=${lyrics.isSynced} пословно=${words > 0} (слов=$words) '
        '| источник=${lyrics.source}');
    if (words > 0) {
      final TimedLyric first =
          timed.firstWhere((TimedLyric l) => l.hasWords);
      final List<TimedWord> words = first.words!;
      print('    первая пословная строка: "${first.text}" — '
          'слов: ${words.length}, '
          'первое=${words.first.time.inMilliseconds} мс, '
          'конец=${words.first.end?.inMilliseconds ?? '—'}');
    }
  } on Object catch (error) {
    watch.stop();
    print('  $label: ${watch.elapsedMilliseconds} мс | ОШИБКА: $error');
  }
}

Future<void> main(List<String> args) async {
  await BypassManager.instance.apply(const AntiDpiConfig());
  final String title = args.isNotEmpty ? args[0] : 'Never Gonna Give You Up';
  final String artist = args.length > 1 ? args[1] : 'Rick Astley';
  const Duration duration = Duration(minutes: 3, seconds: 33);

  print('=== "$title" — "$artist" ===');

  final BetterLyricsSource better = BetterLyricsSource();
  final YouLyPlusSource youly = YouLyPlusSource();
  final KugouSource kugou = KugouSource();
  final LrclibSource lrclib = LrclibSource();

  await _probe('BetterLyrics', () => better.fetch(
        title: title, artist: artist, duration: duration));
  await _probe('YouLy+', () => youly.fetch(
        title: title, artist: artist, duration: duration));
  await _probe('KuGou', () => kugou.fetch(
        title: title, artist: artist, duration: duration));
  await _probe('LRCLIB', () => lrclib.fetch(
        title: title, artist: artist, duration: duration));

  better.dispose();
  youly.dispose();
  kugou.dispose();
  lrclib.dispose();
  await BypassManager.instance.dispose();
  exit(0);
}
