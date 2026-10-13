#ifndef RUNNER_WEBVIEW_LOGIN_H_
#define RUNNER_WEBVIEW_LOGIN_H_

#include <flutter_linux/flutter_linux.h>

// Регистрирует канал "mops/webview_login".
//
// Канал открывает окно со встроенным браузером (WebKitGTK), даёт войти в
// аккаунт Google и возвращает строку cookie. Это нужно потому, что вход в
// YouTube Music требует настоящей страницы входа Google, а часть нужных
// cookie помечена HttpOnly и недоступна из JavaScript.
void webview_login_register(FlBinaryMessenger* messenger);

#endif  // RUNNER_WEBVIEW_LOGIN_H_
