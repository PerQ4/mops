import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';

/// Разовая проверка, знает ли эта сборка libmpv тот или иной фильтр FFmpeg.
///
/// **Почему отдельный пробный плеер, а не живой.** mpv разбирает цепочку `af`
/// в момент установки и при неизвестном фильтре (или неверном параметре) пишет
/// отказ в поток ошибок. На живом плеере этот отказ уходит в движок и обрывает
/// воспроизведение, а чтение `af-metadata/...` по метке, которой в цепочке нет,
/// в некоторых сборках роняет libmpv. Поэтому проверка идёт на ОТДЕЛЬНОМ
/// плеере: аудиовыход не занимается (`ao=null`), а внимать ошибке некому.
/// Ответ кэшируется: это свойство сборки, а не трека.
///
/// **Почему на пустом плеере проверять нельзя.** Пустому плееру фильтр не
/// нужен: mpv принимает значение `af` и откладывает сборку до появления звука.
/// Битый граф или неподходящий параметр всплывают только при воспроизведении,
/// и проверка «на пустом» пропускала бы их к живому плееру. Поэтому каждая
/// проба открывает короткий настоящий WAV и ждёт после `playing`, а после
/// этого читает `af` обратно: при отказе mpv оставляет прежнюю цепочку, и
/// метки в ней не будет.
///
/// Тем же приёмом пользуется [AudioLevelMonitor] для `astats` — здесь общая
/// реализация, чтобы проверка фильтров не расползалась копиями.
class MpvFilterProbe {
  MpvFilterProbe._();

  static final Map<String, Future<bool>> _results = <String, Future<bool>>{};
  static final Map<String, String> _rejections = <String, String>{};

  /// Метка пробной цепочки. Отдельная от рабочих: отказ по ней не спутать с
  /// рабочими метками, а `af-metadata` проб не читается вовсе.
  static const String _probeLabel = 'mopsprobe';

  /// Сколько ждём после `playing`, чтобы отказ фильтра успел дойти: событие
  /// «играет» приходит раньше, чем mpv соберёт граф.
  static const Duration _settleDelay = Duration(milliseconds: 600);

  /// Сколько всего ждём ответа на пробу: на медленной машине инициализация
  /// звука и первого фильтра бывает небыстрой.
  static const Duration _probeWindow = Duration(seconds: 3);

  /// Есть ли в сборке фильтр [name] с параметрами [params].
  ///
  /// [params] задаются ровно так, как пойдут в рабочую цепочку (без метки):
  /// иначе проверка проверяла бы не то, что будет применяться.
  static Future<bool> supports(String name, String params) {
    final String key = '$name|$params';
    final String filter = params.isEmpty ? name : '$name=$params';
    return _results.putIfAbsent(key, () => _probe(filter, name));
  }

  /// Слова mpv, которыми он отказал в фильтре, — причина для пользователя.
  static String? rejection(String name) => _rejections[name];

  /// Проверяет граф `lavfi` по-настоящему — с потоком звука.
  ///
  /// Пустому плееру граф не нужен, и mpv принимает даже неверный: разбор
  /// откладывается до появления аудио. Проверка «на пустом» поэтому пропускает
  /// битый граф к живому плееру, где он уже рвёт воспроизведение.
  static Future<bool> supportsGraph(String graph) {
    final String key = 'lavfi|graph|$graph';
    return _results.putIfAbsent(key, () => _probe('lavfi=[$graph]', 'lavfi'));
  }

