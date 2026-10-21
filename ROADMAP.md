# Роадмапа mOps — по мотивам ArchiveTune

Документ для агентов, которые работают **автономно**. Каждая задача ниже
самодостаточна: что сделать, в каких файлах, как понять, что готово, и как
проверить. Задачи сгруппированы по этапам — сначала то, что даёт больше всего
пользы и меньше всего зависит от остального.

Источники фактов: `README.md`, `CHANGELOG.md`, `docs/archivetune-spec.md` и
код `lib/` этого репозитория; эталон — `rukamori/ArchiveTune`, ветка `dev`
(плюс подмодули `lyrics`, `core`, см. `.gitmodules` эталона). Пути к эталону в
задачах даны от корня репозитория ArchiveTune.

> `docs/ARCHITECTURE.md` устарел (там `go_router`, `audioplayers`,
> `dart_ytmusic_api`), фактический стек — Riverpod, `media_kit` (libmpv),
> собственный InnerTube-клиент. Документ правит владелец `docs/`, в этой
> роадмапе он не затрагивается.

---

## 0. Как пользоваться роадмапой

1. Возьми **одну** задачу, проверь, что её файлы не заняты другой задачей
   (см. «Карта областей» и столбец «Область»).
2. Задачи **внутри одной области выполняются последовательно** — общие файлы
   нельзя править двум агентам одновременно. Задачи из разных областей можно
   делать параллельно.
3. Соблюдай «Правила для агентов» (раздел 6).
4. Помечай прогресс: в чек-листах этапов меняй `- [ ]` на `- [x]`.

**Общие («хабовые») файлы.** Их правят часто, поэтому только один агент за
раз, и правки — минимальные, без рефакторинга:

- `lib/data/local/app_settings.dart` — модель настроек;
- `lib/state/providers.dart` — `SettingsController` и провайдеры;
- `lib/features/settings/settings_screen.dart` — экран настроек;
- `lib/features/common/navigation.dart` — маршруты;
- `lib/state/player_controller.dart` — плеер;
- `lib/state/catalog_providers.dart` — каталог и тексты.

Если задача требует правки хабового файла — так и написано в «Область»; в этом
случае перед началом убедись, что файл свободен.

---

## 1. Что уже сделано (не делать повторно)

Переносить это заново не нужно — оно есть и выстрадано. Таблица нужна, чтобы
агент не «изобрёл» уже существующее.

| Возможность | Где в коде | Статус |
|---|---|---|
| Движок libmpv через `media_kit` | `lib/core/audio/media_kit_engine.dart` | ✅ |
| Качество звука и источник потока (visionOS/Android VR/iOS/библиотека) | `lib/data/local/app_settings.dart`, `lib/data/sources/stream_resolver.dart`, `lib/data/sources/youtube_clients.dart` | ✅ |
| Очередь, перемешивание, повтор, авторадио, перетаскивание | `lib/state/player_controller.dart`, `lib/features/player/queue_list.dart` | ✅ |
| Полноэкранный плеер, фон из обложки, плавающий островок, правая панель | `lib/features/player/now_playing_screen.dart`, `floating_dock.dart`, `lib/features/shell/player_panel.dart` | ✅ |
| Стили полосы перемотки и ползунка громкости, отметка качества | `lib/features/player/player_controls.dart` | ✅ |
| Каталог, главная с бесконечной прокруткой, обзор, поиск, альбом/исполнитель/плейлист | `lib/features/**`, `lib/data/sources/catalog_source.dart`, `browse_parser.dart` | ✅ |
| Библиотека с фильтрами, лайки, подписки | `lib/features/library/library_screen.dart`, `lib/state/library_providers.dart` | ✅ |
| Вход в аккаунт: OAuth Device Flow, cookie, встроенный браузер, обновление токена | `lib/core/auth/**`, `lib/state/auth_controller.dart` | ✅ |
| Перенос плейлистов из Spotify | `lib/data/sources/spotify_client.dart`, `spotify_importer.dart`, `lib/features/settings/spotify_import_screen.dart` | ✅ |
| Тексты: 9 источников, параллельный поиск, приоритет по типу синхронизации, дисковый кэш, оффсет, ручной поиск и правка, романизация, поиск по тексту | `lib/state/catalog_providers.dart`, `lib/features/player/lyrics_view.dart`, `lyrics_actions.dart`, `lib/data/sources/*lyrics*`, `lib/data/local/lyrics_cache.dart` | ✅ |
| Discord Rich Presence (свой IPC, без нативных зависимостей) | `lib/core/discord/**` | ✅ |
| Обход блокировок: подмена хоста, прокси, дробление TLS, авто-проверка | `lib/core/net/**`, `lib/features/settings/bypass_screen.dart` | ✅ |
| Своя безрамочная шапка окна (Windows) | `lib/features/shell/window_title_bar.dart`, `windows/runner/**` | ✅ |
| Тема M3 Expressive, палитры, seed-цвета, палитра из обложки, чистый чёрный | `lib/core/theme/**`, `lib/state/theme_providers.dart` | ✅ |
| Масштаб интерфейса (авто по системе / вручную) | `lib/core/theme/ui_scaler.dart`, `lib/state/ui_scale.dart` | ✅ |
| Горячие клавиши и палитра команд `Ctrl+K` | `lib/features/shell/app_shortcuts.dart`, `command_palette.dart` | ✅ |
| Жест «назад» (тачпад, кнопка мыши, Alt+влево) | `lib/widgets/back_gesture.dart` | ✅ |
| Служебные проверки сети и текстов | `tool/**` | ✅ |
| Golden-тесты интерфейса | `test/goldens/**`, `test/ui_smoke_test.dart` | ✅ |
| Подписки на исполнителей: кнопка на странице и общее состояние | `lib/state/library_providers.dart` (`SubscribedIdsController`), `lib/features/artist/artist_screen.dart` | ✅ |
| Сохранение альбомов и плейлистов в библиотеку | `lib/data/sources/library_source.dart` (`setSaved`, `likedAlbums`), `lib/features/album/media_hero.dart` (`HeroSaveButton`) | ✅ |
| Просмотр клипов во встроенном браузере (пауза своего звука, полный экран, всегда доступный выход во внешний браузер) | `lib/features/player/clip_screen.dart`, `lib/features/common/navigation.dart` | ✅ |
| Клик по названию трека открывает альбом (альбом разрешается по `next` и кэшируется) | `lib/data/sources/catalog_source.dart` (`trackAlbum`), `lib/widgets/section_list.dart` | ✅ |
| Ручной поиск текста списком: метаданные, пометка синхронизации, предпросмотр | `lib/features/player/lyrics_actions.dart`, `lib/state/catalog_providers.dart` (`lyricsHitPreviewProvider`) | ✅ |
| Вставка-пауза отдельной строкой списка с заливающейся снизу нотой | `lib/features/player/lyrics_view.dart` | ✅ |
| Романизация как в ArchiveTune: автоопределение языка по тексту и пять переключателей | `lib/data/sources/romanization.dart`, `lib/features/settings/settings_screen.dart` | ✅ |
| Масштаб интерфейса с привязкой к сетке пикселей | `lib/core/theme/ui_scaler.dart` | ✅ |
| Несколько вариантов текста от одного источника (как `getAllLyrics`): список экрана поиска, выбор конкретного варианта | `lib/state/catalog_providers.dart` (`lyricsVariantsProvider`, `lyricsPickProvider`), `lib/data/sources/lyrics_variants.dart` | ✅ |
| Включение и выключение источников текста + каталоги Paxsenix по отдельности | `lib/data/local/app_settings.dart` (`lyricsDisabledProviders`, `PaxsenixOptions`), `lib/features/settings/settings_screen.dart` | ✅ |
| Резервная копия настроек: экспорт в файл и импорт с проверкой | `lib/features/settings/backup_screen.dart`, `lib/features/common/navigation.dart` | ✅ |
| Ручная правка текста хранится на диске (`lyrics_edits.json` рядом с кэшем) | `lib/data/local/lyrics_cache.dart` (`LyricsEditsStore`), `lib/state/lyrics_edits.dart` | ✅ |
| Добавление трека в плейлист и создание плейлиста | `lib/data/sources/library_source.dart`, `lib/state/library_providers.dart` (`PlaylistEditor`), `lib/features/library/playlist_edit.dart`, `lib/widgets/track_menu.dart` | ✅ |
| Детали потока: кодек, битрейт, частота, каналы (в меню плеера) | `lib/core/audio/{audio_engine,media_kit_engine}.dart`, `lib/features/player/media_info.dart` | ✅ |
| Копировать ссылку и «Открыть в YouTube Music» в меню трека | `lib/widgets/track_menu.dart` | ✅ |
| Диагностика источников текста: статус и время ответа по каждому источнику | `lib/state/catalog_providers.dart` (`LyricsSourceReport`), `lib/features/player/lyrics_actions.dart` | ✅ |
| Управление плейлистом: переименовать, удалить, убрать трек (по `setVideoId`), экспорт M3U | `lib/data/sources/{library_source,browse_parser}.dart`, `lib/features/playlist/{playlist_screen,m3u_export}.dart` | ✅ |
| Хранилище: размеры файлов данных, путь каталога, очистка кэша текстов | `lib/features/settings/storage_screen.dart`, `lib/data/local/lyrics_cache.dart` | ✅ |
| Таймер сна: 5/10/15/30/45/60 минут или после текущего трека | `lib/state/player_controller.dart`, `lib/features/player/sleep_timer.dart` | ✅ |
| Главная: чипы категорий из YouTube, полка «Слушать снова», блок «Быстрый выбор» | `lib/features/home/{home_screen,home_sections}.dart`, `lib/data/sources/catalog_source.dart` (`moodCategories`) | ✅ |
| Восстановление очереди и позиции между запусками (снимок в `shared_preferences`) | `lib/data/local/queue_snapshot.dart`, `lib/state/player_controller.dart` | ✅ |
| Поделиться текстом картинкой (1080×1080 PNG с обложкой) | `lib/features/player/lyrics_share_image.dart`, `lib/features/player/lyrics_actions.dart` | ✅ |
| Теги плейлистов: локальные метки и фильтр в библиотеке | `lib/data/local/playlist_tags.dart`, `lib/features/library/library_screen.dart` | ✅ |
| Диагностика соединения по шагам на экране обхода | `lib/core/net/diagnostics.dart`, `lib/features/settings/bypass_screen.dart` | ✅ |
| Темп и питч: диалог, кнопка в транспорте, питч через `scaletempo` | `lib/features/player/player_controls.dart`, `lib/core/audio/{audio_engine,media_kit_engine}.dart` | ✅ |
| Фильтры содержимого: скрыть explicit и видео, длина топа; признак видео разбирается из `musicVideoType` | `lib/data/local/app_settings.dart` (`TopSize`), `lib/data/sources/{catalog_source,browse_parser}.dart` | ✅ |

### Что есть у нас, но чего нет в ArchiveTune

