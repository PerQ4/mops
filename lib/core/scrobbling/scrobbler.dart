import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import 'lastfm.dart';
import 'listenbrainz.dart';

/// ---------------------------------------------------------------------------
/// Хранилище
/// ---------------------------------------------------------------------------

// Свои ключи держим отдельно от общих настроек: модуль скробблинга пишет
// только то, что относится к нему самому, и не трогает `app_settings.dart`.
const String _kLastFmApiKey = 'mops.scrobble.lastfm.api_key';
const String _kLastFmApiSecret = 'mops.scrobble.lastfm.api_secret';
const String _kLastFmSessionKey = 'mops.scrobble.lastfm.session_key';
const String _kLastFmUsername = 'mops.scrobble.lastfm.username';
const String _kLastFmEnabled = 'mops.scrobble.lastfm.enabled';
const String _kLastFmNowPlaying = 'mops.scrobble.lastfm.now_playing';
const String _kListenBrainzToken = 'mops.scrobble.listenbrainz.token';
const String _kListenBrainzUsername = 'mops.scrobble.listenbrainz.username';
const String _kListenBrainzEnabled = 'mops.scrobble.listenbrainz.enabled';

/// Ключи сессии и токены не держим открытой строкой.
///
/// `shared_preferences` на десктопе — обычный файл, шифрования в проекте нет,
/// поэтому это запутывание, а не защита: оно лишь не выставляет ключ на вид
/// тому, кто откроет файл настроек.
String encodeStoredSecret(String value) =>
    value.isEmpty ? '' : base64Url.encode(utf8.encode(value));

String decodeStoredSecret(String value) {
  if (value.isEmpty) return '';
  try {
    return utf8.decode(base64Url.decode(value));
  } on FormatException {
    return '';
  }
}

/// ---------------------------------------------------------------------------
/// Состояние для интерфейса
/// ---------------------------------------------------------------------------

/// Что знает и показывает интерфейс о скробблинге.
@immutable
class ScrobbleState {
  const ScrobbleState({
    this.lastFmConfigured = false,
    this.lastFmEnabled = false,
    this.lastFmNowPlaying = true,
    this.lastFmUsername = '',
    this.lastFmAuthToken,
    this.lastFmAuthUrl,
    this.listenBrainzEnabled = false,
    this.listenBrainzUsername = '',
    this.busy = false,
    this.error,
  });

  /// Ключи приложения Last.fm заданы — можно запрашивать токен входа.
  final bool lastFmConfigured;

  /// Отправлять прослушивания в Last.fm.
  final bool lastFmEnabled;

  /// Отправлять в Last.fm статус «сейчас играет».
  final bool lastFmNowPlaying;

  final String lastFmUsername;

  /// Одноразовый токен, ожидающий подтверждения в браузере.
  final String? lastFmAuthToken;

  /// Ссылка, которую нужно открыть, чтобы подтвердить вход.
  final String? lastFmAuthUrl;

  /// Отправлять прослушивания в ListenBrainz.
  final bool listenBrainzEnabled;

  final String listenBrainzUsername;

  /// Идёт сетевой запрос (вход, проверка токена).
  final bool busy;
  final String? error;

  bool get lastFmConnected => lastFmUsername.isNotEmpty;
  bool get listenBrainzConnected => listenBrainzUsername.isNotEmpty;

  /// Есть ли хоть одна подключённая площадка — для строки в настройках.
  bool get anyConnected => lastFmConnected || listenBrainzConnected;

