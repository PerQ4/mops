import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'mpv_filter_probe.dart';

/// Что известно об уровне звука.
enum AudioLevelAvailability {
  /// Ещё не проверяли: трек ни разу не играл при включённом визуализаторе.
  unknown,

  /// libmpv отдаёт уровень — гало дышит по звуку.
  available,

  /// Уровня нет: эта сборка libmpv такого фильтра не знает. Причину смотри в
  /// [AudioLevelMonitor.reason].
  unavailable,
}

/// Уровень звука и спектр частот из libmpv для визуализатора.
///
/// Источник — сам libmpv, а не плеер и не позиция трека. В цепочку
/// аудиофильтров (`af`) дописывается один фильтр `lavfi` с графом (метка
/// `mopsvis`): исходный стереосигнал разветвляется на восемь полос
/// (`bandpass`), все девять потоков сводятся вместе, а `astats` считает RMS
/// каждого канала. Каналы 1–2 — исходные левый и правый, 3–10 — полосы от
/// 60 Гц до 8 кГц. Из `af-metadata/mopsvis/lavfi.astats.N.RMS_level` читаются
/// и общий уровень (по каналам 1–2), и полосы. Позиция трека к этому
/// отношения не имеет: на паузе опрос прекращается и визуализатор гаснет.
///
/// **Почему граф, а не готовый `aspectralstats`.** У `aspectralstats` в
/// поставляемой сборке нет энергий полос — только описатели спектра (центр,
/// наклон, энтропия), а `showcqt` метаданных не отдаёт вовсе. Поэтому полосы
/// считаются честными `bandpass` + `astats` внутри одного графа.
///
/// **Почему спрашиваем отдельный плеер, а не живой.** Проверять фильтр на живом
/// плеере дважды опасно: mpv пишет отказ в `stream.error`, и движок принимает его
/// за сбой трека — воспроизведение «ломается»; а чтение `af-metadata/...` по
/// метке, которой в цепочке нет, в такой сборке роняет libmpv. Поэтому разовая
/// проверка идёт на отдельном пустом плеере: ему ошибка не мешает, а метаданные
/// спрашиваются у живого только после утвердительного ответа. Придумывать вместо
/// уровня «уровень от позиции» нельзя: это было бы движение, не связанное со
/// звуком.
///
/// Если графа нет, но `astats` есть, остаётся прежний режим «только уровень»:
/// гало продолжает дышать, а полосы честно отсутствуют.
///
/// Побочных чтений дорого не стоит: `af-metadata/...` — строка из уже
/// посчитанных фильтром метаданных, а опрос идёт только во время
/// воспроизведения (30 раз в секунду).
class AudioLevelMonitor extends ChangeNotifier {
  AudioLevelMonitor(this._player) {
    final PlatformPlayer? platform = _player.platform;
    if (platform is NativePlayer) {
      _native = platform;
    } else {
      // `af` — свойство libmpv; у платформенной реализации media_kit его нет.
      _availability = AudioLevelAvailability.unavailable;
      _reason = 'движок не libmpv: у платформы нет свойств mpv';
    }

    // Сообщения самого mpv — самый честный источник причины отказа: берём
    // «Option af: astats doesn't exist» от него, а не пишем своё предположение.
    _logSub = _player.stream.log.listen((PlayerLog log) {
      final String text = log.text.trim();
      if (text.isEmpty) return;
      if (log.level != 'error' && log.level != 'fatal') return;
      if (text.contains('af') || text.contains('filter')) {
        _lastMpvMessage = text;
        _lastMpvMessageAt = DateTime.now();
      }
    });

    _playingSub = _player.stream.playing.listen(_onPlaying);
    if (_player.state.playing) _onPlaying(true);
  }

  /// Метка фильтра: по ней же читаются метаданные.
  static const String _label = 'mopsvis';

  /// Центры полос спектра, Гц. Шаг — октава: так полосы не налезают друг на
  /// друга и вместе покрывают слышимый диапазон от баса до тарелок.
  static const List<double> bandCenters = <double>[
    60,
    120,
    240,
    500,
    1000,
    2000,
    4000,
    8000,
  ];

  /// Сколько полос отдаёт монитор.
  static int get bandCount => bandCenters.length;

  /// Граф `lavfi`: исходник разветвляется на восемь полосовых ветвей, затем
  /// все девять потоков сводятся в один и считаются `astats`.
  ///
  /// `amerge` складывает каналы входов по порядку, поэтому каналы 1–2 остаются
  /// исходным стерео, а 3–10 — полосами. `pan` в конце возвращает два канала:
  /// он копирует свойства кадра, и метаданные `astats` не теряются (в отличие
  /// от `amix`).
  static final String _spectrumGraph = _buildSpectrumGraph();

