import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../playback/listening_tracker.dart';
import '../playback/scrobble_rules.dart';
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

/// Недописанные прослушивания: сеть пропала — запись ждёт в этом ключе.
const String _kPendingScrobbles = 'mops.scrobble.pending';

/// Сколько неотправленных записей храним. Дольше суток их всё равно не
/// отправить повторно: площадки принимают прослушивание только свежим.
const int _kMaxPending = 200;

/// Сколько раз пробуем одну запись, прежде чем признать её потерянной.
const int _kMaxAttempts = 8;

/// Пауза между повторами отправки.
const Duration _kRetryDelay = Duration(minutes: 1);

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
  final ScrobbleRule _rule = ScrobbleRule();

  /// Прослушивания, которые не удалось отправить: сеть может вернуться, а
  /// прослушивание уже было — терять его нельзя.
  final List<_PendingScrobble> _pending = <_PendingScrobble>[];

  Timer? _retryTimer;
  bool _flushing = false;
  bool _pendingLoaded = false;

  /// Номер попытки входа. Выход из аккаунта или смена ключей во время запроса
  /// отменяют его результат: иначе вход завершился бы уже после выхода.
  int _authEpoch = 0;

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
    _loadPending();

    ref.onDispose(() {
      _retryTimer?.cancel();
      _retryTimer = null;
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
      _authEpoch++;
      _dropPending(_PendingScrobble.lastFm);
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
      busy: false,
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
    final int epoch = _authEpoch;
    state = state.copyWith(busy: true, clearError: true, clearAuth: true);
    try {
      final String token = await _lastFm.getToken();
      // Пока ждали токен, пользователь мог выйти из аккаунта: тогда ссылка на
      // подтверждение уже ни к чему.
      if (epoch != _authEpoch) return null;
      final String url = _lastFm.authUrl(token);
      state = state.copyWith(
        busy: false,
        lastFmAuthToken: token,
        lastFmAuthUrl: url,
      );
      return url;
    } on LastFmException catch (error) {
      if (epoch != _authEpoch) return null;
      state = state.copyWith(busy: false, error: error.message);
      return null;
    } on Object catch (error) {
      if (epoch != _authEpoch) return null;
      state = state.copyWith(busy: false, error: 'Ошибка сети: $error');
      return null;
    }
  }

  /// Шаг 3: обменять подтверждённый токен на ключ сессии.
  Future<bool> completeLastFmAuth() async {
    final String? token = state.lastFmAuthToken;
    if (token == null || token.isEmpty) return false;

    final int epoch = _authEpoch;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final LastFmSession session = await _lastFm.getSession(token);
      // Пока шёл запрос, пользователь мог выйти из аккаунта или сменить ключи:
      // тогда вход уже не относится к текущей сессии и сохранять его нельзя.
      if (epoch != _authEpoch) return false;
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
      // Недописанное за время входа как раз на это и ждало.
      unawaited(_flushPending());
      return true;
    } on LastFmException catch (error) {
      if (epoch != _authEpoch) return false;
      state = state.copyWith(busy: false, error: error.message);
      return false;
    } on Object catch (error) {
      if (epoch != _authEpoch) return false;
      state = state.copyWith(busy: false, error: 'Ошибка сети: $error');
      return false;
    }
  }

  Future<void> setLastFmEnabled(bool value) async {
    _lastFmEnabled = value;
    await _prefs.setBool(_kLastFmEnabled, value);
    state = state.copyWith(lastFmEnabled: value);
    if (value) unawaited(_flushPending());
  }

  Future<void> setLastFmNowPlaying(bool value) async {
    _lastFmNowPlaying = value;
    await _prefs.setBool(_kLastFmNowPlaying, value);
    state = state.copyWith(lastFmNowPlaying: value);
  }

  Future<void> signOutLastFm() async {
    // Отменяем незавершённый вход: иначе он дописал бы сессию уже после выхода.
    _authEpoch++;
    _lastFmSessionKey = null;
    _lastFmEnabled = false;
    _applyLastFmConfig();
    // Недописанное принадлежало прошлому аккаунту: новому оно не нужно.
    _dropPending(_PendingScrobble.lastFm);
    await _prefs.remove(_kLastFmSessionKey);
    await _prefs.remove(_kLastFmUsername);
    await _prefs.setBool(_kLastFmEnabled, false);
    state = state.copyWith(
      lastFmUsername: '',
      lastFmEnabled: false,
      busy: false,
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
      unawaited(_flushPending());
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
    if (value) unawaited(_flushPending());
  }

  Future<void> signOutListenBrainz() async {
    _listenBrainzToken = '';
    _listenBrainzEnabled = false;
    _dropPending(_PendingScrobble.listenBrainz);
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
  void reset() => _rule.reset();

  /// Вызывается плеером на каждом обновлении позиции.
  ///
  /// Сколько уже сыграно ([listened]) и что произошло ([tick]), решает общий
  /// счётчик плеера: правило засчитывания одно на статистику и на площадки.
  /// Здесь только решение «отправлять ли» и сама отправка.
  void onPlayback(
    Track track, {
    required Duration total,
    required Duration listened,
    required ListeningTick tick,
    required bool isPlaying,
    required bool isPodcast,
  }) {
    final ScrobbleActions actions = _rule.advance(
      track: track,
      total: total,
      listened: listened,
      tick: tick,
      isPlaying: isPlaying,
      isPodcast: isPodcast,
    );
    if (actions.nowPlaying) _dispatchNowPlaying();
    if (actions.scrobble) _dispatchScrobble();
  }

  void _dispatchNowPlaying() {
    final String artist = _rule.artist;
    final String title = _rule.title;
    final String? album = _rule.album;
    final int? duration = _rule.durationSeconds;

    if (_lastFmEnabled && _lastFm.isAuthorized && _lastFmNowPlaying) {
      unawaited(
        _lastFm
            .updateNowPlaying(
              artist: artist,
              track: title,
              album: album,
              duration: duration,
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
                artist: artist,
                title: title,
                release: album,
                durationMs: _rule.total.inMilliseconds > 0
                    ? _rule.total.inMilliseconds
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
    final DateTime startedAt = _rule.startedAt ?? DateTime.now();
    if (_lastFmEnabled && _lastFm.isAuthorized) {
      unawaited(
        _send(
          _PendingScrobble(
            platform: _PendingScrobble.lastFm,
            artist: _rule.artist,
            title: _rule.title,
            album: _rule.album,
            durationSeconds: _rule.durationSeconds,
            startedAt: startedAt,
          ),
        ),
      );
    }
    if (_listenBrainzEnabled && _listenBrainzToken.isNotEmpty) {
      unawaited(
        _send(
          _PendingScrobble(
            platform: _PendingScrobble.listenBrainz,
            artist: _rule.artist,
            title: _rule.title,
            album: _rule.album,
            durationSeconds: _rule.durationSeconds,
            startedAt: startedAt,
          ),
        ),
      );
    }
  }

  // ------------------------------------------------- неотправленные записи

  /// Отправляет запись; неудачу не теряет — кладёт в очередь повтора.
  Future<void> _send(_PendingScrobble item) async {
    if (await _deliver(item)) {
      // Сеть появилась — заодно дошлём то, что ждало.
      if (_pending.isNotEmpty) unawaited(_flushPending());
      return;
    }
    _pending.add(item);
    if (_pending.length > _kMaxPending) {
      _pending.removeRange(0, _pending.length - _kMaxPending);
    }
    await _savePending();
    _scheduleRetry();
  }

  /// Одна попытка отправки. `true` — запись больше не нужна (отправлена или
  /// площадка отключена), `false` — сеть подвела, надо повторить.
  Future<bool> _deliver(_PendingScrobble item) async {
    if (item.attempts >= _kMaxAttempts) {
      debugPrint('[Скробблинг] «${item.title}»: попытки исчерпаны');
      return true;
    }
    try {
      switch (item.platform) {
        case _PendingScrobble.lastFm:
          if (!_lastFmEnabled || !_lastFm.isAuthorized) return true;
          await _lastFm.scrobble(
            artist: item.artist,
            track: item.title,
            startedAt: item.startedAt,
            album: item.album,
            duration: item.durationSeconds,
          );
        case _PendingScrobble.listenBrainz:
          if (!_listenBrainzEnabled || _listenBrainzToken.isEmpty) return true;
          await _listenBrainz.submit(
            _listenBrainzToken,
            ListenBrainzListen(
              artist: item.artist,
              title: item.title,
              release: item.album,
              durationMs: item.durationSeconds == null
                  ? null
                  : item.durationSeconds! * 1000,
              listenedAt: item.startedAt,
            ),
            playingNow: false,
          );
        default:
          return true;
      }
      return true;
    } on Object catch (error) {
      debugPrint('[Скробблинг] прослушивание не отправлено: $error');
      return false;
    }
  }

  Future<void> _flushPending() async {
    if (_flushing || _pending.isEmpty) return;
    _flushing = true;
    try {
      final List<_PendingScrobble> batch = List<_PendingScrobble>.of(_pending);
      _pending.clear();
      for (final _PendingScrobble item in batch) {
        if (!await _deliver(item)) _pending.add(item.retried());
      }
      await _savePending();
    } finally {
      _flushing = false;
    }
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_retryTimer != null || _pending.isEmpty) return;
    _retryTimer = Timer(_kRetryDelay, () {
      _retryTimer = null;
      unawaited(_flushPending());
    });
  }

  /// Забывает неотправленное для одной площадки.
  void _dropPending(String platform) {
    final int before = _pending.length;
    _pending.removeWhere((_PendingScrobble item) => item.platform == platform);
    if (_pending.length != before) unawaited(_savePending());
  }

  void _loadPending() {
    if (_pendingLoaded) return;
    _pendingLoaded = true;
    final String? raw = _prefs.getString(_kPendingScrobbles);
    if (raw == null || raw.isEmpty) return;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final Object? item in decoded) {
          final _PendingScrobble? pending = _PendingScrobble.fromJson(item);
          if (pending != null && _pending.length < _kMaxPending) {
            _pending.add(pending);
          }
        }
      }
    } on FormatException catch (error) {
      debugPrint('[Скробблинг] очередь повтора не прочитана: $error');
    }
    if (_pending.isNotEmpty) unawaited(_flushPending());
  }

  Future<void> _savePending() async {
    if (_pending.isEmpty) {
      await _prefs.remove(_kPendingScrobbles);
      return;
    }
    await _prefs.setString(
      _kPendingScrobbles,
      jsonEncode(<Map<String, dynamic>>[
        for (final _PendingScrobble item in _pending) item.toJson(),
      ]),
    );
  }
}

