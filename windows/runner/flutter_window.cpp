#include "flutter_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include <windowsx.h>

#include <algorithm>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

/// Дубль одного и того же нажатия считается таковым только в этом окне:
/// Windows присылает его двумя путями почти одновременно.
constexpr ULONGLONG kMediaCommandDuplicateMs = 200;

/// Транспортные клавиши, которые нас касаются. Громкость, поиск, почта и прочее
/// остаются системе: их обрабатывает DefWindowProc.
std::optional<MediaCommand> MediaCommandFromAppCommand(int command) {
  switch (command) {
    case APPCOMMAND_MEDIA_PLAY_PAUSE:
      return MediaCommand::kPlayPause;
    case APPCOMMAND_MEDIA_PLAY:
      return MediaCommand::kPlay;
    case APPCOMMAND_MEDIA_PAUSE:
      return MediaCommand::kPause;
    case APPCOMMAND_MEDIA_STOP:
      return MediaCommand::kStop;
    case APPCOMMAND_MEDIA_NEXTTRACK:
      return MediaCommand::kNext;
    case APPCOMMAND_MEDIA_PREVIOUSTRACK:
      return MediaCommand::kPrevious;
    default:
      return std::nullopt;
  }
}

/// Одно нажатие приходит двумя путями и может быть названо по-разному:
/// WM_APPCOMMAND присылает клавишу play/pause как «play/pause», а SMTC —
/// «play» или «pause» по текущему состоянию плеера. Поэтому неоднозначное
/// «play/pause» считается тем же действием, что и конкретные play/pause.
///
/// А вот два конкретных действия — разные команды пользователя: быстрая пара
/// Play→Pause (например, с медиаклавиатуры или из другого приложения) не
/// должна схлопываться в одну.
bool SameMediaAction(MediaCommand first, MediaCommand second) {
  if (first == second) return true;

  const auto is_ambiguous = [](MediaCommand command) {
    return command == MediaCommand::kPlayPause;
  };
  if (!is_ambiguous(first) && !is_ambiguous(second)) return false;

  // Группа только из транспорта: «play/pause» не должен глушить next/stop.
  const auto is_transport = [](MediaCommand command) {
    return command == MediaCommand::kPlayPause ||
           command == MediaCommand::kPlay || command == MediaCommand::kPause;
  };
  return is_transport(first) && is_transport(second);
}

}  // namespace


