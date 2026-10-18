import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Окружение WebView2, подготовленное при старте приложения.
///
/// Почему готовим сами. Плагин умеет создавать окружение сам, но тогда папку
/// данных он берёт по умолчанию — рядом с exe. Установленное приложение лежит
/// в `Program Files`, куда без прав администратора писать нельзя, и встроенный
/// браузер не открывался вовсе: им работают и вход в аккаунт, и просмотр
/// клипов.
///
/// Почему передаём в виджет, а не полагаемся на «общее» окружение плагина:
/// так делает пример самого плагина (`example/lib/in_app_webiew_example.screen.dart`)
/// — виджет получает окружение явным параметром `webViewEnvironment`.
WebViewEnvironment? mopsWebViewEnvironment;

/// Создаёт окружение WebView2 в каталоге данных приложения.
///
/// На остальных системах окружения нет — там встроенный браузер работает на
/// своём движке (WKWebView на macOS, WebKitGTK на Linux), и параметр не нужен.
Future<WebViewEnvironment?> prepareWebViewEnvironment(Directory dataDir) async {
  if (!Platform.isWindows) return null;
  try {
    final Directory folder = Directory(
      '${dataDir.path}${Platform.pathSeparator}webview',
    );
    await folder.create(recursive: true);
    return mopsWebViewEnvironment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(userDataFolder: folder.path),
    );
  } on Object catch (error) {
    // Без встроенного браузера приложение работает: остаётся вход по cookie.
    debugPrint('[WebView2] не удалось создать окружение: $error');
    return null;
  }
}

/// Менеджер cookie для нашего окружения WebView2.
///
/// На Windows у менеджера cookie **своё** окружение: если его не передать, он
/// читает cookie из профиля по умолчанию, а вход идёт в наш профиль — и
/// приложение «не видит», что пользователь вошёл: окно входа не закрывается, а
/// данные аккаунта не приходят. На остальных системах окружения нет, и параметр
/// не нужен.
CookieManager cookieManager() => CookieManager.instance(
      webViewEnvironment: Platform.isWindows ? mopsWebViewEnvironment : null,
    );
