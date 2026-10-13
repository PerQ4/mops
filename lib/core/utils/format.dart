/// Форматирование длительностей, чисел и подписей для интерфейса.
library;

/// `Duration` → `3:45` или `1:02:33`.
String formatDuration(Duration? duration) {
  if (duration == null || duration <= Duration.zero) return '--:--';

  final int totalSeconds = duration.inSeconds;
  final int hours = totalSeconds ~/ 3600;
  final int minutes = (totalSeconds % 3600) ~/ 60;
  final int seconds = totalSeconds % 60;

  final String mm = hours > 0 ? minutes.toString().padLeft(2, '0') : '$minutes';
  final String ss = seconds.toString().padLeft(2, '0');

  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}

/// `Duration` для плеера: всегда `чч:мм:сс`-совместимый короткий вид.
String formatDurationClock(Duration? duration) =>
    formatDuration(duration).replaceFirst('--:--', '0:00');

/// Единица времени, как её показывает YouTube Music: «3:45» без ведущих нулей.
String formatTimestamp(Duration duration) {
  final int totalSeconds = duration.inSeconds.abs();
  final int hours = totalSeconds ~/ 3600;
  final int minutes = (totalSeconds % 3600) ~/ 60;
  final int seconds = totalSeconds % 60;

  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// «1,2 тыс.» / «3,4 млн» — человекочитаемое число.
String formatCompactCount(int count) {
  if (count < 1000) return '$count';
  if (count < 1000000) {
    final double value = count / 1000;
    return '${_trim(value)} тыс.';
  }
  if (count < 1000000000) {
    final double value = count / 1000000;
    return '${_trim(value)} млн';
  }
  return '${_trim(count / 1000000000)} млрд';
}

String _trim(double value) {
  final String text = value.toStringAsFixed(value >= 100 ? 0 : 1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

/// «5 треков», «1 трек», «21 трек» — согласование с числительным.
String trackCountLabel(int? count) => _plural(count, 'трек', 'трека', 'треков');

/// Аналогично для плейлистов.
String playlistCountLabel(int? count) =>
    _plural(count, 'плейлист', 'плейлиста', 'плейлистов');

/// Аналогично для исполнителей.
String artistCountLabel(int? count) =>
    _plural(count, 'исполнитель', 'исполнителя', 'исполнителей');

String _plural(int? count, String one, String few, String many) {
  if (count == null) return '';
  final int n = count.abs() % 100;
  final int n1 = n % 10;
  final String word;
  if (n >= 11 && n <= 14) {
    word = many;
  } else if (n1 == 1) {
    word = one;
  } else if (n1 >= 2 && n1 <= 4) {
    word = few;
  } else {
    word = many;
  }
  return '$count $word';
}

/// Убирает суффиксы вида « - Topic», которые YouTube добавляет авто-каналам.
String cleanArtistName(String name) {
  const List<String> suffixes = <String>[' - Topic', ' - Topic', ' – Topic'];
  String result = name;
  for (final String suffix in suffixes) {
    if (result.endsWith(suffix)) {
      result = result.substring(0, result.length - suffix.length);
    }
  }
  return result.trim();
}
