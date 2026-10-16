import 'package:meta/meta.dart';

import '../models/models.dart';

/// Оценка совместимости найденного текста с играющим треком.
///
/// Зачем: баз много, и они отвечают параллельно, но не все находят «тот самый»
/// текст. Раньше выбирался первый непустой ответ (или первый синхронизированный
/// в «Авто»), из-за чего мог победить чужой текст с верными временами. Здесь
/// варианты упорядочиваются по совокупности признаков, и лучший выбирается
/// сразу, а остальные остаются списком на случай ручного переключения.
///
/// Веса подобраны так, чтобы синхронизация была главным критерием (без неё
/// текст нельзя подсветить и прокрутить), а метаданные и перевод — уточняющими.

/// Итог оценки: сколько баллов и почему (причины показываются в меню).
@immutable
class LyricsScore {
  const LyricsScore(this.value, this.reasons);

  final int value;
  final List<String> reasons;
}

/// Тип синхронизации текста — как `SyncType` в BetterLyrics.
///
/// Порядок объявления задаёт приоритет: караоке по слогам лучше пословного,
/// пословное — лучше построчного, построчное — лучше текста без времён.
/// Именно по этому признаку выбирается текст в режиме «Авто», а балл
/// [scoreLyrics] используется лишь для сортировки списка в меню.
enum LyricsSyncType {
  /// Время размечено у нескольких слов внутри строки — настоящее караоке.
  syllable,

  /// Время у слов, но по одному слову на строку.
  word,

  /// Время только у строк.
  line,

  /// Времён нет — подсветить и прокрутить нечего.
  unsynced,
}

/// Определяет тип синхронизации текста.
///
/// Караоке считаем по слогам только тогда, когда размечено **большинство**
/// строк: у некоторых баз слова есть лишь в припеве, и объявлять такой текст
/// караоке было бы обманом.
LyricsSyncType syncTypeOf(Lyrics lyrics) {
  final List<TimedLyric> timed = lyrics.timed ?? const <TimedLyric>[];
  if (timed.isEmpty) return LyricsSyncType.unsynced;

  int withWords = 0;
  int withSeveralWords = 0;
  for (final TimedLyric line in timed) {
    final List<TimedWord> words = line.words ?? const <TimedWord>[];
    if (words.isEmpty) continue;
    withWords++;
    if (words.length > 1) withSeveralWords++;
  }

  if (withWords == 0) return LyricsSyncType.line;
  return withSeveralWords * 2 >= withWords
      ? LyricsSyncType.syllable
      : LyricsSyncType.word;
}

/// Порядок типов синхронизации при выборе лучшего текста (лучший — первый).
const List<LyricsSyncType> kLyricsSyncPriority = <LyricsSyncType>[
  LyricsSyncType.syllable,
  LyricsSyncType.word,
  LyricsSyncType.line,
  LyricsSyncType.unsynced,
];

/// Нормализует строку для сравнения названий и исполнителей.
///
/// Регистр и пунктуацию убираем (Apple Music и YouTube пишут «Feat.»/«feat»
/// по-разному), а буквы и цифры сохраняем — `\p{L}` включает кириллицу, так
/// что «Мельница» и «МЕЛЬНИЦА» считаются одинаковыми.
String normalizeMatchText(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

/// Совпадают ли две строки после нормализации.
///
/// Одной нормализации мало: YouTube часто добавляет к названию «(Official
/// Video)», а к исполнителю « - Topic». Поэтому дополнительно считаем
/// совпадением случай, когда все слова более короткой строки встречаются в
/// длинной. Ограничение «одно короткое слово» отсекает ложные срабатывания
/// вроде «Life» ↔ «Beautiful Life».
bool _similarText(String? a, String? b) {
  if (a == null || b == null) return false;
  final String na = normalizeMatchText(a);
  final String nb = normalizeMatchText(b);
  if (na.isEmpty || nb.isEmpty) return false;
  if (na == nb) return true;

  final Set<String> ta = na.split(' ').toSet();
  final Set<String> tb = nb.split(' ').toSet();
  final Set<String> smaller = ta.length <= tb.length ? ta : tb;
  final Set<String> larger = identical(smaller, ta) ? tb : ta;
  if (smaller.isEmpty) return false;
  final bool subset = smaller.every(larger.contains);
  if (!subset) return false;
  // Все слова короткой строки входят в длинную. Чтобы «life» не совпало с
  // «beautiful life», требуем минимум два слова или достаточно длинное слово.
  return smaller.length >= 2 || na.length >= 6;
}

/// Считает балл совместимости.
///
/// [rank] — место источника в общем порядке (меньше — приоритетнее): им
/// разрешаем ничьи, чтобы «Авто» вёл себя предсказуемо.
LyricsScore scoreLyrics({
  required Lyrics lyrics,
  required int rank,
  String? requestTitle,
  String? requestArtist,
  Duration? requestDuration,
}) {
  int score = 0;
  final List<String> reasons = <String>[];

  // 1. Синхронизация — главный признак. Пословная (TTML) лучше построчной,
  //    построчная лучше обычного текста без времён.
  final bool wordSynced =
      lyrics.timed?.any((TimedLyric line) => line.hasWords) ?? false;
  if (wordSynced) {
    score += 40;
    reasons.add('пословная синхронизация');
  } else if (lyrics.isSynced) {
    score += 20;
    reasons.add('построчная синхронизация');
  } else {
    reasons.add('без синхронизации');
  }

  // 2. Длительность: расхождение до 5 с считаем попаданием, до 15 с —
  //    допустимым (радио-редакция, лайв), больше — признаком чужой записи.
  final Duration? candidateDuration = lyrics.match?.duration;
  if (candidateDuration != null &&
      candidateDuration > Duration.zero &&
      requestDuration != null &&
      requestDuration > Duration.zero) {
    final int diff = (candidateDuration - requestDuration).inSeconds.abs();
    if (diff <= 5) {
      score += 20;
      reasons.add('длительность совпала');
    } else if (diff <= 15) {
      score += 8;
      reasons.add('длительность близка');
    } else {
      score -= 10;
      reasons.add('другая длительность');
    }
  }

  // 3. Название и исполнитель. Неизвестные метаданные не штрафуем: базы их
  //    отдают не всегда, и наказывать за молчание было бы нечестно.
  if (_similarText(lyrics.match?.title, requestTitle)) {
    score += 15;
    reasons.add('название совпало');
  }
  if (_similarText(lyrics.match?.artist, requestArtist)) {
    score += 15;
    reasons.add('исполнитель совпал');
  }

  // 4. Перевод — приятный бонус: он не влияет на синхронизацию.
  if (lyrics.match?.hasTranslation ?? false) {
    score += 10;
    reasons.add('есть перевод');
  }

  // 5. Тай-брейк по порядку источника, как приоритет в ArchiveTune.
  final int bonus = 10 - rank;
  score += bonus.clamp(0, 10);

  return LyricsScore(score, reasons);
}