/// Одно прослушивание, которое не удалось отправить.
///
/// Площадка — часть записи: повтор идёт только туда, где отправка сорвалась,
/// иначе прослушивание задвоилось бы на второй площадке.
@immutable
class _PendingScrobble {
  const _PendingScrobble({
    required this.platform,
    required this.artist,
    required this.title,
    required this.startedAt,
    this.album,
    this.durationSeconds,
    this.attempts = 0,
  });

  static const String lastFm = 'lastfm';
  static const String listenBrainz = 'listenbrainz';

  final String platform;
  final String artist;
  final String title;
  final DateTime startedAt;
  final String? album;
  final int? durationSeconds;
  final int attempts;

  _PendingScrobble retried() => _PendingScrobble(
        platform: platform,
        artist: artist,
        title: title,
        startedAt: startedAt,
        album: album,
        durationSeconds: durationSeconds,
        attempts: attempts + 1,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'platform': platform,
        'artist': artist,
        'track': title,
        'startedAt': startedAt.millisecondsSinceEpoch,
        if (album != null) 'album': album,
        if (durationSeconds != null) 'duration': durationSeconds,
        'attempts': attempts,
      };

  static _PendingScrobble? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final Object? platform = raw['platform'];
    final Object? artist = raw['artist'];
    final Object? title = raw['track'];
    final Object? startedAt = raw['startedAt'];
    if (platform is! String ||
        artist is! String ||
        artist.isEmpty ||
        title is! String ||
        title.isEmpty ||
        startedAt is! int) {
      return null;
    }
    return _PendingScrobble(
      platform: platform,
      artist: artist,
      title: title,
      startedAt: DateTime.fromMillisecondsSinceEpoch(startedAt),
      album: raw['album'] is String ? raw['album'] as String : null,
      durationSeconds:
          raw['duration'] is num ? (raw['duration'] as num).toInt() : null,
      attempts: raw['attempts'] is num ? (raw['attempts'] as num).toInt() : 0,
    );
  }
}

/// Состояние скробблинга для строки в настройках и подэкранов.
final NotifierProvider<ScrobblerController, ScrobbleState> scrobblingProvider =
    NotifierProvider<ScrobblerController, ScrobbleState>(
  ScrobblerController.new,
);
