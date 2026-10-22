import '../../data/sources/stream_resolver.dart';

/// Почему трек не заиграл.
///
/// Код, а не текст сообщения: от причины зависит поведение (искать замену,
/// предложить войти, просто повторить), а текст можно переписать в любой момент.
enum PlaybackFailure {
  /// Трека нет на площадке: удалён, скрыт или ограничен по региону.
  unavailable,

  /// Нужен вход в аккаунт — замена здесь не поможет.
  needsLogin,

  /// Сеть или блокировка: помогает повтор, а не замена.
  offline,

  /// Всё остальное (файл пропал, неизвестный сбой).
  other,
}

/// Ошибка воспроизведения с явной причиной.
///
/// Бросается плеером там, где причина известна точно (например, локальный файл
/// удалили с диска), чтобы выше по стеку не гадать по тексту.
class PlaybackFailureException implements Exception {
  const PlaybackFailureException(this.message, this.reason);

  final String message;
  final PlaybackFailure reason;

  @override
  String toString() => message;
}

/// Причина по ошибке резолвера.
///
/// Резолвер сам ставит отметку [StreamResolutionException.unavailable], когда
/// сервер потока ответил явным отказом: такой случай (503 на ссылку) по тексту
/// от «видео недоступно» не отличить, а от него зависит, предложить ли
/// замену. Остальные причины по-прежнему различаются по тексту: других
/// признаков у ошибки нет.
PlaybackFailure failureOfResolution(StreamResolutionException error) {
  if (error.unavailable) return PlaybackFailure.unavailable;

  final String message = error.message.toLowerCase();
  // «Недоступно» проверяем раньше входа: в тексте про регион вход упомянут
  // как вторая причина, но замена трека нужна именно там.
  if (message.contains('недоступно') || message.contains('недоступен')) {
    return PlaybackFailure.unavailable;
  }
  if (message.contains('требует вход') || message.contains('войдите')) {
    return PlaybackFailure.needsLogin;
  }
  if (message.contains('сети нет') || message.contains('блокируется')) {
    return PlaybackFailure.offline;
  }
  return PlaybackFailure.other;
}
