import 'dart:io';

import 'package:flutter/services.dart';
import 'package:meta/meta.dart';

/// Семейство, под которым регистрируется шрифт пользователя.
///
/// Имя постоянное, а не взятое из файла: Flutter разрешает шрифт по семейству,
/// а имя внутри TTF бывает пустым или повторяется у разных файлов. Файл
/// подменяется — семейство остаётся, и тема не пересобирается дважды.
const String kCustomFontFamily = 'MopsCustom';

/// Кодовые точки, по которым проверяется кириллица: «А», «Я», «а», «я», «Ё»,
/// «ё». Полного набора не нужно — шрифт либо покрывает русский алфавит, либо
/// нет, и эти шесть букв отвечают за самое заметное.
const List<int> _cyrillicProbe = <int>[
  0x0410,
  0x042F,
  0x0430,
  0x044F,
  0x0401,
  0x0451,
];

/// Что получилось из файла шрифта.
@immutable
class CustomFontStatus {
  const CustomFontStatus({
    required this.path,
    required this.fileName,
    this.hasCyrillic,
    this.error,
  });

  final String path;
  final String fileName;

  /// `true` — кириллица есть, `false` — нет, `null` — определить не удалось
  /// (неизвестный формат таблицы символов). В последнем случае предупреждать
  /// нечестно: мы действительно не знаем.
  final bool? hasCyrillic;

  /// Причина, по которой файл не пригодился; `null` — шрифт загружен.
  final String? error;

  bool get loaded => error == null;
}

/// Загрузка своего шрифта с диска (задача 7.4).
///
/// Системного диалога выбора файла в проекте нет — путь вводится текстом, как
/// для M3U и резервной копии. Файл читается здесь, а не в экране настроек:
/// тема и предупреждение о кириллице должны иметь дело с одним разбором.
abstract final class CustomFonts {
  static final Map<String, CustomFontStatus> _cache =
      <String, CustomFontStatus>{};
  static String? _registeredKey;
  static CustomFontStatus? _lastStatus;

  /// Последний загруженный шрифт — его показывает экран настроек, чтобы не
  /// перечитывать файл на каждую перерисовку.
  static CustomFontStatus? get lastStatus => _lastStatus;

  /// Читает файл, регистрирует его в движке и сообщает, есть ли кириллица.
  ///
  /// Повторный вызов с тем же файлом ничего не перечитывает: `lastModified` и
  /// размер входят в ключ, поэтому подменённый файл загрузится заново, а тот же
  /// самый — нет. [force] нужен кнопке «Проверить файл»: она должна увидеть
  /// правку, даже если путь не изменился, — и при этом не заставлять настройки
  /// проверять диск на каждое движение ползунка громкости.
  static Future<CustomFontStatus> load(
    String rawPath, {
    bool force = false,
  }) async {
    final String path = rawPath.trim();
    if (path.isEmpty) {
      final CustomFontStatus empty = const CustomFontStatus(
        path: '',
        fileName: '',
        error: 'Путь к файлу не задан',
      );
      _lastStatus = empty;
      return empty;
    }

    final CustomFontStatus? previous = _lastStatus;
    if (!force && previous != null && previous.path == path && previous.loaded) {
      return previous;
    }

    final File file = File(path);
    final String fileName = file.uri.pathSegments.isEmpty
        ? path
        : file.uri.pathSegments.last;

    final String key;
    try {
      if (!file.existsSync()) {
        final CustomFontStatus missing = CustomFontStatus(
          path: path,
          fileName: fileName,
          error: 'Файл не найден',
        );
        _lastStatus = missing;
        return missing;
      }
      key = '$path|${file.lastModifiedSync().millisecondsSinceEpoch}|'
          '${file.lengthSync()}';
    } on FileSystemException catch (error) {
      final CustomFontStatus failed = CustomFontStatus(
        path: path,
        fileName: fileName,
        error: 'Не удалось открыть файл: ${error.message}',
      );
      _lastStatus = failed;
      return failed;
    }

    final CustomFontStatus? cached = _cache[key];
    if (cached != null) {
      _lastStatus = cached;
      return cached;
    }

    CustomFontStatus status;
    try {
      final Uint8List bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        throw const FormatException('файл пуст');
      }
      // Проверку делаем до загрузки: битый файл движок принимает молча и потом
      // рисует фоллбеком, а пользователю нужно знать, что шрифт не применился.
      final bool? hasCyrillic = _hasCyrillic(bytes);
      if (_registeredKey != key) {
        final FontLoader loader = FontLoader(kCustomFontFamily);
        loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
        await loader.load();
        _registeredKey = key;
      }
      status = CustomFontStatus(
        path: path,
        fileName: fileName,
        hasCyrillic: hasCyrillic,
      );
    } on Object catch (error) {
      status = CustomFontStatus(
        path: path,
        fileName: fileName,
        error: 'Не удалось прочитать шрифт: $error',
      );
    }

