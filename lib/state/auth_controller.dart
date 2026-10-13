import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth/oauth_device_flow.dart';
import '../core/auth/token_store.dart';
import '../core/innertube/innertube_client.dart';
import '../data/sources/library_source.dart';
import 'catalog_providers.dart';
import 'providers.dart';

/// Состояние входа в аккаунт.
@immutable
class AuthState {
  const AuthState({
    this.session,
    this.busy = false,
    this.error,
    this.pendingCode,
    this.waitingForUser = false,
  });

  final AuthSession? session;

  /// Идёт сетевой запрос (получение кода, обмен токена, загрузка профиля).
  final bool busy;
  final String? error;

  /// Код, который пользователь должен ввести в браузере.
  final DeviceCodeResponse? pendingCode;

  /// Ждём подтверждения входа в браузере.
  final bool waitingForUser;

  bool get isSignedIn => session != null;
  String get methodLabel => session?.method.label ?? 'Гость';

  AuthState copyWith({
    AuthSession? session,
    bool? busy,
    String? error,
    DeviceCodeResponse? pendingCode,
    bool? waitingForUser,
    bool clearError = false,
    bool clearPending = false,
    bool clearSession = false,
  }) {
    return AuthState(
      session: clearSession ? null : (session ?? this.session),
      busy: busy ?? this.busy,
      error: clearError ? null : (error ?? this.error),
      pendingCode: clearPending ? null : (pendingCode ?? this.pendingCode),
      waitingForUser: waitingForUser ?? this.waitingForUser,
    );
  }
}

/// Управляет входом в аккаунт YouTube Music.
///
/// Поддерживаются два способа:
///  * **OAuth Device Flow** — нужен собственный бесплатный OAuth-клиент
///    из Google Cloud Console типа «TVs and Limited Input devices»;
///  * **Cookie браузера** — достаточно вставить cookie с `SAPISID`/`__Secure-3PAPISID`.
///
/// Google не выдаёт сторонним приложениям общие ключи, поэтому первый способ
/// требует client_id/client_secret от пользователя — так же работают
/// `ytmusicapi` и другие неофициальные клиенты.
class AuthController extends Notifier<AuthState> {
  OAuthDeviceFlow? _flow;

  @override
  AuthState build() {
    final AuthSession? initial = ref.watch(initialSessionProvider);

    // Клиент может пересоздаться при смене региона — тогда авторизацию
    // нужно применить к новому экземпляру.
    final InnerTubeClient client = ref.watch(innerTubeProvider);
    _applyAuth(client, initial);

    if (initial != null) {
      // Обновляем токен в фоне, если срок близок к концу.
      unawaited(_refreshIfNeeded());
    }

    ref.onDispose(() => _flow?.dispose());

    return AuthState(session: initial);
  }

  // ------------------------------------------------------- вход через OAuth

  /// Шаг 1: получаем код устройства и ссылку для браузера.
  Future<void> startOAuthLogin() async {
    final settings = ref.read(settingsControllerProvider);
    final String clientId = settings.oauthClientId.trim();
    final String clientSecret = settings.oauthClientSecret.trim();

    if (clientId.isEmpty || clientSecret.isEmpty) {
      state = state.copyWith(
        error: 'Укажите client_id и client_secret в настройках аккаунта. '
            'Инструкция — на экране входа.',
      );
      return;
    }

    state = state.copyWith(busy: true, clearError: true, clearPending: true);

    try {
      _flow?.dispose();
      _flow = OAuthDeviceFlow(clientId: clientId, clientSecret: clientSecret);
      final DeviceCodeResponse code = await _flow!.requestDeviceCode();
      state = state.copyWith(busy: false, pendingCode: code);
    } on OAuthException catch (error) {
      state = state.copyWith(busy: false, error: error.message);
    } on Exception catch (error) {
      state = state.copyWith(busy: false, error: 'Ошибка сети: $error');
    }
  }

  /// Шаг 2: ждём, пока пользователь подтвердит вход в браузере.
  Future<void> completeOAuthLogin() async {
    final DeviceCodeResponse? code = state.pendingCode;
    final OAuthDeviceFlow? flow = _flow;
    if (code == null || flow == null) return;

    state = state.copyWith(
      busy: true,
      waitingForUser: true,
      clearError: true,
    );

    try {
      final OAuthTokenSet tokens = await flow.pollForToken(code);
      final AuthSession session = AuthSession(
        method: AuthMethod.oauth,
        tokens: tokens,
      );
      await _persist(session);
      state = state.copyWith(
        busy: false,
        waitingForUser: false,
        session: session,
        clearPending: true,
      );
      await _loadProfile();
      _invalidateCatalog();
    } on OAuthException catch (error) {
      state = state.copyWith(
        busy: false,
        waitingForUser: false,
        error: error.message,
      );
    } on Exception catch (error) {
      state = state.copyWith(
        busy: false,
        waitingForUser: false,
        error: 'Ошибка сети: $error',
      );
    }
  }

