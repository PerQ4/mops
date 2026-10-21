import '../../data/local/local_media.dart';
import '../../data/models/models.dart';
import 'listening_tracker.dart';

/// Короче этого трек в профиль не отправляется: правило Last.fm, но оно же
/// годится и для ListenBrainz — короткие служебные вставки там тоже лишние.
const Duration kScrobbleMinDuration = Duration(seconds: 30);

/// Имена исполнителей, которые можно отправить.
///
/// Пустые имена отбрасываем: иначе в профиль ушла бы пустая строка, а
/// подстановка «Неизвестный исполнитель» создала бы выдуманного артиста.
List<String> trackArtistNames(Track track) => <String>[
      for (final ArtistRef artist in track.artists)
        if (artist.name.trim().isNotEmpty) artist.name.trim(),
    ];

/// Трек вообще можно отправлять в профиль пользователя.
///
/// Отсекаем три случая: локальный файл (у него нет идентификатора площадки),
/// эпизод подкаста (не музыка) и трек без исполнителя.
bool isScrobbleable(Track track, {required bool isPodcast}) {
  if (isPodcast) return false;
  if (isLocalTrackId(track.id)) return false;
  return trackArtistNames(track).isNotEmpty;
}

/// Что отправить после очередного тика позиции.
class ScrobbleActions {
  const ScrobbleActions({this.nowPlaying = false, this.scrobble = false});

  static const ScrobbleActions none = ScrobbleActions();

  /// Отправить «сейчас играет».
  final bool nowPlaying;

  /// Зачесть прослушивание.
  final bool scrobble;

  bool get isEmpty => !nowPlaying && !scrobble;
}

/// Решение «отправлять ли» для одного проигрывания.
///
/// Чистое правило: ни сети, ни Riverpod, ни движка — поэтому проверяется тестом
/// без заглушек. Контроллер только исполняет [ScrobbleActions].
class ScrobbleRule {
  ScrobbleRule({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  String? _trackId;
  String _artist = '';
  String _title = '';
  String? _album;
  Duration _total = Duration.zero;
  DateTime? _startedAt;
  bool _nowPlayingSent = false;
  bool _scrobbled = false;

  String? get trackId => _trackId;
  String get artist => _artist;
  String get title => _title;
  String? get album => _album;

  /// Когда началось текущее проигрывание: это время уходит на площадку.
  DateTime? get startedAt => _startedAt;

  /// Длительность текущего трека.
  Duration get total => _total;

  /// Длительность в секундах для запроса; `null`, если она неизвестна.
  int? get durationSeconds =>
      _total > Duration.zero ? _total.inSeconds : null;

  /// Забывает всё: очередь пуста или трека больше нет.
  void reset() {
    _trackId = null;
    _artist = '';
    _title = '';
    _album = null;
    _total = Duration.zero;
    _startedAt = null;
    _nowPlayingSent = false;
    _scrobbled = false;
  }

  /// Учитывает тик и говорит, что отправить.
  ///
  /// [listened] и [tick] приходят из общего [ListeningTracker]: правило только
  /// решает, когда накопленного достаточно.
  ScrobbleActions advance({
    required Track track,
    required Duration total,
    required Duration listened,
    required ListeningTick tick,
    required bool isPlaying,
    required bool isPodcast,
  }) {
    if (track.id != _trackId) {
      _trackId = track.id;
      _artist = trackArtistNames(track).join(', ');
      _title = track.title;
      _album = track.album?.name;
      _total = total;
      _startedAt = _clock();
      _nowPlayingSent = false;
      _scrobbled = false;
    }
    // Длительность могла уточниться: движок узнаёт её позже модели.
    if (total > Duration.zero) _total = total;

    if (tick == ListeningTick.started) {
      // Повтор того же трека: и «сейчас играет», и зачёт начинаются заново,
      // иначе второй раз не отправился бы никогда.
      _startedAt = _clock();
      _nowPlayingSent = false;
      _scrobbled = false;
    }

    // Локальный файл, подкаст и трек без исполнителя не отправляем вообще:
    // ни «сейчас играет», ни прослушивание.
    if (!isScrobbleable(track, isPodcast: isPodcast)) {
      return ScrobbleActions.none;
    }

    final bool nowPlaying = isPlaying && !_nowPlayingSent;
    if (nowPlaying) _nowPlayingSent = true;

    final bool scrobble = !_scrobbled &&
        (tick == ListeningTick.progressed ||
            tick == ListeningTick.completed) &&
        shouldCreditListen(
          total: total,
          listened: listened,
          minDuration: kScrobbleMinDuration,
        );
    if (scrobble) _scrobbled = true;

    return ScrobbleActions(nowPlaying: nowPlaying, scrobble: scrobble);
  }
}
