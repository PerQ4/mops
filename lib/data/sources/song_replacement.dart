import 'package:meta/meta.dart';

import '../models/models.dart';
import 'catalog_source.dart';
import 'lyrics_match.dart';

/// Минимальный балл, при котором кандидат считается заменой.
///
/// Порог отсекает случайные результаты поиска: одного совпадения слова в
/// названии мало, иначе «Life» находил бы «Beautiful Life» и предлагал его как
/// замену. Ниже порога кандидатов нет вовсе — честнее сказать «замена не
/// найдена», чем показать чужой трек.
const int kReplacementMinScore = 55;

/// Кандидат на замену недоступного трека.
@immutable
class SongCandidate {
  const SongCandidate({
    required this.track,
    required this.score,
    required this.reasons,
  });

  final Track track;

  /// Оценка совпадения от 0 до 100.
  final int score;

  /// Из чего сложился балл — подсказка, почему кандидат в списке.
  final List<String> reasons;
}

/// Считает, насколько [candidate] похож на исходный [source].
///
/// Сравниваем то, что видит пользователь: название, исполнителя и
/// длительность. Нормализация общая с текстами песен ([normalizeMatchText]):
/// она убирает регистр и пунктуацию, поэтому «(Official Video)» и «feat.»
/// не мешают совпадению.
SongCandidate scoreSongReplacement({
  required Track source,
  required Track candidate,
}) {
  final List<String> reasons = <String>[];

  final double titleSimilarity = _textSimilarity(source.title, candidate.title);
  int score = (titleSimilarity * 60).round();
  if (titleSimilarity >= 1) {
    reasons.add('название совпало');
  } else if (titleSimilarity > 0) {
    reasons.add('название похоже');
  }

  final double artistSimilarity = _artistSimilarity(
    source.artists,
    candidate.artists,
  );
  score += (artistSimilarity * 30).round();
  if (artistSimilarity >= 1) {
    reasons.add('исполнитель совпал');
  } else if (artistSimilarity > 0) {
    reasons.add('исполнитель похож');
  }

  if (source.duration > Duration.zero && candidate.duration > Duration.zero) {
    final int diff = (source.duration - candidate.duration).inSeconds.abs();
    if (diff <= 3) {
      score += 10;
      reasons.add('длительность совпала');
    } else if (diff <= 10) {
      score += 6;
      reasons.add('длительность близка');
    } else if (diff <= 20) {
      score += 3;
    } else if (diff > 60) {
      // Большая разница — обычно другая запись: лайв, ремикс, расширенная
      // версия. Штрафуем, но не отбрасываем: пусть решает пользователь.
      score -= 10;
      reasons.add('другая длительность');
    }
  }

  // Клип на ту же песню тоже подходит, но студийная дорожка — то, что обычно
  // ищут взамен пропавшего трека, поэтому у неё небольшой перевес.
  if (!candidate.isVideo) {
    score += 5;
    reasons.add('аудиозапись');
  }

  return SongCandidate(
    track: candidate,
    score: score.clamp(0, 100),
    reasons: reasons,
  );
}

/// Ищет замену недоступному треку в каталоге YouTube Music.
class SongReplacementFinder {
  const SongReplacementFinder(this._catalog);

  final CatalogSource _catalog;

  /// Возвращает кандидатов, отсортированных по убыванию совпадения.
  ///
  /// Пустой список — совпадений нет; придумывать «запасной» трек нельзя.
  Future<List<SongCandidate>> find(Track track, {int limit = 10}) async {
    final String query = _queryFor(track);
    if (query.isEmpty) return const <SongCandidate>[];

    final List<BrowseSection> sections = await _catalog.search(
      query,
      filter: SearchFilter.songs,
    );

    // Один и тот же трек может прийти в нескольких секциях ответа — держим
    // лучшее совпадение по id.
    final Map<String, SongCandidate> best = <String, SongCandidate>{};
    for (final BrowseSection section in sections) {
      for (final BrowseItem item in section.items) {
        if (item is! TrackItem) continue;
        final Track candidate = item.track;
        if (candidate.id == track.id) continue;

        final SongCandidate scored = scoreSongReplacement(
          source: track,
          candidate: candidate,
        );
        if (scored.score < kReplacementMinScore) continue;

        final SongCandidate? previous = best[candidate.id];
        if (previous == null || scored.score > previous.score) {
          best[candidate.id] = scored;
        }
      }
    }

    final List<SongCandidate> candidates = best.values.toList()
      ..sort((SongCandidate a, SongCandidate b) {
        final int byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        // При равном балле выше та запись, что ближе по длительности.
        return _durationDistance(
          track,
          a.track,
        ).compareTo(_durationDistance(track, b.track));
      });

    return candidates.take(limit.clamp(1, 50)).toList(growable: false);
  }

  /// Запрос к каталогу: исполнитель и название, как их вводит человек.
  String _queryFor(Track track) {
    final String title = track.title.trim();
    if (title.isEmpty) return '';
    if (track.artists.isEmpty) return title;
    final String artist = track.artists.first.name.trim();
    return artist.isEmpty ? title : '$artist $title';
  }
}

int _durationDistance(Track source, Track candidate) {
  if (source.duration <= Duration.zero || candidate.duration <= Duration.zero) {
    return 1 << 30;
  }
  return (source.duration - candidate.duration).inSeconds.abs();
}

/// Похожесть двух строк от 0 до 1.
///
/// Точное совпадение после нормализации — 1. Если все слова короткой строки
/// входят в длинную (YouTube дописывает «Official Video», «Remastered»),
/// считаем почти точным. Иначе — коэффициент Дайса по словам: он не даёт
/// одному общему слову перевесить всё название.
double _textSimilarity(String a, String b) {
  final String na = normalizeMatchText(a);
  final String nb = normalizeMatchText(b);
  if (na.isEmpty || nb.isEmpty) return 0;
  if (na == nb) return 1;

  final Set<String> ta = na.split(' ').toSet();
  final Set<String> tb = nb.split(' ').toSet();
  if (ta.isEmpty || tb.isEmpty) return 0;

  final Set<String> smaller = ta.length <= tb.length ? ta : tb;
  final Set<String> larger = identical(smaller, ta) ? tb : ta;
  if (smaller.every(larger.contains)) {
    // Совпадение по вхождению принимаем только у достаточно «весомой»
    // строки: одно короткое слово не должно перевешивать («Life» и
    // «Beautiful Life» — разные песни).
    final String shortText = identical(smaller, ta) ? na : nb;
    if (smaller.length >= 2 || shortText.length >= 6) return 0.85;
  }

  final int common = ta.intersection(tb).length;
  if (common == 0) return 0;
  return (2 * common) / (ta.length + tb.length) * 0.7;
}

/// Лучшая похожесть среди пар исполнителей.
double _artistSimilarity(List<ArtistRef> source, List<ArtistRef> candidate) {
  double best = 0;
  for (final ArtistRef a in source) {
    for (final ArtistRef b in candidate) {
      final double similarity = _textSimilarity(a.name, b.name);
      if (similarity > best) best = similarity;
    }
  }
  return best;
}
