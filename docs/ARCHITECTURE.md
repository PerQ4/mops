# mOps — кросс-платформенный плеер YouTube Music

Material Design 3 **Expressive**, Flutter. Единый код для Linux / Windows / macOS / Android / iOS / Web.

## Целевой UX

Ориентир — **ArchiveTune** (Kotlin/Compose, Android). Что переносим в первую версию:

| Фича ArchiveTune | Статус в mOps v1 |
|---|---|
| Вход в аккаунт YouTube Music | ✅ OAuth Device Flow |
| Свои плейлисты / лайки / подписки | ✅ |
| Воспроизведение без рекламы | ✅ |
| Локальные файлы | ⏳ v2 |
| Синхронизированные тексты (live lyrics) | ✅ |
| Album-art dynamic colors | ✅ |
| Материал 3 Expressive | ✅ |
| Responsive-раскладки | ✅ |
| Аудиокачество / выбор потока | ✅ |
| Скорость и питч | ✅ (темп/speed) |
| Кроссфейд, EBU R128 нормализация | ⏳ v2 |
| Last.fm / ListenBrainz / Discord RPC | ⏳ v2 |
| Распознавание музыки (Shazam) | ⏳ v2 |
| Статистика прослушивания | ⏳ v2 |
| Импорт из Spotify | ⏳ v2 |

## Стек

- **Flutter 3.47.7** (stable) + Dart 3.13 — Material 3 Expressive из коробки.
- **Riverpod** — состояние.
- **go_router** — навигация, deep links.
- **dart_ytmusic_api** — метаданные YT Music: home, search, album, artist, playlist, up-next, lyrics (в т.ч. синхронизированные).
- **youtube_explode_dart** — извлечение аудиопотоков (чистый Dart, без внешних бинарников).
- **audioplayers** — воспроизведение. На Linux работает через GStreamer, на остальных платформах — нативно.
- **material_color_utilities + palette_generator** — динамическая палитра из обложки.
- **extended_image / cached_network_image** — кэш обложек.

### Почему audioplayers, а не media_kit

`media_kit` качественнее (gapless, точный seek), но на Linux требует системный `libmpv`.
На текущей машине `libmpv` отсутствует, а `sudo` недоступен. GStreamer же установлен
полностью (opus, matroska, souphttpsrc, pipewire). Поэтому v1 использует `audioplayers`,
а движок спрятан за интерфейсом `AudioEngine` — замена на media_kit/just_audio делается
в одном классе (см. `lib/core/audio/`).

## Слои

```
lib/
  main.dart
  app.dart                     # MaterialApp.router, тема, локаль
  core/
    audio/                     # AudioEngine (абстракция) + audioplayers-реализация
    auth/                      # OAuth device flow, хранилище токенов
    http/                      # InnerTube-клиент, заголовки, ретраи
    theme/                     # M3 Expressive: схема, типографика, motion, формы
    utils/
  data/
    models/                    # Song, Album, Artist, Playlist, HomeSection, ...
    repositories/              # YtMusicRepository, LibraryRepository, PlayerRepository
    sources/                   # ytmusic (anonymous), ytmusic (authenticated), stream resolver
    local/                     # настройки, кэш, история
  features/
    home/ explore/ search/ library/ album/ artist/ playlist/
    player/                    # мини-плеер, Now Playing, очередь, тексты
    settings/ account/
  widgets/                     # переиспользуемые MD3-компоненты
```

## Тема: Material 3 Expressive

- Базовая схема генерируется из seed-цвета (`ColorScheme.fromSeed`) **или** из обложки
  играющего трека (album-art dynamic colors).
- `TextTheme` — Expressive-шкала (крупные display/headline).
- Формы — Expressive shape scale (сильно скруглённые, «морфящие»).
- Motion — пружинные кривые.
- Компоненты: navigation rail/bar, expressive FAB, split/segmented buttons, toolbar,
  loading indicator, card-группы, bottom sheet.

## Ответственность и правовое

Клиент неофициальный, не аффилирован с Google/YouTube, не обходит технические защиты.
Пользователь сам отвечает за соблюдение ToS YouTube. Код под GPLv3.
