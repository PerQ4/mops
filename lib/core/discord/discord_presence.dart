import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/app_settings.dart';
import '../../data/models/models.dart';
import '../../state/player_controller.dart';
import '../../state/providers.dart';
import 'discord_ipc.dart';

/// Что отправлять в Discord: собирается из настроек и состояния плеера.
///
/// Позиция попадает сюда только в момент смены трека или паузы — отдельная
/// подписка на позицию не нужна, иначе presence обновлялся бы несколько раз
/// в секунду.
@immutable
class DiscordPresenceInput {
  const DiscordPresenceInput({
    required this.enabled,
    required this.applicationId,
    required this.track,
    required this.isPlaying,
    required this.position,
    required this.duration,
  });

  final bool enabled;
  final String applicationId;
  final Track? track;
  final bool isPlaying;
  final Duration position;
  final Duration duration;

  @override
  bool operator ==(Object other) =>
      other is DiscordPresenceInput &&
      other.enabled == enabled &&
      other.applicationId == applicationId &&
      other.track == track &&
      other.isPlaying == isPlaying &&
      other.position == position &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(
        enabled,
        applicationId,
        track,
        isPlaying,
        position,
        duration,
      );
}

/// Держит соединение с Discord и отправляет текущий трек в Rich Presence.
///
/// Устойчивость: если Discord не запущен, приложение продолжает работать, а
/// соединение переподключается с экспоненциальной паузой. Все ошибки
/// проглатываются — presence не должен влиять на воспроизведение.
class DiscordPresenceService {
  DiscordIpcClient? _client;
  String? _clientAppId;
  DiscordPresenceInput? _desired;
  Timer? _retryTimer;
  Timer? _keepAliveTimer;
  Map<String, dynamic>? _lastActivity;
  int _failures = 0;
  bool _disposed = false;

  /// Последовательная очередь: обновления не должны выполняться параллельно.
  Future<void> _chain = Future<void>.value();

  /// Ставит в очередь новое состояние presence.
  Future<void> apply(DiscordPresenceInput input) {
    _desired = input;
    return _enqueue();
  }

  Future<void> _enqueue() {
    _chain = _chain.then((_) => _sync()).catchError((Object error) {
      debugPrint('[Discord] обновление пропущено: $error');
    });
    return _chain;
  }

  Future<void> _sync() async {
    if (_disposed) return;
    final DiscordPresenceInput? input = _desired;
    if (input == null) return;

    // Выключено или нет Application ID — отправлять нечего, снимаем presence.
    if (!input.enabled || input.applicationId.isEmpty) {
      await _disconnect();
      return;
    }

    if (!await _ensureConnected(input.applicationId)) return;

    try {
      final Map<String, dynamic>? activity =
          input.track == null ? null : _buildActivity(input);
      await _client!.setActivity(activity);
      // Кэш нужен для keep-alive: повторная отправка тех же абсолютных
      // таймстемпов не сбивает счётчик и заодно отвечает на ping Discord.
      _lastActivity = activity;
      _failures = 0;
    } on Object catch (error) {
      debugPrint('[Discord] не удалось обновить presence: $error');
      _handleDrop();
    }
  }

  Future<bool> _ensureConnected(String appId) async {
    final DiscordIpcClient? existing = _client;
    if (existing != null && existing.isConnected && _clientAppId == appId) {
      return true;
    }
    await _disconnect();

    final DiscordIpcClient client = DiscordIpcClient(appId);
    try {
      await client.connect();
      _client = client;
      _clientAppId = appId;
      _failures = 0;
      _retryTimer?.cancel();
      _retryTimer = null;
      _startKeepAlive();
      return true;
    } on Object catch (error) {
      debugPrint('[Discord] соединение недоступно: $error');
      await client.close();
      _failures++;
      _scheduleRetry();
      return false;
    }
  }

  /// Соединение разорвано — планируем переподключение.
  void _handleDrop() {
    _client = null;
    _clientAppId = null;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    if (_disposed) return;
    _failures++;
    _scheduleRetry();
  }

