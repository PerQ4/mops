import '../models/models.dart';
import 'lrclib_source.dart';

/// Общие разборы форматов текстов, которыми пользуются внешние базы.
///
/// Базы отдают либо LRC (со временами строк), либо обычный текст без разметки,
/// либо TTML (формат Apple Music). Здесь собраны преобразования в нашу
/// [Lyrics] — чтобы каждая база не повторяла один и тот же разбор.

/// Превращает сырой ответ базы в [Lyrics].
///
/// Формат определяем по меткам времени: если они есть — это LRC с
/// синхронизацией, иначе честно возвращаем обычный текст. Так интерфейс сам
/// покажет, что подсветки и автопрокрутки у этого текста не будет.
Lyrics lyricsFromText(String raw, String source) {
  final String text = raw.trim();
  if (text.isEmpty) return Lyrics.none;

  final List<TimedLyric> timed = LrclibSource.parseLrc(text);
  if (timed.isNotEmpty) {
    return lyricsFromTimed(timed, source);
  }
  return Lyrics(plain: text, source: source);
}

/// Собирает [Lyrics] из готовых строк со временами.
Lyrics lyricsFromTimed(List<TimedLyric> timed, String source) {
  if (timed.isEmpty) return Lyrics.none;
  return Lyrics(
    timed: timed,
    plain: timed.map((TimedLyric line) => line.text).join('\n'),
    source: source,
  );
}

/// Разбирает TTML (формат Apple Music) в строки со временами.
///
/// Текст строки собирается из содержимого `<p>` с удалением тегов — так
/// сохраняются пробелы между пословными `<span>` (склейка содержимого спанов
/// без пробелов давала «Theclubisn't...»). Если у спанов есть `begin`, из них
/// дополнительно собирается пословная разметка для «караоке».
List<TimedLyric> parseTtml(String ttml) {
  final RegExp pTag =
      RegExp(r'<p\b[^>]*>(.*?)</p>', caseSensitive: false, dotAll: true);
  final RegExp spanTag = RegExp(
    r'<span\b([^>]*)>(.*?)</span>',
    caseSensitive: false,
    dotAll: true,
  );
  final RegExp beginAttr = RegExp(
    r'''\bbegin\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  );
  final RegExp brTag = RegExp(r'<br\s*/?>', caseSensitive: false);
  final RegExp anyTag = RegExp('<[^>]+>');
  final RegExp spaces = RegExp(r'\s+');

  final List<TimedLyric> lines = <TimedLyric>[];
  for (final RegExpMatch paragraph in pTag.allMatches(ttml)) {
    final Duration? time =
        parseTtmlTime(beginAttr.firstMatch(paragraph.group(0) ?? '')?.group(1));
    if (time == null) continue;

    final String inner = paragraph.group(1) ?? '';

    final List<TimedWord> words = <TimedWord>[];
    for (final RegExpMatch span in spanTag.allMatches(inner)) {
      final Duration? wordTime =
          parseTtmlTime(beginAttr.firstMatch(span.group(1) ?? '')?.group(1));
      final String wordText = unescapeEntities(
        (span.group(2) ?? '').replaceAll(anyTag, ''),
      ).trim();
      if (wordTime == null || wordText.isEmpty) continue;
      words.add(TimedWord(time: wordTime, text: wordText));
    }

    final String text = words.isNotEmpty
        ? words.map((TimedWord w) => w.text).join(' ')
        : unescapeEntities(
            inner.replaceAll(brTag, ' ').replaceAll(anyTag, ''),
          ).replaceAll(spaces, ' ').trim();
    if (text.isEmpty) continue;

    lines.add(
      TimedLyric(
        time: time,
        text: text,
        words: words.isEmpty ? null : words,
      ),
    );
  }

  lines.sort((TimedLyric a, TimedLyric b) => a.time.compareTo(b.time));
  return lines;
}

/// Разбирает время TTML: `12.345`, `00:12.345`, `0:00:12.345`, возможно с
/// суффиксом `s`/`ms`. Возвращает `null`, если формат незнаком.
Duration? parseTtmlTime(String? raw) {
  if (raw == null) return null;

  String value = raw.trim();
  if (value.endsWith('ms')) {
    value = value.substring(0, value.length - 2);
  } else if (value.endsWith('s')) {
    value = value.substring(0, value.length - 1);
  }

  final List<String> parts = value.split(':');
  if (parts.isEmpty || parts.length > 3) return null;

  double seconds;
  try {
    if (parts.length == 3) {
      seconds = int.parse(parts[0]) * 3600 +
          int.parse(parts[1]) * 60 +
          double.parse(parts[2]);
    } else if (parts.length == 2) {
      seconds = int.parse(parts[0]) * 60 + double.parse(parts[1]);
    } else {
      seconds = double.parse(parts[0]);
    }
  } on FormatException {
    return null;
  }

  if (seconds < 0) return null;
  return Duration(milliseconds: (seconds * 1000).round());
}

/// Раскодирует базовые HTML-сущности, которые встречаются в текстах.
String unescapeEntities(String value) => value
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&#39;', "'");