  /// Запись фильтра для `af`. Квадратные скобки — форма, в которой mpv
  /// принимает граф с метками и точкой с запятой (проверено на живой сборке).
  static String get _spectrumFilter => '@$_label:lavfi=[$_spectrumGraph]';

  /// Запасной вариант: только общий уровень, без полос.
  static const String _levelFilter = '@$_label:astats=metadata=1';

  /// Свойства с RMS каналов исходного стерео (1 и 2 в нумерации `astats`).
  static const String _leftProperty =
      'af-metadata/$_label/lavfi.astats.1.RMS_level';
  static const String _rightProperty =
      'af-metadata/$_label/lavfi.astats.2.RMS_level';

  /// Свойство общего уровня запасного режима.
  static const String _levelProperty =
      'af-metadata/$_label/lavfi.astats.Overall.RMS_level';

  /// Свойство RMS полосы [index] (0 — 60 Гц). Полосы начинаются с третьего
  /// канала: первые два заняты исходным стерео.
  static String _bandProperty(int index) =>
      'af-metadata/$_label/lavfi.astats.${index + 3}.RMS_level';

  /// Нижняя граница шкалы: тише −60 dBFS считаем тишиной.
  static const double _floorDb = -60;

  /// Частота опроса: 30 раз в секунду — заметно чаще кадра не нужно.
  static const Duration _pollInterval = Duration(milliseconds: 33);

  /// Сколько пустых чтений подряд считать «фильтр пропал», а не «метаданных
  /// ещё нет». 60 чтений — это ~2 секунды.
  static const int _emptyReadsBeforeCheck = 60;

  /// Сколько раз за сессию поднимать фильтр заново, если его вытеснил движок
  /// (темп и питч пишутся в то же свойство `af`).
  static const int _maxReattaches = 3;

  final Player _player;

  /// Плеер libmpv; `null` — у платформы нет свойств mpv.
  NativePlayer? _native;

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<PlayerLog>? _logSub;
  Timer? _timer;

  double _level = 0;
  AudioLevelAvailability _availability = AudioLevelAvailability.unknown;
  String? _reason;

  /// Полосы спектра 0..1. Список один и тот же: его читает отрисовка, а
  /// обновляется он на месте, без аллокаций на каждый кадр.
  final List<double> _bands = List<double>.filled(bandCount, 0);

  /// Граф с полосами принят. Иначе работает запасной режим «только уровень».
  bool _spectrumMode = true;
  bool _bandsAvailable = false;

  bool _attached = false;
  bool _disposed = false;
  bool _pollInFlight = false;
  int _emptyReads = 0;
  int _reattaches = 0;
  String? _lastMpvMessage;
  DateTime? _lastMpvMessageAt;

  /// Уровень 0..1 (0 — тишина). Готов для отрисовки.
  double get level => _level;

  /// Полосы 0..1 от низких частот к высоким. Пока спектр недоступен — нули.
  ///
  /// Список отдаётся без копии: он обновляется монитором, а читает его только
  /// отрисовка. Менять его снаружи нельзя.
  List<double> get bands => _bands;

  /// Есть ли настоящие полосы (граф `lavfi` принят сборкой libmpv).
  bool get spectrumAvailable => _bandsAvailable;

  AudioLevelAvailability get availability => _availability;

  /// Причина недоступности — словами mpv, если он их сказал.
  String? get reason => _reason;

  void _onPlaying(bool playing) {
    if (_disposed) return;
    if (playing) {
      unawaited(_begin());
      return;
    }
    _stopPolling();
    // Пауза: визуализатор гаснет. Уведомляем только если было что гасить.
    if (_level != 0 || _bands.any((double b) => b != 0)) {
      _level = 0;
      _bands.fillRange(0, bandCount, 0);
      notifyListeners();
    }
  }

