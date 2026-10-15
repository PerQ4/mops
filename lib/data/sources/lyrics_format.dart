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
Lyrics lyricsFromText(String raw, String source, {LyricsMatch? match}) {
  final String text = raw.trim();
  if (text.isEmpty) return Lyrics.none;

  final List<TimedLyric> timed = LrclibSource.parseLrc(text);
  if (timed.isNotEmpty) {
    return lyricsFromTimed(timed, source, match: match);
  }
  return Lyrics(plain: text, source: source, match: match);
}

/// Собирает [Lyrics] из готовых строк со временами.
Lyrics lyricsFromTimed(
  List<TimedLyric> timed,
  String source, {
  LyricsMatch? match,
}) {
  if (timed.isEmpty) return Lyrics.none;
  return Lyrics(
    timed: timed,
    plain: timed.map((TimedLyric line) => line.text).join('\n'),
    source: source,
    match: match,
  );
}

/// Есть ли в TTML отдельный блок перевода (`x-translation`).
///
/// Проверяем по сырому документу, а не по разобранным строкам: перевод идёт
/// вложенными узлами и в основной текст не попадает, но для оценки
/// совместимости важно знать, что он вообще есть.
bool ttmlHasTranslation(String ttml) => _roleAttr
    .allMatches(ttml)
    .any((RegExpMatch m) => m.group(1)?.toLowerCase() == 'x-translation');

final RegExp _roleAttr = RegExp(
  r'''\b(?:ttm:)?role\s*=\s*["']([^"']+)["']''',
  caseSensitive: false,
);

/// Разбирает TTML (формат Apple Music) в строки со временами.
///
/// Текст строки берётся из содержимого `<p>` с удалением тегов — так
/// сохраняются пробелы между пословными `<span>` (склейка содержимого спанов
/// без пробелов давала «Theclubisn't...»). Пословная разметка собирается
/// только из **основных** спанов.
///
/// Почему так сложно: Apple Music кладёт бэк-вокал и перевод отдельными
/// спанами с `ttm:role="x-bg"`/`"x-translation"`. Раньше роли игнорировались,
/// и бэк-вокал («Sunshine, beautiful life») попадал в ту же строку вторым
/// экземпляром — строка показывалась дважды подряд. Теперь дополнительные
/// спаны (вместе с их вложенностью) в основной текст и в «караоке» не идут.
List<TimedLyric> parseTtml(String ttml) {
  final RegExp pTag =
      RegExp(r'<p\b[^>]*>(.*?)</p>', caseSensitive: false, dotAll: true);
  final RegExp spaces = RegExp(r'\s+');

  final List<TimedLyric> lines = <TimedLyric>[];
  for (final RegExpMatch paragraph in pTag.allMatches(ttml)) {
    // Роль и время берём из открывающего тега <p>, а не из всего содержимого:
    // иначе роль вложенного спана (x-bg/x-translation) ошибочно «повесила» бы
    // перевод на весь параграф.
    final String raw = paragraph.group(0) ?? '';
    final int openEnd = raw.indexOf('>');
    final String openTag = openEnd < 0 ? raw : raw.substring(0, openEnd + 1);

    // Параграф может целиком быть переводом/бэк-вокалом — тогда его пропускаем.
    if (_isSupplementaryRole(_roleAttr.firstMatch(openTag)?.group(1))) {
      continue;
    }

    final Duration? time =
        parseTtmlTime(_beginAttr.firstMatch(openTag)?.group(1));
    if (time == null) continue;

    final _ParseResult parsed = _parseParagraph(paragraph.group(1) ?? '');
    final String text = parsed.text.toString().replaceAll(spaces, ' ').trim();
    if (text.isEmpty) continue;

    lines.add(
      TimedLyric(
        time: time,
        text: text,
        words: parsed.words.isEmpty ? null : parsed.words,
      ),
    );
  }

  lines.sort((TimedLyric a, TimedLyric b) => a.time.compareTo(b.time));
  // Дубликаты одной и той же строки с одной и той же меткой (например, бэк-вокал
  // отдельным <p> с тем же временем) убираем: показывать её дважды незачем.
  // Повторы на разных временах — законный припев, их не трогаем.
  return _dedupeTimed(lines);
}

/// Убирает соседние строки с одинаковым временем и текстом.
List<TimedLyric> _dedupeTimed(List<TimedLyric> lines) {
  final List<TimedLyric> result = <TimedLyric>[];
  for (final TimedLyric line in lines) {
    if (result.isNotEmpty) {
      final TimedLyric previous = result.last;
      if (previous.time == line.time && previous.text == line.text) continue;
    }
    result.add(line);
  }
  return result;
}