// Атрибуты DWM для окраски нативного заголовка (Windows 11).
#ifndef DWMWA_BORDER_COLOR
#define DWMWA_BORDER_COLOR 34
#endif
#ifndef DWMWA_CAPTION_COLOR
#define DWMWA_CAPTION_COLOR 35
#endif
#ifndef DWMWA_TEXT_COLOR
#define DWMWA_TEXT_COLOR 36
#endif

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Своя шапка: Flutter управляет окном через этот канал.
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "mops/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HWND hwnd = GetHandle();
        if (hwnd == nullptr) {
          result->Error("no_window", "Window handle is not available");
          return;
        }
        const std::string& method = call.method_name();
        if (method == "minimize") {
          ShowWindow(hwnd, SW_MINIMIZE);
          result->Success();
        } else if (method == "toggleMaximize") {
          // Двойной клик по шапке сначала начинает перетаскивание: снимаем
          // его, иначе первое движение потащило бы уже развёрнутое окно.
          EndDrag();
          ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
          result->Success();
        } else if (method == "close") {
          PostMessage(hwnd, WM_CLOSE, 0, 0);
          result->Success();
        } else if (method == "isMaximized") {
          result->Success(flutter::EncodableValue(IsZoomed(hwnd) != 0));
        } else if (method == "snap") {
          const std::string* side = std::get_if<std::string>(call.arguments());
          if (side == nullptr) {
            result->Error("bad_arguments",
                          "snap expects \"left\", \"right\" or \"max\"");
            return;
          }
          SnapWindow(*side);
          result->Success();
        } else if (method == "startDrag") {
          BeginDrag();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  // Медиаклавиши и системный оверлей. Канал отдельный: это не управление
  // окном, и событий у него больше.
  media_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "mops/media",
          &flutter::StandardMethodCodec::GetInstance());
  media_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "clear") {
          media_session_.Clear();
          result->Success();
          return;
        }
        if (method != "nowPlaying") {
          result->NotImplemented();
          return;
        }

        const flutter::EncodableMap* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("bad_arguments", "nowPlaying expects a map");
          return;
        }
        const auto text = [arguments](const char* key) {
          const auto found = arguments->find(flutter::EncodableValue(key));
          if (found == arguments->end()) return std::string();
          const std::string* value = std::get_if<std::string>(&found->second);
          return value == nullptr ? std::string() : *value;
        };
        const auto flag = [arguments](const char* key) {
          const auto found = arguments->find(flutter::EncodableValue(key));
          if (found == arguments->end()) return false;
          const bool* value = std::get_if<bool>(&found->second);
          return value != nullptr && *value;
        };
        media_session_.SetNowPlaying(text("title"), text("artist"),
                                     text("album"), flag("playing"));
        result->Success();
      });

  // Оверлей привязывается к окну: без него клавиши работают только в фокусе.
  media_session_.Attach(GetHandle());

  // Create() сначала зовёт Destroy() (и OnDestroy), поэтому флаг живости
  // взводим здесь: до этого окна ещё не было.
  alive_->store(true, std::memory_order_release);
  auto alive = alive_;
  flutter_controller_->engine()->SetNextFrameCallback([this, alive]() {
    // Окно могло закрыться до первого кадра: тогда this уже недействителен.
    if (!alive->load(std::memory_order_acquire)) return;
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

bool FlutterWindow::HandleMediaCommand(MediaCommand command) {
  if (!media_channel_) return false;

  // Дубль одного нажатия, пришедший другим путём: действия не повторяем.
  const ULONGLONG now = GetTickCount64();
  if (last_media_command_.has_value() &&
      SameMediaAction(*last_media_command_, command) &&
      now - last_media_command_tick_ < kMediaCommandDuplicateMs) {
    // Дубль уточняет неоднозначное «play/pause» до конкретного действия:
    // иначе следующая настоящая команда в том же окне тоже считалась бы
    // дублем неоднозначного события.
    if (*last_media_command_ != command) {
      last_media_command_ = command;
    }
    return true;
  }
  last_media_command_ = command;
  last_media_command_tick_ = now;

  media_channel_->InvokeMethod(
      "mediaKey", std::make_unique<flutter::EncodableValue>(
                      std::string(MediaCommandName(command))));
  return true;
}

void FlutterWindow::SnapWindow(const std::string& side) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) return;

  // «Весь экран» — это обычный разворот: его границы уже ограничены рабочей
  // областью в WM_GETMINMAXINFO (см. win32_window.cpp), поэтому панель задач
  // остаётся видна.
  if (side == "max") {
    ShowWindow(hwnd, SW_MAXIMIZE);
    return;
  }

  const bool left = side == "left";
  const bool right = side == "right";
  if (!left && !right) return;

  // Раскладка отменяет начатое перетаскивание, иначе следующее движение
  // мыши вернуло бы окно к прежнему прямоугольнику.
  EndDrag();

  // У развёрнутого окна SetWindowPos меняет только размер восстановления:
  // сначала возвращаем окно в обычное состояние.
  if (IsZoomed(hwnd) || IsIconic(hwnd)) {
    ShowWindow(hwnd, SW_RESTORE);
  }

  // Рабочая область монитора — без панели задач. Координаты здесь физические:
  // процесс объявлен PerMonitorV2 (runner.exe.manifest), поэтому rcWork и
  // SetWindowPos живут в одних и тех же пикселях и масштаб DPI применять не
  // нужно — умножение на него уехало бы мимо края экрана.
  HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info = {};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfo(monitor, &info)) {
    return;
  }

  const RECT work = info.rcWork;
  const int work_width = work.right - work.left;
  const int work_height = work.bottom - work.top;

  // Минимум окна задан в WM_GETMINMAXINFO в физических пикселях этого же
  // монитора. На HiDPI половина рабочей области может оказаться уже минимума:
  // тогда окно шире половины, и его надо прижать к нужному краю, иначе оно
  // вылезет за противоположный край экрана. Если минимум не влезает и целиком,
  // остаётся рабочая область — лучше окно во весь экран, чем за края.
  const double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  const int min_width = static_cast<int>(kMinWindowWidth * scale);
  const int width =
      std::min(work_width, std::max(work_width / 2, min_width));
  const int x = left ? work.left : work.right - width;

  SetWindowPos(hwnd, nullptr, x, work.top, width, work_height,
               SWP_NOZORDER | SWP_NOACTIVATE);
}

void FlutterWindow::NotifyMaximizedChanged() {
  HWND hwnd = GetHandle();
  // Ранние WM_SIZE приходят до создания канала — их пропускаем: начальное
  // состояние Dart всё равно спрашивает сам. После OnDestroy канал и
  // контроллер уже уничтожены, а WM_SIZE может прийти ещё раз.
  if (hwnd == nullptr || !window_channel_ || !flutter_controller_) {
    return;
  }

  const bool maximized = IsZoomed(hwnd) != 0;
  if (reported_maximized_.has_value() && *reported_maximized_ == maximized) {
    return;
  }
  reported_maximized_ = maximized;

  window_channel_->InvokeMethod(
      "maximizedChanged",
      std::make_unique<flutter::EncodableValue>(maximized));
}