  ScrobbleState copyWith({
    bool? lastFmConfigured,
    bool? lastFmEnabled,
    bool? lastFmNowPlaying,
    String? lastFmUsername,
    String? lastFmAuthToken,
    String? lastFmAuthUrl,
    bool? listenBrainzEnabled,
    String? listenBrainzUsername,
    bool? busy,
    String? error,
    bool clearError = false,
    bool clearAuth = false,
  }) {
    return ScrobbleState(
      lastFmConfigured: lastFmConfigured ?? this.lastFmConfigured,
      lastFmEnabled: lastFmEnabled ?? this.lastFmEnabled,
      lastFmNowPlaying: lastFmNowPlaying ?? this.lastFmNowPlaying,
      lastFmUsername: lastFmUsername ?? this.lastFmUsername,
      lastFmAuthToken:
          clearAuth ? null : (lastFmAuthToken ?? this.lastFmAuthToken),
      lastFmAuthUrl: clearAuth ? null : (lastFmAuthUrl ?? this.lastFmAuthUrl),
      listenBrainzEnabled:
          listenBrainzEnabled ?? this.listenBrainzEnabled,
      listenBrainzUsername:
          listenBrainzUsername ?? this.listenBrainzUsername,
      busy: busy ?? this.busy,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ScrobbleState &&
      other.lastFmConfigured == lastFmConfigured &&
      other.lastFmEnabled == lastFmEnabled &&
      other.lastFmNowPlaying == lastFmNowPlaying &&
      other.lastFmUsername == lastFmUsername &&
      other.lastFmAuthToken == lastFmAuthToken &&
      other.lastFmAuthUrl == lastFmAuthUrl &&
      other.listenBrainzEnabled == listenBrainzEnabled &&
      other.listenBrainzUsername == listenBrainzUsername &&
      other.busy == busy &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
        lastFmConfigured,
        lastFmEnabled,
        lastFmNowPlaying,
        lastFmUsername,
        lastFmAuthToken,
        lastFmAuthUrl,
        listenBrainzEnabled,
        listenBrainzUsername,
        busy,
        error,
      );
}

/// ---------------------------------------------------------------------------
/// Контроллер и хук плеера
/// ---------------------------------------------------------------------------

/// Управляет обеими площадками и решает, когда отправлять прослушивание.
///
/// Один контроллер на Last.fm и ListenBrainz намеренно: правило «когда
/// скробблить» общее, и держать два независимых счётчика времени — значит
/// разойтись в подсчёте. Плеер дёргает [onPlayback] при каждом обновлении
/// позиции; сюда же приходят действия с экранов настроек.
class ScrobblerController extends Notifier<ScrobbleState> {
  final LastFmClient _lastFm = LastFmClient();
  final ListenBrainzClient _listenBrainz = ListenBrainzClient();

  late SharedPreferences _prefs;

  // --- настройки, продублированные в поля: хук читает их на каждом тике
  // позиции, и ходить за этим в `state` было бы лишним.
  String _lastFmApiKey = '';
  String _lastFmApiSecret = '';
  String? _lastFmSessionKey;
  bool _lastFmEnabled = false;
  bool _lastFmNowPlaying = true;

  String _listenBrainzToken = '';
  bool _listenBrainzEnabled = false;

  // --- состояние текущего проигрыша (в `ScrobbleState` не выносим: оно
  // меняется несколько раз в секунду и перестраивало бы всех слушателей).
  String? _trackId;
  String _artist = '';
  String _title = '';
  String? _album;
  Duration _total = Duration.zero;
  Duration _listened = Duration.zero;
  Duration _lastPosition = Duration.zero;
  DateTime? _startedAt;
  bool _nowPlayingSent = false;
  bool _scrobbled = false;

  @override
  ScrobbleState build() {
    _prefs = ref.read(sharedPreferencesProvider);

    _lastFmApiKey = _prefs.getString(_kLastFmApiKey) ?? kLastFmApiKey;
    _lastFmApiSecret = _prefs.getString(_kLastFmApiSecret) ?? kLastFmApiSecret;
    _lastFmSessionKey =
        _nonEmpty(decodeStoredSecret(_prefs.getString(_kLastFmSessionKey) ?? ''));
    _lastFmEnabled = _prefs.getBool(_kLastFmEnabled) ?? false;
    _lastFmNowPlaying = _prefs.getBool(_kLastFmNowPlaying) ?? true;

    _listenBrainzToken =
        _nonEmpty(decodeStoredSecret(_prefs.getString(_kListenBrainzToken) ?? '')) ??
            '';
    _listenBrainzEnabled = _prefs.getBool(_kListenBrainzEnabled) ?? false;

    _applyLastFmConfig();

    ref.onDispose(() {
      _lastFm.dispose();
      _listenBrainz.dispose();
    });

    return ScrobbleState(
      lastFmConfigured: _lastFm.isConfigured,
      lastFmEnabled: _lastFmEnabled,
      lastFmNowPlaying: _lastFmNowPlaying,
      lastFmUsername: _prefs.getString(_kLastFmUsername) ?? '',
      listenBrainzEnabled: _listenBrainzEnabled,
      listenBrainzUsername: _prefs.getString(_kListenBrainzUsername) ?? '',
    );
  }

