import 'dart:convert';

import 'package:charset/charset.dart';

/// Текст тега, декодированный без падений.
///
/// Файлы из реального мира не всегда в UTF-8: у старых русских rip'ов ID3v1
/// записан в cp1251, у самодельных тегов встречаются битые байты. Штатный
/// `utf8.decode` на таком бросает `FormatException`, и файл целиком выпадает из
/// библиотеки вместе с длительностью — это хуже кривых букв. Поэтому пробуем
/// UTF-8, затем cp1251, затем latin1 с заменой невалидных байт.
///
/// Это единственное отличие форка от пакета `audio_metadata_reader` 1.8.1.
String decodeTagText(List<int> bytes) {
  if (bytes.isEmpty) return '';
  try {
    return utf8.decode(bytes);
  } on FormatException {
    // Не UTF-8 — значит скорее всего cp1251: так писали теги до середины
    // двухтысячных, и таких файлов много.
  }
  try {
    return windows1251.decode(bytes);
  } catch (_) {
    return latin1.decode(bytes, allowInvalid: true);
  }
}

/// Число из тега, где может стоять что угодно: «12», «12/12», «12 из 12».
///
/// Штатный `int.parse` на «12/12» бросает исключение и роняет чтение всего
/// файла — вместе с тегами и длительностью. Берём первое число: остальное к
/// нашей модели отношения не имеет.
int? parseTagInt(String? value) {
  if (value == null) return null;
  final RegExpMatch? match = RegExp(r'\d+').firstMatch(value);
  if (match == null) return null;
  return int.tryParse(match.group(0)!);
}