/// Итог разбора содержимого `<p>`: текст строки и основные слова.
class _ParseResult {
  _ParseResult();

  final StringBuffer text = StringBuffer();
  final List<TimedWord> words = <TimedWord>[];
}

/// Один открытый `<span>`. `leaf` снимается, когда внутри открывается
/// основной дочерний span — чтобы контейнер не превратился в лишнее слово.
class _SpanFrame {
  _SpanFrame({
    required this.supplementary,
    required this.begin,
    required this.end,
  });

  final bool supplementary;
  final Duration? begin;
  final Duration? end;
  final StringBuffer text = StringBuffer();
  bool leaf = true;
}

final RegExp _beginAttr = RegExp(
  r'''\bbegin\s*=\s*["']([^"']+)["']''',
  caseSensitive: false,
);
final RegExp _endAttr = RegExp(
  r'''\bend\s*=\s*["']([^"']+)["']''',
  caseSensitive: false,
);
final RegExp _tagOrText = RegExp(r'<[^>]*>|[^<]+');
final RegExp _tagName = RegExp(r'^<\s*([a-zA-Z0-9:_-]+)');
final RegExp _anyTag = RegExp('<[^>]+>');

bool _isSupplementaryRole(String? role) {
  final String? value = role?.toLowerCase();
  return value == 'x-bg' || value == 'x-translation' || value == 'x-roman';
}

/// Разбирает внутренность одного `<p>`.
///
/// Идём по тегам и тексту вручную (regexp не умеет парную вложенность):
/// считаем глубину дополнительных спанов, копим текст строки и пословную
/// разметку по основным спанам с `begin`.
_ParseResult _parseParagraph(String inner) {
  final _ParseResult result = _ParseResult();
  final List<_SpanFrame> stack = <_SpanFrame>[];
  int supplementaryDepth = 0;

  for (final RegExpMatch match in _tagOrText.allMatches(inner)) {
    final String token = match.group(0)!;

    if (token.startsWith('</')) {
      if (stack.isEmpty) continue;
      final _SpanFrame frame = stack.removeLast();
      if (frame.supplementary) {
        supplementaryDepth--;
        continue;
      }
      // Слово берём только с листового спана с временем; текст контейнера
      // уже разошёлся по строке, дублировать его словом не нужно.
      final Duration? begin = frame.begin;
      if (!frame.leaf || begin == null) continue;
      final String wordText = unescapeEntities(
        frame.text.toString().replaceAll(_anyTag, ''),
      ).trim();
      if (wordText.isEmpty) continue;
      final Duration? end = frame.end;
      result.words.add(TimedWord(
        time: begin,
        text: wordText,
        // Конец берём только если он позже начала: иначе отрицательная
        // длительность сломала бы «караоке».
        end: (end != null && end > begin) ? end : null,
      ));
      continue;
    }

    if (token.startsWith('<')) {
      // Перенос строки — это пробел, а не отдельный текст.
      if (token.startsWith('<br')) {
        if (supplementaryDepth == 0) result.text.write(' ');
        continue;
      }
      final String local = _tagName.firstMatch(token)?.group(1) ?? '';
      if (!local.toLowerCase().endsWith('span')) continue;

      final String? role = _roleAttr.firstMatch(token)?.group(1);
      final bool supplementary = _isSupplementaryRole(role);
      if (!supplementary &&
          stack.isNotEmpty &&
          !stack.last.supplementary) {
        // У основного родителя появился основной ребёнок — родитель контейнер.
        stack.last.leaf = false;
      }
      if (supplementary) supplementaryDepth++;
      stack.add(_SpanFrame(
        supplementary: supplementary,
        begin: parseTtmlTime(_beginAttr.firstMatch(token)?.group(1)),
        end: parseTtmlTime(_endAttr.firstMatch(token)?.group(1)),
      ));
      continue;
    }

    // Текстовый узел.
    if (supplementaryDepth > 0) continue;
    final String text = unescapeEntities(token.replaceAll(_anyTag, ''));
    result.text.write(text);
    // Копим слово — в ближайшем открытом основном спане с временем.
    for (int i = stack.length - 1; i >= 0; i--) {
      final _SpanFrame frame = stack[i];
      if (!frame.supplementary && frame.begin != null) {
        frame.text.write(text);
        break;
      }
    }
  }

  return result;
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
