import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Встроенный браузер для входа — на Windows и macOS.
///
/// На Linux панель входа сделана на WebKitGTK (`linux/runner/webview_login.cc`):
/// Flutter встроенного браузера там не предоставляет. На остальных системах
/// используем `flutter_inappwebview` — он работает через WebView2 в Windows и
/// WKWebView в macOS, и у него есть доступ к cookie.
///
/// Возвращает строку cookie после входа или null, если вход закрыли.
Future<String?> openInAppLogin(
  BuildContext context, {
  required String url,
  required String cookieHost,
  required bool Function(String cookies) isDone,
}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(
      builder: (BuildContext context) => _LoginPage(
        url: url,
        cookieHost: cookieHost,
        isDone: isDone,
      ),
    ),
  );
}

/// Доступен ли встроенный браузер на этой системе.
bool get inAppLoginAvailable => Platform.isWindows || Platform.isMacOS;

class _LoginPage extends StatefulWidget {
  const _LoginPage({
    required this.url,
    required this.cookieHost,
    required this.isDone,
  });

  final String url;
  final String cookieHost;
  final bool Function(String cookies) isDone;

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<_LoginPage> {
  bool _checking = false;

  /// Проверяет cookie после каждой загрузки: вход мог уже состояться.
  Future<void> _checkCookies() async {
    if (_checking || !mounted) return;
    _checking = true;
    try {
      final List<Cookie> cookies = await CookieManager.instance().getCookies(
        url: WebUri(widget.cookieHost),
      );
      // Оставляем только домены нужного сервиса: смешивать нельзя, иначе
      // имена (SID, SAPISID) дублируются и YouTube считает нас гостем.
      final String joined = cookies
          .where((Cookie c) => c.value.isNotEmpty)
          .map((Cookie c) => '${c.name}=${c.value}')
          .join('; ');
      if (widget.isDone(joined) && mounted) {
        Navigator.of(context).pop(joined);
      }
    } on Object {
      // Не получилось прочитать cookie — попробуем на следующей загрузке.
    } finally {
      _checking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Вход'),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              await _checkCookies();
            },
            child: const Text('Готово'),
          ),
        ],
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(widget.url)),
        onLoadStop: (InAppWebViewController controller, WebUri? url) {
          unawaited(_checkCookies());
        },
      ),
    );
  }
}
