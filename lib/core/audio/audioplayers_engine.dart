import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import 'audio_engine.dart';

/// Реализация [AudioEngine] поверх `audioplayers`.
///
/// Почему `audioplayers`: это единственный бэкенд, который работает на всех
/// целевых платформах без установки дополнительных системных пакетов.
/// На Linux он использует GStreamer (opus, matroska и `souphttpsrc` для
/// HTTPS-стриминга), на Windows/macOS/Android/iOS — нативные плееры,
/// в вебе — HTML5 audio.
///
/// Если позже понадобится gapless и точный seek, этот класс заменяется на
/// реализацию поверх `media_kit` — интерфейс [AudioEngine] не меняется.
class AudioplayersEngine implements AudioEngine {
  AudioplayersEngine({AudioPlayer? player})
      : _player = player ?? AudioPlayer() {
    _attach();
  }

  final AudioPlayer _player;
  final StreamController<PlaybackState> _controller =
      StreamController<PlaybackState>.broadcast();

  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];

  PlaybackState _state = PlaybackState.initial;
  bool _disposed = false;

  /// Идёт перемотка. GStreamer на flush-перемотке сетевого потока иногда
  /// присылает EOS: принимать его за конец трека нельзя, иначе очередь
  /// перескочит на следующий. Флаг снимается по `onSeekComplete`, страховочным
  /// таймером или в конце самой перемотки.
  bool _seeking = false;
  Timer? _seekSafetyTimer;

  /// Куда перематывали в последний раз — чтобы восстановить тот же трек,
  /// если поток всё же оборвался.
  Duration _lastSeekTarget = Duration.zero;

  /// Поток оборвался на перемотке и его нужно переставить на место,
  /// когда пользователь нажмёт «играть».
  bool _needsRecovery = false;

  /// Последний загруженный источник. Нужен, чтобы поднять поток заново:
  /// `audioplayers` на Linux в режиме release освобождает источник по
  /// завершении, и тогда ни `resume`, ни `seek` трек уже не оживят.
  String? _lastSource;
  bool _lastIsLocal = false;

  /// Источник сейчас загружен в нативный плеер.
  ///
  /// После EOS Linux-плагин делает `Stop()` и освобождает поток. Перемотка на
  /// освобождённом потоке не доходит до конца: `audioplayers` ждёт событие
  /// `onSeekComplete` и падает по таймауту через 30 секунд. Поэтому перед
  /// любой перемоткой/возобновлением источник поднимается заново.
  bool _sourceLoaded = false;

  @override
  Stream<PlaybackState> get stateStream => _controller.stream;

  @override
  PlaybackState get state => _state;

  void _attach() {
    _subs.addAll(<StreamSubscription<dynamic>>[
      _player.onPlayerStateChanged.listen(_onPlayerState),
      _player.onPositionChanged.listen((Duration position) {
        _emit(_state.copyWith(position: position));
      }),
      _player.onDurationChanged.listen((Duration duration) {
        _emit(_state.copyWith(duration: duration));
      }),
      _player.onPlayerComplete.listen((_) => _emitCompletion()),
      _player.onSeekComplete.listen((_) => _endSeek()),
      _player.onLog.listen(_onLog),
    ]);
  }

  void _onPlayerState(PlayerState state) {
    final PlaybackStatus mapped = switch (state) {
      PlayerState.playing => PlaybackStatus.playing,
      PlayerState.paused => PlaybackStatus.paused,
      PlayerState.completed => PlaybackStatus.completed,
      PlayerState.stopped => PlaybackStatus.idle,
      PlayerState.disposed => PlaybackStatus.idle,
    };

    // Завершение приходит и сюда, и в `onPlayerComplete`. Обрабатываем в
    // одном месте, чтобы фильтр «это не перемотка» сработал одинаково.
    if (mapped == PlaybackStatus.completed) {
      _emitCompletion();
      return;
    }

    if (mapped == PlaybackStatus.playing) {
      // Звук пошёл — восстанавливать позицию больше не нужно.
      _needsRecovery = false;
    }
    _emit(_state.copyWith(status: mapped, clearError: true));
  }

  /// Сообщает об окончании воспроизведения, отсекая ложный EOS перемотки.
  void _emitCompletion() {
    if (_seeking) {
      // Перемотка оборвала поток в EOS. Держим тот же трек и позицию:
      // очередь переключать нельзя, иначе «играть» включит следующий.
      // Нативный плеер на EOS освободил поток — запоминаем это, чтобы
      // «играть» подняло трек заново, а не перематывало пустоту.
      _needsRecovery = true;
      _sourceLoaded = false;
      _emit(_state.copyWith(
        status: PlaybackStatus.paused,
        position: _lastSeekTarget,
      ));
      return;
    }
    // Завершение приходит двумя путями — из `onPlayerComplete` и из смены
    // состояния. Сообщаем о нём один раз, иначе очередь перескочит дважды.
    if (_state.status == PlaybackStatus.completed) return;
    // Источник освобождён нативным плеером — без повторного `setSourceUrl`
    // повторное «играть» не сработает.
    _sourceLoaded = false;
    _emit(_state.copyWith(
      status: PlaybackStatus.completed,
      position: _state.duration,
    ));
  }

  void _onLog(String message) {
    // audioplayers пишет в лог и ошибки, и отладку. Понятный пользователю
    // текст формируем только для явных сбоев.
    final String lower = message.toLowerCase();
    if (lower.contains('error') || lower.contains('failed')) {
      // Сбой перемотки — не сбой трека: движок уже вернул позицию.
      if (_seeking) return;
      _emit(_state.copyWith(
        status: PlaybackStatus.error,
        error: _humanizeError(message),
      ));
    }
  }

  String _humanizeError(String raw) {
    if (raw.contains('403')) {
      return 'YouTube отклонил ссылку на поток. Попробуйте запустить трек ещё раз.';
    }
    if (raw.contains('404')) {
      return 'Поток не найден. Возможно, трек удалён или недоступен в регионе.';
    }
    return 'Не удалось воспроизвести трек. Попробуйте другой или повторите позже.';
  }

  void _emit(PlaybackState next) {
    _state = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  @override
  Future<void> load(
    String source, {
    bool autoplay = true,
    bool isLocal = false,
  }) async {
    // Новый трек — прежняя перемотка и её последствия больше не важны.
    _needsRecovery = false;
    _lastSeekTarget = Duration.zero;
    _endSeek();
    // Запоминаем источник: если его потом освободит EOS, по этим данным
    // поток можно поднять заново.
    _lastSource = source;
    _lastIsLocal = isLocal;
    _sourceLoaded = false;
    _emit(_state.copyWith(
      status: PlaybackStatus.loading,
      position: Duration.zero,
      duration: Duration.zero,
      clearError: true,
    ));

    try {
      if (isLocal) {
        await _player.setSourceDeviceFile(source);
      } else {
        await _player.setSourceUrl(source);
      }
      _sourceLoaded = true;
      if (autoplay) {
        await _player.resume();
        // Часть платформ не отдаёт состояние сразу — выставляем сами.
        if (_state.status == PlaybackStatus.loading) {
          _emit(_state.copyWith(status: PlaybackStatus.playing));
        }
      }
    } on Exception catch (error) {
      _sourceLoaded = false;
      _emit(_state.copyWith(
        status: PlaybackStatus.error,
        error: _humanizeError(error.toString()),
      ));
    }
  }

  @override
  Future<void> play() async {
    // Потока в плеере нет (трек доиграл, оборвался) — поднимаем его заново.
    // Просто `seek`/`resume` здесь не работают: нативный плеер освобождён,
    // а `seek` на нём ждёт событие и падает по таймауту через 30 секунд.
    if (!_sourceLoaded || _state.status == PlaybackStatus.completed) {
      // Прерванную перемотку продолжаем с её места, завершённый трек — с нуля.
      final Duration target = _needsRecovery ? _lastSeekTarget : Duration.zero;
      _needsRecovery = false;
      await _restart(target);
      return;
    }
    // Если поток оборвался на перемотке, возвращаем его на выбранное место,
    // чтобы «играть» продолжило ТОТ ЖЕ трек, а не тишину.
    if (_needsRecovery) {
      _needsRecovery = false;
      try {
        await _player.seek(_lastSeekTarget);
      } on Object catch (error) {
        debugPrint('Не удалось восстановить позицию после перемотки: $error');
      }
    }
    await _player.resume();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    _needsRecovery = false;
    // На `stop` Linux-плагин освобождает поток — помним об этом.
    _sourceLoaded = false;
    _emit(_state.copyWith(status: PlaybackStatus.idle, position: Duration.zero));
  }

  @override
  Future<void> seek(Duration position) async {
    final Duration clamped = position < Duration.zero ? Duration.zero : position;
    _lastSeekTarget = clamped;
    _beginSeek();

    // Позицию показываем сразу: перемотка сетевого потока занимает время,
    // а полоса не должна «отпрыгивать» назад.
    _emit(_state.copyWith(position: clamped));

    // Источника в плеере нет — перематывать нечего. Поднимаем поток заново
    // и начинаем с выбранного места (иначе `seek` уйдёт в 30-секундный таймаут).
    if (!_sourceLoaded) {
      _needsRecovery = false;
      try {
        await _restart(clamped, emitLoading: false);
      } finally {
        _endSeek();
      }
      return;
    }

    try {
      await _player.seek(clamped);
    } on Object catch (error) {
      // Ошибку перемотки не показываем как сбой воспроизведения: звук
      // продолжает идти, плеер остаётся на прежнем месте.
      debugPrint('Перемотка не удалась: $error');
    } finally {
      _endSeek();
    }
  }

  /// Заново поднимает последний источник — после EOS или остановки.
  ///
  /// `audioplayers` на Linux освобождает поток по завершении, поэтому без
  /// нового `setSourceUrl` ни «играть», ни перемотка не сработают. `target` —
  /// куда встать после загрузки (ноль — с начала).
  Future<void> _restart(Duration target, {bool emitLoading = true}) async {
    final String? source = _lastSource;
    if (source == null) return;
    if (emitLoading) {
      _emit(_state.copyWith(status: PlaybackStatus.loading, clearError: true));
    }
    try {
      if (_lastIsLocal) {
        await _player.setSourceDeviceFile(source);
      } else {
        await _player.setSourceUrl(source);
      }
      _sourceLoaded = true;
      // `setSourceUrl` завершается только после подготовки потока, поэтому
      // перемотка сразу за ним уже безопасна.
      if (target > Duration.zero) {
        await _player.seek(target);
      }
      await _player.resume();
      _emit(_state.copyWith(
        status: PlaybackStatus.playing,
        position: target,
        clearError: true,
      ));
    } on Object catch (error) {
      _sourceLoaded = false;
      _emit(_state.copyWith(
        status: PlaybackStatus.error,
        error: _humanizeError(error.toString()),
      ));
    }
  }

  /// Включает защиту от ложного EOS на время перемотки.
  void _beginSeek() {
    _seeking = true;
    _seekSafetyTimer?.cancel();
    // Страховка: если `onSeekComplete` не придёт (например, платформа его не
    // шлёт), снимаем флаг сами — иначе настоящий конец трека будет пропущен.
    _seekSafetyTimer = Timer(const Duration(seconds: 10), _endSeek);
  }

  void _endSeek() {
    _seeking = false;
    _seekSafetyTimer?.cancel();
    _seekSafetyTimer = null;
  }

  @override
  Future<void> setVolume(double volume) async {
    final double clamped = volume.clamp(0.0, 1.0);
    await _player.setVolume(clamped);
    _emit(_state.copyWith(volume: clamped));
  }

  @override
  Future<void> setSpeed(double speed) async {
    // audioplayers меняет темп без сохранения тона на части платформ,
    // поэтому ограничиваем разумным диапазоном.
    final double clamped = speed.clamp(0.5, 2.0);
    await _player.setPlaybackRate(clamped);
    _emit(_state.copyWith(speed: clamped));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _seekSafetyTimer?.cancel();
    _seekSafetyTimer = null;
    for (final StreamSubscription<dynamic> sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await _controller.close();
    try {
      await _player.dispose();
    } on Exception catch (error) {
      debugPrint('Ошибка при освобождении плеера: $error');
    }
  }
}
