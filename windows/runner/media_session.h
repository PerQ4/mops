#ifndef RUNNER_MEDIA_SESSION_H_
#define RUNNER_MEDIA_SESSION_H_

#include <windows.h>

#include <memory>
#include <string>

/// Действие, пришедшее из системы — от медиаклавиши или из оверлея.
enum class MediaCommand {
  kPlayPause,
  kPlay,
  kPause,
  kNext,
  kPrevious,
  kStop,
};

/// Строковое имя действия: уходит в Dart аргументом события `mediaKey`.
const char* MediaCommandName(MediaCommand command);

/// Кнопка оверлея нажата; wParam — MediaCommand в виде числа.
///
/// События SMTC приходят на поток WinRT, а канал в Dart живёт на потоке окна:
/// команда возвращается туда через PostMessage, чтобы не трогать messenger
/// из чужого потока.
constexpr UINT kMediaCommandMessage = WM_APP + 0x51;

/// Системный оверлей Windows (SMTC) для одного окна.
///
/// C++/WinRT спрятан в реализации: заголовок остаётся обычным Win32, и если
/// оверлей не создался, окно и медиаклавиши работают как раньше.
class MediaSession {
 public:
  MediaSession();
  ~MediaSession();

  MediaSession(const MediaSession&) = delete;
  MediaSession& operator=(const MediaSession&) = delete;

  /// Подключает оверлей к окну. false — оверлея не будет.
  bool Attach(HWND window);

  /// Обновляет карточку оверлея. Вызывается с потока окна.
  void SetNowPlaying(const std::string& title, const std::string& artist,
                     const std::string& album, bool playing);

  /// Убирает карточку: играть нечего.
  void Clear();

  /// Отписывается от кнопок и отпускает SMTC.
  void Detach();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_MEDIA_SESSION_H_