| Возможность | Почему это наше, а не перенос |
|---|---|
| Обход блокировок (подмена хоста + авто-поиск локального прокси + дробление TLS) | В ArchiveTune только базовый прокси (`utils/ProxyUtils.kt`); механизм SNI/DNS-обхода у нас развит сильнее |
| Своя шапка окна и масштаб интерфейса | Десктоп-специфика; в Android-приложении не нужны |
| Дисковый кэш текстов отдельным файлом с TTL и лимитом записей | В ArchiveTune тексты кэшируются в Room (`db/entities/LyricsEntity.kt`) |
| Golden-тесты и `tool/`-проверки | Инфраструктура этого репозитория |

---

## 2. Карта областей

| Область | Файлы (кто владеет) |
|---|---|
| **W1 Плеер** | `lib/state/player_controller.dart`, `lib/features/player/{now_playing_screen,player_controls,queue_list,floating_dock}.dart`, `lib/core/audio/**` |
| **W2 Тексты** | `lib/features/player/{lyrics_view,lyrics_actions}.dart`, `lib/state/{lyrics_edits,catalog_providers}.dart`, `lib/data/local/lyrics_cache.dart`, `lib/data/sources/{lyrics_format,lyrics_match,romanization,better_lyrics_source,youly_plus_source,lrclib_source,kugou_source,unison_source,paxsenix_source}.dart` |
| **W3 Настройки и состояние** | `lib/data/local/app_settings.dart`, `lib/state/providers.dart`, `lib/features/settings/**` (кроме `bypass_screen.dart` и новых подэкранов интеграций) |
| **W4 Библиотека и каталог** | `lib/features/{library,home,explore,search,album,artist,playlist}/**`, `lib/widgets/{track_tile,track_menu,media_card,section_list,section_carousel,horizontal_list,library_empty_state,library_spotlight_tile}.dart`, `lib/data/sources/{catalog_source,browse_parser,library_source}.dart`, `lib/state/library_providers.dart` |
| **W5 Интеграции** | `lib/core/discord/**`, новые `lib/core/scrobbling/**`, новые `lib/features/settings/*_screen.dart` (подэкраны интеграций) |
| **W6 Сеть и поток** | `lib/core/net/**`, `lib/data/sources/{stream_resolver,stream_proxy,stream_downloader,range_downloader}.dart`, `lib/features/settings/bypass_screen.dart` |
| **W7 Оболочка и тема** | `lib/features/shell/**`, `lib/features/common/navigation.dart`, `lib/core/theme/**`, `lib/app.dart`, `lib/main.dart`, `lib/widgets/{artwork,async_views,empty_state,blurred_artwork_background}.dart` |

Обозначения сложности: **S** — до ~100 строк, **M** — до ~400, **L** — больше.
Маркер **[LIVE]** — задачу нельзя закрыть без живой проверки в запущенном
приложении (звук, анимации, сеть, ввод через браузер). Такие задачи агент
доводит до состояния «просит ведущего запустить» и описывает сценарий проверки.

---

## 3. Этапы и задачи

### Этап 1. Быстрые победы (независимые, польза сразу)

Чек-лист:

- [x] 1.1 Таймер сна
- [x] 1.2 Восстановление очереди и позиции между запусками
- [x] 1.3 Скорость и питч в плеере
- [x] 1.4 Копировать ссылку и «поделиться» треком
- [x] 1.5 Клик по строке текста — перемотка к ней
- [x] 1.6 Поделиться текстом картинкой
- [x] 1.7 Экспорт и импорт настроек (резервная копия)
- [x] 1.8 Настройки содержимого: скрыть explicit и видео, длина топа
- [x] 1.9 Провайдеры текстов: включение и под-провайдеры Paxsenix
- [x] 1.10 Романизация: выбор набора языков — сделано раньше (пять отдельных переключателей, язык определяется по тексту)

#### 1.1 Таймер сна
- **Зачем:** выключить музыку через N минут или после текущего трека — чтобы
  засыпать под музыку и не оставлять её играть всю ночь.
- **Область:** `lib/state/player_controller.dart`, новый
  `lib/features/player/sleep_timer.dart`, `lib/features/settings/settings_screen.dart`.
- **Что сделать:** 1) поле `sleepTimer` в `PlayerUiState` (минуты: `-1` —
  «после трека», `>0` — дедлайн; `0` — выключено); 2) методы
  `startSleepTimer(int minutes)` и `clearSleepTimer()`; отсчёт `Timer` в
  контроллере, по истечении — `_engine.pause()`; 3) при режиме «после трека» —
  пауза в `_handleTrackEnded`; 4) пункт меню с вариантами 5/10/15/30/45/60 мин,
  «после трека» и «выключить» в блоке управления плеером и в настройках.
- **Готово, когда:** выбранные 5 минут реально останавливают звук; «после
  трека» останавливает на границе трека; активный таймер виден в интерфейсе и
  снимается кнопкой.
- **Проверка:** `C:\Users\perqa\flutter\bin\flutter.bat analyze lib`; глазами —
  выбрать 5 минут, дождаться остановки; выбрать «после трека», дождаться
  перехода.
- **Ориентир:** `playback/SleepTimer.kt`.
- **Сложность:** S · **Зависимости:** нет.

#### 1.2 Восстановление очереди и позиции между запусками
- **Зачем:** после перезапуска приложение возвращает очередь и позицию —
  не приходится собирать её заново.
- **Область:** `lib/state/player_controller.dart`, `lib/data/local/app_settings.dart`,
  `lib/state/providers.dart`.
- **Что сделать:** 1) сохранять компактный снимок очереди (id, название,
  исполнитель, длительность, обложка, `playlistId`), индекс и позицию — в
  `shared_preferences` (не в `AppSettings`, отдельным ключом); 2) при старте
  восстанавливать очередь без автозапуска; 3) настройка «Восстанавливать
  очередь при запуске» (по умолчанию включена); 4) очистка снимка при
  `clearQueue`.
- **Готово, когда:** закрыл приложение во время трека — при следующем запуске
  видна та же очередь, текущий трек подсвечен, позиция сохранена.
- **Проверка:** `flutter analyze lib`; глазами — два запуска приложения.
- **Ориентир:** `models/PersistQueue.kt`, `models/PersistPlayerState.kt`,
  `playback/PlaybackResumptionPlanner.kt`.
- **Сложность:** M · **Зависимости:** нет.

#### 1.3 Скорость и питч в плеере
- **Зачем:** аудиокниги и разбор песен слушают на 0.75×–1.5×; сейчас движок
  умеет `setSpeed`, но в интерфейсе это не выведено.
- **Область:** `lib/features/player/player_controls.dart`, `lib/core/audio/media_kit_engine.dart`,
  `lib/core/audio/audio_engine.dart`, `lib/state/player_controller.dart`.
- **Что сделать:** 1) диалог «Темп и питч» со слайдером темпа (0.5–2.0, шаг
  0.05) и питча; 2) питч через свойство mpv (`af`/`scaletempo` + `audio-pitch-
  correction`), метод `setPitch` в `AudioEngine` и `MediaKitEngine`; 3) кнопка
  темпа в блоке управления и пункт в меню трека; 4) сброс к 1.0.
- **Готово, когда:** темп меняет скорость без «бурундука» (питч компенсирован),
  отдельный питч сдвигает высоту; значение сохраняется в `lastSpeed`.
- **Проверка:** `flutter analyze lib`; **[LIVE]** глазами и на слух — смена
  темпа на играющем треке.
- **Ориентир:** `ui/menu/PlayerMenu.kt` (диалог `tempo_and_pitch`).
- **Сложность:** M · **Зависимости:** нет.

#### 1.4 Копировать ссылку и «поделиться» треком
- **Зачем:** отправить другу ссылку на YouTube Music, а не объяснять, что за
  трек играет.
- **Область:** `lib/widgets/track_menu.dart`, `lib/features/player/now_playing_screen.dart`.
- **Что сделать:** 1) пункты «Копировать ссылку» и «Открыть в YouTube Music» в
  меню трека; 2) ссылка вида `https://music.youtube.com/watch?v=<id>`; 3)
  копирование через `Clipboard.setData`, открытие — `url_launcher`
  (`LaunchMode.externalApplication`); 4) короткое подтверждение (`SnackBar`).
- **Готово, когда:** ссылка попадает в буфер обмена, а «открыть» запускает
  браузер на нужном треке.
- **Проверка:** `flutter analyze lib`; глазами — вставить из буфера, открыть
  ссылку.
- **Ориентир:** `ui/menu/PlayerMenu.kt` (`share`, `copy_link`),
  `utils/YouTubeMusicLauncher.kt`.
- **Сложность:** S · **Зависимости:** нет.

#### 1.5 Клик по строке текста — перемотка к ней
- **Зачем:** услышать нужный припев сразу — нажал на строку и перемотал.
- **Область:** `lib/features/player/lyrics_view.dart`.
- **Что сделать:** 1) `onTap` строки с известным временем —
  `playerController.seek(line.time + оффсет)`; 2) строки без времени не
  кликабельны; 3) настройка «Клик по тексту перематывает» (по умолчанию
  включена) — если строку не хочется трогать, чтобы не сбить автопрокрутку.
- **Готово, когда:** нажатие на строку перематывает трек и подсветка
  переезжает на неё; нажатие на строку без времени ничего не делает.
- **Проверка:** `flutter analyze lib`; глазами — нажать на разные строки.
- **Ориентир:** `ui/screens/settings/LyricsSettings.kt` (`lyrics_click_change`).
- **Сложность:** S · **Зависимости:** нет.

#### 1.6 Поделиться текстом картинкой
- **Зачем:** красивая карточка со строками песни — для сторис и чатов.
- **Область:** `lib/features/player/lyrics_actions.dart`, новый
  `lib/features/player/lyrics_share.dart`.
- **Что сделать:** 1) кнопка «Поделиться текстом» в меню текста; 2) диалог с
  выбором числа строк и фона (тема / градиент обложки); 3) отрисовка виджета в
  PNG через `RepaintBoundary` + `toImage`; 4) сохранение в файл и открытие
  системного «поделиться»/папки (`path_provider`, `url_launcher`).
- **Готово, когда:** на выходе PNG с обложкой, названием, исполнителем и
  строками; файл открывается из проводника.
- **Проверка:** `flutter analyze lib`; глазами — сохранить и открыть файл.
- **Ориентир:** `ui/component/LyricsShareDialog.kt`,
  `LyricsShareImageOptions.kt`, `utils/ComposeToImage.kt`.
- **Сложность:** M · **Зависимости:** нет.

#### 1.7 Экспорт и импорт настроек (резервная копия)
- **Зачем:** перенести настройки на другой компьютер или откатиться после
  неудачного эксперимента.
- **Область:** `lib/features/settings/settings_screen.dart`, новый
  `lib/features/settings/backup_screen.dart`.
- **Что сделать:** 1) «Сохранить настройки в файл» — JSON из `AppSettings`
  плюс дисковый кэш текстов по желанию; 2) «Загрузить из файла» — валидация и
  применение через `SettingsController`; 3) пункт в разделе «О приложении».
