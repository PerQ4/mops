/// Безопасное чтение полей JSON-настроек.
///
/// Домены читают сохранённые значения через эти функции, а не через `as`.
/// Причина: одно поле неверного типа (ручная правка prefs, бэкап от чужой
/// версии) бросало `TypeError` ещё до `runApp`, и приложение не запускалось
/// вовсе. Здесь неверный тип — это дефолт конкретного поля, а не падение.
library;

/// Строка; значение другого типа — [fallback].
String readString(Object? value, String fallback) =>
    value is String ? value : fallback;

/// Да/нет; значение другого типа — [fallback].
///
/// Строки «true» и «yes» намеренно не угадываются: тип должен совпадать с тем,
/// что пишет `toJson`, иначе непонятно, чему верить в испорченном файле.
bool readBool(Object? value, bool fallback) => value is bool ? value : fallback;

/// Целое; `num` приводим, всё остальное — [fallback].
int readInt(Object? value, int fallback) =>
    value is num ? value.toInt() : fallback;

/// Дробное; `num` приводим, всё остальное — [fallback].
double readDouble(Object? value, double fallback) =>
    value is num ? value.toDouble() : fallback;

/// Список строк из строки через запятую или из JSON-массива.
///
/// `null` — значения нет или тип не тот: вызывающий сам решает, что считать
/// дефолтом. Пустая строка — это пустой список, а не «нет значения»: так
/// хранится осознанный выбор «не выбрано ничего» (например, все категории
/// SponsorBlock сняты).
List<String>? readStringList(Object? value) {
  if (value is String) {
    return value
        .split(',')
        .map((String part) => part.trim())
        .where((String part) => part.isNotEmpty)
        .toList(growable: false);
  }
  if (value is List) {
    final List<String> parts = <String>[
      for (final Object? item in value)
        if (item is String && item.trim().isNotEmpty) item.trim(),
    ];
    // Массив целиком из не-строк — тоже неверный тип, а не пустой выбор.
    if (parts.isEmpty && value.isNotEmpty) return null;
    return parts;
  }
  return null;
}

/// Значение перечисления по имени; неизвестное имя или не строка — [fallback].
T readEnumByName<T extends Enum>(Object? value, List<T> values, T fallback) {
  if (value is! String) return fallback;
  for (final T item in values) {
    if (item.name == value) return item;
  }
  return fallback;
}
