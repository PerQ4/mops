import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

  /// Проверяет граф `lavfi` по-настоящему — с потоком звука.
  ///
  /// Пустому плееру граф не нужен, и mpv принимает даже неверный: разбор
  /// откладывается до появления аудио. Проверка «на пустом» поэтому пропускает
  /// битый граф к живому плееру, где он уже рвёт воспроизведение. Здесь пробный
  /// плеер открывает короткий беззвучный WAV, а вывод идёт в `ao=null`: фильтр
  /// собирается по-настоящему, но ничего не слышно и устройство не занято.
  static Future<bool> supportsGraph(String graph) {
    final String key = 'lavfi|graph|$graph';
    return _results.putIfAbsent(key, () => _probeGraph(graph));
  }

  static const String _probeLabelName = 'lavfi';

  /// Сколько ждём сборку графа: локальный файл и `ao=null` — это мгновения,
  /// но на медленной машине инициализация аудио бывает небыстрой.
  static const Duration _graphWindow = Duration(seconds: 2);

  static Future<bool> _probeGraph(String graph) async {
    Player? probe;
    StreamSubscription<String>? errors;
    StreamSubscription<bool>? playing;
    Directory? temp;
    try {
      probe = Player(configuration: const PlayerConfiguration(pitch: false));
      final PlatformPlayer? platform = probe.platform;
      if (platform is! NativePlayer) {
        _rejections[_probeLabelName] = 'у платформы нет свойств mpv';
        return false;
      }
      temp = await Directory.systemTemp.createTemp('mops_spectrum_probe');
      final File wav = await _silentWav(temp);

      await platform.setProperty('ao', 'null');
      await platform.setProperty(
        'af',
        '@$_probeLabel:lavfi=[$graph]',
      );

      final Completer<String> rejected = Completer<String>();
      final Completer<bool> settled = Completer<bool>();
      errors = probe.stream.error.listen((String message) {
        if (!rejected.isCompleted && _mentions(message, _probeLabelName)) {
          rejected.complete(message);
        }
      });
      playing = probe.stream.playing.listen((bool value) {
        // «Играет» приходит раньше, чем mpv успевает отказать фильтру:
        // поэтому не верим событию сразу, а даём отказу дойти.
        if (!value || settled.isCompleted) return;
        Future<void>.delayed(
          const Duration(milliseconds: 600),
          () {
            if (!settled.isCompleted && !rejected.isCompleted) {
              settled.complete(true);
            }
          },
        );
      });

      await probe.open(Media(Uri.file(wav.path).toString()));
      final bool accepted = await Future.any<bool>(<Future<bool>>[
        rejected.future.then((String message) {
          _rejections[_probeLabelName] = message;
          return false;
        }),
        settled.future,
        Future<bool>.delayed(_graphWindow, () {
          _rejections[_probeLabelName] ??=
              'граф lavfi не собрался за ${_graphWindow.inSeconds} с';
          return false;
        }),
      ]);
      return accepted;
    } on Object catch (error) {
      _rejections[_probeLabelName] = 'проверка графа не удалась: $error';
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

  /// Короткий беззвучный WAV: нужен только чтобы у фильтра появился звук.
  static Future<File> _silentWav(Directory dir) async {
    const int rate = 44100;
    const int frames = rate ~/ 2; // полсекунды
    const int dataSize = frames * 4;
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
    // Сэмплы уже нули: тишина.

    final File file = File('${dir.path}${Platform.pathSeparator}probe.wav');
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return file;
  }


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