- **Готово, когда:** после экспорта и импорта в другом профиле тема, порядок
  источников текста, обход блокировок и прочее совпадают.
- **Проверка:** `flutter analyze lib`; глазами — экспорт, смена настроек,
  импорт, сравнение.
- **Ориентир:** `backup/BackupArchiveRepository.kt`,
  `ui/screens/settings/BackupAndRestore.kt`.
- **Сложность:** S · **Зависимости:** нет.

#### 1.8 Настройки содержимого: скрыть explicit и видео, длина топа
- **Зачем:** убрать из выдачи клипы и мат, задать размер чартов — как в
  оригинале.
- **Область:** `lib/data/local/app_settings.dart`, `lib/state/providers.dart`,
  `lib/features/settings/settings_screen.dart`, `lib/data/sources/catalog_source.dart`.
- **Что сделать:** 1) настройки `hideExplicit`, `hideVideo`, `topSize`
  (10/20/50/100); 2) применять фильтры в выдаче каталога и поиска; 3) строки в
  настройках в группе «Поиск»/«Содержимое».
- **Готово, когда:** при включённом «скрыть видео» клипы не появляются в
  поиске и на главной; explicit-треки скрыты; чарты приходят запрошенной длины.
- **Проверка:** `flutter analyze lib`; глазами — поиск с включёнными фильтрами.
- **Ориентир:** `ui/screens/settings/ContentSettings.kt` (`HideExplicitKey`,
  `HideVideoKey`, `TopSize`).
- **Сложность:** S · **Зависимости:** нет.

#### 1.9 Провайдеры текстов: включение и под-провайдеры Paxsenix
- **Зачем:** выключить лишние базы (быстрее поиск) и выбрать, что именно берём
  у Paxsenix.
- **Область:** `lib/data/local/app_settings.dart`, `lib/state/providers.dart`,
  `lib/features/settings/settings_screen.dart`, `lib/state/catalog_providers.dart`.
- **Что сделать:** 1) набор включённых источников (`Set<LyricsSource>`) —
  выключенный не опрашивается вовсе; 2) у Paxsenix — переключатели Apple Music
  / Spotify / Musixmatch (все три уже поддержаны в `paxsenix_source.dart`);
  3) список переключателей в разделе «Текст песни».
- **Готово, когда:** выключенный источник не участвует в поиске (видно по
  логу `[Lyrics] источник … пропущен` и по отсутствию карточки в меню);
  выключенный под-провайдер Paxsenix не возвращает свой текст.
- **Проверка:** `flutter analyze lib`; глазами — выключить один источник и
  открыть меню текста.
- **Ориентир:** `ui/screens/settings/LyricsSettings.kt`
  (`EnableBetterLyricsKey`, `EnablePaxsenixAppleMusicLyricsKey` и др.).
- **Сложность:** M · **Зависимости:** нет.

#### 1.10 Романизация: выбор набора языков
- **Зачем:** сейчас выбирается один язык; удобнее включить сразу несколько.
- **Область:** `lib/data/local/app_settings.dart`, `lib/state/providers.dart`,
  `lib/features/settings/settings_screen.dart`, `lib/data/sources/romanization.dart`,
  `lib/features/player/lyrics_view.dart`.
- **Что сделать:** 1) вместо одного `romanizationLanguage` — набор
  включённых языков; 2) запрос романизации для каждой включённой пары
  (исходный → латиница); 3) переключатели по языкам в настройках; 4) миграция
  старого значения (один язык → набор из одного).
- **Готово, когда:** включены японский и корейский — латиница появляется у
  обоих; выключение языка убирает латиницу.
- **Проверка:** `flutter analyze lib`; глазами — треки на разных языках.
- **Ориентир:** `ui/screens/settings/LyricsSettings.kt` (группа `romanization`).
- **Сложность:** S · **Зависимости:** нет.

---

### Этап 2. Плеер и звук

Чек-лист:

- [ ] 2.1 Скачивание треков и офлайн-воспроизведение **[LIVE]**
- [ ] 2.2 Эквалайзер **[LIVE]**
- [ ] 2.3 Пропуск тишины и нормализация громкости **[LIVE]**
- [ ] 2.4 Предзагрузка следующего трека **[LIVE]**
- [ ] 2.5 Устройства вывода и пауза при заглушении **[LIVE]**
- [ ] 2.6 Дополнительные стили фона плеера **[LIVE]**
- [ ] 2.7 Стиль фона мини-плеера **[LIVE]**

#### 2.1 Скачивание треков и офлайн-воспроизведение
- **Зачем:** слушать любимое без сети и без повторной загрузки одного и того же
  потока.
- **Область:** новые `lib/data/local/downloads.dart`, `lib/features/settings/downloads_screen.dart`,
  `lib/state/player_controller.dart`, `lib/data/sources/stream_resolver.dart`,
  `lib/widgets/track_menu.dart`.
- **Что сделать:** 1) каталог загрузок в данных приложения, файл `<videoId>.m4a`
  и запись метаданных; 2) загрузка трека/альбома/плейлиста через уже готовый
  `RangeDownloader` (не изобретать заново); 3) в `stream_resolver` — сначала
  локальный файл, потом сеть; 4) пункты «Скачать»/«Удалить загрузку» в меню
  трека, прогресс в островке; 5) экран «Загрузки» со списком и общим размером.
- **Готово, когда:** скачанный трек играет при выключенной сети; удаление
  освобождает файл; прогресс виден.
- **Проверка:** `flutter analyze lib`; **[LIVE]** — скачать, выключить сеть,
  включить трек.
- **Ориентир:** `downloads/DownloadRepository.kt`,
  `playback/DownloadUtil.kt`, `ui/screens/downloads/DownloadLibraryScreen.kt`.
- **Сложность:** L · **Зависимости:** W6 (резолвер/поток). Затрагивает
  `player_controller.dart` — согласовать порядок с 1.1/1.2/1.3.

#### 2.2 Эквалайзер
- **Зачем:** подстроить звук под наушники и комнату.
- **Область:** новый `lib/features/player/equalizer.dart`, `lib/core/audio/media_kit_engine.dart`,
  `lib/core/audio/audio_engine.dart`, `lib/features/settings/settings_screen.dart`.
- **Что сделать:** 1) метод `setEqualizer(List<double> bands)` в `AudioEngine`
  через mpv `af=superequalizer` (или `equalizer`), с пересборкой фильтра;
  2) набор пресетов (плоский, бас, вокал, рок и т.п.) и 10 полос; 3) диалог из
  меню трека и строка в настройках; 4) сохранение пресета.
- **Готово, когда:** ползунки слышимо меняют тембр; «плоский» возвращает
  исходный звук; пресет переживает перезапуск.
- **Проверка:** `flutter analyze lib`; **[LIVE]** — на слух по знакомому треку.
- **Ориентир:** `equalizer/EqualizerRepository.kt`,
  `playback/EqualizerPlaybackController.kt`, `ui/menu/EqualizerDialog.kt`.
- **Сложность:** M · **Зависимости:** W1 (аудио-движок).

#### 2.3 Пропуск тишины и нормализация громкости
- **Зачем:** не слушать паузы в начале/конце треков и выровнять громкость
  между ними.
- **Область:** `lib/core/audio/media_kit_engine.dart`, `lib/core/audio/audio_engine.dart`,
  `lib/features/settings/settings_screen.dart`, `lib/data/local/app_settings.dart`.
- **Что сделать:** 1) флаги `skipSilence` и `audioNormalization`; 2) mpv-фильтры
  `silenceremove` и `dynaudnorm` (или `loudnorm`) через `af`; 3) переключатели
  в разделе «Воспроизведение» с честным описанием эффекта.
- **Готово, когда:** при включённой нормализации громкость треков выравнивается;
  при пропуске тишины начало играет сразу.
- **Проверка:** `flutter analyze lib`; **[LIVE]** — на слух.
- **Ориентир:** `ui/screens/settings/PlayerSettings.kt` (`skip_silence`,
  `audio_normalization`).
- **Сложность:** M · **Зависимости:** W1.

#### 2.4 Предзагрузка следующего трека
- **Зачем:** переход без паузы — следующий трек уже разрешён и прогрет.
- **Область:** `lib/state/player_controller.dart`, `lib/data/sources/stream_proxy.dart`.
- **Что сделать:** 1) включить уже написанный механизм прогрева (сейчас за
  флагом `_preloadEnabled = false` в `player_controller.dart`) и убедиться, что
  он не конфликтует с прямым воспроизведением через libmpv; 2) настройка
  «Предзагружать следующий трек»; 3) не прогревать при перемешивании.
- **Готово, когда:** следующий трек начинается заметно быстрее; на слабой сети
  предзагрузка не мешает текущему треку.
- **Проверка:** `flutter analyze lib`; **[LIVE]** — секундомер до звука с
  предзагрузкой и без.
- **Ориентир:** `playback/preload/NextStreamPreloader.kt`,
  `PlaybackPerformanceSettingsRepository.kt`.
- **Сложность:** M · **Зависимости:** 2.1 (офлайн-ветка резолвера) — иначе
  будет конфликт по `stream_resolver.dart`.

#### 2.5 Устройства вывода и пауза при заглушении
- **Зачем:** звук идёт в нужные колонки; при отключении наушников музыка
  встаёт на паузу, а не играет в тишину.
- **Область:** `lib/core/audio/media_kit_engine.dart`, `lib/state/player_controller.dart`,
  `lib/features/player/player_controls.dart`.
- **Что сделать:** 1) реакция на смену устройства (media_kit отдаёт список) —
  пауза при исчезновении активного устройства; 2) настройка «Пауза при
  отключении устройства»; 3) восстановление громкости после возврата
  (не «0», как бывает у системного микшера).
- **Готово, когда:** отключение наушников ставит трек на паузу; возврат не
  оставляет нулевую громкость.
- **Проверка:** `flutter analyze lib`; **[LIVE]** — переключение устройства.
- **Ориентир:** `ui/screens/settings/PlayerSettings.kt`
  (`pause_on_device_mute`, `device_mute_recovery_volume`).
- **Сложность:** M · **Зависимости:** W1.

#### 2.6 Дополнительные стили фона плеера
- **Зачем:** сейчас «градиент» и «размытая обложка»; в оригинале есть ещё
  свечение и окрашивание — плеер выглядит живее.
- **Область:** `lib/data/local/app_settings.dart`, `lib/state/providers.dart`,
  `lib/features/player/now_playing_screen.dart`, `lib/features/settings/settings_screen.dart`.
- **Что сделать:** 1) добавить стили `glow` и `coloring` в
  `PlayerBackgroundStyle`; 2) реализовать в `_ArtworkBackdrop`; 3) описать
  каждый в подписи настройки.
- **Готово, когда:** переключение стиля заметно меняет фон; выбор сохраняется.
- **Проверка:** `flutter analyze lib`; **[LIVE]** — посмотреть все стили на
  разных обложках.
- **Ориентир:** `ui/screens/settings/AppearanceSettings.kt`
  (`PlayerBackgroundStyle`), `ui/player/PlayerComponents.kt`.