void FlutterWindow::BeginDrag() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) return;

  // Команда приходит через канал уже после нажатия. Если нажатие не записано
  // или успело устареть, тянуть нечего: отпускание могло пройти раньше.
  if (!press_recorded_ || GetTickCount64() - press_tick_ > 1000) return;

  if (dragging_) {
    EndDrag();
  }

  drag_cursor_start_ = press_cursor_;
  drag_window_start_ = press_window_;
  press_recorded_ = false;

  // Развёрнутое окно восстанавливаем на первом движении, а не здесь: одиночный
  // клик по шапке не должен менять состояние окна. SetWindowPos у развёрнутого
  // окна иначе менял бы только размер восстановления.
  drag_restore_pending_ = IsZoomed(hwnd) != 0;
  dragging_ = true;

  // Захват мыши не перехватываем: он уже у окна содержимого, и сообщения о
  // движении и отпускании приходят к нам через процедуру дочернего окна.
  // Поток при этом свободен — канал и ответы Flutter идут как обычно.
}

void FlutterWindow::EndDrag() {
  dragging_ = false;
  drag_restore_pending_ = false;
  drag_pointer_id_ = 0;
}

void FlutterWindow::UpdateDrag(POINT cursor) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    EndDrag();
    return;
  }

  if (drag_restore_pending_) {
    RestoreFromMaximizedForDrag(hwnd, cursor);
  }

  // Считаем в физических пикселях: при переезде на монитор с другим DPI
  // размер окна меняет WM_DPICHANGED, а смещение курсора остаётся честным.
  const int dx = cursor.x - drag_cursor_start_.x;
  const int dy = cursor.y - drag_cursor_start_.y;
  if (dx == 0 && dy == 0) return;

  SetWindowPos(hwnd, nullptr, drag_window_start_.left + dx,
               drag_window_start_.top + dy, 0, 0,
               SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

void FlutterWindow::OnChildContentMessage(HWND child, UINT message,
                                          WPARAM wparam, LPARAM lparam) {
  // Нажатие запоминаем всегда: команда startDrag придёт позже, через канал, и
  // должна тянуть окно от точки нажатия, а не от того, где курсор оказался к
  // моменту обработки.
  if (message == WM_LBUTTONDOWN) {
    HWND hwnd = GetHandle();
    POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    if (hwnd != nullptr && ClientToScreen(child, &point) &&
        GetWindowRect(hwnd, &press_window_)) {
      press_cursor_ = point;
      press_tick_ = GetTickCount64();
      press_recorded_ = true;
      drag_pointer_id_ = 0;
    }
  } else if (message == WM_POINTERDOWN) {
    // Касание и перо приходят указателем, а не мышью. ptPixelLocation уже в
    // экранных координатах — как раз то, что нужно точке отсчёта.
    HWND hwnd = GetHandle();
    POINTER_INFO info = {};
    if (hwnd != nullptr &&
        GetPointerInfo(GET_POINTERID_WPARAM(wparam), &info) &&
        GetWindowRect(hwnd, &press_window_)) {
      press_cursor_ = info.ptPixelLocation;
      press_tick_ = GetTickCount64();
      press_recorded_ = true;
      drag_pointer_id_ = GET_POINTERID_WPARAM(wparam);
    }
  }

  if (!dragging_) return;

  switch (message) {
    case WM_POINTERUPDATE: {
      // Мышиное перетаскивание идёт через WM_MOUSEMOVE.
      if (drag_pointer_id_ == 0 ||
          GET_POINTERID_WPARAM(wparam) != drag_pointer_id_) {
        return;
      }
      POINTER_INFO info = {};
      if (!GetPointerInfo(drag_pointer_id_, &info)) return;
      if ((info.pointerFlags & POINTER_FLAG_INCONTACT) == 0) {
        EndDrag();
        return;
      }
      UpdateDrag(info.ptPixelLocation);
      return;
    }

    case WM_POINTERUP:
      if (drag_pointer_id_ != 0 &&
          GET_POINTERID_WPARAM(wparam) == drag_pointer_id_) {
        EndDrag();
      }
      return;

    case WM_MOUSEMOVE: {
      // Кнопку уже отпустили (или она ушла в другое окно) — перетаскивание
      // закончилось, но захват остаётся у содержимого.
      if ((wparam & MK_LBUTTON) == 0) {
        EndDrag();
        return;
      }
      // Экранную точку курсора берём из системы: клиентские координаты в
      // сообщении считаются от уже сдвинутого окна, и по ним окно уезжало бы
      // на сумму всех предыдущих шагов.
      POINT cursor = {0, 0};
      if (GetCursorPos(&cursor)) {
        UpdateDrag(cursor);
      }
      return;
    }

    case WM_LBUTTONUP:
      EndDrag();
      return;

    case WM_CAPTURECHANGED:
      // Захват забрали (Alt+Tab, системный диалог): дальше движения к нам не
      // придут, перетаскивание закончилось.
      EndDrag();
      return;
  }
}

void FlutterWindow::RestoreFromMaximizedForDrag(HWND hwnd, POINT cursor) {
  RECT maximized = {0, 0, 0, 0};
  if (!GetWindowRect(hwnd, &maximized)) return;

  WINDOWPLACEMENT placement = {};
  placement.length = sizeof(placement);
  if (!GetWindowPlacement(hwnd, &placement)) return;

  ShowWindow(hwnd, SW_RESTORE);

  // Курсор остаётся на том же месте шапки: по горизонтали — та же доля
  // ширины (как в системном перетаскивании), по вертикали — тот же отступ,
  // чтобы шапка не выскочила из-под курсора.
  const RECT normal = placement.rcNormalPosition;
  const int width = normal.right - normal.left;
  const int height = normal.bottom - normal.top;
  const double fraction_x =
      maximized.right > maximized.left
          ? static_cast<double>(cursor.x - maximized.left) /
                static_cast<double>(maximized.right - maximized.left)
          : 0.5;

  int x = cursor.x - static_cast<int>(width * fraction_x);
  int y = maximized.top;

  MONITORINFO info = {};
  info.cbSize = sizeof(info);
  if (GetMonitorInfo(MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST),
                     &info)) {
    const RECT work = info.rcWork;
    x = std::max<int>(work.left, std::min<int>(x, work.right - width));
    y = std::max<int>(work.top, std::min<int>(y, work.bottom - height));
  }

  SetWindowPos(hwnd, nullptr, x, y, width, height,
               SWP_NOZORDER | SWP_NOACTIVATE);

  // Точка отсчёта — уже новое положение: следующее движение продолжит
  // перетаскивание от курсора, а не прыгнет к старому прямоугольнику.
  GetWindowRect(hwnd, &drag_window_start_);
  drag_cursor_start_ = cursor;
  drag_restore_pending_ = false;
}

