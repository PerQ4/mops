/// Правило засчитывания прослушивания — одно на всё приложение.
///
/// Счётчик один: журнал статистики и скробблер получают время из одного
/// [ListeningTracker], поэтому «сколько сыграно» у них совпадает всегда. Разным
/// остаётся только порог площадки (Last.fm не берёт треки короче 30 секунд), и
/// он передаётся в [shouldCreditListen] параметром, а не вторым счётчиком.
library;

/// Предел правдоподобного приращения позиции.
///
/// Больше — значит перемотка или подвисание, а не прослушивание: такой скачок в
/// зачёт не идёт. Раньше у статистики и скробблера окна были разными (2 и 5
/// секунд), из-за чего один и тот же трек засчитывался по-разному.
const Duration kListenSeekWindow = Duration(seconds: 2);

/// Ближе этого к началу перемотка назад считается новым проигрыванием.
///
/// По этой позиции отличаем повтор («в начало») от обычного возврата на пару
/// минут назад: в первом случае трек слушают заново, во втором — продолжают.
const Duration kListenRestartPosition = Duration(seconds: 3);

/// Что произошло на тике позиции.
enum ListeningTick {
  /// Ничего: пауза, перемотка или повторный тик на месте.
  none,

  /// Идёт накопление прослушанного.
  progressed,

  /// Началось новое проигрывание: сменился трек или его слушают заново.
  started,

  /// Трек доиграл до конца.
  completed,
}

/// Порог засчитывания: половина трека или четыре минуты — что раньше.
///
/// Длительность неизвестна — считаем по четырём минутам: это верхняя граница
/// того же правила.
Duration listenThreshold(Duration total) {
  if (total <= Duration.zero) return const Duration(minutes: 4);
  final Duration half = total ~/ 2;
  return half < const Duration(minutes: 4) ? half : const Duration(minutes: 4);
}

/// Пора ли засчитывать прослушивание.
///
/// [minDuration] — порог площадки: трек короче него не засчитывается вовсе
/// (Last.fm такое не принимает). Для журнала статистики порога нет.
bool shouldCreditListen({
  required Duration total,
  required Duration listened,
  Duration minDuration = Duration.zero,
}) {
  if (total > Duration.zero && total <= minDuration) return false;
  return listened >= listenThreshold(total);
}

/// Ход одного трека: сколько реально сыграно и где была позиция на прошлом тике.
///
/// Ничего не знает ни о движке, ни о площадках — поэтому проверяется тестом без
/// media_kit и без сети.
class ListeningTracker {
  String? _trackId;
  Duration _listened = Duration.zero;
  Duration _lastPosition = Duration.zero;

  /// Трек, для которого ведётся счёт.
  String? get trackId => _trackId;

  /// Реально проигранное время текущего проигрывания.
  Duration get listened => _listened;

  /// Забывает всё: очередь пуста или трека больше нет.
  void reset() {
    _trackId = null;
    _listened = Duration.zero;
    _lastPosition = Duration.zero;
  }

  /// Учитывает тик позиции.
  ///
  /// [total] — длительность трека; [completed] — движок сообщил о завершении.
  /// Завершение, пришедшее вместе со сменой трека, не учитывается: только что
  /// начавшийся трек доиграть не мог, а засчитывать его целиком нельзя.
  ListeningTick advance({
    required String trackId,
    required Duration position,
    required Duration total,
    required bool isPlaying,
    bool completed = false,
  }) {
    if (trackId != _trackId) {
      _start(trackId, position);
      return ListeningTick.started;
    }

    final Duration delta = position - _lastPosition;
    _lastPosition = position;

    // Возврат в начало — новое проигрывание, а не продолжение: иначе повтор
    // не засчитался бы никогда.
    if (delta < -kListenSeekWindow && position <= kListenRestartPosition) {
      _start(trackId, position);
      return ListeningTick.started;
    }

    if (completed) {
      _listened = total > Duration.zero ? total : _listened;
      return ListeningTick.completed;
    }

    if (isPlaying && delta > Duration.zero && delta <= kListenSeekWindow) {
      _listened += delta;
      return ListeningTick.progressed;
    }
    return ListeningTick.none;
  }

  void _start(String trackId, Duration position) {
    _trackId = trackId;
    _listened = Duration.zero;
    _lastPosition = position;
  }
}
