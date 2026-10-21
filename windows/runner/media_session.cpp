#include "media_session.h"

#include <optional>

#if defined(MOPS_HAS_SMTC)

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>

#include <systemmediatransportcontrolsinterop.h>

#include <atomic>

namespace {

using winrt::Windows::Media::MediaPlaybackStatus;
using winrt::Windows::Media::MediaPlaybackType;
using winrt::Windows::Media::MusicDisplayProperties;
using winrt::Windows::Media::SystemMediaTransportControls;
using winrt::Windows::Media::SystemMediaTransportControlsButton;
using winrt::Windows::Media::SystemMediaTransportControlsButtonPressedEventArgs;
using winrt::Windows::Media::SystemMediaTransportControlsDisplayUpdater;

/// Строки из Dart приходят в UTF-8, а WinRT ждёт UTF-16.
std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return std::wstring();
  const int size = ::MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                         static_cast<int>(text.size()),
                                         nullptr, 0);
  if (size <= 0) return std::wstring();
  std::wstring wide(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                        wide.data(), size);
  return wide;
}

std::optional<MediaCommand> CommandFromButton(
    SystemMediaTransportControlsButton button) {
  switch (button) {
    case SystemMediaTransportControlsButton::Play:
      return MediaCommand::kPlay;
    case SystemMediaTransportControlsButton::Pause:
      return MediaCommand::kPause;
    case SystemMediaTransportControlsButton::Stop:
      return MediaCommand::kStop;
    case SystemMediaTransportControlsButton::Next:
      return MediaCommand::kNext;
    case SystemMediaTransportControlsButton::Previous:
      return MediaCommand::kPrevious;
    default:
      // Запись, перемотка и каналы — не про этот плеер.
      return std::nullopt;
  }
}

}  // namespace

struct MediaSession::Impl {
  // Обработчик WinRT живёт на своём потоке и может быть уже в работе, когда
  // окно закрывается и Impl удаляется. Поэтому всё, что нужно обработчику,
  // лежит в отдельном состоянии под shared_ptr: он владеет своей копией и
  // после удаления Impl не касается освобождённой памяти.
  struct HandlerState {
    // Дескриптор обнуляется до отписки, и поздняя кнопка никуда не постится.
    std::atomic<HWND> window{nullptr};
    // Гасится в Detach до отписки: событие, пришедшее в этот момент, уже
    // ничего не отправит.
    std::atomic<bool> alive{false};
  };

  std::shared_ptr<HandlerState> handler = std::make_shared<HandlerState>();
  SystemMediaTransportControls controls{nullptr};
  winrt::event_token button_token{};
  bool subscribed = false;
};

MediaSession::MediaSession() : impl_(std::make_unique<Impl>()) {}

MediaSession::~MediaSession() {
  Detach();
}

bool MediaSession::Attach(HWND window) {
  Detach();
  if (window == nullptr) return false;

  try {
    // SMTC создаётся только через Interop-интерфейс: обычная активация класса
    // возвращает фабрику, у которой нет привязки к окну.
    auto interop =
        winrt::get_activation_factory<ISystemMediaTransportControlsInterop>(
            L"Windows.Media.SystemMediaTransportControls");
    SystemMediaTransportControls controls{nullptr};
    winrt::check_hresult(interop->GetForWindow(
        window, winrt::guid_of<SystemMediaTransportControls>(),
        winrt::put_abi(controls)));
    if (!controls) return false;

    controls.IsEnabled(true);
    controls.IsPlayEnabled(true);
    controls.IsPauseEnabled(true);
    controls.IsStopEnabled(true);
    controls.IsNextEnabled(true);
    controls.IsPreviousEnabled(true);
    controls.PlaybackStatus(MediaPlaybackStatus::Closed);

    // Копия shared_ptr остаётся в лямбде: обработчик не держит Impl.
    std::shared_ptr<Impl::HandlerState> handler = impl_->handler;
    handler->window.store(window, std::memory_order_release);
    handler->alive.store(true, std::memory_order_release);
    impl_->button_token = controls.ButtonPressed(
        [handler](SystemMediaTransportControls const&,
                  SystemMediaTransportControlsButtonPressedEventArgs const&
                      args) {
          const std::optional<MediaCommand> command =
              CommandFromButton(args.Button());
          if (!command.has_value()) return;
          if (!handler->alive.load(std::memory_order_acquire)) return;
          HWND hwnd = handler->window.load(std::memory_order_acquire);
          if (hwnd != nullptr) {
            ::PostMessageW(hwnd, kMediaCommandMessage,
                           static_cast<WPARAM>(*command), 0);
          }
        });
    impl_->subscribed = true;
    impl_->controls = controls;
    return true;
  } catch (...) {
    // Оверлей — необязательная часть. Старая Windows или запрет политики
    // оставляют приложение с одними медиаклавишами.
    Detach();
    return false;
  }
}

