import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/player_controller.dart';

/// Канал медиаклавиш и системного оверлея Windows (`mops/media`).
///
/// Нативная сторона присылает `mediaKey` со строкой действия: аппаратные
/// Play/Pause/Next/Prev и кнопки оверлея приходят одним и тем же событием, а
/// разбирать, откуда оно, интерфейсу незачем. Обратно уходит `nowPlaying` —
/// из него оверлей берёт название, исполнителя и состояние.
class MediaKeys {
  MediaKeys(this._ref) {
    _channel.setMethodCallHandler(_onMethodCall);
    // fireImmediately: первый кадр не должен ждать первого изменения плеера —
    // восстановленная очередь уже выбрана, и карточку нужно показать сразу.
    _ref.listen<PlayerUiState>(
      playerControllerProvider,
      _onPlayerState,
      fireImmediately: true,
    );
  }

  final Ref _ref;
  final MethodChannel _channel = const MethodChannel('mops/media');

  /// Оверлей обновляем не чаще двух раз в секунду. Позицию он не показывает,
  /// а каждая перерисовка карточки — работа системы вхолостую.
  static const Duration _minInterval = Duration(milliseconds: 500);

  /// Отложенное обновление, пока не истёк [_minInterval].
  Timer? _throttle;

  /// Когда карточка уходила в систему в последний раз.
  DateTime? _lastSent;

  /// Самое свежее состояние, ждущее своей очереди.
  _NowPlaying? _pending;

  /// Что уже показано: одинаковую карточку повторно не отправляем.
  _NowPlaying? _shown;

  void dispose() {
    _throttle?.cancel();
    _throttle = null;
    _pending = null;
    unawaited(_send('clear'));
    _channel.setMethodCallHandler(null);
  }

  Future<void> _onMethodCall(MethodCall call) async {
    if (call.method != 'mediaKey') return;
    final Object? arguments = call.arguments;
    if (arguments is! String) return;
    _runCommand(arguments);
  }

  /// Действие из системы. Пока трека нет, делать нечего: пустой плеер не
  /// должен «просыпаться» от случайного нажатия.
  void _runCommand(String command) {
    if (!_ref.read(playerControllerProvider).hasTrack) return;
    final PlayerController player = _ref.read(
      playerControllerProvider.notifier,
    );
    switch (command) {
      case 'playPause':
        unawaited(player.togglePlayPause());
      case 'play':
        unawaited(player.play());
      case 'pause':
        unawaited(player.pause());
      case 'next':
        unawaited(player.next());
      case 'previous':
        unawaited(player.previous());
      case 'stop':
        // Отдельной остановки с сохранением очереди у плеера нет, а стирать
        // очередь по клавише Stop было бы неожиданно — останавливаем звук.
        unawaited(player.pause());
    }
  }

  void _onPlayerState(PlayerUiState? previous, PlayerUiState next) {
    final _NowPlaying? info = _NowPlaying.fromState(next);
    final bool paused =
        (previous?.playback.isPlaying ?? false) && !next.playback.isPlaying;

    // Пустая очередь убирает карточку, пауза — то, что пользователь ждёт
    // увидеть немедленно. Эти два случая не откладываем.
    if (info == null || paused) {
      _throttle?.cancel();
      _throttle = null;
      _pending = null;
      _sendInfo(info);
      return;
    }

    _pending = info;
    final DateTime now = DateTime.now();
    final DateTime? last = _lastSent;
    if (last == null || now.difference(last) >= _minInterval) {
      _flush();
      return;
    }
    _throttle ??= Timer(_minInterval - now.difference(last), _flush);
  }

  void _flush() {
    _throttle?.cancel();
    _throttle = null;
    final _NowPlaying? info = _pending;
    _pending = null;
    _sendInfo(info);
  }

  void _sendInfo(_NowPlaying? info) {
    if (info == _shown) return;
    _shown = info;
    _lastSent = DateTime.now();
    unawaited(
      info == null ? _send('clear') : _send('nowPlaying', info.toMap()),
    );
  }

  Future<void> _send(String method, [Map<String, Object?>? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on Object {
      // Канал есть только на Windows — на других платформах это норма.
    }
  }
}

/// Карточка оверлея: только то, что он умеет показать.
@immutable
class _NowPlaying {
  const _NowPlaying({
    required this.title,
    required this.artist,
    required this.album,
    required this.playing,
  });

  static _NowPlaying? fromState(PlayerUiState state) {
    final Track? track = state.current;
    if (track == null) return null;
    return _NowPlaying(
      title: track.title,
      artist: track.artistLine,
      album: track.album?.name ?? '',
      playing: state.playback.isPlaying,
    );
  }

  final String title;
  final String artist;
  final String album;
  final bool playing;

  Map<String, Object?> toMap() => <String, Object?>{
    'title': title,
    'artist': artist,
    'album': album,
    'playing': playing,
  };

  @override
  bool operator ==(Object other) =>
      other is _NowPlaying &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.playing == playing;

  @override
  int get hashCode => Object.hash(title, artist, album, playing);
}

/// Сессия медиаклавиш и оверлея — одна на приложение.
///
/// Отдельный провайдер, а не статика: у подписки на состояние плеера должен
/// быть владелец, который её снимет.
final Provider<MediaKeys> mediaKeysProvider = Provider<MediaKeys>((ref) {
  final MediaKeys keys = MediaKeys(ref);
  ref.onDispose(keys.dispose);
  return keys;
});
