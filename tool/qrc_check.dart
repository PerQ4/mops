// Инструмент для проверки: печать в консоль здесь уместна.
// ignore_for_file: avoid_print

// Временный инструмент: проверка разбора QRC (караоке QQ Music) на живом
// ответе. Запуск: dart run tool/qrc_check.dart /путь/к/qq.json
import 'dart:convert';
import 'dart:io';

import 'package:mops/data/models/models.dart';
import 'package:mops/data/sources/lyrics_format.dart';

void main(List<String> args) {
  final String path = args.isNotEmpty ? args[0] : '/tmp/opencode/qq.json';
  final Map<String, dynamic> json =
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final String lyrics = json['lyrics'] as String;

  print('похоже на QRC: ${looksLikeQrc(lyrics)}');
  final List<TimedLyric> lines = parseQrc(lyrics);
  final int words =
      lines.fold<int>(0, (int a, TimedLyric l) => a + (l.words?.length ?? 0));
  print('строк: ${lines.length}, слов: $words');
  for (final TimedLyric line in lines.take(4)) {
    print('  [${line.time.inMilliseconds} мс] "${line.text}"');
    final List<TimedWord>? w = line.words;
    if (w != null && w.isNotEmpty) {
      print('    слова: ${w.take(4).map((TimedWord x) => "${x.text}@${x.time.inMilliseconds}").join(', ')}');
    }
  }
}
