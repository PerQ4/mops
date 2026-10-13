import 'package:flutter/services.dart';

/// Ошибка входа через встроенный браузер.
class WebviewLoginException implements Exception {
  WebviewLoginException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Вход в аккаунт во встроенном браузере.
///
/// На Linux окно построено на WebKitGTK (см. `linux/runner/webview_login.cc`).
/// Такой вход нужен потому, что страницу Google нельзя пройти программно, а
/// часть нужных cookie помечена HttpOnly и из JavaScript недоступна.
///
/// Окно закрывается само, как только на music.youtube.com появляется SAPISID,
/// то есть вход действительно выполнен.
abstract final class WebviewLogin {
  static const MethodChannel _channel = MethodChannel('mops/webview_login');

  /// Доступен ли встроенный браузер на этой платформе.
  static Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Открывает окно входа и возвращает строку cookie.
  ///
  /// Бросает [WebviewLoginException], если вход отменён или cookie не получены.
  static Future<String> openLogin({
    String url = 'https://music.youtube.com/',
  }) async {
    try {
      final String? cookies = await _channel.invokeMethod<String>(
        'openLogin',
        <String, Object?>{'url': url},
      );
      if (cookies == null || cookies.trim().isEmpty) {
        throw WebviewLoginException('Cookie не получены — вход не выполнен.');
      }
      return cookies;
    } on PlatformException catch (error) {
      throw WebviewLoginException(
        error.message ?? 'Не удалось войти через встроенный браузер.',
      );
    } on MissingPluginException {
      throw WebviewLoginException(
        'Встроенный браузер доступен только в сборке для Linux.',
      );
    }
  }

  /// Закрывает окно входа, если оно открыто.
  static Future<void> close() async {
    try {
      await _channel.invokeMethod<bool>('close');
    } on PlatformException {
      // Закрывать нечего — это не ошибка.
    } on MissingPluginException {
      // Платформа без встроенного браузера.
    }
  }
}
