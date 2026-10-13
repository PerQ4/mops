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
/// На Linux панель построена на WebKitGTK (см. `linux/runner/webview_login.cc`)
/// и открывается поверх интерфейса, в том же окне приложения.
/// Такой вход нужен потому, что страницу Google нельзя пройти программно, а
/// часть нужных cookie помечена HttpOnly и из JavaScript недоступна.
///
/// Панель закрывается сама, как только на music.youtube.com появляется SAPISID,
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

  /// Адрес страницы входа Google.
  ///
  /// После входа Google возвращает на music.youtube.com, и панель закрывается
  /// сама, как только появится SAPISID.
  static const String signInUrl =
      'https://accounts.google.com/ServiceLogin?service=youtube'
      '&continue=https%3A%2F%2Fmusic.youtube.com%2F&hl=ru';

  /// Открывает панель входа и возвращает строку cookie.
  ///
  /// Бросает [WebviewLoginException], если вход отменён или cookie не получены.
  static Future<String> openLogin({String url = signInUrl}) async {
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

  /// Закрывает панель входа, если она открыта.
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
