#include "webview_login.h"

#include <glib/gstdio.h>
#include <gtk/gtk.h>
#include <libsoup/soup.h>
#include <webkit2/webkit2.h>

#include <cstring>
#include <string>

// Встроенный браузер для входа в аккаунт.
//
// Почему так: страницу входа Google нельзя пройти программно, а часть нужных
// cookie помечена HttpOnly — из JavaScript их не видно. Поэтому открывается
// настоящий WebKit, а cookie забираются у менеджера cookie браузера.
//
// Панель показывается поверх интерфейса приложения, в том же окне: Flutter
// рисует в собственном нативном окне, поэтому панель кладётся в GtkEventBox —
// он тоже получает своё окно и оказывается выше.
//
// Панель создаётся один раз и при закрытии только прячется. Уничтожать её
// нельзя: WebKit в этот момент ещё выполняет колбэки страницы, и удаление
// вида приводит к падению внутри libwebkit2gtk (use-after-free). Вместо
// удаления страница освобождается загрузкой about:blank.
//
// Панель закрывается сама, как только появляется SAPISID — то есть вход
// действительно выполнен. На случай, если этого не произошло, в шапке есть
// кнопки «Готово» и «Отмена», а также работает Esc.

namespace {

constexpr char kChannelName[] = "mops/webview_login";

// Страница входа Google. После входа Google возвращает на music.youtube.com.
constexpr char kSignInUrl[] =
    "https://accounts.google.com/ServiceLogin?service=youtube"
    "&continue=https%3A%2F%2Fmusic.youtube.com%2F&hl=ru";

GtkOverlay* g_overlay = nullptr;
GtkWidget* g_flutter_view = nullptr;
WebKitWebContext* g_context = nullptr;
GtkWidget* g_panel = nullptr;
WebKitWebView* g_view = nullptr;
FlMethodCall* g_pending_call = nullptr;

// Идём на music.youtube.com, чтобы забрать cookie YouTube (LOGIN_INFO и прочие).
bool g_waiting_home = false;

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

// Прячет панель и освобождает страницу, не удаляя сам вид.
void hide_panel() {
  if (g_view != nullptr) {
    webkit_web_view_stop_loading(g_view);
    // about:blank отпускает память тяжёлой страницы, но не сам вид.
    webkit_web_view_load_uri(g_view, "about:blank");
  }
  if (g_panel != nullptr) {
    gtk_widget_hide(g_panel);
  }
  // Возвращаем фокус клавиатуры интерфейсу: панель его забирала, и без этого
  // приложение перестаёт принимать ввод.
  if (g_flutter_view != nullptr) {
    gtk_widget_grab_focus(g_flutter_view);
    g_message("[Login] фокус возвращён интерфейсу");
  }
}

// Приводит состояние к «панель закрыта».
void reset_state() {
  g_waiting_home = false;
  if (g_pending_call != nullptr) {
    g_object_unref(g_pending_call);
    g_pending_call = nullptr;
  }
  hide_panel();
}

// Собирает строку cookie из списка WebKit.
//
// Оставляем только cookie домена YouTube. Это важно: браузер шлёт на
// music.youtube.com именно их, а cookie домена google.com туда не попадают.
// Если смешать оба набора, имена (SID, SAPISID, __Secure-3PAPISID) окажутся
// в строке дважды, YouTube возьмёт значение не от того домена и ответит как
// гостю — вход и библиотека перестанут работать.
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
    if (domain == nullptr || !g_str_has_suffix(domain, "youtube.com")) {
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

// Находимся ли мы именно на music.youtube.com.
//
// Проверять подстроку нельзя: в адресе страницы входа Google есть параметр
// continue=https%3A%2F%2Fmusic.youtube.com%2F, и подстрока совпадёт там же.
bool is_music_youtube_page(const gchar* uri) {
  if (uri == nullptr) {
    return false;
  }
  g_autoptr(GUri) parsed = g_uri_parse(uri, G_URI_FLAGS_NONE, nullptr);
  if (parsed == nullptr) {
    return false;
  }
  const gchar* host = g_uri_get_host(parsed);
  return host != nullptr && g_strcmp0(host, "music.youtube.com") == 0;
}

bool has_sapisid(const std::string& cookies) {
  return cookies.find("SAPISID=") != std::string::npos ||
         cookies.find("__Secure-3PAPISID=") != std::string::npos;
}

// Cookie именно домена YouTube. Без них YouTube считает нас гостем, даже
// если вход в Google выполнен.
bool has_youtube_cookies(const std::string& cookies) {
  return cookies.find("LOGIN_INFO=") != std::string::npos ||
         cookies.find("VISITOR_INFO1_LIVE=") != std::string::npos;
}

// Ответ на запрос уже сохранённого входа.
void on_cookies_for_stored(GObject* source, GAsyncResult* result,
                           gpointer data) {
  GError* error = nullptr;
  GList* cookies = webkit_cookie_manager_get_all_cookies_finish(
      WEBKIT_COOKIE_MANAGER(source), result, &error);
  const std::string cookie_string = cookies_from_list(cookies);
  if (error != nullptr) {
    g_error_free(error);
  }

  FlMethodCall* call = FL_METHOD_CALL(data);
  if (has_sapisid(cookie_string) && has_youtube_cookies(cookie_string)) {
    g_message("[Login] сохранённый вход найден: %zu символов",
              cookie_string.size());
    respond_with_cookies(call, cookie_string);
  } else {
    g_message("[Login] сохранённого входа нет");
    g_autoptr(FlValue) value = fl_value_new_string("");
    fl_method_call_respond_success(call, value, nullptr);
  }
  g_object_unref(call);
}

// Диагностика: показывает, помнит ли браузер предыдущий вход.
void on_cookies_for_diagnostic(GObject* source, GAsyncResult* result,
                               gpointer /*data*/) {
  GError* error = nullptr;
  GList* cookies = webkit_cookie_manager_get_all_cookies_finish(
      WEBKIT_COOKIE_MANAGER(source), result, &error);
  const std::string cookie_string = cookies_from_list(cookies);
  if (error != nullptr) {
    g_error_free(error);
  }
  g_message("[Login] cookie браузера до входа: %zu символов, "
            "сохранённый вход: %s",
            cookie_string.size(), has_sapisid(cookie_string) ? "да" : "нет");
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
    hide_panel();
    return;
  }

  // Без SAPISID вход не состоялся: остальные cookie приложению бесполезны.
  if (!has_sapisid(cookie_string)) {
    g_message("[Login] SAPISID не найден — вход не выполнен");
    respond_with_error(
        call,
        "Вход не выполнен: данных аккаунта в cookie нет. Войдите в аккаунт "
        "Google и нажмите «Готово» ещё раз.");
  } else {
    g_message("[Login] cookie получены, вход завершён");
    respond_with_cookies(call, cookie_string);
  }
  g_object_unref(call);
  hide_panel();
}

// Забирает cookie и отвечает на отложенный вызов.
void harvest_cookies() {
  if (g_pending_call == nullptr || g_view == nullptr) {
    reset_state();
    return;
  }
  WebKitCookieManager* manager =
      webkit_web_context_get_cookie_manager(webkit_web_view_get_context(g_view));
  webkit_cookie_manager_get_all_cookies(manager, nullptr,
                                        on_cookies_for_finish, nullptr);
}

// Завершает вход.
//
// Cookie YouTube (LOGIN_INFO и прочие) выдаются только на самом youtube.com,
// а вход идёт на accounts.google.com. Поэтому если мы ещё не на YouTube Music,
// сначала заходим туда, и забираем cookie уже после загрузки — иначе в сессию
// попадут только cookie google.com, и YouTube будет считать нас гостем.
void request_finish() {
  if (g_pending_call == nullptr || g_view == nullptr) {
    reset_state();
    return;
  }
  if (g_waiting_home) {
    return;  // уже идём за cookie
  }

  if (!is_music_youtube_page(webkit_web_view_get_uri(g_view))) {
    g_message("[Login] иду на music.youtube.com за cookie YouTube");
    g_waiting_home = true;
    webkit_web_view_load_uri(g_view, "https://music.youtube.com/");
    return;
  }

  harvest_cookies();
}

// Закрывает панель, сообщая об отмене входа.
void cancel_login() {
  FlMethodCall* call = g_pending_call;
  g_pending_call = nullptr;
  if (call != nullptr) {
    respond_with_error(call, "Вход отменён.");
    g_object_unref(call);
  }
  reset_state();
}

void on_done_clicked(GtkButton* /*button*/, gpointer /*data*/) {
  request_finish();
}

void on_cancel_clicked(GtkButton* /*button*/, gpointer /*data*/) {
  cancel_login();
}

// Страховка: если панель всё же удалили, вызов не должен «зависнуть».
void on_panel_destroy(GtkWidget* /*widget*/, gpointer /*data*/) {
  g_panel = nullptr;
  g_view = nullptr;
  if (g_pending_call != nullptr) {
    FlMethodCall* call = g_pending_call;
    g_pending_call = nullptr;
    respond_with_error(call, "Панель входа закрыта.");
    g_object_unref(call);
  }
}

// Esc закрывает панель.
gboolean on_key_press(GtkWidget* /*widget*/, GdkEventKey* event,
                      gpointer /*data*/) {
  if (event->keyval == GDK_KEY_Escape) {
    cancel_login();
    return TRUE;
  }
  return FALSE;
}

// Небольшая пауза перед сбором cookie.
gboolean on_harvest_timeout(gpointer /*data*/) {
  harvest_cookies();
  return G_SOURCE_REMOVE;
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

  // Панель закрывается сама, только когда есть и вход Google, и cookie
  // YouTube: иначе в сессию попадут cookie google.com, и YouTube будет
  // считать нас гостем.
  if (g_pending_call != nullptr && has_sapisid(cookie_string) &&
      has_youtube_cookies(cookie_string)) {
    g_message("[Login] вход подтверждён, забираю cookie");
    request_finish();
  }
}

// Загрузка закончилась. Проверяем вход только на самом music.youtube.com:
// cookie YouTube выдаются лишь там, а на страницах Google их ещё нет.
void on_load_changed(WebKitWebView* view, WebKitLoadEvent event,
                     gpointer /*data*/) {
  if (event != WEBKIT_LOAD_FINISHED || g_pending_call == nullptr) {
    return;
  }
  if (!is_music_youtube_page(webkit_web_view_get_uri(view))) {
    return;
  }

  // Мы пришли сюда специально за cookie. Небольшая пауза — чтобы страница
  // успела догрузить свои данные и выставить все нужные cookie.
  if (g_waiting_home) {
    g_waiting_home = false;
    g_timeout_add(1200, on_harvest_timeout, nullptr);
    return;
  }

  WebKitCookieManager* manager =
      webkit_web_context_get_cookie_manager(webkit_web_view_get_context(view));
  webkit_cookie_manager_get_all_cookies(manager, nullptr,
                                        on_cookies_for_check, nullptr);
}

// Создаёт контекст браузера с постоянным хранилищем cookie.
//
// Контекст один на всё приложение: так и панель, и чтение уже сохранённого
// входа работают с одними и теми же cookie.
WebKitWebContext* ensure_context() {
  if (g_context != nullptr) {
    return g_context;
  }

  g_autofree gchar* data_dir = g_build_filename(
      g_get_user_data_dir(), "com.mops.mops", "webkit", nullptr);
  g_autofree gchar* cache_dir = g_build_filename(
      g_get_user_cache_dir(), "com.mops.mops", "webkit", nullptr);
  g_mkdir_with_parents(data_dir, 0700);
  g_mkdir_with_parents(cache_dir, 0700);

  WebKitWebsiteDataManager* data_manager = webkit_website_data_manager_new(
      "base-data-directory", data_dir, "base-cache-directory", cache_dir,
      nullptr);
  g_context = webkit_web_context_new_with_website_data_manager(data_manager);
  g_object_unref(data_manager);

  WebKitCookieManager* manager = webkit_web_context_get_cookie_manager(g_context);
  webkit_cookie_manager_set_accept_policy(manager,
                                          WEBKIT_COOKIE_POLICY_ACCEPT_ALWAYS);

  // Явно указываем файл cookie: без этого WebKit держит их только в памяти,
  // и вход не переживает перезапуск.
  g_autofree gchar* cookie_file =
      g_build_filename(data_dir, "cookies.sqlite", nullptr);
  webkit_cookie_manager_set_persistent_storage(
      manager, cookie_file, WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);

  g_message("[Login] хранилище браузера: %s", data_dir);
  return g_context;
}

// Создаёт панель один раз. Возвращает false, если окно ещё не готово.
bool ensure_panel() {
  if (g_panel != nullptr) {
    return true;
  }
  if (g_overlay == nullptr) {
    return false;
  }

  // GtkEventBox даёт панели собственное окно: Flutter рисует в отдельном
  // нативном окне, и без этого панель оказалась бы под ним.
  GtkWidget* panel = gtk_event_box_new();
  g_panel = panel;

  GtkWidget* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  gtk_container_add(GTK_CONTAINER(panel), box);

  GtkHeaderBar* header = GTK_HEADER_BAR(gtk_header_bar_new());
  gtk_header_bar_set_title(header, "Вход в YouTube Music");
  gtk_header_bar_set_subtitle(
      header, "Войдите в аккаунт — панель закроется сама");
  gtk_header_bar_set_show_close_button(header, FALSE);

  GtkWidget* done_button = gtk_button_new_with_label("Готово");
  gtk_widget_set_tooltip_text(done_button, "Забрать cookie и закрыть панель");
  g_signal_connect(done_button, "clicked", G_CALLBACK(on_done_clicked),
                   nullptr);
  gtk_header_bar_pack_end(header, done_button);

  GtkWidget* cancel_button = gtk_button_new_with_label("Отмена");
  g_signal_connect(cancel_button, "clicked", G_CALLBACK(on_cancel_clicked),
                   nullptr);
  gtk_header_bar_pack_start(header, cancel_button);
  gtk_box_pack_start(GTK_BOX(box), GTK_WIDGET(header), FALSE, FALSE, 0);

  WebKitWebContext* context = ensure_context();
  WebKitCookieManager* manager = webkit_web_context_get_cookie_manager(context);

  g_view = WEBKIT_WEB_VIEW(webkit_web_view_new_with_context(context));
  webkit_cookie_manager_get_all_cookies(manager, nullptr,
                                        on_cookies_for_diagnostic, nullptr);
  gtk_box_pack_start(GTK_BOX(box), GTK_WIDGET(g_view), TRUE, TRUE, 0);

  g_signal_connect(g_view, "load-changed", G_CALLBACK(on_load_changed),
                   nullptr);
  g_signal_connect(panel, "destroy", G_CALLBACK(on_panel_destroy), nullptr);
  g_signal_connect(panel, "key-press-event", G_CALLBACK(on_key_press), nullptr);
  gtk_widget_add_events(panel, GDK_KEY_PRESS_MASK);

  // Панель занимает всю площадь окна и перекрывает интерфейс приложения.
  gtk_widget_set_hexpand(panel, TRUE);
  gtk_widget_set_vexpand(panel, TRUE);
  gtk_widget_set_halign(panel, GTK_ALIGN_FILL);
  gtk_widget_set_valign(panel, GTK_ALIGN_FILL);

  gtk_overlay_add_overlay(g_overlay, panel);
  // Показываем, чтобы виджеты получили окна, и сразу прячем.
  gtk_widget_show_all(panel);
  gtk_widget_hide(panel);
  return true;
}

void open_panel(const std::string& url) {
  if (!ensure_panel()) {
    return;
  }

  gtk_widget_show_all(g_panel);
  webkit_web_view_load_uri(g_view, url.c_str());
  gtk_widget_grab_focus(GTK_WIDGET(g_view));
  g_message("[Login] панель входа открыта: %s", url.c_str());

  // Нативное окно панели должно оказаться поверх окна Flutter.
  GdkWindow* panel_window = gtk_widget_get_window(g_panel);
  if (panel_window != nullptr) {
    gdk_window_raise(panel_window);
  }
}

void method_call_cb(FlMethodChannel* /*channel*/, FlMethodCall* method_call,
                    gpointer /*user_data*/) {
  const gchar* method = fl_method_call_get_name(method_call);

  if (g_strcmp0(method, "isAvailable") == 0) {
    g_autoptr(FlValue) value = fl_value_new_bool(g_overlay != nullptr);
    fl_method_call_respond_success(method_call, value, nullptr);
    return;
  }

  if (g_strcmp0(method, "openLogin") == 0) {
    if (g_pending_call != nullptr) {
      respond_with_error(method_call, "Панель входа уже открыта.");
      return;
    }

    std::string url = kSignInUrl;
    FlValue* args = fl_method_call_get_args(method_call);
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* url_value = fl_value_lookup_string(args, "url");
      if (url_value != nullptr &&
          fl_value_get_type(url_value) == FL_VALUE_TYPE_STRING) {
        const gchar* requested = fl_value_get_string(url_value);
        if (requested != nullptr && requested[0] != '\0') {
          url = requested;
        }
      }
    }

    if (g_overlay == nullptr) {
      respond_with_error(method_call,
                         "Окно приложения не готово к показу входа.");
      return;
    }

    g_pending_call = FL_METHOD_CALL(g_object_ref(method_call));
    open_panel(url);
    // Ответ отправим позже — когда вход завершится.
    return;
  }

  if (g_strcmp0(method, "storedCookies") == 0) {
    // Отдаём уже сохранённый вход, не открывая панель: приложение может
    // подхватить его само после перезапуска.
    WebKitCookieManager* manager =
        webkit_web_context_get_cookie_manager(ensure_context());
    // Ссылку держим до конца асинхронного ответа: иначе вызов освободится
    // сразу после возврата из обработчика, и колбэк обратится к мусору.
    FlMethodCall* pending = FL_METHOD_CALL(g_object_ref(method_call));
    webkit_cookie_manager_get_all_cookies(manager, nullptr,
                                          on_cookies_for_stored, pending);
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

void webview_login_set_host(GtkOverlay* overlay, GtkWidget* flutter_view) {
  g_overlay = overlay;
  g_flutter_view = flutter_view;
}

void webview_login_register(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      messenger, kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr,
                                            nullptr);
}