void MediaSession::SetNowPlaying(const std::string& title,
                                 const std::string& artist,
                                 const std::string& album, bool playing) {
  if (!impl_ || !impl_->controls) return;
  try {
    SystemMediaTransportControls controls = impl_->controls;
    controls.PlaybackStatus(playing ? MediaPlaybackStatus::Playing
                                    : MediaPlaybackStatus::Paused);

    SystemMediaTransportControlsDisplayUpdater updater =
        controls.DisplayUpdater();
    updater.Type(MediaPlaybackType::Music);
    MusicDisplayProperties music = updater.MusicProperties();
    music.Title(winrt::hstring(Utf8ToWide(title)));
    music.Artist(winrt::hstring(Utf8ToWide(artist)));
    music.AlbumTitle(winrt::hstring(Utf8ToWide(album)));
    updater.Update();
  } catch (...) {
    // Сбой обновления карточки не должен мешать воспроизведению.
  }
}

void MediaSession::Clear() {
  if (!impl_ || !impl_->controls) return;
  try {
    SystemMediaTransportControls controls = impl_->controls;
    controls.PlaybackStatus(MediaPlaybackStatus::Closed);
    controls.DisplayUpdater().ClearAll();
  } catch (...) {
  }
}

void MediaSession::Detach() {
  if (!impl_) return;

  // Сначала гасим живость: обработчик, уже выполняющийся на потоке WinRT,
  // после этой строки ничего не отправит. Общее состояние он держит сам,
  // поэтому освобождать Impl можно сразу следом.
  impl_->handler->alive.store(false, std::memory_order_release);
  impl_->handler->window.store(nullptr, std::memory_order_release);

  if (impl_->subscribed && impl_->controls) {
    try {
      impl_->controls.ButtonPressed(impl_->button_token);
    } catch (...) {
    }
    impl_->subscribed = false;
  }
  impl_->controls = nullptr;
}

#else  // !MOPS_HAS_SMTC

// Заголовков C++/WinRT нет (SDK без cppwinrt): оверлея не будет. Медиаклавиши
// живут отдельно, в WM_APPCOMMAND, и здесь ничего не теряют.
struct MediaSession::Impl {
  HWND window = nullptr;
};

MediaSession::MediaSession() : impl_(std::make_unique<Impl>()) {}

MediaSession::~MediaSession() = default;

bool MediaSession::Attach(HWND window) {
  impl_->window = window;
  return false;
}

void MediaSession::SetNowPlaying(const std::string& title,
                                 const std::string& artist,
                                 const std::string& album, bool playing) {
  (void)title;
  (void)artist;
  (void)album;
  (void)playing;
}

void MediaSession::Clear() {}

void MediaSession::Detach() {
  impl_->window = nullptr;
}

#endif  // MOPS_HAS_SMTC

const char* MediaCommandName(MediaCommand command) {
  switch (command) {
    case MediaCommand::kPlayPause:
      return "playPause";
    case MediaCommand::kPlay:
      return "play";
    case MediaCommand::kPause:
      return "pause";
    case MediaCommand::kNext:
      return "next";
    case MediaCommand::kPrevious:
      return "previous";
    case MediaCommand::kStop:
      return "stop";
  }
  return "playPause";
}
