import 'package:flutter_test/flutter_test.dart';
import 'package:mops/core/playback/listening_tracker.dart';

/// Правило засчитывания прослушивания проверяем без движка: счётчик знает
/// только позицию и её приращения.
void main() {
  const Duration total = Duration(seconds: 200);

  /// Прокручивает трек от [from] до [to] секундами по секунде.
  List<ListeningTick> play(
    ListeningTracker tracker,
    String id,
    int from,
    int to, {
    required void Function(Duration position) onTick,
  }) {
    final List<ListeningTick> ticks = <ListeningTick>[];
    for (int second = from; second <= to; second++) {
      final Duration position = Duration(seconds: second);
      final ListeningTick tick = tracker.advance(
        trackId: id,
        position: position,
        total: total,
        isPlaying: true,
      );
      ticks.add(tick);
      onTick(position);
    }
    return ticks;
  }

  group('счётчик прослушанного', () {
    test('новый трек начинает счёт с нуля', () {
      final ListeningTracker tracker = ListeningTracker();
      final ListeningTick tick = tracker.advance(
        trackId: 'a',
        position: const Duration(seconds: 40),
        total: total,
        isPlaying: true,
      );

      expect(tick, ListeningTick.started);
      expect(tracker.listened, Duration.zero,
          reason: 'позиция включения — не прослушанное время');
      expect(tracker.trackId, 'a');
    });

    test('копится только приращение, похожее на воспроизведение', () {
      final ListeningTracker tracker = ListeningTracker();
      tracker.advance(
        trackId: 'a',
        position: Duration.zero,
        total: total,
        isPlaying: true,
      );

      expect(
        tracker.advance(
          trackId: 'a',
          position: const Duration(seconds: 1),
          total: total,
          isPlaying: true,
        ),
        ListeningTick.progressed,
      );
      expect(tracker.listened, const Duration(seconds: 1));

      // Перемотка на минуту вперёд — не прослушивание.
      expect(
        tracker.advance(
          trackId: 'a',
          position: const Duration(seconds: 61),
          total: total,
          isPlaying: true,
        ),
        ListeningTick.none,
      );
      expect(tracker.listened, const Duration(seconds: 1));
    });

    test('на паузе время не идёт', () {
      final ListeningTracker tracker = ListeningTracker();
      tracker.advance(
        trackId: 'a',
        position: Duration.zero,
        total: total,
        isPlaying: true,
      );
      tracker.advance(
        trackId: 'a',
        position: const Duration(milliseconds: 200),
        total: total,
        isPlaying: true,
      );
      expect(tracker.listened, const Duration(milliseconds: 200));

      expect(
        tracker.advance(
          trackId: 'a',
          position: const Duration(seconds: 30),
          total: total,
          isPlaying: false,
        ),
        ListeningTick.none,
      );
      expect(tracker.listened, const Duration(milliseconds: 200),
          reason: 'пауза не добавляет время');
    });

    test('перемотка в начало — новое проигрывание', () {
      final ListeningTracker tracker = ListeningTracker();
      play(tracker, 'a', 0, 120, onTick: (Duration _) {});
      expect(tracker.listened, const Duration(seconds: 120));

      // Пользователь нажал «в начало».
      expect(
        tracker.advance(
          trackId: 'a',
          position: Duration.zero,
          total: total,
          isPlaying: true,
        ),
        ListeningTick.started,
      );
      expect(tracker.listened, Duration.zero,
          reason: 'второй раз трек слушают заново');
    });

    test('возврат не в начало счёт не сбрасывает', () {
      final ListeningTracker tracker = ListeningTracker();
      play(tracker, 'a', 0, 100, onTick: (Duration _) {});

      expect(
        tracker.advance(
          trackId: 'a',
          position: const Duration(seconds: 40),
          total: total,
          isPlaying: true,
        ),
        ListeningTick.none,
      );
      expect(tracker.listened, const Duration(seconds: 100),
          reason: 'перемотка назад — не повод забыть уже сыгранное');
    });

    test('завершение засчитывает трек целиком', () {
      final ListeningTracker tracker = ListeningTracker();
      play(tracker, 'a', 0, 5, onTick: (Duration _) {});

      final ListeningTick tick = tracker.advance(
        trackId: 'a',
        position: total,
        total: total,
        isPlaying: false,
        completed: true,
      );
      expect(tick, ListeningTick.completed);
      expect(tracker.listened, total);
    });

    test('завершение прошлого трека после смены текущего не засчитывается', () {
      final ListeningTracker tracker = ListeningTracker();
      play(tracker, 'a', 0, 150, onTick: (Duration _) {});

      // Очередь переключилась на «b», а движок прислал конец «a» уже на новом
      // треке: только что начавшийся трек доиграть не мог.
      final ListeningTick tick = tracker.advance(
        trackId: 'b',
        position: Duration.zero,
        total: total,
        isPlaying: false,
        completed: true,
      );

      expect(tick, ListeningTick.started);
      expect(tracker.listened, Duration.zero);
    });
  });

  group('порог засчитывания', () {
    test('половина трека или четыре минуты — что раньше', () {
      expect(listenThreshold(const Duration(seconds: 200)),
          const Duration(seconds: 100));
      expect(listenThreshold(const Duration(minutes: 20)),
          const Duration(minutes: 4));
      expect(listenThreshold(Duration.zero), const Duration(minutes: 4));
    });

    test('короткий трек засчитывается после половины', () {
      expect(
        shouldCreditListen(
          total: const Duration(seconds: 40),
          listened: const Duration(seconds: 19),
        ),
        isFalse,
      );
      expect(
        shouldCreditListen(
          total: const Duration(seconds: 40),
          listened: const Duration(seconds: 20),
        ),
        isTrue,
      );
    });

    test('порог площадки блокирует короткий трек', () {
      const Duration minDuration = Duration(seconds: 30);
      expect(
        shouldCreditListen(
          total: const Duration(seconds: 20),
          listened: const Duration(seconds: 20),
          minDuration: minDuration,
        ),
        isFalse,
      );
      expect(
        shouldCreditListen(
          total: const Duration(seconds: 60),
          listened: const Duration(seconds: 30),
          minDuration: minDuration,
        ),
        isTrue,
      );
    });
  });
}
