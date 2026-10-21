#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

/// Цвет рамки окна в DWM. `DWMWA_COLOR_NONE` — «не рисовать рамку вовсе»:
/// окно своё, шапку рисует Flutter, и светлая кромка по краю выглядела бы
/// остатком нативной рамки.
#ifndef DWMWA_BORDER_COLOR
#define DWMWA_BORDER_COLOR 34
#endif
#ifndef DWMWA_COLOR_NONE
#define DWMWA_COLOR_NONE 0xFFFFFFFE
#endif

/// Скругление углов окна (Windows 11). Без него безрамочное окно рисуется
/// прямоугольником, хотя у системных оно скруглено.
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWCP_ROUND
#define DWMWCP_ROUND 2
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// DPI окна. Берём динамически, чтобы не зависеть от версии Windows SDK.
UINT GetWindowDpi(HWND hwnd) {
  HMODULE user32_module = GetModuleHandleA("User32.dll");
  if (user32_module != nullptr) {
    auto get_dpi_for_window = reinterpret_cast<UINT(WINAPI*)(HWND)>(
        GetProcAddress(user32_module, "GetDpiForWindow"));
    if (get_dpi_for_window != nullptr) {
      return get_dpi_for_window(hwnd);
    }
  }
  return 96;
}

// Зона изменения размера по экранной точке курсора: 0, если точка не у края.
//
// Нужна и родительскому окну, и дочернему: содержимое Flutter занимает всю
// клиентскую область, поэтому курсор всегда оказывается над дочерним окном, и
// систему о краях спрашивает именно оно (см. ChildContentWndProc).
LRESULT HitTestResizeBorder(HWND hwnd, LPARAM lparam) {
  if (hwnd == nullptr || IsZoomed(hwnd)) return 0;

  const int border = static_cast<int>(6 * GetWindowDpi(hwnd) / 96.0);
  const int x = static_cast<short>(LOWORD(lparam));
  const int y = static_cast<short>(HIWORD(lparam));

  RECT rect;
  if (!GetWindowRect(hwnd, &rect)) return 0;

  const bool left = x < rect.left + border;
  const bool right = x >= rect.right - border;
  const bool top = y < rect.top + border;
  const bool bottom = y >= rect.bottom - border;

  if (top && left) return HTTOPLEFT;
  if (top && right) return HTTOPRIGHT;
  if (bottom && left) return HTBOTTOMLEFT;
  if (bottom && right) return HTBOTTOMRIGHT;
  if (left) return HTLEFT;
  if (right) return HTRIGHT;
  if (top) return HTTOP;
  if (bottom) return HTBOTTOM;
  return 0;
}

// Исходная процедура дочернего окна содержимого — её надо вызывать для всех
// сообщений, которые мы не перехватываем.
WNDPROC g_child_content_proc = nullptr;

