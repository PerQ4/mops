// Историческое имя файла.
//
// Раньше движок был реализован поверх `audioplayers` (на Linux — GStreamer).
// Он слал `Range: bytes=0-`, медиасервер YouTube отвечал 403, и поток
// приходилось качать целиком. Движок заменён на [MediaKitEngine] (libmpv),
// см. `media_kit_engine.dart`.
//
// Файл оставлен ради совместимости: `providers.dart` создаёт
// `AudioplayersEngine`, и переименовывать его ради смены движка не хочется.
// Псевдоним ниже сохраняет прежнее имя класса, указывая на новую реализацию.
import 'media_kit_engine.dart';

export 'media_kit_engine.dart';

typedef AudioplayersEngine = MediaKitEngine;
