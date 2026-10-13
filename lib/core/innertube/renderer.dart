/// Утилиты обхода ответов InnerTube.
///
/// InnerTube отдаёт глубоко вложенные структуры вида
/// `contents.singleColumnMusicWatchNextResultsRenderer.tabbedRenderer...`,
/// где на каждом уровне может лежать либо объект, либо список объектов.
/// Эти помощники позволяют писать парсеры без ручных проверок на тип.
library;

/// Возвращает список значений по пути `keys`.
///
/// На каждом шаге: если текущее значение — список, рекурсивно спускается
/// по всем его элементам; если карта — берёт значение по ключу.
/// Результат — плоский список всех найденных значений.
List<dynamic> traverseList(dynamic node, List<String> keys) {
  final List<dynamic> found = <dynamic>[];
  _walk(node, keys, 0, found);
  return found;
}

void _walk(dynamic node, List<String> keys, int index, List<dynamic> out) {
  if (node == null) return;
  if (index >= keys.length) {
    if (node is List) {
      out.addAll(node);
    } else {
      out.add(node);
    }
    return;
  }

  if (node is List) {
    for (final dynamic item in node) {
      _walk(item, keys, index, out);
    }
    return;
  }

  if (node is Map) {
    final String key = keys[index];
    if (node.containsKey(key)) {
      _walk(node[key], keys, index + 1, out);
    } else {
      // Ключа нет на этом уровне — ищем глубже, чтобы не терять данные
      // при небольших изменениях схемы ответа.
      for (final dynamic value in node.values) {
        if (value is Map || value is List) {
          _walk(value, keys, index, out);
        }
      }
    }
  }
}

/// Первое найденное значение по пути (или `null`).
dynamic traverse(dynamic node, List<String> keys) {
  final List<dynamic> all = traverseList(node, keys);
  return all.isEmpty ? null : all.first;
}

/// Первая найденная строка по пути.
String? traverseString(dynamic node, List<String> keys) {
  final dynamic value = traverse(node, keys);
  return value is String ? value : null;
}

/// Все строки, найденные по пути.
List<String> traverseStrings(dynamic node, List<String> keys) {
  return traverseList(node, keys).whereType<String>().toList();
}

/// Возвращает строку по первому пути из `candidates`, который дал результат.
String? traverseFirstString(dynamic node, List<List<String>> candidates) {
  for (final List<String> path in candidates) {
    final String? value = traverseString(node, path);
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

/// Достаёт `runs`-текст: некоторые поля приходят как `{"runs":[{"text":"..."}]}`,
/// другие как `{"simpleText":"..."}`.
String? textOf(dynamic node) {
  if (node == null) return null;
  if (node is String) return node;
  if (node is Map) {
    final dynamic simple = node['simpleText'];
    if (simple is String && simple.isNotEmpty) return simple;

    final dynamic runs = node['runs'];
    if (runs is List) {
      final String joined = runs
          .whereType<Map>()
          .map((Map run) => run['text']?.toString() ?? '')
          .join();
      if (joined.isNotEmpty) return joined;
    }

    final dynamic text = node['text'];
    if (text is String && text.isNotEmpty) return text;
  }
  return null;
}

/// Парсит строку длительности (`3:45`, `1:02:33`) в `Duration`.
Duration? parseDurationText(String? text) {
  if (text == null) return null;
  final String cleaned = text.trim();
  if (cleaned.isEmpty) return null;

  final List<String> parts = cleaned.split(':');
  if (parts.length < 2 || parts.length > 3) return null;

  final List<int?> nums =
      parts.map((String p) => int.tryParse(p.trim())).toList();
  if (nums.any((int? n) => n == null)) return null;

  int seconds = 0;
  for (final int? n in nums) {
    seconds = seconds * 60 + n!;
  }
  return Duration(seconds: seconds);
}

/// Убирает приписки вида «1.2M views», «2.3 млн прослушиваний» — оставляет число с единицей.
String? cleanCount(String? text) => text?.trim();