  /// Отмена ожидания входа.
  void cancelOAuthLogin() {
    _flow?.dispose();
    _flow = null;
    state = state.copyWith(
      busy: false,
      waitingForUser: false,
      clearPending: true,
      clearError: true,
    );
  }

  // ----------------------------------------------------- вход через cookie

  /// Вход по cookie браузера.
  ///
  /// Достаточно строки с `SAPISID` или `__Secure-3PAPISID`; остальные
  /// cookie можно не указывать — подпись считается только по `SAPISID`.
  Future<void> signInWithCookies(String cookieString) async {
    final String trimmed = cookieString.trim();
    if (trimmed.isEmpty) {
      state = state.copyWith(error: 'Вставьте cookie из браузера.');
      return;
    }

    final CookieAuth auth = CookieAuth(trimmed);
    if (!auth.isUsable) {
      state = state.copyWith(
        error: 'В cookie не найден SAPISID — вход не выполнен. '
            'Войдите в аккаунт Google или вставьте cookie вручную.',
      );
      return;
    }

    state = state.copyWith(busy: true, clearError: true);

    final AuthSession session = AuthSession(
      method: AuthMethod.cookies,
      cookieString: trimmed,
    );
    await _persist(session);
    state = state.copyWith(busy: false, session: session);

    await _loadProfile();
    _invalidateCatalog();
  }

  // ---------------------------------------------------------------- выход

  Future<void> signOut() async {
    await ref.read(tokenStoreProvider).clear();
    _flow?.dispose();
    _flow = null;

    state = const AuthState();
    _applyAuth(ref.read(innerTubeProvider), null);
    _invalidateCatalog();
  }

  /// Обновление access_token (для OAuth-сессии).
  Future<void> refreshToken() async {
    if (!await _refreshIfNeeded(force: true)) {
      state = state.copyWith(
        error: 'Не удалось обновить сессию. Войдите заново.',
      );
    }
  }

  // -------------------------------------------------------------- private

  Future<void> _persist(AuthSession session) async {
    await ref.read(tokenStoreProvider).write(session);
    _applyAuth(ref.read(innerTubeProvider), session);
  }

  void _applyAuth(InnerTubeClient client, AuthSession? session) {
    if (session == null) {
      client.setAuth(const AnonymousAuth());
      return;
    }

    if (session.isOAuth) {
      client.setAuth(BearerAuth(session.tokens!.accessToken));
      return;
    }

    if (session.isCookie) {
      client.setAuth(CookieAuth(session.cookieString!));
      return;
    }

    client.setAuth(const AnonymousAuth());
  }

  /// Подтягивает имя и аватар аккаунта — полезно и как проверка, что вход удался.
  Future<void> _loadProfile() async {
    try {
      final AccountInfo info =
          await ref.read(librarySourceProvider).accountInfo();
      final AuthSession? session = state.session;
      if (session == null) return;

      final AuthSession updated = session.copyWith(
        displayName: info.name,
        channelId: info.channelId,
        avatarUrl: info.avatarUrl,
      );
      await _persist(updated);
      state = state.copyWith(session: updated);
    } on InnerTubeException catch (error) {
      if (error.isUnauthorized) {
        state = state.copyWith(
          error: 'Google отклонил вход. Проверьте, что OAuth-клиент создан '
              'как «TVs and Limited Input devices» и YouTube Data API включён.',
        );
      }
    } on Exception {
      // Имя аккаунта — не критично, вход мог пройти успешно.
    }
  }

  Future<bool> _refreshIfNeeded({bool force = false}) async {
    final AuthSession? session = state.session;
    final OAuthTokenSet? tokens = session?.tokens;
    if (session == null || tokens == null) return false;
    if (!force && !tokens.isExpired) return false;

    final settings = ref.read(settingsControllerProvider);
    if (settings.oauthClientId.isEmpty || settings.oauthClientSecret.isEmpty) {
      return false;
    }

    try {
      final OAuthDeviceFlow flow = OAuthDeviceFlow(
        clientId: settings.oauthClientId,
        clientSecret: settings.oauthClientSecret,
      );
      final OAuthTokenSet refreshed = await flow.refresh(tokens.refreshToken);
      flow.dispose();

      final AuthSession updated = session.copyWith(tokens: refreshed);
      await _persist(updated);
      state = state.copyWith(session: updated, clearError: true);
      return true;
    } on Exception {
      return false;
    }
  }

  /// После входа/выхода персональные подборки должны перезагрузиться.
  void _invalidateCatalog() {
    ref.invalidate(homeSectionsProvider);
    ref.invalidate(exploreSectionsProvider);
  }
}

final NotifierProvider<AuthController, AuthState> authControllerProvider =
    NotifierProvider<AuthController, AuthState>(AuthController.new);
