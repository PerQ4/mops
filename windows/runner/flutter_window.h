#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <memory>
#include <optional>
#include <string>

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
  void OnChildContentMessage(HWND child, UINT message, WPARAM wparam,
                             LPARAM lparam) override;

 private:
  // Сообщает Dart, развёрнуто окно или нет. Событие уходит только при
  // изменении состояния.
  void NotifyMaximizedChanged();

  // Кладёт окно в половину рабочей области монитора или разворачивает его на
  // весь экран. |side| — "left", "right" или "max".
  void SnapWindow(const std::string& side);

  // Отдаёт действие в Dart событием `mediaKey`. true — событие отправлено
  // (или это дубль уже обработанного).
  bool HandleMediaCommand(MediaCommand command);

  // Перетаскивание своей шапки без модального цикла системного SC_MOVE:
  // окно само ведёт себя за курсором до отпускания кнопки, поэтому поток
  // остаётся свободным для канала и ответов Flutter.
  void BeginDrag();
  void EndDrag();
  // Двигает окно так, чтобы точка захвата осталась под курсором.
  void UpdateDrag(POINT cursor);
  // Развёрнутое окно перед перетаскиванием уменьшается под курсором.
  void RestoreFromMaximizedForDrag(HWND hwnd, POINT cursor);

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

  // Состояние перетаскивания своей шапки.
  bool dragging_ = false;
  bool drag_restore_pending_ = false;
  POINT drag_cursor_start_ = {0, 0};
  RECT drag_window_start_ = {0, 0, 0, 0};

  // Нажатие, с которого начинается возможное перетаскивание. Запоминается на
  // WM_LBUTTONDOWN: команда startDrag приходит через канал уже после него.
  bool press_recorded_ = false;
  POINT press_cursor_ = {0, 0};
  RECT press_window_ = {0, 0, 0, 0};
  ULONGLONG press_tick_ = 0;
  // 0 — тянет мышь; иначе номер указателя касания/пера.
  UINT32 drag_pointer_id_ = 0;

  // Колбэк первого кадра ставится в очередь движка и может выполниться уже
  // после OnDestroy: флаг держится отдельно от окна и гасится при разрушении.
  std::shared_ptr<std::atomic<bool>> alive_ =
      std::make_shared<std::atomic<bool>>(true);

  // Последнее состояние, о котором Dart уже знает. WM_SIZE приходит на каждый
  // шаг перетаскивания границы, и без этой проверки канал бы захлебнулся.
  std::optional<bool> reported_maximized_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