  /// Периодически повторяем активность: Discord видит живое соединение, а
  /// пришедший ping получает ответ при чтении ответа на эту же команду.
  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_enqueueKeepAlive());
    });
  }

  Future<void> _enqueueKeepAlive() {
    _chain = _chain.then((_) async {
      final DiscordIpcClient? client = _client;
      if (client == null || !client.isConnected) return;
      try {
        await client.setActivity(_lastActivity);
      } on Object catch (error) {
        debugPrint('[Discord] keep-alive не удался: $error');
        _handleDrop();
      }
    }).catchError((Object error) {
      debugPrint('[Discord] keep-alive пропущен: $error');
    });
    return _chain;
  }

  void _scheduleRetry() {
    if (_disposed) return;
    _retryTimer?.cancel();
    // 1, 2, 4… до 60 секунд — не долбим Discord, если он закрыт.
    final int seconds = min(60, 1 << min(_failures, 6));
    _retryTimer = Timer(Duration(seconds: seconds), () {
      unawaited(_enqueue());
    });
  }

  Future<void> _disconnect() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    final DiscordIpcClient? client = _client;
    _client = null;
    _clientAppId = null;
    if (client == null) return;
    // Снимаем активность, чтобы в профиле не остался «зависший» трек.
    try {
      await client.setActivity(null);
    } on Object {
      // Уже отключились — очищать нечего.
    }
    await client.close();
  }

  Map<String, dynamic> _buildActivity(DiscordPresenceInput input) {
    final Track track = input.track!;
    final int positionMs = max(0, input.position.inMilliseconds);
    final int startMs = DateTime.now().millisecondsSinceEpoch - positionMs;

    final Map<String, dynamic> timestamps;
    if (input.isPlaying && input.duration > Duration.zero) {
      timestamps = <String, dynamic>{
        'start': startMs,
        'end': startMs + input.duration.inMilliseconds,
      };
    } else {
      // На паузе конца нет: счётчик показывает позицию и «замирает».
      timestamps = <String, dynamic>{'start': startMs};
    }

    final String cover = _coverUrl(track);
    return <String, dynamic>{
      'type': 2, // Listening — «слушает».
      'details': _truncate(track.title, 128),
      'state': _truncate(track.artistLine, 128),
      'timestamps': timestamps,
      'assets': <String, dynamic>{
        'large_image': cover,
        'large_text': _truncate(track.title, 128),
      },
      'buttons': <Map<String, dynamic>>[
        <String, dynamic>{
          'label': 'Слушать в YouTube Music',
          'url': 'https://music.youtube.com/watch?v=${track.id}',
        },
      ],
    };
  }

  /// Обложка для Discord. Предпочитаем `i.ytimg.com` — там картинка доступна
  /// без токенов; если её нет, собираем адрес из videoId.
  String _coverUrl(Track track) {
    for (final String url in track.artworkFallbacks(1024)) {
      if (url.contains('i.ytimg.com')) return url;
    }
    return 'https://i.ytimg.com/vi/${track.id}/hqdefault.jpg';
  }

  String _truncate(String value, int maxLength) =>
      value.length <= maxLength ? value : value.substring(0, maxLength);

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    final DiscordIpcClient? client = _client;
    _client = null;
    _clientAppId = null;
    if (client != null) unawaited(client.close());
  }
}

/// Сервис Discord Rich Presence — один на приложение.
final Provider<DiscordPresenceService> discordPresenceServiceProvider =
    Provider<DiscordPresenceService>((ref) {
  final DiscordPresenceService service = DiscordPresenceService();
  ref.onDispose(service.dispose);
  return service;
});

/// Состояние, которое нужно отправить в Discord.
///
/// Подписка идёт только на «стабильные» поля — трек и «играет ли»: позиция
/// читается в момент пересчёта, поэтому смена секунд не дёргает presence.
final Provider<DiscordPresenceInput> discordPresenceInputProvider =
    Provider<DiscordPresenceInput>((ref) {
  final bool enabled = ref.watch(
    settingsControllerProvider.select(
      (AppSettings s) => s.discordRichPresence,
    ),
  );
  final String applicationId = ref.watch(
    settingsControllerProvider.select(
      (AppSettings s) => s.discordApplicationId,
    ),
  );

  ref.watch(
    playerControllerProvider.select(
      (PlayerUiState s) => (s.current?.id, s.isPlaying),
    ),
  );
  final PlayerUiState player = ref.read(playerControllerProvider);

  return DiscordPresenceInput(
    enabled: enabled,
    applicationId: applicationId,
    track: player.current,
    isPlaying: player.isPlaying,
    position: player.playback.position,
    duration: player.playback.duration,
  );
});