  Future<void> _begin() async {
    if (_disposed || _native == null) return;
    // Пока не знаем, какой фильтр есть в сборке, — не трогаем живой `af`:
    // установка неподдерживаемой цепочки пишет ошибку в `stream.error`, и
    // движок принял бы её за сбой воспроизведения.
    if (_availability == AudioLevelAvailability.unknown) {
      final bool spectrum = await MpvFilterProbe.supportsGraph(
        _spectrumGraph,
      );
      // За время проверки трек мог кончиться или его сняли с паузы.
      if (_disposed || !_player.state.playing) return;
      if (!spectrum) {
        final String spectrumReason = MpvFilterProbe.rejection('lavfi') ??
            'в сборке libmpv нет фильтра lavfi';
        // Без графа полос нет, но общий уровень может остаться: не отнимаем у
        // пользователя гало из-за того, что сборка не умеет спектр.
        final bool level =
            await MpvFilterProbe.supports('astats', 'metadata=1');
        if (_disposed || !_player.state.playing) return;
        if (!level) {
          _markUnavailable(
            MpvFilterProbe.rejection('astats') ?? spectrumReason,
          );
          return;
        }
        _spectrumMode = false;
        debugPrint('Визуализатор: спектр недоступен — $spectrumReason');
      }
    }
    if (_availability == AudioLevelAvailability.unavailable) return;
    if (!_attached && !await _attach()) return;
    _timer ??= Timer.periodic(_pollInterval, (_) => unawaited(_poll()));
  }

  /// Дописывает свой фильтр в конец цепочки `af` и проверяет, что он принят.
  Future<bool> _attach() async {
    final NativePlayer? native = _native;
    if (native == null) return false;
    final String filter = _spectrumMode ? _spectrumFilter : _levelFilter;
    try {
      // Цепочку не затираем: в том же свойстве `af` живёт `scaletempo` движка
      // (темп и питч), и подмена выключила бы компенсацию высоты тона.
      final String current = (await native.getProperty('af')).trim();
      await native.setProperty('af', _append(current, filter));
      final String applied = await native.getProperty('af');
      // Метка в цепочке ещё не значит, что фильтр собрался: граф `lavfi`
      // инициализируется позже. Окончательный ответ даст метаданные или
      // сообщение mpv (см. [_repairFilter]).
      if (!applied.contains(_label)) {
        // mpv отверг фильтр и оставил прежнюю цепочку.
        _markUnavailable(_lastMpvMessage ?? 'libmpv не принял фильтр «$filter»');
        return false;
      }
      _attached = true;
      _emptyReads = 0;
      _bandsAvailable = _spectrumMode;
      if (_availability != AudioLevelAvailability.available) {
        _availability = AudioLevelAvailability.available;
        _reason = null;
        notifyListeners();
      }
      return true;
    } on Object catch (error) {
      _markUnavailable('не удалось обратиться к libmpv: $error');
      return false;
    }
  }

  static String _append(String chain, String filter) =>
      chain.isEmpty ? filter : '$chain,$filter';

  /// Собирает граф `lavfi` из восьми полосовых ветвей.
  static String _buildSpectrumGraph() {
    final StringBuffer graph = StringBuffer('asplit=9');
    for (int i = 0; i <= bandCenters.length; i++) {
      graph.write('[s$i]');
    }
    for (int i = 0; i < bandCenters.length; i++) {
      graph.write(
        ';[s${i + 1}]bandpass=f=${bandCenters[i].round()}:'
        'width_type=o:width=1,pan=mono|c0=0.5*c0+0.5*c1[b${i + 1}]',
      );
    }
    graph.write(';[s0]');
    for (int i = 0; i < bandCenters.length; i++) {
      graph.write('[b${i + 1}]');
    }
    graph.write(
      'amerge=inputs=9,astats=metadata=1:'
      'measure_perchannel=RMS_level:measure_overall=none,'
      'pan=stereo|c0=c0|c1=c1',
    );
    return graph.toString();
  }

  Future<void> _poll() async {
    if (_disposed || _pollInFlight) return;
    final NativePlayer? native = _native;
    if (native == null) return;
    _pollInFlight = true;
    try {
      if (_spectrumMode) {
        // Один проход по всем свойствам: уровень (каналы 1–2) и полосы.
        final List<String> raw = await Future.wait<String>(<Future<String>>[
          native.getProperty(_leftProperty),
          native.getProperty(_rightProperty),
          for (int i = 0; i < bandCount; i++)
            native.getProperty(_bandProperty(i)),
        ]);
        if (raw.every((String value) => value.trim().isEmpty)) {
          _emptyReads++;
          if (_emptyReads == _emptyReadsBeforeCheck) await _repairFilter();
          return;
        }
        _emptyReads = 0;
        final bool levelChanged = _applyStereo(raw[0], raw[1]);
        final bool bandsChanged = _applyBands(
          raw.sublist(2),
        );
        if (levelChanged || bandsChanged) notifyListeners();
        return;
      }

      final String raw = (await native.getProperty(_levelProperty)).trim();
      if (raw.isEmpty) {
        _emptyReads++;
        if (_emptyReads == _emptyReadsBeforeCheck) await _repairFilter();
        return;
      }
      _emptyReads = 0;
      final double? db = double.tryParse(raw);
      if (_applyDb(db ?? _floorDb)) notifyListeners();
    } on Object catch (error) {
      _markUnavailable('чтение уровня из libmpv сорвалось: $error');
    } finally {
      _pollInFlight = false;
    }
  }