  /// Общая проба: настоящий звук, `ao=null`, ожидание после `playing`.
  ///
  /// [filter] — запись фильтра без метки, [name] — имя для причины отказа.
  static Future<bool> _probe(String filter, String name) async {
    Player? probe;
    StreamSubscription<String>? errors;
    StreamSubscription<bool>? playing;
    Directory? temp;
    try {
      probe = Player(configuration: const PlayerConfiguration(pitch: false));
      final PlatformPlayer? platform = probe.platform;
      if (platform is! NativePlayer) {
        _rejections[name] = 'у платформы нет свойств mpv';
        return false;
      }
      // Звук не выводим: устройство не занимаем, а фильтр всё равно собирается.
      await platform.setProperty('ao', 'null');

      final Completer<String> rejected = Completer<String>();
      final Completer<bool> settled = Completer<bool>();
      errors = probe.stream.error.listen((String message) {
        if (!rejected.isCompleted && _mentions(message, name)) {
          rejected.complete(message);
        }
      });
      playing = probe.stream.playing.listen((bool value) {
        if (!value || settled.isCompleted) return;
        Future<void>.delayed(_settleDelay, () {
          if (!settled.isCompleted && !rejected.isCompleted) {
            settled.complete(true);
          }
        });
      });

      temp = await Directory.systemTemp.createTemp('mops_filter_probe');
      final File wav = await _toneWav(temp);
      await platform.setProperty('af', '@$_probeLabel:$filter');
      await probe.open(Media(Uri.file(wav.path).toString()));

      final bool accepted = await Future.any<bool>(<Future<bool>>[
        rejected.future.then((String message) {
          _rejections[name] = message;
          return false;
        }),
        settled.future,
        Future<bool>.delayed(_probeWindow, () {
          _rejections[name] ??=
              'фильтр не собрался за ${_probeWindow.inSeconds} с';
          return false;
        }),
      ]);
      if (!accepted) return false;

      // Пост-проверка: mpv при отказе оставляет прежнюю цепочку, поэтому
      // метки в прочитанном `af` быть не должно только в случае отказа.
      final String applied = (await platform.getProperty('af')).trim();
      if (!applied.contains('@$_probeLabel')) {
        _rejections[name] = 'mpv не принял фильтр «$filter»';
        return false;
      }
      return true;
    } on Object catch (error) {
      _rejections[name] = 'проверка фильтра не удалась: $error';
      return false;
    } finally {
      await errors?.cancel();
      await playing?.cancel();
      await probe?.dispose();
      try {
        await temp?.delete(recursive: true);
      } on FileSystemException {
        // Временная папка могла не создаться.
      }
    }
  }

  /// Короткий тихий тон: нужен только чтобы фильтру было что обрабатывать.
  ///
  /// Совсем нулевые сэмплы не годятся: часть фильтров на цифровой тишине
  /// ничего не делает, и проверка снова стала бы формальной.
  static Future<File> _toneWav(Directory dir) async {
    const int rate = 44100;
    final int frames = rate; // секунда: фильтру хватает, чтобы собраться
    final int dataSize = frames * 4;
    final ByteData data = ByteData(44 + dataSize);
    void ascii(int offset, String text) {
      for (int i = 0; i < text.length; i++) {
        data.setUint8(offset + i, text.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    data.setUint32(4, 36 + dataSize, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little); // PCM
    data.setUint16(22, 2, Endian.little); // стерео
    data.setUint32(24, rate, Endian.little);
    data.setUint32(28, rate * 4, Endian.little);
    data.setUint16(32, 4, Endian.little);
    data.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, dataSize, Endian.little);

    // 440 Гц с малой амплитудой: слышно не будет (ao=null), но звук настоящий.
    const double amplitude = 0.1;
    for (int frame = 0; frame < frames; frame++) {
      final double sample =
          amplitude * math.sin(2 * math.pi * 440 * frame / rate);
      final int value = (sample * 32767).round();
      final int offset = 44 + frame * 4;
      data.setInt16(offset, value, Endian.little);
      data.setInt16(offset + 2, value, Endian.little);
    }

    final File file = File('${dir.path}${Platform.pathSeparator}probe.wav');
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return file;
  }

  /// Ошибка, которой mpv сообщает, что фильтра нет или что он отвергнут.
  ///
  /// Ловим по словам, а не «любую ошибку»: на пробном плеере бывают и
  /// посторонние сообщения (например, о кэше файлов), и принять их за отказ
  /// нельзя.
  static bool _mentions(String message, String name) {
    final String text = message.toLowerCase();
    return text.contains(name.toLowerCase()) ||
        _soundsLikeFilterRejection(text);
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
    // Граф `lavfi` собирается уже после разбора `af`: mpv сообщает об этом
    // отдельно — «Creating filter 'lavfi' failed» или «Audio filter
    // initialized failed». Это тот же отказ фильтра, а не сбой трека.
    if (text.contains('creating filter') && text.contains('fail')) return true;
    if (text.contains('audio filter') &&
        (text.contains('fail') || text.contains('error'))) {
      return true;
    }
    if (text.contains('lavfi') &&
        (text.contains('fail') ||
            text.contains('error') ||
            text.contains('invalid'))) {
      return true;
    }
    // Параметр фильтра не принят: «Option 1b not found» и подобное.
    return text.contains('option') && text.contains('not found');
  }
}
