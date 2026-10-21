#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>

#include "media_session.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Сообщает Dart, развёрнуто окно или нет. Событие уходит только при
  // изменении состояния.
  void NotifyMaximizedChanged();

  // Отдаёт действие в Dart событием `mediaKey`. true — событие отправлено
  // (или это дубль уже обработанного).
  bool HandleMediaCommand(MediaCommand command);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Канал управления окном: свернуть / развернуть / закрыть (своя шапка).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // Канал медиаклавиш и системного оверлея (`mops/media`). Отдельный от
  // `mops/window`: у него своё состояние и своё направление данных.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      media_channel_;

  // Оверлей Windows (SMTC). Без него остаются медиаклавиши через
  // WM_APPCOMMAND — это разные пути к одному и тому же действию.
  MediaSession media_session_;

  // Одна и та же клавиша приходит двумя путями: WM_APPCOMMAND, пока окно в
  // фокусе, и SMTC, когда оно не в фокусе. Иногда оба сразу — без проверки
  // play/pause сработал бы дважды и ничего бы не изменил.
  std::optional<MediaCommand> last_media_command_;
  ULONGLONG last_media_command_tick_ = 0;

  // Последнее состояние, о котором Dart уже знает. WM_SIZE приходит на каждый
  // шаг перетаскивания границы, и без этой проверки канал бы захлебнулся.
  std::optional<bool> reported_maximized_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