// Процедура дочернего окна содержимого (окно Flutter).
//
// Перехватываем только определение попадания: содержимое закрывает всю
// клиентскую область, и без этого система считала бы край окна обычной
// клиентской зоной — окно нельзя было бы растянуть, а курсор у кромки
// оставался бы стрелкой.
LRESULT CALLBACK ChildContentWndProc(HWND child,
                                     UINT message,
                                     WPARAM wparam,
                                     LPARAM lparam) {
  HWND parent = GetAncestor(child, GA_PARENT);

  if (message == WM_NCHITTEST) {
    if (HitTestResizeBorder(parent, lparam) != 0) {
      // Точка у кромки окна: пропускаем определение попадания к родителю.
      // Возвращать зону растягивания самому нельзя — тогда система считает
      // кромкой содержимое, и при перетаскивании окно и содержимое расходятся:
      // тянется содержимое, а окно стоит.
      return HTTRANSPARENT;
    }
  }

  // Родитель может следить за мышью для перетаскивания своей шапки. Захват
  // мыши при этом остаётся у содержимого: иначе Flutter не получил бы
  // отпускание кнопки и его состояние указателя залипло бы.
  if (parent != nullptr) {
    auto* owner = reinterpret_cast<Win32Window*>(
        GetWindowLongPtr(parent, GWLP_USERDATA));
    if (owner != nullptr) {
      owner->HandleChildContentMessage(child, message, wparam, lparam);
    }
  }

  if (g_child_content_proc != nullptr) {
    return CallWindowProc(g_child_content_proc, child, message, wparam, lparam);
  }
  return DefWindowProc(child, message, wparam, lparam);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  // Своя шапка, как в Telegram: убираем системный заголовок (WS_CAPTION), но
  // оставляем рамку изменения размера и кнопки «свернуть/развернуть». Панель
  // рисует Flutter (`WindowTitleBar`), перетаскивание — каналом `startDrag`.
  const DWORD style = WS_OVERLAPPEDWINDOW & ~WS_CAPTION;
  HWND window = CreateWindow(
      window_class, title.c_str(), style,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  // Страховка: даже если окно почему-то создалось с системным заголовком,
  // снимаем WS_CAPTION перед показом и просим пересчитать рамку. Иначе
  // получается два заголовка — нативный и наша панель во Flutter.
  LONG_PTR style = GetWindowLongPtr(window_handle_, GWL_STYLE);
  if ((style & WS_CAPTION) != 0) {
    SetWindowLongPtr(window_handle_, GWL_STYLE, style & ~WS_CAPTION);
    SetWindowPos(window_handle_, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
  }
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_GETMINMAXINFO: {
      // Минимальный размер окна: на меньшем раскладка ломается — островки,
      // боковая библиотека и панель плеера перестают помещаться. Значение
      // масштабируем по DPI, иначе на HiDPI минимум окажется крошечным.
      const double scale = static_cast<double>(GetWindowDpi(hwnd)) / 96.0;
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = static_cast<LONG>(kMinWindowWidth * scale);
      info->ptMinTrackSize.y = static_cast<LONG>(kMinWindowHeight * scale);

      // Без WS_CAPTION Windows разворачивает окно на ВЕСЬ монитор и накрывает
      // панель задач. Ограничиваем разворот рабочей областью: панель задач
      // остаётся видна, ничего не уезжает за края.
      MONITORINFO monitor_info = {};
      monitor_info.cbSize = sizeof(MONITORINFO);
      if (GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                         &monitor_info)) {
        const RECT work = monitor_info.rcWork;
        const RECT full = monitor_info.rcMonitor;
        info->ptMaxPosition.x = work.left - full.left;
        info->ptMaxPosition.y = work.top - full.top;
        info->ptMaxSize.x = work.right - work.left;
        info->ptMaxSize.y = work.bottom - work.top;
      }
      return 0;
    }

    case WM_NCCALCSIZE: {
      // Своя шапка: клиентская область занимает окно целиком, нативной рамки
      // заголовка нет. Без этого при развороте содержимое уезжало бы за края
      // на ширину рамки, а сверху оставалась бы нативная полоса.
      if (wparam == TRUE) {
        return 0;
      }
      break;
    }

    case WM_NCHITTEST: {
      // Своя рамка: `WM_NCCALCSIZE` убрал неклиентскую область, поэтому зоны
      // изменения размера считаем сами.
      const LRESULT hit = HitTestResizeBorder(hwnd, lparam);
      if (hit != 0) return hit;
      break;
    }

    case WM_NCACTIVATE:
      // Система при смене активности перерисовывает рамку несуществующего
      // заголовка — по краю окна мелькала белая полоса. Рисовать нечего:
      // всю шапку рисует Flutter.
      return TRUE;

    case WM_NCPAINT:
      // Рамку тоже рисует Flutter.
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  // Именно hwnd: после WM_DESTROY window_handle_ уже нулевой, а WM_NCDESTROY
  // ещё приходит — с nullptr вместо дескриптора система не доводит разрушение.
  return DefWindowProc(hwnd, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);

  // Содержимое Flutter занимает всю клиентскую область, поэтому край окна
  // обязан распознавать именно оно — иначе окно не растягивается.
  g_child_content_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtr(
      content, GWLP_WNDPROC,
      reinterpret_cast<LONG_PTR>(ChildContentWndProc)));

  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

void Win32Window::HandleChildContentMessage(HWND child, UINT message,
                                            WPARAM wparam, LPARAM lparam) {
  OnChildContentMessage(child, message, wparam, lparam);
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }

  // Бордюр не рисуем: у своего окна он лишний и выглядит как остаток нативной
  // рамки. Тень и скругление углов при этом сохраняются.
  COLORREF no_border = DWMWA_COLOR_NONE;
  DwmSetWindowAttribute(window, DWMWA_BORDER_COLOR, &no_border,
                        sizeof(no_border));

  // Скругление углов окна — как у системных окон Windows 11.
  int corner_preference = DWMWCP_ROUND;
  DwmSetWindowAttribute(window, DWMWA_WINDOW_CORNER_PREFERENCE,
                        &corner_preference, sizeof(corner_preference));
}