- **Сложность:** M · **Зависимости:** нет.

#### 2.7 Стиль фона мини-плеера
- **Зачем:** островок сейчас на теме; в оригинале можно свечение или градиент.
- **Область:** `lib/features/player/floating_dock.dart`,
  `lib/data/local/app_settings.dart`, `lib/features/settings/settings_screen.dart`.
- **Что сделать:** 1) настройка `MiniPlayerBackgroundStyle` (тема / градиент /
  свечение); 2) реализация в островке, аккуратно — не ломать кромки и стык
  островков (см. «Правила»).
- **Готово, когда:** островок меняет фон, а геометрия и стык остаются как были.
- **Проверка:** `flutter analyze lib`; **[LIVE]** — все три стиля, широкая и
  узкая раскладки.
- **Ориентир:** `ui/screens/settings/AppearanceSettings.kt`
  (`MiniPlayerBackgroundStyle`), `ui/player/MiniPlayerComponents.kt`.
- **Сложность:** M · **Зависимости:** нет.

---

### Этап 3. Тексты

Чек-лист:

- [ ] 3.1 Режимы отображения текста (V2 / Enhanced) **[LIVE]**
- [ ] 3.2 Стили анимации текста **[LIVE]**
- [x] 3.3 Сохранение ручной правки текста
- [x] 3.4 Диагностика источников текста

#### 3.1 Режимы отображения текста (V2 / Enhanced)
- **Зачем:** у текста может быть не один вид: классический список, V2 и
  «расширенный» — на широком экране это заметно.
- **Область:** `lib/features/player/lyrics_view.dart`,
  `lib/data/local/app_settings.dart`, `lib/features/settings/settings_screen.dart`.
- **Что сделать:** 1) настройка `LyricsMode` (классический / V2 / Enhanced);
  2) реализовать V2 (крупная активная строка, соседние строки мельче и
  прозрачнее) как отдельную ветку рендера; 3) сохранить существующие механизмы:
  автопрокрутку, подсветку слов, размытие, поиск, оффсет.
- **Готово, когда:** переключение режима меняет вид, но караоке и автопрокрутка
  работают во всех режимах.
- **Проверка:** `flutter analyze lib`; **[LIVE]** — все режимы на треке с
  пословной разметкой.
- **Ориентир:** `ui/component/LyricsV2.kt`, `LyricsEnhanced.kt`,
  `ui/screens/settings/LyricsSettings.kt` (`lyrics_mode`).
- **Сложность:** L · **Зависимости:** нет (но затрагивает `lyrics_view.dart`
  целиком — не запускать параллельно с 3.2/1.5).

#### 3.2 Стили анимации текста
- **Зачем:** плавное появление строк и подсветка слов — визуальный комфорт.
- **Область:** `lib/features/player/lyrics_view.dart`,
  `lib/data/local/app_settings.dart`, новый
  `lib/features/settings/lyrics_animation_screen.dart`.
- **Что сделать:** 1) набор стилей анимации (нет / плавное / пружинное /
  масштаб) для появления активной строки и подсветки слов; 2) выбор в отдельном
  экране настроек; 3) уважать настройку «отключить анимации» (см. 7.3).
- **Готово, когда:** стиль меняет анимацию, при «нет» переход мгновенный.
- **Проверка:** `flutter analyze lib`; **[LIVE]** — смотреть на слух/глазами,
  без просадок частоты кадров.
- **Ориентир:** `ui/screens/settings/LyricsAnimationSettings.kt`,
  `AnimationPreferences.kt`.
- **Сложность:** M · **Зависимости:** 3.1 (та же ветка рендера).

#### 3.3 Сохранение ручной правки текста
- **Зачем:** правка строк сейчас живёт в памяти и теряется при перезапуске.
- **Область:** `lib/state/lyrics_edits.dart`, `lib/data/local/lyrics_cache.dart`.
- **Что сделать:** 1) складывать правки на диск рядом с кэшем текстов (тот же
  файл или отдельный `lyrics_edits.json`); 2) при загрузке — поднимать правку
  поверх найденного текста; 3) кнопка «Сбросить правку» очищает запись.
- **Готово, когда:** после перезапуска приложения исправленный текст остаётся
  исправленным.
- **Проверка:** `flutter analyze lib`; глазами — правка, перезапуск, проверка.
- **Ориентир:** `db/entities/LyricsEntity.kt` (там правки хранятся в БД).
- **Сложность:** S · **Зависимости:** нет.

#### 3.4 Диагностика источников текста
- **Зачем:** когда текст не нашёлся, непонятно, кто не ответил — а кто ответил
  пустотой.
- **Область:** `lib/features/player/lyrics_actions.dart`,
  `lib/state/catalog_providers.dart`.
- **Что сделать:** 1) в `LyricsSearchState` — статус по каждому источнику
  (ответил с текстом / ответил пусто / ошибка / таймаут); 2) в меню текста —
  компактный список с этими статусами и временем ответа; 3) не менять сам
  механизм приоритетного выбора.
- **Готово, когда:** в меню видно, что, например, BetterLyrics ответил за 0.4 с
  с текстом, а LRCLIB не успел; при успехе всё работает как раньше.
- **Проверка:** `flutter analyze lib`; глазами — открыть меню текста на треке
  без текста и с текстом.
- **Ориентир:** `ui/screens/settings/LyricsSettings.kt` (статистика Paxsenix).
- **Сложность:** M · **Зависимости:** 3.1/3.2 (общий файл `catalog_providers.dart`).

---

### Этап 4. Библиотека и каталог

Чек-лист:

- [x] 4.1 Добавление в плейлист и создание плейлиста
- [x] 4.2 Управление плейлистом и экспорт в файл
- [x] 4.3 Теги плейлистов
- [x] 4.4 Блокировка исполнителя
- [x] 4.5 Главная: категории, «Слушать снова», быстрый набор
- [x] 4.6 Замена недоступного трека

#### 4.1 Добавление в плейлист и создание плейлиста
- **Зачем:** собрать свой плейлист прямо из приложения — сейчас этого нет.
- **Область:** `lib/widgets/track_menu.dart`, `lib/data/sources/library_source.dart`,
  `lib/state/library_providers.dart`, новый `lib/features/library/playlist_edit.dart`.
- **Что сделать:** 1) метод `addToPlaylist(playlistId, videoId)` и
  `createPlaylist(title)` в `LibrarySource` (InnerTube `playlist/edit`); 2) диалог
  «Добавить в плейлист» со списком своих плейлистов и строкой «Новый плейлист»;
  3) инвалидация списка плейлистов после изменения.
- **Готово, когда:** трек появляется в выбранном плейлисте в YouTube Music;
  новый плейлист виден в библиотеке.
- **Проверка:** `flutter analyze lib`; глазами — добавить трек и открыть
  плейлист в веб-версии YouTube Music.
- **Ориентир:** `ui/menu/AddToPlaylistDialog.kt`, `AddToPlaylistDialogOnline.kt`,
  `playlist/CreatePlaylistUseCase.kt`.
- **Сложность:** M · **Зависимости:** нужен вход в аккаунт.

#### 4.2 Управление плейлистом и экспорт в файл
- **Зачем:** удалить трек из плейлиста, переименовать его, сохранить список в
  файл для другого плеера.
- **Область:** `lib/features/playlist/playlist_screen.dart`,
  `lib/data/sources/library_source.dart`, `lib/features/library/library_screen.dart`.
- **Что сделать:** 1) действия над плейлистом (переименовать, удалить,
  удалить трек) через `playlist/edit`; 2) экспорт в M3U (id/название/исполнитель
  /длительность) через сохранение файла; 3) обновление обложки плейлиста, если
  API отдаёт подходящий эндпоинт (иначе — не делать и отметить в отчёте).
- **Готово, когда:** изменения видны в аккаунте; M3U открывается другим
  плеером.
- **Проверка:** `flutter analyze lib`; глазами — изменить плейлист и открыть
  M3U.
- **Ориентир:** `ui/menu/PlaylistMenu.kt`, `playlist/PlaylistCoverUseCases.kt`,
  `playlistexport/PlaylistExportUseCases.kt`.
- **Сложность:** M · **Зависимости:** 4.1 (общий `library_source.dart`).

#### 4.3 Теги плейлистов
- **Зачем:** разложить плейлисты по тегам («работа», «тренировка») и
  фильтровать по ним.
- **Область:** `lib/features/library/library_screen.dart`, новый
  `lib/data/local/playlist_tags.dart`, `lib/state/library_providers.dart`.
- **Что сделать:** 1) локальное хранилище «плейлист → набор тегов»; 2) диалог
  назначения тегов; 3) фильтр-чипы по тегам над списком плейлистов.
- **Готово, когда:** плейлист с тегом показывается при выборе тега и
  скрывается при снятии; теги переживают перезапуск.
- **Проверка:** `flutter analyze lib`; глазами — назначить и отфильтровать.
- **Ориентир:** `playlisttags/PlaylistTagsUseCases.kt`,
  `ui/component/TagsManagementDialog.kt`.
- **Сложность:** M · **Зависимости:** нет.

#### 4.4 Блокировка исполнителя
- **Зачем:** убрать из выдачи артиста, которого не хочется видеть.
- **Область:** `lib/features/artist/artist_screen.dart`,
  `lib/widgets/track_menu.dart`, новый `lib/data/local/blocked_artists.dart`,
  `lib/data/sources/catalog_source.dart`.
- **Что сделать:** 1) локальный список заблокированных id исполнителей;
  2) фильтрация треков и секций по нему в каталоге, поиске и на главной;
  3) пункт «Заблокировать исполнителя» в меню трека и на странице исполнителя;
  4) экран управления списком в настройках.
- **Готово, когда:** треки заблокированного исполнителя пропадают из выдачи;
  разблокировка возвращает их.
- **Проверка:** `flutter analyze lib`; глазами — заблокировать и обновить
  главную/поиск.
- **Ориентир:** `artist/ArtistBlockRepository.kt`, `ArtistBlockUseCases.kt`.
- **Сложность:** M · **Зависимости:** нет.

#### 4.5 Главная: категории, «Слушать снова», быстрый набор
- **Зачем:** верх главной в оригинале полезнее: категории настроений, полка
  недавнего, быстрый набор плиткой.
- **Область:** `lib/features/home/home_screen.dart`, `home_sections.dart`,
  `lib/data/sources/catalog_source.dart`, `lib/state/catalog_providers.dart`.
- **Что сделать:** 1) полка «Слушать снова» из истории (если истории ещё нет —
  из секции YouTube, без выдумки); 2) чипы категорий (настроения и жанры) из
  существующего `browseSection`; 3) блок быстрого набора плиткой. Данных не
  выдумывать: чего разбор не отдаёт — не показывать (см. раздел 5).
- **Готово, когда:** новые блоки появляются и ведут на реальные разделы; при
  отсутствии данных блок не рисуется.