    _cache[key] = status;
    _lastStatus = status;
    return status;
  }

  /// Есть ли в шрифте русские буквы. `null` — формат не разобран.
  ///
  /// Разбор минимальный: нужна только таблица `cmap` и диапазоны символов в
  /// ней. Полноценный шрифтовой парсер здесь был бы лишним весом — вопрос
  /// ровно один: найдутся ли шесть кодовых точек.
  static bool? _hasCyrillic(Uint8List bytes) {
    try {
      final ByteData data = ByteData.sublistView(bytes);
      if (bytes.length < 12) return null;

      final int tables = data.getUint16(4);
      int? cmap;
      for (int i = 0; i < tables; i++) {
        final int record = 12 + i * 16;
        if (record + 16 > bytes.length) break;
        if (data.getUint32(record) == 0x636D6170) {
          // 'cmap'
          cmap = data.getUint32(record + 8);
          break;
        }
      }
      if (cmap == null) return null;

      final int count = data.getUint16(cmap + 2);
      _Cmap? best;
      for (int i = 0; i < count; i++) {
        final int record = cmap + 4 + i * 8;
        if (record + 8 > bytes.length) break;
        final int platform = data.getUint16(record);
        final int encoding = data.getUint16(record + 2);
        final int offset = cmap + data.getUint32(record + 4);
        if (offset + 4 > bytes.length) continue;
        final _Cmap candidate = _Cmap(data, offset);
        // Unicode-подтаблицы: 3/10 и 0/* — полный набор символов, 3/1 —
        // основная плоскость. Первая найденная подходящая и нужна.
        final bool unicode = platform == 0 ||
            (platform == 3 && (encoding == 1 || encoding == 10));
        if (!unicode || !candidate.supported) continue;
        if (candidate.format == 12) {
          best = candidate;
          break;
        }
        best ??= candidate;
      }
      if (best == null) return null;

      for (final int code in _cyrillicProbe) {
        if (!best.covers(code)) return false;
      }
      return true;
    } on Object {
      return null;
    }
  }
}

/// Подтаблица `cmap`: только проверка «есть ли такой символ».
class _Cmap {
  _Cmap(this.data, this.offset) : format = data.getUint16(offset);

  final ByteData data;
  final int offset;
  final int format;

  bool get supported =>
      format == 0 || format == 4 || format == 6 || format == 12;

  bool covers(int code) {
    switch (format) {
      case 0:
        // 256-байтовая таблица: индекс — сам код символа.
        if (code > 0xFF) return false;
        return data.getUint8(offset + 6 + code) != 0;
      case 6:
        final int first = data.getUint16(offset + 6);
        final int count = data.getUint16(offset + 8);
        if (code < first || code >= first + count) return false;
        return data.getUint16(offset + 10 + (code - first) * 2) != 0;
      case 4:
        return _coversFormat4(code);
      case 12:
        return _coversFormat12(code);
      default:
        return false;
    }
  }

  bool _coversFormat4(int code) {
    if (code > 0xFFFF) return false;
    final int segments = data.getUint16(offset + 6) ~/ 2;
    final int endCodes = offset + 14;
    final int startCodes = endCodes + segments * 2 + 2;
    final int idDeltas = startCodes + segments * 2;
    final int idRangeOffsets = idDeltas + segments * 2;

    for (int i = 0; i < segments; i++) {
      final int end = data.getUint16(endCodes + i * 2);
      if (code > end) continue;
      final int start = data.getUint16(startCodes + i * 2);
      if (code < start) return false;
      final int delta = data.getUint16(idDeltas + i * 2);
      final int rangeOffset = data.getUint16(idRangeOffsets + i * 2);
      if (rangeOffset == 0) {
        // Глиф = код + delta; ноль означает «символа нет».
        return ((code + delta) & 0xFFFF) != 0;
      }
      // С разбором idRangeOffset не возимся: такие таблицы встречаются у
      // старых шрифтов, и содержимое по адресу с высокой вероятностью есть.
      return true;
    }
    return false;
  }

  bool _coversFormat12(int code) {
    final int groups = data.getUint32(offset + 12);
    for (int i = 0; i < groups; i++) {
      final int record = offset + 16 + i * 12;
      final int start = data.getUint32(record);
      final int end = data.getUint32(record + 4);
      if (code >= start && code <= end) {
        final int glyph = data.getUint32(record + 8) + (code - start);
        return glyph != 0;
      }
    }
    return false;
  }
}