  /// Текущие ключи приложения — экран показывает их в полях ввода.
  String get lastFmApiKey => _lastFmApiKey;
  String get lastFmApiSecret => _lastFmApiSecret;

  void _applyLastFmConfig() {
    _lastFm.configure(
      apiKey: _lastFmApiKey,
      apiSecret: _lastFmApiSecret,
      sessionKey: _lastFmSessionKey,
    );
  }

  static String? _nonEmpty(String value) => value.isEmpty ? null : value;

  // --------------------------------------------------------------- Last.fm

  /// Сохраняет ключи приложения и (если были) сбрасывает сессию под них.
  Future<void> saveLastFmCredentials({
    required String apiKey,
    required String apiSecret,
  }) async {
    final String key = apiKey.trim();
    final String secret = apiSecret.trim();
    if (key.isEmpty || secret.isEmpty) {
      state = state.copyWith(error: 'Нужны и API key, и shared secret.');
      return;
    }

    final bool changed = key != _lastFmApiKey || secret != _lastFmApiSecret;
    _lastFmApiKey = key;
    _lastFmApiSecret = secret;
    if (changed) {
      // Ключи сменились — прежняя сессия к ним не относится.
      _lastFmSessionKey = null;
      _lastFmEnabled = false;
      await _prefs.remove(_kLastFmSessionKey);
      await _prefs.remove(_kLastFmUsername);
      await _prefs.setBool(_kLastFmEnabled, false);
    }
    await _prefs.setString(_kLastFmApiKey, key);
    await _prefs.setString(_kLastFmApiSecret, secret);
    _applyLastFmConfig();

    state = state.copyWith(
      lastFmConfigured: _lastFm.isConfigured,
      lastFmUsername: changed ? '' : state.lastFmUsername,
      lastFmEnabled: _lastFmEnabled,
      clearError: true,
      clearAuth: true,
    );
  }

  /// Шаг 1: получить токен и ссылку для подтверждения. Возвращает ссылку,
  /// которую нужно открыть в браузере (или `null`, если не вышло).
  Future<String?> startLastFmAuth() async {
    if (!_lastFm.isConfigured) {
      state = state.copyWith(
        error: 'Сначала укажите API key и shared secret.',
        clearAuth: true,
      );
      return null;
    }
    state = state.copyWith(busy: true, clearError: true, clearAuth: true);
    try {
      final String token = await _lastFm.getToken();
      final String url = _lastFm.authUrl(token);
      state = state.copyWith(
        busy: false,
        lastFmAuthToken: token,
        lastFmAuthUrl: url,
      );
      return url;
    } on LastFmException catch (error) {
      state = state.copyWith(busy: false, error: error.message);
      return null;
    } on Object catch (error) {
      state = state.copyWith(busy: false, error: 'Ошибка сети: $error');
      return null;
    }
  }

  /// Шаг 3: обменять подтверждённый токен на ключ сессии.
  Future<bool> completeLastFmAuth() async {
    final String? token = state.lastFmAuthToken;
    if (token == null || token.isEmpty) return false;

    state = state.copyWith(busy: true, clearError: true);
    try {
      final LastFmSession session = await _lastFm.getSession(token);
      _lastFmSessionKey = session.key;
      _applyLastFmConfig();
      await _prefs.setString(_kLastFmSessionKey, encodeStoredSecret(session.key));
      await _prefs.setString(_kLastFmUsername, session.username);
      // После входа отправку включаем сразу: пользователь шёл сюда за этим.
      _lastFmEnabled = true;
      await _prefs.setBool(_kLastFmEnabled, true);

      state = state.copyWith(
        busy: false,
        lastFmUsername: session.username,
        lastFmEnabled: true,
        clearError: true,
        clearAuth: true,
      );
      return true;
    } on LastFmException catch (error) {
      state = state.copyWith(busy: false, error: error.message);
      return false;
    } on Object catch (error) {
      state = state.copyWith(busy: false, error: 'Ошибка сети: $error');
      return false;
    }
  }

  Future<void> setLastFmEnabled(bool value) async {
    _lastFmEnabled = value;
    await _prefs.setBool(_kLastFmEnabled, value);
    state = state.copyWith(lastFmEnabled: value);
  }