- **Проверка:** `flutter analyze lib`; глазами — главная на широком и узком окне.
- **Ориентир:** `home/HomeRepository.kt`, `ui/screens/HomeScreenComponents.kt`,
  `ui/screens/HomeScreen.kt`.
- **Сложность:** M · **Зависимости:** 8.1, если «Слушать снова» строится на
  локальной истории.

#### 4.6 Замена недоступного трека
- **Зачем:** трек пропал из YouTube — предложить замену вместо ошибки.
- **Область:** `lib/features/playlist/playlist_screen.dart`,
  `lib/widgets/track_tile.dart`, новый `lib/data/sources/song_replacement.dart`.
- **Что сделать:** 1) поиск замены по названию и исполнителю с оценкой
  совпадения (использовать `lyrics_match`-подобную нормализацию строк);
  2) пометка «недоступен» в списке и пункт «Найти замену»; 3) замена в очереди
  и плейлисте по выбору пользователя.
- **Готово, когда:** для недоступного трека предлагается список кандидатов,
  выбор подменяет его в очереди.
- **Проверка:** `flutter analyze lib`; глазами — трек-«призрак» из плейлиста.
- **Ориентир:** `playlistimport/ImportSongResolver.kt`,
  `PlaylistSongSourceReplacement.kt`, `ui/menu/SongSourceReplacementDialog.kt`.
- **Сложность:** M · **Зависимости:** нет.

---

### Этап 5. Интеграции

Чек-лист:

- [ ] 5.1 Last.fm: скробблинг **[LIVE]**
- [ ] 5.2 ListenBrainz: скробблинг **[LIVE]**
- [x] 5.3 Discord: кнопки, таймстампы, состояние паузы

#### 5.1 Last.fm: скробблинг
- **Зачем:** вести статистику прослушивания в Last.fm, как в оригинале.
- **Область:** новый `lib/core/scrobbling/lastfm.dart`,
  новый `lib/features/settings/lastfm_screen.dart`,
  `lib/state/player_controller.dart`.
- **Что сделать:** 1) авторизация (токен) и подпись запросов; 2) `nowPlaying`
  при старте трека и `scrobble` после половины или 4 минут; 3) экран входа и
  состояния в настройках; 4) хранение токена в `shared_preferences` (не в
  открытом виде, где возможно).
- **Готово, когда:** трек появляется в профиле Last.fm; при ошибке сети
  приложение не падает.
- **Проверка:** `flutter analyze lib`; **[LIVE]** — прослушать трек и проверить
  профиль.
- **Ориентир:** `scrobbling/LastFmSettingsRepository.kt`,
  `utils/ScrobbleManager.kt`, `lastfm/src/main/kotlin/.../LastFM.kt`.
- **Сложность:** M · **Зависимости:** W3 добавит пункт в настройки.

#### 5.2 ListenBrainz: скробблинг
- **Зачем:** вторая площадка статистики, включается одним токеном.
- **Область:** новый `lib/core/scrobbling/listenbrainz.dart`,
  новый `lib/features/settings/listenbrainz_screen.dart`,
  `lib/state/player_controller.dart`.
- **Что сделать:** 1) ввод токена; 2) `playing_now` и `single` submit;
  3) экран настроек.
- **Готово, когда:** прослушивание появляется в ListenBrainz.
- **Проверка:** `flutter analyze lib`; **[LIVE]** — проверить профиль.
- **Ориентир:** `ui/screens/settings/ListenBrainzManager.kt`.
- **Сложность:** S · **Зависимости:** 5.1 (общий хук скробблинга в плеере).

#### 5.3 Discord: кнопки, таймстампы, состояние паузы
- **Зачем:** presence сейчас показывает трек; добавить кнопку, время трека и
  явное «на паузе».
- **Область:** `lib/core/discord/discord_presence.dart`, `discord_ipc.dart`.
- **Что сделать:** 1) timestamps start/end по позиции и длительности;
  2) кнопка «Слушать в YouTube Music» (уже есть) — проверить и оформить;
  3) при паузе — соответствующая строка состояния; 4) не чаще одного
  обновления в несколько секунд.
- **Готово, когда:** в профиле Discord видно прогресс и паузу, кнопка открывает
  трек.
- **Проверка:** `flutter analyze lib`; глазами — профиль Discord при игре и
  паузе.
- **Ориентир:** `discord/DiscordPresenceModels.kt`, `playback/DiscordPresencePolicy.kt`.
- **Сложность:** S · **Зависимости:** нет.

---

### Этап 6. Сеть и устойчивость

Чек-лист:

- [ ] 6.1 SponsorBlock **[LIVE]**
- [x] 6.2 Низкий расход трафика
- [x] 6.3 Диагностика соединения в интерфейсе
- [x] 6.4 Управление кэшами и хранилищем

#### 6.1 SponsorBlock
- **Зачем:** пропускать вставки в клипах-видео.
- **Область:** новый `lib/data/sources/sponsorblock.dart`,
  `lib/state/player_controller.dart`, `lib/features/settings/settings_screen.dart`.
- **Что сделать:** 1) запрос сегментов по `videoId` с публичного API;
  2) выбор категорий (sponsor, intro, outro, self-promo); 3) авто-пропуск:
  при входе позиции в сегмент — `seek` за его конец; 4) ручная кнопка «Пропустить».
- **Готово, когда:** на клипе с разметкой вставка пропускается; выключение
  категории возвращает её.
- **Проверка:** `flutter analyze lib`; **[LIVE]** — клип с известной разметкой.
- **Ориентир:** `sponsorblock/SponsorBlockRepository.kt`,
  `SponsorBlockPlaybackController.kt`.
- **Сложность:** M · **Зависимости:** W1 (`player_controller.dart`).

#### 6.2 Низкий расход трафика
- **Зачем:** экономия на мобильном/лимитном интернете: меньше обложек и
  качества.
- **Область:** `lib/core/utils/artwork_urls.dart`, `lib/data/local/app_settings.dart`,
  `lib/features/settings/settings_screen.dart`, `lib/widgets/artwork.dart`.
- **Что сделать:** 1) флаг `lowDataMode`; 2) при включении — понижать
  запрашиваемый размер обложек и не тянуть превью видео; 3) переключатель в
  настройках.
- **Готово, когда:** при включённом режиме запрашиваются обложки меньшего
  размера (видно по URL/трафику), интерфейс не ломается.
- **Проверка:** `flutter analyze lib`; глазами — списки и плеер.
- **Ориентир:** `utils/LowDataMode.kt`.
- **Сложность:** S · **Зависимости:** нет.

#### 6.3 Диагностика соединения в интерфейсе
- **Зачем:** при «не играет» пользователь сам видит, где обрыв, не запуская
  скрипты.
- **Область:** `lib/features/settings/bypass_screen.dart`, новый
  `lib/core/net/diagnostics.dart`.
- **Что сделать:** 1) перенести логику `tool/diagnose.dart` в класс и вызвать
  из экрана «Обход блокировок»; 2) пошаговый вывод: DNS, API напрямую, API с
  подменой, медиахост, прокси; 3) кнопка «Проверить соединение» уже есть —
  расширить до полного отчёта.
- **Готово, когда:** отчёт показывает по шагам, что работает, а что нет, и
  подсказывает включить прокси.
- **Проверка:** `flutter analyze lib`; глазами — прогнать на рабочей и на
  «сломанной» сети (VPN).
- **Ориентир:** `ui/screens/settings/InternetSettings.kt`,
  `network/ObserveNetworkBannerStateUseCase.kt`.
- **Сложность:** M · **Зависимости:** W6.

#### 6.4 Управление кэшами и хранилищем
- **Зачем:** видеть, сколько занимают кэш текстов, загрузки и обложки, и
  очищать их.
- **Область:** новый `lib/features/settings/storage_screen.dart`,
  `lib/data/local/lyrics_cache.dart`, `lib/data/local/downloads.dart`.
- **Что сделать:** 1) подсчёт размеров каталогов данных; 2) кнопки «Очистить
  кэш текстов», «Удалить все загрузки»; 3) показ пути каталога данных.
- **Готово, когда:** размеры соответствуют диску, очистка освобождает место.
- **Проверка:** `flutter analyze lib`; глазами — очистить и сравнить размер
  каталога.
- **Ориентир:** `ui/screens/settings/StorageSettings.kt`,
  `storage/StorageLocationRepository.kt`.
- **Сложность:** M · **Зависимости:** 2.1 (если загрузок ещё нет — только кэш
  текстов).

---

### Этап 7. Оболочка, тема и полировка

Чек-лист:

- [x] 7.1 Обновления и «Что нового»
- [x] 7.2 «О приложении»: лицензии и участники
- [x] 7.3 Отключение анимаций и высокая частота обновления
- [x] 7.4 Свой шрифт
- [x] 7.5 Детали потока (медиа-инфо)

#### 7.1 Обновления и «Что нового»
- **Зачем:** узнать о новой версии и посмотреть, что изменилось.
- **Область:** новый `lib/features/settings/updates_screen.dart`,
  новый `lib/core/updates/update_check.dart`, `lib/features/settings/settings_screen.dart`.
- **Что сделать:** 1) запрос к GitHub Releases по API; 2) сравнение версии с
  текущей; 3) экран с кнопкой «Скачать» (открыть страницу релиза) и логом
  изменений; 4) бейдж «есть обновление» в настройках.
- **Готово, когда:** при выходе тега `v*` приложение показывает новую версию и
  открывает релиз; без сети — тихо ничего.
- **Проверка:** `flutter analyze lib`; глазами — подсунуть фиктивный ответ API.
- **Ориентир:** `updates/UpdateSettingsRepository.kt`,
  `ui/screens/settings/UpdateScreen.kt`, `ChangelogScreen.kt`.
- **Сложность:** M · **Зависимости:** нет.

#### 7.2 «О приложении»: лицензии и участники
- **Зачем:** честные лицензии и благодарности — требование GPLv3.
- **Область:** новый `lib/features/settings/about_screen.dart`,
  `lib/features/settings/settings_screen.dart`.
- **Что сделать:** 1) экран с версией, ссылкой на репозиторий и `LicensePage`
  из Flutter; 2) список использованных проектов (ArchiveTune, media_kit,
  youtube_explode_dart, lyrics-базы).
- **Готово, когда:** экран открывается, лицензии читаются, ссылки работают.
- **Проверка:** `flutter analyze lib`; глазами — открыть экран.
- **Ориентир:** `ui/screens/settings/AboutScreen.kt`, `about/`.
- **Сложность:** S · **Зависимости:** нет.

#### 7.3 Отключение анимаций и высокая частота обновления
- **Зачем:** на слабой машине — меньше анимаций; на 120 Гц — плавнее.
- **Область:** `lib/data/local/app_settings.dart`, `lib/app.dart`,
  `lib/features/settings/settings_screen.dart`.
- **Что сделать:** 1) флаг `disableAnimations` — обнулять длительности
  `Theme`-анимаций и переходов; 2) флаг «высокая частота» (если платформа
  позволяет запросить, иначе — честно отметить ограничение).
