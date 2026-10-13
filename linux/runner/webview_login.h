#ifndef RUNNER_WEBVIEW_LOGIN_H_
#define RUNNER_WEBVIEW_LOGIN_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Регистрирует канал "mops/webview_login".
//
// Канал открывает встроенный браузер (WebKitGTK), даёт войти в аккаунт Google
// и возвращает строку cookie. Это нужно потому, что вход в YouTube Music
// требует настоящей страницы входа Google, а часть нужных cookie помечена
// HttpOnly и недоступна из JavaScript.
void webview_login_register(FlBinaryMessenger* messenger);

// Задаёт контейнер, поверх которого показывается панель входа.
//
// Браузер открывается не в отдельном окне, а внутри окна приложения: панель
// добавляется в переданный GtkOverlay и занимает всю его площадь.
void webview_login_set_host(GtkOverlay* overlay);

#endif  // RUNNER_WEBVIEW_LOGIN_H_