  /// Метаданных нет дольше двух секунд. Либо фильтр вытеснили из `af`, либо он
  /// не собрался. Различаем по цепочке и словам mpv.
  Future<void> _repairFilter() async {
    final NativePlayer? native = _native;
    if (native == null) return;
    final String chain = (await native.getProperty('af')).trim();
    if (chain.contains(_label)) {
      // Метка на месте, но метаданных нет: значит, не собрался сам фильтр.
      // Такое mpv пишет отдельным сообщением — его и показываем.
      final DateTime? at = _lastMpvMessageAt;
      final String? message = _lastMpvMessage;
      final bool recent = at != null &&
          DateTime.now().difference(at) < const Duration(seconds: 5);
      if (recent && message != null && _mentionsOurFilter(message)) {
        _markUnavailable(message);
        return;
      }
      _emptyReads = 0;
      return;
    }
    if (_reattaches >= _maxReattaches) {
      _markUnavailable('фильтр уровня вытеснен из цепочки af');
      return;
    }
    _reattaches++;
    _attached = false;
    await _attach();
  }

  /// Сообщение относится к нашему фильтру, а не к эффектам движка.
  static bool _mentionsOurFilter(String message) {
    final String text = message.toLowerCase();
    return text.contains('lavfi') ||
        text.contains('astats') ||
        text.contains('audio filter initialized');
  }

  /// Уровень из RMS левого и правого каналов. Пустая строка — канала нет,
  /// `-inf` — тишина: и то и другое даёт ноль.
  bool _applyStereo(String left, String right) {
    final String l = left.trim();
    final String r = right.trim();
    if (l.isEmpty && r.isEmpty) return false;
    double power(String raw) {
      final double? db = double.tryParse(raw);
      if (db == null || !db.isFinite) return 0;
      return math.pow(10, db / 10).toDouble();
    }

    final int channels = (l.isEmpty ? 0 : 1) + (r.isEmpty ? 0 : 1);
    final double sum = power(l) + power(r);
    final double db = sum <= 0
        ? _floorDb
        : 10 * (math.log(sum / channels) / math.ln10);
    return _applyDb(db);
  }

  /// Сглаживает полосы; возвращает, изменилось ли что-то заметно.
  bool _applyBands(List<String> raw) {
    bool changed = false;
    for (int i = 0; i < bandCount; i++) {
      final String text = raw[i].trim();
      // Пустое значение — метаданных ещё нет; прежнюю полосу не трогаем.
      if (text.isEmpty) continue;
      final double? db = double.tryParse(text);
      final double target = db == null || !db.isFinite
          ? 0
          : ((db - _floorDb) / -_floorDb).clamp(0.0, 1.0);
      final double current = _bands[i];
      // Атака быстрее спада: полосы должны успевать за ударом, но не мигать.
      final double next = target > current
          ? current + (target - current) * 0.55
          : current + (target - current) * 0.16;
      if ((next - current).abs() < 0.003) continue;
      _bands[i] = next;
      changed = true;
    }
    return changed;
  }

  /// Обновляет общий уровень; возвращает, изменился ли он заметно.
  bool _applyDb(double db) {
    final double target = ((db - _floorDb) / -_floorDb).clamp(0.0, 1.0);
    // Атака быстрая, спад медленный: иначе гало дрожало бы на каждом слоге.
    final double next = target > _level
        ? _level + (target - _level) * 0.55
        : _level + (target - _level) * 0.14;
    // Мельче четырёх тысячных — это уже не видно, а перерисовку не стоит.
    if ((next - _level).abs() < 0.004) return false;
    _level = next;
    return true;
  }

  void _stopPolling() {
    _timer?.cancel();
    _timer = null;
    _emptyReads = 0;
  }

  void _markUnavailable(String reason) {
    _stopPolling();
    if (_availability == AudioLevelAvailability.unavailable && _reason == reason) {
      return;
    }
    _availability = AudioLevelAvailability.unavailable;
    _reason = reason;
    _level = 0;
    _bands.fillRange(0, bandCount, 0);
    _bandsAvailable = false;
    debugPrint('Визуализатор: уровень звука недоступен — $reason');
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopPolling();
    _playingSub?.cancel();
    _logSub?.cancel();
    super.dispose();
  }
}
