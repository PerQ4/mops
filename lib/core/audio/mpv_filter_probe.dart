import 'dart:async';

import 'package:media_kit/media_kit.dart';

/// Разовая проверка, знает ли эта сборка libmpv тот или иной фильтр FFmpeg.
///
/// Зачем отдельный пробный плеер, а не живой. mpv разбирает цепочку `af` в
/// момент установки и при неизвестном фильтре (или неверном параметре) пишет
/// отказ в поток ошибок. На живом плеере этот отказ уходит в движок и обрывает
/// воспроизведение, а чтение `af-metadata/...` по метке, которой в цепочке нет,
/// в некоторых сборках роняет libmpv. Поэтому проверка идёт на ОТДЕЛЬНОМ пустом
/// плеере: медиа в него не грузится, аудиовыход не занимается, а внимать ошибке
/// некому. Ответ кэшируется: это свойство сборки, а не трека.
///
/// Тем же приёмом пользуется [AudioLevelMonitor] для `astats` — здесь общая
/// реализация, чтобы проверка фильтров не расползалась копиями.
class MpvFilterProbe {
  MpvFilterProbe._();

  /// Сколько ждём ответ mpv: цепочку он разбирает сразу, но отказ доходит
  /// потоком событий — даём ему время.
  static const Duration _window = Duration(milliseconds: 600);

  static final Map<String, Future<bool>> _results = <String, Future<bool>>{};
  static final Map<String, String> _rejections = <String, String>{};

  /// Метка пробной цепочки. Отдельная от рабочих: отказ по ней не спутать с
  /// рабочими метками, а `af-metadata` проб не читается вовсе.
  static const String _probeLabel = 'mopsprobe';

  /// Есть ли в сборке фильтр [name] с параметрами [params].
  ///
  /// [params] задаются ровно так, как пойдут в рабочую цепочку (без метки):
  /// иначе проверка проверяла бы не то, что будет применяться.
  static Future<bool> supports(String name, String params) {
    final String key = '$name|$params';
    return _results.putIfAbsent(key, () => _probe(name, params));
  }

  /// Слова mpv, которыми он отказал в фильтре, — причина для пользователя.
  static String? rejection(String name) => _rejections[name];

  static Future<bool> _probe(String name, String params) async {
    Player? probe;
    StreamSubscription<String>? errors;
    final String filter = params.isEmpty ? name : '$name=$params';
    try {
      probe = Player(configuration: const PlayerConfiguration(pitch: false));
      final PlatformPlayer? platform = probe.platform;
      if (platform is! NativePlayer) {
        _rejections[name] = 'у платформы нет свойств mpv';
        return false;
      }
      final Completer<String> rejected = Completer<String>();
      errors = probe.stream.error.listen((String message) {
        if (!rejected.isCompleted && _mentions(message, name)) {
          rejected.complete(message);
        }
      });
      await platform.setProperty('af', '@$_probeLabel:$filter');
      final String? message = await Future.any<String?>(<Future<String?>>[
        rejected.future,
        Future<String?>.delayed(_window),
      ]);
      if (message != null) _rejections[name] = message;
      return message == null;
    } on Object catch (error) {
      _rejections[name] = 'проверка фильтра не удалась: $error';
      return false;
    } finally {
      await errors?.cancel();
      await probe?.dispose();
    }
  }

  /// Ошибка, которой mpv сообщает, что фильтра нет или что он отвергнут.
  ///
  /// Ловим по словам, а не «любую ошибку»: на пустом плеере бывают и посторонние
  /// сообщения (например, о кэше файлов), и принять их за отказ нельзя.
  static bool _mentions(String message, String name) {
    final String text = message.toLowerCase();
    return text.contains(name.toLowerCase()) || _soundsLikeFilterRejection(text);
  }

  /// Отказ, который не означает сбой трека: неизвестный фильтр, неверный
  /// параметр или сборка цепочки. По такому сообщению движок звук не обрывает.
  static bool looksLikeFilterError(String message) =>
      _soundsLikeFilterRejection(message.toLowerCase());

  static bool _soundsLikeFilterRejection(String text) {
    if (text.contains('superequalizer') ||
        text.contains('dynaudnorm') ||
        text.contains('silenceremove') ||
        text.contains('loudnorm')) {
      return true;
    }
    // «Option af: equalizer doesn't exist» и подобные — про цепочку целиком.
    if ((text.contains('af') || text.contains('filter')) &&
        (text.contains('exist') ||
            text.contains('not found') ||
            text.contains('unknown') ||
            text.contains('invalid'))) {
      return true;
    }
    // Параметр фильтра не принят: «Option 1b not found» и подобное.
    return text.contains('option') && text.contains('not found');
  }
}