  Future<void> setLastFmNowPlaying(bool value) async {
    _lastFmNowPlaying = value;
    await _prefs.setBool(_kLastFmNowPlaying, value);
    state = state.copyWith(lastFmNowPlaying: value);
  }

  Future<void> signOutLastFm() async {
    _lastFmSessionKey = null;
    _lastFmEnabled = false;
    _applyLastFmConfig();
    await _prefs.remove(_kLastFmSessionKey);
    await _prefs.remove(_kLastFmUsername);
    await _prefs.setBool(_kLastFmEnabled, false);
    state = state.copyWith(
      lastFmUsername: '',
      lastFmEnabled: false,
      clearAuth: true,
      clearError: true,
    );
  }

  // ----------------------------------------------------------- ListenBrainz

  /// Подключает ListenBrainz по токену: сначала проверяем его на сервере,
  /// иначе опечатка сохранилась бы и «успешно» ломала отправку.
  Future<bool> connectListenBrainz(String token) async {
    final String trimmed = token.trim();
    if (trimmed.isEmpty) {
      state = state.copyWith(error: 'Вставьте токен ListenBrainz.');
      return false;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      final ListenBrainzUser user = await _listenBrainz.validateToken(trimmed);
      _listenBrainzToken = trimmed;
      _listenBrainzEnabled = true;
      await _prefs.setString(_kListenBrainzToken, encodeStoredSecret(trimmed));
      await _prefs.setString(_kListenBrainzUsername, user.username);
      await _prefs.setBool(_kListenBrainzEnabled, true);
      state = state.copyWith(
        busy: false,
        listenBrainzUsername: user.username,
        listenBrainzEnabled: true,
        clearError: true,
      );
      return true;
    } on ListenBrainzException catch (error) {
      state = state.copyWith(busy: false, error: error.message);
      return false;
    } on Object catch (error) {
      state = state.copyWith(busy: false, error: 'Ошибка сети: $error');
      return false;
    }
  }

  Future<void> setListenBrainzEnabled(bool value) async {
    _listenBrainzEnabled = value;
    await _prefs.setBool(_kListenBrainzEnabled, value);
    state = state.copyWith(listenBrainzEnabled: value);
  }

  Future<void> signOutListenBrainz() async {
    _listenBrainzToken = '';
    _listenBrainzEnabled = false;
    await _prefs.remove(_kListenBrainzToken);
    await _prefs.remove(_kListenBrainzUsername);
    await _prefs.setBool(_kListenBrainzEnabled, false);
    state = state.copyWith(
      listenBrainzUsername: '',
      listenBrainzEnabled: false,
      clearError: true,
    );
  }

  // ------------------------------------------------------------ хук плеера

  /// Сбрасывает счётчик: очередь пуста или трека больше нет.
  void reset() {
    _trackId = null;
    _listened = Duration.zero;
    _lastPosition = Duration.zero;
    _startedAt = null;
    _nowPlayingSent = false;
    _scrobbled = false;
  }

  /// Вызывается плеером на каждом обновлении позиции.
  ///
  /// [position] — позиция трека, а не настенные часы: на паузе она стоит, и
  /// время простоя в статистику не попадает. [completed] — трек доиграл сам;
  /// такой проигрыш считается полным даже если частые обновления позиции до
  /// нас не дошли.
  void onPlayback(
    Track track, {
    required Duration position,
    required Duration duration,
    required bool isPlaying,
    bool completed = false,
  }) {
    final Duration total = duration > Duration.zero ? duration : track.duration;
    if (track.id != _trackId) _begin(track, position, total);

    if (isPlaying) {
      _accumulate(position);
      if (!_nowPlayingSent) {
        _nowPlayingSent = true;
        _dispatchNowPlaying();
      }
    } else if (completed) {
      _listened = total;
    } else {
      // Пауза или перемотка: позицию запоминаем, но не засчитываем.
      _lastPosition = position;
      return;
    }

    if (!_scrobbled && _shouldScrobble(total, _listened)) {
      _scrobbled = true;
      _dispatchScrobble();
    }

    // Трек доиграл: следующий проигрыш того же трека (повтор одного) должен
    // начать счёт заново — иначе повтор не попадёт в статистику.
    if (completed) _resetCycle();
  }

