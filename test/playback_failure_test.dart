import 'package:flutter_test/flutter_test.dart';
import 'package:mops/core/playback/playback_failure.dart';
import 'package:mops/data/sources/stream_resolver.dart';

/// Причина сбоя — код для логики, а не подстрока в тексте сообщения.
void main() {
  group('причина по ошибке резолвера', () {
    test('ограничение площадки — недоступно', () {
      expect(
        failureOfResolution(
          StreamResolutionException(
            'YouTube не отдаёт это видео: оно недоступно в вашем регионе '
            'или требует вход в аккаунт.',
          ),
        ),
        PlaybackFailure.unavailable,
      );
    });

    test('требование входа отличается от недоступности', () {
      expect(
        failureOfResolution(
          StreamResolutionException(
            'YouTube требует вход в аккаунт для этого видео.',
          ),
        ),
        PlaybackFailure.needsLogin,
      );
    });

    test('сетевая ошибка — повод повторить, а не искать замену', () {
      expect(
        failureOfResolution(
          StreamResolutionException(
            'Не удалось получить аудиопоток. Проверьте соединение.',
          ),
        ),
        PlaybackFailure.other,
      );
      expect(
        failureOfResolution(
          StreamResolutionException(
            'Не удалось получить поток: сети нет или соединение с '
            'YouTube блокируется.',
          ),
        ),
        PlaybackFailure.offline,
      );
    });
  });

  test('ошибка плеера несёт причину явно', () {
    const PlaybackFailureException error = PlaybackFailureException(
      'Файл не найден',
      PlaybackFailure.unavailable,
    );

    expect(error.reason, PlaybackFailure.unavailable);
    expect(error.toString(), 'Файл не найден');
  });
}