void FlutterWindow::OnDestroy() {
  media_session_.Detach();

  // Каналы отпускаем до контроллера: их деструктор отписывается от messenger
  // движка, и после уничтожения контроллера он уже недействителен.
  window_channel_ = nullptr;
  media_channel_ = nullptr;
  flutter_controller_ = nullptr;

  // Колбэк первого кадра больше не должен трогать это окно.
  alive_->store(false, std::memory_order_release);

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;

    case WM_APPCOMMAND: {
      const std::optional<MediaCommand> command =
          MediaCommandFromAppCommand(GET_APPCOMMAND_LPARAM(lparam));
      // Обработанное не отдаём DefWindowProc: иначе система прокрутит то же
      // действие ещё раз — по своему маршруту к активной медиасессии.
      if (command.has_value() && HandleMediaCommand(*command)) {
        return TRUE;
      }
      break;
    }

    case kMediaCommandMessage:
      // Кнопка из оверлея: пришла с потока WinRT, теперь мы в потоке окна.
      HandleMediaCommand(static_cast<MediaCommand>(wparam));
      return 0;

    case WM_SIZE:
      // Развернуть окно можно не только кнопкой: Win+стрелка, Aero Snap,
      // двойной клик по шапке. WM_SIZE — единственное общее место, где видно
      // любое такое изменение, поэтому состояние уходит в Dart событием.
      // Иконка в шапке больше не угадывается по клику.
      if (wparam != SIZE_MINIMIZED) {
        NotifyMaximizedChanged();
      }
      [[fallthrough]];
    case WM_EXITSIZEMOVE:
      // Живое изменение размера: движок может не успеть отрисовать кадр, и по
      // краю окна остаётся картинка прежнего размера. Просим перерисовать.
      if (flutter_controller_) {
        flutter_controller_->ForceRedraw();
      }
      break;

    case WM_DPICHANGED:
      // Окно перетащили на монитор с другим масштабом: Win32Window применит
      // предложенный размер, а точку отсчёта перетаскивания сдвигаем вместе с
      // ним — иначе следующее движение курсора вернуло бы старый масштаб.
      if (dragging_) {
        drag_window_start_ = *reinterpret_cast<const RECT*>(lparam);
        GetCursorPos(&drag_cursor_start_);
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
