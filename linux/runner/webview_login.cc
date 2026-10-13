#include "webview_login.h"

#include <gtk/gtk.h>
#include <libsoup/soup.h>
#include <webkit2/webkit2.h>

#include <cstring>
#include <string>

// Встроенный браузер для входа в аккаунт.
//
// Почему так: страницу входа Google нельзя пройти программно, а часть нужных
// cookie помечена HttpOnly — из JavaScript их не видно. Поэтому открывается
// настоящее окно WebKit, а cookie забираются у менеджера cookie браузера.
//
// Окно закрывается само, как только на music.youtube.com появляется SAPISID —
// то есть вход действительно выполнен. На случай, если этого не произошло,
// в шапке есть кнопка «Готово».

namespace {

constexpr char kChannelName[] = "mops/webview_login";
constexpr char kHomeUrl[] = "https://music.youtube.com/";

GtkWindow* g_window = nullptr;
WebKitWebView* g_view = nullptr;
FlMethodCall* g_pending_call = nullptr;

// Ответ на отложенный вызов: строка cookie или ошибка.
void respond_with_cookies(FlMethodCall* call, const std::string& cookies) {
  g_autoptr(FlValue) value = fl_value_new_string(cookies.c_str());
  fl_method_call_respond_success(call, value, nullptr);
}

void respond_with_error(FlMethodCall* call, const std::string& message) {
  g_autoptr(FlValue) value = fl_value_new_string(message.c_str());
  fl_method_call_respond_error(call, "webview_error", message.c_str(), value,
                               nullptr);
}

// Приводит окно и вызов в исходное состояние.
void reset_state() {
  if (g_pending_call != nullptr) {
    g_object_unref(g_pending_call);
    g_pending_call = nullptr;
  }
  if (g_window != nullptr) {
    gtk_widget_destroy(GTK_WIDGET(g_window));
    g_window = nullptr;
  }
  g_view = nullptr;
}

// Собирает строку cookie из списка WebKit.
//
// Оставляем только домены Google и YouTube: остальное приложению не нужно
// и не должно попадать в файл сессии.
std::string cookies_from_list(GList* cookies) {
  if (cookies == nullptr) {
    return std::string();
  }

  std::string result;
  for (GList* node = cookies; node != nullptr; node = node->next) {
    SoupCookie* cookie = static_cast<SoupCookie*>(node->data);
    const char* name = soup_cookie_get_name(cookie);
    const char* value = soup_cookie_get_value(cookie);
    const char* domain = soup_cookie_get_domain(cookie);
    if (name == nullptr || value == nullptr) {
      continue;
    }
    if (domain != nullptr && !g_str_has_suffix(domain, "youtube.com") &&
        !g_str_has_suffix(domain, "google.com") &&
        !g_str_has_suffix(domain, "googleusercontent.com")) {
      continue;
    }
    if (!result.empty()) {
      result += "; ";
    }
    result += name;
    result += "=";
    result += value;
  }

  g_list_free_full(cookies, reinterpret_cast<GDestroyNotify>(soup_cookie_free));
  return result;
}

bool has_sapisid(const std::string& cookies) {
  return cookies.find("SAPISID=") != std::string::npos ||
         cookies.find("__Secure-3PAPISID=") != std::string::npos;
}

// Ответ на отложенный вызов после получения cookie.
void on_cookies_for_finish(GObject* source, GAsyncResult* result,
                           gpointer /*data*/) {
  GError* error = nullptr;
  GList* cookies = webkit_cookie_manager_get_all_cookies_finish(
      WEBKIT_COOKIE_MANAGER(source), result, &error);
  const std::string cookie_string = cookies_from_list(cookies);
  if (error != nullptr) {
    g_error_free(error);
  }

  FlMethodCall* call = g_pending_call;
  g_pending_call = nullptr;
  if (call == nullptr) {
    reset_state();
    return;
  }

  if (cookie_string.empty()) {
    respond_with_error(call, "Не удалось получить cookie после входа.");
  } else {
    respond_with_cookies(call, cookie_string);
  }
  g_object_unref(call);
  reset_state();
}

// Забирает cookie и отвечает на отложенный вызов.
void finish_login() {
  if (g_pending_call == nullptr || g_view == nullptr) {
    reset_state();
    return;
  }
  WebKitCookieManager* manager =
      webkit_web_context_get_cookie_manager(webkit_web_view_get_context(g_view));
  webkit_cookie_manager_get_all_cookies(manager, nullptr,
                                        on_cookies_for_finish, nullptr);
}

void on_done_clicked(GtkButton* /*button*/, gpointer /*data*/) {
  finish_login();
}

// Закрытие окна крестиком: отвечаем ошибкой, чтобы Dart не ждал вечно.
void on_window_destroy(GtkWidget* /*widget*/, gpointer /*data*/) {
  FlMethodCall* call = g_pending_call;
  if (call != nullptr) {
    g_pending_call = nullptr;
    respond_with_error(call, "Вход отменён.");
    g_object_unref(call);
  }
  g_window = nullptr;
  g_view = nullptr;
}

// Проверка после загрузки: вход мог уже состояться.
void on_cookies_for_check(GObject* source, GAsyncResult* result,
                          gpointer /*data*/) {
  GError* error = nullptr;
  GList* cookies = webkit_cookie_manager_get_all_cookies_finish(
      WEBKIT_COOKIE_MANAGER(source), result, &error);
  const std::string cookie_string = cookies_from_list(cookies);
  if (error != nullptr) {
    g_error_free(error);
  }

  // Если вход уже выполнен, окно закрывается само.
  if (g_pending_call != nullptr && has_sapisid(cookie_string)) {
    on_done_clicked(nullptr, nullptr);
  }
}

// Когда страница загрузилась, проверяем, не выполнен ли уже вход.
void on_load_changed(WebKitWebView* view, WebKitLoadEvent event,
                     gpointer /*data*/) {
  if (event != WEBKIT_LOAD_FINISHED) {
    return;
  }
  const gchar* uri = webkit_web_view_get_uri(view);
  if (uri == nullptr || strstr(uri, "music.youtube.com") == nullptr) {
    return;
  }
  if (g_pending_call == nullptr) {
    return;
  }

  WebKitCookieManager* manager =
      webkit_web_context_get_cookie_manager(webkit_web_view_get_context(view));
  webkit_cookie_manager_get_all_cookies(manager, nullptr,
                                        on_cookies_for_check, nullptr);
}

void open_window(const std::string& url) {
  if (g_window != nullptr) {
    gtk_window_present(g_window);
    return;
  }

  g_window = GTK_WINDOW(gtk_window_new(GTK_WINDOW_TOPLEVEL));
  gtk_window_set_title(g_window, "Вход в YouTube Music");
  gtk_window_set_default_size(g_window, 1000, 760);
  gtk_window_set_transient_for(g_window, nullptr);

  GtkHeaderBar* header = GTK_HEADER_BAR(gtk_header_bar_new());
  gtk_header_bar_set_title(header, "Вход в YouTube Music");
  gtk_header_bar_set_subtitle(
      header, "Войдите в аккаунт Google — окно закроется само");
  gtk_header_bar_set_show_close_button(header, TRUE);

  GtkWidget* done_button = gtk_button_new_with_label("Готово");
  gtk_widget_set_tooltip_text(
      done_button, "Забрать cookie и закрыть окно");
  g_signal_connect(done_button, "clicked", G_CALLBACK(on_done_clicked), nullptr);
  gtk_header_bar_pack_end(header, done_button);
  gtk_window_set_titlebar(g_window, GTK_WIDGET(header));

  // Свой контекст с постоянным хранилищем cookie: так вход переживает
  // перезапуск окна.
  WebKitWebContext* context = webkit_web_context_new();
  WebKitCookieManager* manager = webkit_web_context_get_cookie_manager(context);
  webkit_cookie_manager_set_accept_policy(manager,
                                          WEBKIT_COOKIE_POLICY_ACCEPT_ALWAYS);

  g_view = WEBKIT_WEB_VIEW(webkit_web_view_new_with_context(context));
  g_object_unref(context);

  g_signal_connect(g_view, "load-changed", G_CALLBACK(on_load_changed),
                   nullptr);
  g_signal_connect(g_window, "destroy", G_CALLBACK(on_window_destroy), nullptr);

  gtk_container_add(GTK_CONTAINER(g_window), GTK_WIDGET(g_view));
  webkit_web_view_load_uri(g_view, url.c_str());

  gtk_widget_show_all(GTK_WIDGET(g_window));
  gtk_window_present(g_window);
}

void method_call_cb(FlMethodChannel* /*channel*/, FlMethodCall* method_call,
                    gpointer /*user_data*/) {
  const gchar* method = fl_method_call_get_name(method_call);

  if (g_strcmp0(method, "isAvailable") == 0) {
    g_autoptr(FlValue) value = fl_value_new_bool(TRUE);
    fl_method_call_respond_success(method_call, value, nullptr);
    return;
  }

  if (g_strcmp0(method, "openLogin") == 0) {
    if (g_pending_call != nullptr) {
      respond_with_error(method_call, "Окно входа уже открыто.");
      return;
    }

    std::string url = kHomeUrl;
    FlValue* args = fl_method_call_get_args(method_call);
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* url_value = fl_value_lookup_string(args, "url");
      if (url_value != nullptr &&
          fl_value_get_type(url_value) == FL_VALUE_TYPE_STRING) {
        url = fl_value_get_string(url_value);
      }
    }

    g_pending_call = FL_METHOD_CALL(g_object_ref(method_call));
    open_window(url);
    // Ответ отправим позже — когда вход завершится.
    return;
  }

  if (g_strcmp0(method, "close") == 0) {
    reset_state();
    g_autoptr(FlValue) value = fl_value_new_bool(TRUE);
    fl_method_call_respond_success(method_call, value, nullptr);
    return;
  }

  fl_method_call_respond_not_implemented(method_call, nullptr);
}

}  // namespace

void webview_login_register(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      messenger, kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr,
                                            nullptr);
}