  void _begin(Track track, Duration position, Duration total) {
    _trackId = track.id;
    _artist = _artistNames(track);
    _title = track.title;
    _album = track.album?.name;
    _total = total;
    _listened = Duration.zero;
    _lastPosition = position;
    _startedAt = DateTime.now();
    _nowPlayingSent = false;
    _scrobbled = false;
  }

  void _resetCycle() {
    _listened = Duration.zero;
    _lastPosition = Duration.zero;
    _startedAt = DateTime.now();
    _nowPlayingSent = false;
    _scrobbled = false;
  }

  /// Накапливает прослушанное по приращению позиции.
  ///
  /// Приращение больше пары секунд — это перемотка, а не прослушивание:
  /// такой скачок не засчитываем.
  void _accumulate(Duration position) {
    final Duration delta = position - _lastPosition;
    if (delta > Duration.zero && delta <= const Duration(seconds: 5)) {
      _listened += delta;
    }
    _lastPosition = position;
  }

  /// Правило Last.fm: трек короче 30 секунд не скробблим; в остальных случаях
  /// достаточно половины трека или четырёх минут — что наступит раньше.
  bool _shouldScrobble(Duration duration, Duration listened) {
    if (duration > Duration.zero && duration.inSeconds <= 30) return false;
    if (duration <= Duration.zero) return listened >= const Duration(minutes: 4);
    final Duration half = duration ~/ 2;
    final Duration threshold =
        half < const Duration(minutes: 4) ? half : const Duration(minutes: 4);
    return listened >= threshold;
  }

  int? get _durationSeconds =>
      _total > Duration.zero ? _total.inSeconds : null;

  void _dispatchNowPlaying() {
    if (_lastFmEnabled && _lastFm.isAuthorized && _lastFmNowPlaying) {
      unawaited(
        _lastFm
            .updateNowPlaying(
              artist: _artist,
              track: _title,
              album: _album,
              duration: _durationSeconds,
            )
            .catchError(
              (Object error) =>
                  debugPrint('[Last.fm] «сейчас играет» не отправлено: $error'),
            ),
      );
    }
    if (_listenBrainzEnabled && _listenBrainzToken.isNotEmpty) {
      unawaited(
        _listenBrainz
            .submit(
              _listenBrainzToken,
              ListenBrainzListen(
                artist: _artist,
                title: _title,
                release: _album,
                durationMs: _total.inMilliseconds > 0
                    ? _total.inMilliseconds
                    : null,
              ),
              playingNow: true,
            )
            .catchError(
              (Object error) => debugPrint(
                '[ListenBrainz] playing_now не отправлен: $error',
              ),
            ),
      );
    }
  }

  void _dispatchScrobble() {
    final DateTime startedAt = _startedAt ?? DateTime.now();
    if (_lastFmEnabled && _lastFm.isAuthorized) {
      unawaited(
        _lastFm
            .scrobble(
              artist: _artist,
              track: _title,
              startedAt: startedAt,
              album: _album,
              duration: _durationSeconds,
            )
            .catchError(
              (Object error) =>
                  debugPrint('[Last.fm] прослушивание не отправлено: $error'),
            ),
      );
    }
    if (_listenBrainzEnabled && _listenBrainzToken.isNotEmpty) {
      unawaited(
        _listenBrainz
            .submit(
              _listenBrainzToken,
              ListenBrainzListen(
                artist: _artist,
                title: _title,
                release: _album,
                durationMs: _total.inMilliseconds > 0
                    ? _total.inMilliseconds
                    : null,
                listenedAt: startedAt,
              ),
              playingNow: false,
            )
            .catchError(
              (Object error) => debugPrint(
                '[ListenBrainz] прослушивание не отправлено: $error',
              ),
            ),
      );
    }
  }

  static String _artistNames(Track track) {
    final List<String> names = track.artists
        .map((ArtistRef artist) => artist.name.trim())
        .where((String name) => name.isNotEmpty)
        .toList(growable: false);
    return names.isEmpty ? track.artistLine : names.join(', ');
  }
}

/// Состояние скробблинга для строки в настройках и подэкранов.
final NotifierProvider<ScrobblerController, ScrobbleState> scrobblingProvider =
    NotifierProvider<ScrobblerController, ScrobbleState>(
  ScrobblerController.new,
);
