import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

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

/// Уровень звука из libmpv для визуализатора.
///
/// Источник уровня — сам libmpv, а не плеер и не позиция трека. В цепочку
/// аудиофильтров (`af`) дописывается `@mopsvis:astats=metadata=1`, а из свойства
/// `af-metadata/mopsvis/lavfi.astats.Overall.RMS_level` читается RMS в dBFS.
/// Позиция трека к уровню отношения не имеет: на паузе опрос прекращается и гало
/// гаснет, а не продолжает «дышать».
///
/// **Почему этого может не быть.** `astats` — фильтр FFmpeg, а в поставляемом с
/// media_kit libmpv для Windows FFmpeg собран с `--disable-filters` (включены
/// только `overlay` и `equalizer`). mpv на такой запрос отвечает «Option af:
/// astats doesn't exist» и фильтр отключает. Поэтому фильтр не принимается на
/// слово: после установки цепочка `af` читается обратно, и если метки в ней нет —
/// уровень помечается недоступным. Придумывать вместо него «уровень от позиции»
/// нельзя: это было бы движение, не связанное со звуком.
///
/// Побочных чтений дорого не стоит: `af-metadata/...` — одна строка из уже
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
      }
    });

    _playingSub = _player.stream.playing.listen(_onPlaying);
    if (_player.state.playing) _onPlaying(true);
  }

  /// Метка фильтра: по ней же читаются метаданные.
  static const String _label = 'mopsvis';

  /// Запись фильтра для `af`. Метка задаётся явно: без неё mpv сам назовёт
  /// фильтр `astats.NN`, и имя пришлось бы угадывать.
  static const String _filter = '@$_label:astats=metadata=1';

  /// Свойство с уровнем. `lavfi.` — префикс метаданных фильтров, которые mpv
  /// выполняет через libavfilter (как `astats`).
  static const String _levelProperty =
      'af-metadata/$_label/lavfi.astats.Overall.RMS_level';

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

  bool _attached = false;
  bool _disposed = false;
  bool _pollInFlight = false;
  int _emptyReads = 0;
  int _reattaches = 0;
  String? _lastMpvMessage;

  /// Уровень 0..1 (0 — тишина). Готов для отрисовки.
  double get level => _level;

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
    // Пауза: гало гаснет. Уведомляем только если было что гасить.
    if (_level != 0) {
      _level = 0;
      notifyListeners();
    }
  }

  Future<void> _begin() async {
    if (_disposed || _native == null) return;
    if (!_attached && !await _attach()) return;
    _timer ??= Timer.periodic(_pollInterval, (_) => unawaited(_poll()));
  }

  /// Дописывает свой фильтр в конец цепочки `af` и проверяет, что он принят.
  Future<bool> _attach() async {
    final NativePlayer? native = _native;
    if (native == null) return false;
    try {
      // Цепочку не затираем: в том же свойстве `af` живёт `scaletempo` движка
      // (темп и питч), и подмена выключила бы компенсацию высоты тона.
      final String current = (await native.getProperty('af')).trim();
      await native.setProperty('af', _append(current, _filter));
      final String applied = await native.getProperty('af');
      if (!applied.contains(_label)) {
        // mpv отверг фильтр и оставил прежнюю цепочку.
        _markUnavailable(
          _lastMpvMessage ?? 'libmpv не принял фильтр «$_filter»',
        );
        return false;
      }
      _attached = true;
      _emptyReads = 0;
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

  Future<void> _poll() async {
    if (_disposed || _pollInFlight) return;
    final NativePlayer? native = _native;
    if (native == null) return;
    _pollInFlight = true;
    try {
      final String raw = (await native.getProperty(_levelProperty)).trim();
      if (raw.isEmpty) {
        _emptyReads++;
        if (_emptyReads == _emptyReadsBeforeCheck) await _repairFilter();
        return;
      }
      _emptyReads = 0;
      // В тишине astats отдаёт «-inf» — это не число, и уровень просто не меняем.
      final double? db = double.tryParse(raw);
      if (db != null) _applyDb(db);
    } on Object catch (error) {
      _markUnavailable('чтение уровня из libmpv сорвалось: $error');
    } finally {
      _pollInFlight = false;
    }
  }

  /// Метаданных нет дольше двух секунд. Либо фильтр вытеснили из `af`, либо он
  /// перестал считать. Различаем по цепочке: если метка на месте — ждём дальше.
  Future<void> _repairFilter() async {
    final NativePlayer? native = _native;
    if (native == null) return;
    final String chain = (await native.getProperty('af')).trim();
    if (chain.contains(_label)) {
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

  void _applyDb(double db) {
    final double target = ((db - _floorDb) / -_floorDb).clamp(0.0, 1.0);
    // Атака быстрая, спад медленный: иначе гало дрожало бы на каждом слоге.
    final double next = target > _level
        ? _level + (target - _level) * 0.55
        : _level + (target - _level) * 0.14;
    // Мельче четырёх тысячных — это уже не видно, а перерисовку не стоит.
    if ((next - _level).abs() < 0.004) return;
    _level = next;
    notifyListeners();
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
