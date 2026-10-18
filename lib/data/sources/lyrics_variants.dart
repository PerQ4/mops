import '../../state/catalog_providers.dart';
import '../models/models.dart';

/// Сколько вариантов брать у одного источника.
///
/// В ArchiveTune база отдаёт все совпадения, но там текст приходит вместе с
/// ответом поиска — одним обращением. У нас часть источников требует отдельного
/// запроса за каждым текстом, поэтому число вариантов ограничено: список должен
/// оставаться читаемым, а поиск — не превращаться в десяток запросов.
const int kMaxLyricsVariants = 4;

/// Достаёт тексты нескольких найденных записей — параллельно.
///
/// Записи берём по порядку совпадения: первые в списке — самые похожие на
/// запрос. Пустые ответы отбрасываются: карточка без текста не нужна.
Future<List<Lyrics>> fetchVariants(
  List<LyricsTrackHit> hits,
  Future<Lyrics> Function(LyricsTrackHit hit) fetch,
) async {
  if (hits.isEmpty) return const <Lyrics>[];
  final List<Lyrics> fetched = await Future.wait(
    hits.take(kMaxLyricsVariants).map(fetch),
  );
  return fetched.where((Lyrics lyrics) => !lyrics.isEmpty).toList(
        growable: false,
      );
}
