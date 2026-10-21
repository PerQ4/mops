import 'package:flutter_test/flutter_test.dart';
import 'package:mops/core/playback/listening_tracker.dart';
import 'package:mops/core/playback/scrobble_rules.dart';
import 'package:mops/data/models/models.dart';

/// Правила скробблинга — чистые: ни сети, ни движка, ни Riverpod.
void main() {
  const Duration total = Duration(seconds: 200);

  Track track({
    String id = 'video',
    String title = 'Песня',
    List<String> artists = const <String>['Исполнитель'],
  }) {
    return Track(
      id: id,
      title: title,
      artists: <ArtistRef>[
        for (final String name in artists) ArtistRef(name: name),
      ],
      duration: total,
    );
  }

  group('что вообще можно отправлять', () {
    test('обычный трек с исполнителем — можно', () {
      expect(isScrobbleable(track(), isPodcast: false), isTrue);
    });

    test('трек без исполнителя — нельзя', () {
      expect(
        isScrobbleable(track(artists: const <String>[]), isPodcast: false),
        isFalse,
        reason: '«Неизвестный исполнитель» в профиле — выдуманный артист',
      );
      expect(
        isScrobbleable(track(artists: const <String>['  ']), isPodcast: false),
        isFalse,
      );
    });

    test('локальный файл — нельзя', () {
      expect(
        isScrobbleable(track(id: r'local:C:\music\a.mp3'), isPodcast: false),
        isFalse,
      );
    });

    test('эпизод подкаста — нельзя', () {
      expect(isScrobbleable(track(), isPodcast: true), isFalse);
    });
  });

  group('решение об отправке', () {
    late ListeningTracker tracker;
    late ScrobbleRule rule;
    late int nowPlaying;
    late int scrobbles;

    /// Один тик так, как его делает плеер: сначала счётчик, потом правило.
    ListeningTick tick(
      Track current,
      Duration position, {
      bool playing = true,
      bool completed = false,
      int seconds = 200,
    }) {
      final ListeningTick result = tracker.advance(
        trackId: current.id,
        position: position,
        total: Duration(seconds: seconds),
        isPlaying: playing,
        completed: completed,
      );
      final ScrobbleActions actions = rule.advance(
        track: current,
        total: Duration(seconds: seconds),
        listened: tracker.listened,
        tick: result,
        isPlaying: playing,
        isPodcast: false,
      );
      if (actions.nowPlaying) nowPlaying++;
      if (actions.scrobble) scrobbles++;
      return result;
    }

    void play(
      Track current,
      int from,
      int to, {
      int seconds = 200,
    }) {
      for (int second = from; second <= to; second++) {
        tick(
          current,
          Duration(seconds: second),
          seconds: seconds,
        );
      }
    }

    setUp(() {
      tracker = ListeningTracker();
      rule = ScrobbleRule();
      nowPlaying = 0;
      scrobbles = 0;
    });

    test('«сейчас играет» уходит один раз за проигрывание', () {
      final Track current = track();
      play(current, 0, 10);

      expect(nowPlaying, 1);
      expect(scrobbles, 0);
    });

    test('трек без исполнителя не отправляется вовсе', () {
      final Track anonymous = track(artists: const <String>[]);
      play(anonymous, 0, 200);

      expect(nowPlaying, 0);
      expect(scrobbles, 0);
    });

    test('короткий трек не засчитывается', () {
      final Track short = track();
      for (int second = 0; second <= 25; second++) {
        tick(short, Duration(seconds: second), seconds: 25);
      }

      expect(scrobbles, 0, reason: 'Last.fm не принимает треки короче 30 с');
    });

    test('прослушивание уходит один раз, когда набралась половина', () {
      final Track current = track();
      play(current, 0, 99);
      expect(scrobbles, 0);

      play(current, 100, 130);
      expect(scrobbles, 1);
    });

    test('повтор после ручной перемотки в начало засчитывается снова', () {
      final Track current = track();
      play(current, 0, 120);
      expect(scrobbles, 1);

      // Пользователь нажал «в начало»: счётчик начинает новое проигрывание.
      expect(tick(current, Duration.zero), ListeningTick.started);
      play(current, 1, 120);

      expect(scrobbles, 2, reason: 'повтор — это отдельное прослушивание');
      expect(nowPlaying, 2);
    });

    test('пауза на зачёт не влияет, но и время не добавляет', () {
      final Track current = track();
      play(current, 0, 40);
      // Пауза на минуту: позиция стоит.
      tick(current, const Duration(seconds: 40), playing: false);
      tick(current, const Duration(seconds: 40), playing: false);
      expect(scrobbles, 0);

      play(current, 41, 100);
      expect(scrobbles, 1);
    });

    test('Play→Pause на 200 мс не засчитывается', () {
      final Track current = track();
      tick(current, Duration.zero);
      tick(current, const Duration(milliseconds: 200));
      tick(current, const Duration(milliseconds: 200), playing: false);

      expect(scrobbles, 0);
    });

    test('конец прошлого трека после смены текущего не засчитывает новый', () {
      final Track first = track(id: 'a');
      final Track second = track(id: 'b', title: 'Другая');
      play(first, 0, 150);
      expect(scrobbles, 1, reason: 'первый трек уже заслужен');
      final int afterFirst = scrobbles;

      // Движок прислал завершение «a», когда текущим уже стал «b».
      tick(second, Duration.zero, playing: false, completed: true);

      expect(scrobbles, afterFirst,
          reason: '«b» только начался — засчитывать нечего');
      expect(tracker.listened, Duration.zero);
    });

    test('завершение доигранного трека засчитывается целиком', () {
      final Track current = track();
      play(current, 0, 30);
      tick(current, total, playing: false, completed: true);

      expect(scrobbles, 1);
    });
  });
}