- **Готово, когда:** при выключенных анимациях переходы мгновенные; настройка
  переживает перезапуск.
- **Проверка:** `flutter analyze lib`; глазами — навигация и плеер.
- **Ориентир:** `ui/screens/settings/AppearanceSettings.kt`
  (`disable_animations`, `force_high_refresh_rate`).
- **Сложность:** S · **Зависимости:** нет.

#### 7.4 Свой шрифт
- **Зачем:** не всем подходит Poppins; можно подставить системный или свой.
- **Область:** `lib/core/theme/app_theme.dart`, `lib/data/local/app_settings.dart`,
  `lib/features/settings/settings_screen.dart`.
- **Что сделать:** 1) варианты «Poppins (по умолчанию) / системный / свой»;
  2) загрузка файла шрифта из проводника и применение; 3) для кириллицы —
  сохранить текущее поведение (Montserrat), не сломать.
- **Готово, когда:** выбор меняет шрифт интерфейса; кириллица остаётся
  читаемой.
- **Проверка:** `flutter analyze lib`; глазами — переключить все варианты.
- **Ориентир:** `ui/theme/CustomFontLoader.kt`, `Type.kt`,
  `ui/screens/settings/AppearanceSettings.kt` (`font_preference`).
- **Сложность:** M · **Зависимости:** нет.

#### 7.5 Детали потока (медиа-инфо)
- **Зачем:** понять, каким кодеком и битрейтом играет трек, — при отладке
  качества.
- **Область:** `lib/features/player/now_playing_screen.dart`,
  `lib/core/audio/audio_engine.dart`, новый `lib/features/player/media_info.dart`.
- **Что сделать:** 1) расширить `PlaybackState` полями кодек/контейнер/битрейт/
  частота (media_kit их отдаёт); 2) диалог «Детали потока» из меню трека.
- **Готово, когда:** в диалоге видны реальные параметры текущего потока.
- **Проверка:** `flutter analyze lib`; глазами — открыть на играющем треке.
- **Ориентир:** `mediainfo/MediaInfoRepository.kt`,
  `ui/utils/ShowMediaInfo.kt`.
- **Сложность:** S · **Зависимости:** W1.

---

### Этап 8. Долгосрочное (большая польза, большой объём)

Чек-лист:

- [x] 8.1 Статистика прослушивания и история
- [ ] 8.2 Canvas: анимированная обложка **[LIVE]**
- [x] 8.3 Локальные аудиофайлы
- [x] 8.4 Подкасты

#### 8.1 Статистика прослушивания и история
- **Зачем:** видеть, что и сколько слушал; основа для «Слушать снова» и
  рекомендаций.
- **Область:** новый `lib/data/local/listening_stats.dart`,
  новый `lib/features/settings/stats_screen.dart`, `lib/state/player_controller.dart`.
- **Что сделать:** 1) локальная база прослушиваний (файл JSON или `sqflite`,
  если решим тянуть зависимость); 2) запись факта «трек прослушан» (порог —
  половина или 4 минуты); 3) экран с топом за неделю/месяц/год и полной
  историей; 4) кнопка «сбросить статистику».
- **Готово, когда:** после нескольких прослушиваний топ и история совпадают с
  реальностью; сброс очищает.
- **Проверка:** `flutter analyze lib`; глазами — прослушать несколько треков.
- **Ориентир:** `privacy/ListeningStatsRepository.kt`,
  `ui/screens/StatsScreen.kt`, `db/DatabaseDao.kt`.
- **Сложность:** L · **Зависимости:** W1.

#### 8.2 Canvas: анимированная обложка
- **Зачем:** живая обложка вместо статичной картинки — заметная «фишка»
  оригинала.
- **Область:** новый `lib/data/sources/canvas.dart`,
  `lib/features/player/now_playing_screen.dart`,
  `lib/features/settings/settings_screen.dart`.
- **Что сделать:** 1) получение Canvas по треку (провайдеры Spotify/Apple/Tidal,
  как в оригинале — начать с одного); 2) воспроизведение короткого видео/цикла
  кадров вместо обложки в плеере; 3) настройка вкл/выкл и источник; 4) кэш,
  чтобы не качать повторно.
- **Готово, когда:** для трека с Canvas обложка анимируется; без Canvas —
  обычная картинка, без ошибок.
- **Проверка:** `flutter analyze lib`; **[LIVE]** — трек с известным Canvas.
- **Ориентир:** `canvas/` (модуль), `ui/player/CanvasArtworkPlayer.kt`,
  `ui/screens/settings/CanvasSettings.kt`.
- **Сложность:** L · **Зависимости:** нет.

#### 8.3 Локальные аудиофайлы
- **Зачем:** слушать свою музыку вместе с потоковой.
- **Область:** новый `lib/data/local/local_media.dart`,
  `lib/features/library/library_screen.dart`, `lib/state/library_providers.dart`.
- **Что сделать:** 1) сканирование выбранной папки на аудиофайлы;
  2) чтение метаданных (исполнитель, альбом, обложка); 3) раздел «Локальные» в
  библиотеке и воспроизведение локального файла движком; 4) сопоставление с
  потоковыми треками по метаданным — по желанию, отдельным шагом.
- **Готово, когда:** файлы из папки видны и играют; удаление файла убирает
  строку.
- **Проверка:** `flutter analyze lib`; глазами — папка с несколькими mp3.
- **Ориентир:** `localmedia/LocalSongScanner.kt`,
  `ScanLocalMusicUseCase.kt`, `ui/screens/library/LocalSongScreen.kt`.
- **Сложность:** L · **Зависимости:** нет.

#### 8.4 Подкасты
- **Зачем:** в YouTube Music есть подкасты; в оригинале — отдельный раздел.
- **Область:** новый `lib/features/podcast/podcast_screen.dart`,
  `lib/data/sources/catalog_source.dart`, `lib/features/shell/destinations.dart`.
- **Что сделать:** 1) разбор секций подкастов из каталога; 2) экран со списком
  и воспроизведением выпусков; 3) переход из «Обзора».
- **Готово, когда:** подкаст открывается и играет; обычная музыка не затронута.
- **Проверка:** `flutter analyze lib`; глазами — открыть подкаст из «Обзора».
- **Ориентир:** `podcast/PodcastRepository.kt`,
  `ui/screens/podcast/PodcastScreen.kt`.
- **Сложность:** L · **Зависимости:** W4 (`catalog_source.dart`).

---

### Этап 11. Десктоп по ревью

Источник — `docs/design_review.md`: полный отчёт с ссылками на файлы и строки.
Здесь только чек-лист, чтобы не потерялось.

- [x] 11.1 Правый клик и меню для карточек альбомов, исполнителей и плейлистов
- [x] 11.1.1 Контекстное меню на месте (`MenuAnchor`) вместо нижней шторки
- [x] 11.2 Плотность строк: компактный режим для трек-строк и строк библиотеки
- [x] 11.3 Герой страницы в две колонки на широком окне (альбом, исполнитель, плейлист)
- [x] 11.4 Карусели: Shift+колесо и стрелки по краям, полоса прокрутки на десктопе
- [x] 11.5 Максимизация окна по нативному событию и доступность кнопок
- [ ] 11.5.1 Snap Layouts: нужна шапка в настоящей non-client зоне, иначе теряются наведение и подсказки
- [x] 11.5.2 Подсказки на кнопках окна через `Overlay` над шапкой
- [x] 11.6 Медиаклавиши и системный оверлей Windows через свой канал
- [x] 11.7 Один источник состояний: hover и focus вместо дефолтов Flutter
- [x] 11.8 Индикатор загрузки M3E вместо пятнадцати `CircularProgressIndicator`
- [x] 11.9 Разбить `AppSettings` по доменам: семь доменов, фасад с прежним API
- [x] 11.10 Поиск без вкладки «Обзор», фильтры библиотеки видны целиком
- [ ] 11.11 Медиа-теги: пакет `audio_metadata_reader` пробовали и откатили — cp1251 в ID3v1, нечисловой `TRACKTOTAL` и строгий UTF-8 роняют чтение файла целиком, теряется и длительность. Нужен апстрим или узкая заплатка на эти три случая

**Сделано из ревью:** палитра прокручивается к выделению; правый клик по строке
трека открывает меню (пока шторкой — настоящий `MenuAnchor` это 11.1); действия
строк библиотеки доступны с клавиатуры; свайп по строке только для тача и
стилуса; автофокус в поиске; мёртвый `PlayerTheme` и девять мёртвых констант
раскладки убраны; «чистый чёрный» покрывает все контейнеры; суперэллипс на
крупной обложке по переключателю Expressive; радиус обложки больше не
вычитывается из дерева виджетов.

**Дальше по этапу:** плотность строк; герой в две колонки; карусели с
Shift+колесом и стрелками; максимизация по нативному событию и доступность
кнопок окна; подсказки на кнопках окна; медиаклавиши и оверлей Windows; единый
индикатор загрузки; единые слои наведения и фокуса; меню для карточек сущностей;
поиск без вкладки «Обзор» и фильтры библиотеки целиком; `AppSettings` разложен
по семи доменам с прежним API и прежним JSON.

**Правый клик:** работает на строках треков, строках библиотеки в панели,
карточках треков (главная, поиск, исполнитель, секции), в очереди, на экране
«Загрузки», в панели плеера и полноэкранном плеере. **Не сделан** у карточек
альбомов, исполнителей и плейлистов: готового меню у них нет — только кнопки в
шапках страниц. Чтобы там появился правый клик, нужен общий `MenuEntry` и меню
для этих сущностей, это отдельная задача вместе с настоящим `MenuAnchor` (11.1).

Сознательно не берём из ревью: полный squircle-язык по всему интерфейсу
(дорого и шумно на десктопе), полную шкалу типографики M3E, сведение трёх
представлений плеера в одно, перенос Linux-масштабирования.

---

## 4. Задачи, требующие живой проверки

Эти задачи агент **не может закрыть сам**: нужен запущенный звук, живой
браузер, живой ввод или сеть. Агент доводит код до состояния «готово к
проверке», описывает сценарий и просит ведущего запустить приложение.

**Готовый сценарий проверки — `docs/testing_checklist.md`:** всё собрано в один
список, чтобы пройти за один заход, с ожидаемым результатом и известными
ограничениями.

| Задача | Почему живая проверка |
|---|---|
| 1.3 Скорость и питч | темп и высота проверяются на слух; питч зависит от версии libmpv |
| 2.1 Скачивание и офлайн | нужно реально скачать и выключить сеть |
| 2.2 Эквалайзер | тембр оценивается только на слух |
| 2.3 Пропуск тишины и нормализация | эффект на слух, зависит от mpv-фильтров |
| 2.4 Предзагрузка | выигрыш во времени до звука измеряется на живом потоке |
| 2.5 Устройства вывода | нужно физически отключать наушники/колонки |
| 2.6, 2.7 Стили фона | визуальная оценка на разных обложках |
| 3.1, 3.2 Режимы и анимации текста | смотреть глазами, без просадок кадров |
| 5.1, 5.2 Скробблинг | нужен реальный аккаунт и внешний сервис |
| 6.1 SponsorBlock | нужен клип с живой разметкой |
| 8.2 Canvas | сеть и живой провайдер Canvas |
| 9.5 Обложка плейлиста | протокол недокументированный: проверяется только настоящей загрузкой |
| 9.6 Импорт из Spotify | нужен реальный аккаунт Spotify и его сессия |
| Любая задача с входом в аккаунт через браузер | WebView2/WKWebView/WebKitGTK проверяются только в запущенном приложении |

