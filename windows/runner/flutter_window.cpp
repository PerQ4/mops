#include "flutter_window.h"

#include <dwmapi.h>

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

/// Play, pause и play/pause — одно действие для проверки на дубль: два пути
/// могут назвать одно нажатие по-разному.
bool SameMediaAction(MediaCommand first, MediaCommand second) {
  const auto group = [](MediaCommand command) {
    if (command == MediaCommand::kPlay || command == MediaCommand::kPause) {
      return MediaCommand::kPlayPause;
    }
    return command;
  };
  return group(first) == group(second);
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
          ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
          result->Success();
        } else if (method == "close") {
          PostMessage(hwnd, WM_CLOSE, 0, 0);
          result->Success();
        } else if (method == "isMaximized") {
          result->Success(flutter::EncodableValue(IsZoomed(hwnd) != 0));
        } else if (method == "startDrag") {
          // Тянем окно за свою шапку: отдаём системе нативный перетаскиватель.
          ReleaseCapture();
          SendMessage(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
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

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
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
    return true;
  }
  last_media_command_ = command;
  last_media_command_tick_ = now;

  media_channel_->InvokeMethod(
      "mediaKey", std::make_unique<flutter::EncodableValue>(
                      std::string(MediaCommandName(command))));
  return true;
}

void FlutterWindow::NotifyMaximizedChanged() {
  HWND hwnd = GetHandle();
  // Ранние WM_SIZE приходят до создания канала — их пропускаем: начальное
  // состояние Dart всё равно спрашивает сам.
  if (hwnd == nullptr || !window_channel_) {
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

void FlutterWindow::OnDestroy() {
  media_session_.Detach();
  media_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

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
      flutter_controller_->engine()->ReloadSystemFonts();
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
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