К задачам без маркера **[LIVE]** живая проверка не обязательна — достаточно
`flutter analyze lib` и, где есть, юнит-тестов.

---

## 5. Чего сознательно не делаем

Причины честные: либо механизм не реализуется корректно на нашем стеке, либо
это решение владельца, либо нужен внешний сервис.

- **Перевод текстов (в том числе через AI).** Решение владельца: романизация
  есть, перевода не будет. AI-перевод и AI-фильтр контента (`ai/`,
  `aicontentfilter/`) не переносим.
- **Кроссфейд.** Честно не реализуется: нужен второй плеер и предзагрузка
  следующего потока одновременно. Возвращаемся только если появится реальная
  предзагрузка (2.4) и подтверждённый спрос.
- **Gapless «в лоб».** libmpv играет поток напрямую; бесшовный переход требует
  локального потока через посредника (код лежит под флагом `_preloadEnabled`).
  Отдельная задача — после 2.1/2.4.
- **Music Together (совместное прослушивание).** Нужен сервер синхронизации
  (`together/` в оригинале) — это отдельный проект, не фича клиента.
- **Распознавание музыки (Shazam-подобное).** Нужен захват системного звука и
  бинарный движок; на десктопе это отдельная большая работа.
- **Android Auto, Android-виджеты, TV/automotive, AOD, Cast.** Приложение
  десктопное; этих платформ у нас нет.
- **SponsorBlock — только категории, без «показать кнопку на экране».** Ручной
  интерфейс пропуска откладываем до 6.1.
- **Главная: спец-секции** (возобновление, «колоды», быстрый набор, плейлисты
  аккаунта в исходном виде) — разбор не отдаёт обложку секции, число песен и
  локальные плейлисты. Сначала данные, потом формы.
- **Стрелка у заголовка секции** — нужен переход по произвольному `browseId`.
- **Трековые секции сеткой (4 строки)** — нужен виджет с прокруткой колесом.
- **Тексты: ключ BetterLyrics** (ключи не выдают); источники по списку Better
  Lyrics + диагностика; Musixmatch richsync при наличии ключа.
- **Очередь: дублирование названия** (строка трека и шапка) — в шапке оставить
  счётчик и кнопки.
- **Жест «назад»:** проверить на живом тачпаде, что свайп приходит как
  `PointerPanZoom`, а не как горизонтальная прокрутка.
- **Волна от звука:** движок уровень не отдаёт (`media_kit` даёт только
  `position`, `duration`, `volume`, `audioParams`, `audioBitrate`). Сейчас
  «живость» условная — от позиции, темпа и громкости. Настоящий уровень — у
  libmpv через `af=astats` и свойство `af-metadata`: отдельная задача, дороже по
  процессору и хрупче при смене версии libmpv.
- **Выпуски:** 0.2.0 — следующий (см. `CHANGELOG.md`), предрелизы фич тегами
  `v0.2.0-home.1`. Проверить Windows: вход в браузере и установщик.

---

### Этап 9. Баги и дизайн (по следам живых проверок)

Это не перенос из ArchiveTune, а найденное на живых запусках: то, что видно
глазами и мешает пользоваться. Каждая задача — с причиной, а не «сделать
красивее».

Чек-лист:

- [x] 9.1 Волновой прогресс вокруг обложки в мини-плеере и панели
- [x] 9.2 Клипы: ошибка 153 у встроенного плеера
- [x] 9.3 Качество звука у видео: выбор аудиодорожки
- [x] 9.4 Клипы: полный экран не убирает свою шапку окна
- [x] 9.5 Обложка плейлиста: нужен ресайзбл-протокол загрузки
- [x] 9.6 Импорт из Spotify: перепроверить после починки `playlist/edit`
- [x] 9.7 Golden-тесты: на Windows не грузятся шрифты, эталоны не сходятся
- [x] 9.8 `ui_smoke_test`: падают «Островок… очередь» и «Полноэкранный плеер»
- [x] 9.9 `cards_test`: падает «лента прокручивается колесом мыши»
- [x] 9.10 Радио по треку: кнопка «Начать радио» в меню трека
- [x] 9.11 «Смотреть клип» — только для треков-видео
- [x] 9.12 Признак видео у треков из радио: `_panelTrack` не заполняет `isVideo`
- [x] 9.13 Устаревшие комментарии про колесо мыши в `horizontal_list.dart` и `queue_list.dart`
- [x] 9.14 `_searchLyrics`: таймеры поиска текста не снимаются при dispose

#### 9.1 Волновой прогресс вокруг обложки
- **Зачем:** в эталоне вокруг обложки идёт волнистое кольцо прогресса — видно,
  сколько трек уже играет, не глядя на полосу перемотки.
- **Область:** `lib/features/player/floating_dock.dart`,
  `lib/features/shell/player_panel.dart`, новый файл кольца.
- **Что сделать:** `CircularWavyProgressIndicator(progress:, color:, trackColor:)`
  в эталоне (`MiniPlayerComponents.kt:348`) оборачивает обложку; у нас такого нет
  вовсе. Нарисовать кольцо по периметру обложки, обновлять по позиции точечно
  (`select`), пока трек грузится — неопределённое кольцо.
- **Готово, когда:** на играющем треке вокруг обложки видно волновое кольцо,
  заливка растёт по времени; на паузе оно стоит, при загрузке крутится.
- **Сложность:** M.

#### 9.2 Клипы: ошибка 153 у встроенного плеера
- **Зачем:** клип открывается, но внутри «Ошибка настройки видеопроигрывателя.
  Ошибка 153» — смотреть нельзя.
- **Область:** `lib/features/player/clip_screen.dart`.
- **Что сделать:** ошибка 153 — отказ встраивания без валидного
  `Referer`/`origin`. Передавать заголовки в `URLRequest`, рассмотреть
  `youtube-nocookie.com/embed`; если плеер всё равно отказал — честное сообщение
  и кнопка «Открыть в браузере», а не пустое окно.
- **Готово, когда:** клип играет внутри окна; при отказе видно причину и выход.
- **Сложность:** S.

#### 9.3 Качество звука у видео
- **Зачем:** у треков-клипов звук заметно хуже, чем у обычных треков.
- **Область:** `lib/data/sources/stream_resolver.dart`.
- **Что сделать:** пробоем сравнить выбранную дорожку для обычного трека и для
  клипа (`_pickFromPlayerResponse`, `_pickCandidate`): не берём ли мы аудио
  внутри видеоформата вместо адаптивной аудиодорожки и как влияет
  `AudioQuality`. Если причина на стороне YouTube — зафиксировать цифрами.
- **Готово, когда:** для видео выбирается лучшая доступная аудиодорожка.
- **Сложность:** M.

#### 9.4 Клипы: полный экран не убирает свою шапку окна
- **Зачем:** в полном экране остаётся своя 34-пиксельная шапка окна — полного
  экрана не получается.
- **Область:** `lib/app.dart` (шапка рисуется выше навигатора),
  `lib/features/player/clip_screen.dart`.
- **Что сделать:** либо прятать шапку окна на время полного экрана клипа, либо
  завести в канале `mops/window` метод, который её скрывает.
- **Готово, когда:** в полном экране клипа нет ни шапки экрана, ни шапки окна.
- **Сложность:** S.

#### 9.5 Обложка плейлиста
- **Зачем:** сменить обложку своего плейлиста сейчас нельзя (задача 4.2 без
  этой части).
- **Область:** `lib/data/sources/library_source.dart`, новый файл.
- **Что сделать:** нужен ресайзбл-протокол загрузки (`playlist_image_upload` с
  `X-Goog-Upload-*`), чтение заголовков ответа и кадрирование картинки ≤ 2 МБ.
  Наш `InnerTubeClient` умеет только JSON-POST — расширить его.
- **Готово, когда:** обложка меняется и видна в аккаунте.
- **Сложность:** L.

#### 9.6 Импорт из Spotify: перепроверить
- **Зачем:** `browse/edit_playlist` собирался неверно (id с префиксом `VL`,
  короткое `ADD_VIDEO`) — треки могли молча не добавляться.
- **Область:** проверка, правок не требует.
- **Что сделать:** импортировать плейлист и глазами сверить в веб-версии.
- **Сложность:** S, нужна живая проверка.

#### 9.7 Golden-тесты: шрифты на Windows
- **Зачем:** `flutter test` ругается на восемь случаев — эталоны снимались на
  Linux, а кириллический шрифт берётся из системных путей Linux.
- **Область:** `test/ui_smoke_test.dart` (`_loadFonts`, `_flutterRoot`).
- **Что сделать:** грузить шрифт для кириллицы кроссплатформенно (из
  `assets/fonts`) и пересобрать эталоны один раз.
- **Готово, когда:** `flutter test` проходит на этой машине.
- **Сложность:** S.

#### 9.8 `ui_smoke_test`: два падающих случая
- **Зачем:** «Островок показывает трек и раскрывает очередь» и «Полноэкранный
  плеер на телефоне» падают исключением, а не сравнением картинок.
- **Область:** `test/ui_smoke_test.dart`, возможно `lib/features/player/**`.
- **Что сделать:** найти причину исключения (таймер, отсутствующий провайдер) и
  починить; если это свойство тестовой обвязки — починить обвязку.
- **Сложность:** S.

#### 9.9 `cards_test`: лента и колесо мыши
- **Зачем:** тест «лента прокручивается колесом мыши» падает детерминированно.
- **Область:** `test/cards_test.dart`, возможно `lib/widgets/**`.
- **Что сделать:** понять, изменилось ли поведение ленты или ожидание теста.
- **Сложность:** S.

#### 9.10 Радио по треку
- **Зачем:** в YouTube Music из любого трека можно запустить радио — у нас только
  автоматическое продление очереди, кнопки нет.
- **Область:** `lib/widgets/track_menu.dart`, `lib/state/player_controller.dart`.
- **Что сделать:** пункт «Начать радио» в меню трека: очередь заменяется на радио
  от этого трека. Механизм уже есть — `CatalogSource.autoplayQueue(seedId)` и
  `_extendWithRadio` в контроллере; нужен ручной запуск (seed первым, затем
  радио) вместо продления.
- **Готово, когда:** нажатие на трек → «Начать радио» ставит его первым и
  продолжает похожими треками.
- **Сложность:** S.

#### 9.11 «Смотреть клип» — только для треков-видео
- **Зачем:** пункт есть у всех треков, хотя клип существует не у каждого.
- **Область:** `lib/widgets/track_menu.dart`, `lib/data/local/queue_snapshot.dart`
  (если нужно донести признак до восстановленной очереди), `now_playing_screen.dart`.
- **Что сделать:** показывать пункт только при `Track.isVideo == true` (признак
  разбирается из `musicVideoType`, см. `browse_parser.dart`); в плеере кнопку
  клипа скрывать так же. Учесть восстановленную очередь: снимок не хранит
  `isVideo`, поэтому после перезапуска признак терялся бы.
- **Готово, когда:** у обычной песни пункта нет, у клипа — есть.
- **Сложность:** S. **Сделано:** пункт под `isVideo`, признак добавлен в снимок
  очереди (`video`); отдельной кнопки клипа в плеере нет — клип открывается
  только из меню трека.

#### 9.12 Признак видео у треков из радио
- **Зачем:** треки, пришедшие из радио (`CatalogSource.autoplayQueue`), собираются
  через `_panelTrack`, который `isVideo` не заполняет. У клипа из радио пункт
  «Смотреть клип» не появится.
- **Область:** `lib/data/sources/catalog_source.dart` (`_panelTrack`).
- **Что сделать:** заполнять `isVideo` из `musicVideoType` так же, как это делает
  `browse_parser.dart` для обычных списков.
- **Готово, когда:** у клипа, пришедшего из радио, пункт «Смотреть клип» есть.
- **Сложность:** S.

---

### Этап 10. Что стоит перенять у Swiftify

`shredos67/swiftify` — десктопный Spotify-клиент (Qt Quick + Rust/librespot),
тоже на Material 3 Expressive. Код другой (C++/Qt/Rust против Flutter), поэтому
берём идеи, а не строки. Ниже — то, что у них сделано и у нас отсутствует.

Чек-лист:

- [x] 10.1 Словарь движений M3 Expressive (переходы, а не разрозненные анимации)
- [x] 10.2 Liquid backdrop: живой фон плеера на шейдере
- [x] 10.3 Спектр-визуализатор (полосы или гало) из звука
- [x] 10.4 Кривая эквалайзера (к задаче 2.2)
- [x] 10.5 Кроппер обложки (нужен для 9.5 и для локальных файлов)
- [x] 10.6 Бегущая строка для длинных названий
- [x] 10.7 Discord: искать клиент во всех сборках, а не только в стандартной
- [x] 10.8 Спектр по частотам: полосы вместо гало (`aspectralstats` стал доступен)
- [x] 10.9 Выпуск 0.2: версия в pubspec, CHANGELOG за 0.2.1–0.2.11, заметки релиза

#### 10.1 Словарь движений M3 Expressive
- **Зачем:** у них 15 именованных переходов (`ElementMove`, `ElementMoveEnter`,
  `ElementMoveExit`, `ElementResize`, `HeroFlight`, `ShapeBurst`, `ClickBounce`,
  `Drift`, `HoverFade`, `SidebarSlideEnter/Exit` и прочие) — один язык анимации
  на всё приложение. У нас анимации разрознены: где-то 160 мс, где-то 220.
- **Область:** новый `lib/core/theme/motion.dart`, применение в `lib/widgets/**`,
  `lib/features/**`.
- **Что сделать:** выписать длительности и кривые из motion-схемы M3 Expressive
  (они уже есть в пакете `material_3_expressive`), завести именованные переходы
  (`elementMove`, `elementMoveEnter`, `elementResize`, `heroFlight`,
  `clickBounce`) и перевести на них существующие анимации.
- **Готово, когда:** длительности берутся из одного места, переходы одинаковы на
  схожих действиях.
- **Сложность:** M.

#### 10.2 Liquid backdrop
- **Зачем:** у них фон плеера — живой «жидкий» шейдер (`LiquidBackdrop.qml`,
  `shaders/liquid_backdrop.frag`), он и есть основная «красота».
- **Область:** новый шейдер в `shaders/` (Flutter `FragmentProgram`),
  `lib/features/player/now_playing_screen.dart`, настройка в `app_settings.dart`.
- **Что сделать:** перенести идею на Flutter: `FragmentProgram` с медленно
  текущей жидкостью из цветов обложки, как ещё один стиль фона рядом с
  «Градиент» и «Размытая обложка». Шейдер писать свой — их GLSL для Qt, не для
  Flutter.
- **Готово, когда:** стиль выбирается в настройках и не съедает кадры на слабой
  машине (при простое анимация останавливается).
- **Сложность:** M.

#### 10.3 Спектр-визуализатор
- **Зачем:** у них полосы и «гало» вокруг обложки (`spectrum_bars.frag`,
  `spectrum_halo.frag`, `CompactMeter.qml`).
- **Область:** `lib/core/audio/**` (источник уровней), новый виджет визуализатора,
  `now_playing_screen.dart`.
- **Что сделать:** получить спектр из libmpv (`af=showcqt`/`af=astats` или разбор
  аудио из нашего прокси), нарисовать полосы шейдером или `CustomPainter`.
  В роадмапе уже есть заметка про `af=astats` (этап 2) — начать с неё.
- **Готово, когда:** визуализатор двигается по музыке, а не по позиции трека.
- **Сложность:** L.

#### 10.4 Кривая эквалайзера
- **Зачем:** у них эквалайзер нарисован кривой (`EqualizerCurve.qml`), по ней
  видно, что настроено, — понятнее ползунков.
- **Область:** к задаче 2.2 (эквалайзер), новый виджет кривой.
- **Что сделать:** когда появится эквалайзер, показать сумму полос кривой.
- **Готово, когда:** кривая меняется вместе с ползунками.
- **Сложность:** S.

#### 10.5 Кроппер обложки
- **Зачем:** у них есть кадрирование обложки (`CoverCropper.qml`) — и для
  локальных файлов, и для плейлистов.
- **Область:** новый виджет; пригодится в 9.5 и 8.3.
- **Что сделать:** квадратное кадрирование с перетаскиванием и масштабом.
- **Сложность:** M.

#### 10.6 Бегущая строка для длинных названий
- **Зачем:** у нас длинные названия обрезаются («Солдатами не рождаю…»), у них
  есть `ScrollingText.qml`.
- **Область:** `lib/widgets/marquee_text.dart` (новый),
  `lib/features/player/floating_dock.dart` (заголовок островка),
  `lib/features/shell/player_panel.dart`. В `player_controls.dart` названий нет —
  формулировка была неточной.
- **Что сделать:** если текст не влезает — плавно прокручивать его туда-сюда,
  на паузе останавливать, при наведении показывать полностью.
- **Готово, когда:** длинное название читается целиком.
- **Сложность:** S.

#### 10.7 Discord: искать клиент во всех сборках
- **Зачем:** они проверяют не только стандартный путь, но и Flatpak, Snap,
  Canary, PTB и сторонние клиенты вроде Vesktop. У нас свой IPC — стоит искать
  так же широко.
- **Область:** `lib/core/discord/discord_ipc.dart`.
- **Что сделать:** добавить пути Windows/macOS/Linux для сборок Discord и
  сторонних клиентов.
- **Готово, когда:** присутствие видно и в Canary/PTB/Vesktop.
- **Сложность:** S.

#### 10.8 Спектр по частотам
- **Зачем:** в старой libmpv фильтров не было вовсе, теперь сборка полная:
  `aspectralstats` и `showcqt` на месте. Значит вместо «дыхания» уровня можно
  рисовать настоящие полосы по частотам — как `spectrum_bars` у Swiftify.
- **Область:** `lib/core/audio/audio_level_monitor.dart`,
  `lib/widgets/spectrum_visualizer.dart`, `shaders/**`.
- **Что сделать:** читать полосы из `af-metadata` (`aspectralstats`), нарисовать
  полосы шейдером или `CustomPainter`, оставить выбор стиля (гало или полосы).
- **Готово, когда:** визуализатор показывает частоты, а не общий уровень.
- **Сложность:** M.

#### 10.9 Выпуск 0.2
- **Зачем:** версия в `pubspec.yaml` застряла на `0.2.0+1`, а теги уже до
  `v0.2.11`; в `CHANGELOG.md` последняя запись — 0.2.0, то есть вся работа
  последних дней не описана. Установщик берёт версию из pubspec, поэтому сейчас
  он представляется как 0.2.0.
- **Область:** `pubspec.yaml`, `CHANGELOG.md`, `README.md`.
- **Что сделать:** поднять версию, описать 0.2.1–0.2.11 по коммитам и тегам,
  проверить, что установщик и архивы собираются с новой версией.
- **Готово, когда:** версия, тег и установщик совпадают, изменения описаны.
- **Сложность:** S.

---

## 6. Правила для агентов

1. **Своя область — только своя.** Не рефактори чужие файлы. Если для задачи
   нужна правка хабового файла (`app_settings.dart`, `providers.dart`,
   `settings_screen.dart`, `navigation.dart`, `player_controller.dart`,
   `catalog_providers.dart`) — это указано в «Область»; убедись, что файл
   свободен, и делай **минимальную** правку.
2. **Не коммить и не пушить.** Роадмапу и релиз собирает ведущий агент.
3. **Не запускать сборку.** `flutter build`, `flutter run`, `flutter pub get`
   не запускать — это делает ведущий. Разрешено: `flutter analyze` и
   обычные юнит-тесты.
4. **Обязательный прогон анализа:** `C:\Users\perqa\flutter\bin\flutter.bat
   analyze lib` — без новых ошибок и предупреждений.
5. **Не ломать выстраданные механизмы** (если задача их касается — проверь, что
   они работают как раньше):
   - **приоритетный выбор текста** (тип синхронизации важнее порядка
     источников, `bestByOrder` в `catalog_providers.dart`);
   - **кэш текстов** (`lyrics_cache.json`, TTL 7 суток, лимит 500, пустой
     ответ не пишется);
   - **дедлайн поиска текста** (бюджет источника 5 с, общий дедлайн 6 с);
   - **привязка масштаба к пикселям** (`ui_scaler.dart` — границы виджетов
     между пикселями дают щели);
   - **кромки окна и стык островков** (`window_title_bar.dart`,
     `floating_dock.dart` — стык 12, кромки для изменения размера);
   - **обход блокировок** (`lib/core/net/**` — подмена хоста, прокси,
     дробление TLS; медиахосты намеренно не подменяются).
6. **Комментарии — по-русски**, как во всём проекте. Объясняй «почему», а не
   «что»; не оставляй мёртвый код.
7. **Golden-тесты.** Если задача меняет интерфейс, покрытый голденами
   (`test/goldens/01_home_desktop.png`, `03_dock.png`, `05_settings.png`,
   `06_now_playing.png`), не «подгоняй» картинку молча — сообщи ведущему, что
   голдены нужно обновить (`flutter test --update-goldens` запускает ведущий).
8. **Одна задача — один отчёт.** В отчёте: что сделано, какие файлы тронуты,
   результат `flutter analyze lib`, сценарий живой проверки (если нужна),
   известные ограничения.
9. **Не выдумывать данные.** Если каталог или база чего-то не отдают — блок не
   рисуем и пишем это в отчёте, а не подставляем заглушку.
