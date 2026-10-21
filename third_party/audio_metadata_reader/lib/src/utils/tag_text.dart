import 'dart:convert';

import 'package:charset/charset.dart';

/// Доля «кириллических» байтов среди букв, выше которой считаем cp1251.
///
/// В cp1251 байты 0xC0–0xFF — это и заглавные, и строчные русские буквы,
/// поэтому доля у русского текста близка к единице. В latin1 те же байты —
/// редкие акцентированные буквы, и доля обычно мала.
const double _cyrillicShareThreshold = 0.4;

/// Текст тега, декодированный без падений.
///
/// Файлы из реального мира не всегда в UTF-8: у старых русских rip'ов ID3v1
/// записан в cp1251, у самодельных тегов встречаются битые байты. Штатный
/// `utf8.decode` на таком бросает `FormatException`, и файл целиком выпадает из
/// библиотеки вместе с длительностью — это хуже кривых букв.
///
/// Порядок важен: cp1251 декодирует любые байты без ошибки, поэтому «cp1251,
/// затем latin1» всегда заканчивалось бы cp1251 и превращало западные
/// latin1-теги в кириллическую кашу. После неудачи UTF-8 решаем по составу
/// байтов (см. [_looksLikeWindows1251]), и только иначе — latin1.
///
/// Это единственное отличие форка от пакета `audio_metadata_reader` 1.8.1.
String decodeTagText(List<int> bytes) {
  if (bytes.isEmpty) return '';
  try {
    return utf8.decode(bytes);
  } on FormatException {
    // Не UTF-8 — остаётся выбрать между однобайтовыми кодировками.
  }
  if (_looksLikeWindows1251(bytes)) {
    try {
      return windows1251.decode(bytes);
    } on FormatException {
      // В cp1251 байт 0x98 не определён: строка с ним — не cp1251.
      // Ниже latin1 не бросает и не теряет остальные буквы.
    }
  }
  return latin1.decode(bytes, allowInvalid: true);
}

/// Похожи ли байты на текст в cp1251?
///
/// Считаем только буквы: ASCII-буквы всегда латиница, байты 0xC0–0xFF в cp1251
/// — кириллица (в latin1 — акцентированные латинские буквы). Цифры, пробелы и
/// пунктуацию не учитываем, чтобы «ДДТ — 2024» не склонялось к latin1 из-за
/// короткого текста. Если кириллических букв больше [_cyrillicShareThreshold],
/// это cp1251: западная latin1-строка почти всегда состоит в основном из ASCII.
///
/// Одной доли мало для коротких слов: «Été» в latin1 — две акцентированные
/// буквы из трёх. У кириллицы буквы слова идут подряд, поэтому требуем ещё и
/// пару соседних «кириллических» байтов: в «Été» таких пар нет, в «Тест» —
/// одна длиной в слово.
bool _looksLikeWindows1251(List<int> bytes) {
  int cyrillic = 0;
  int latin = 0;
  int run = 0;
  int longestRun = 0;
  for (final int byte in bytes) {
    if (_isCyrillicByte(byte)) {
      cyrillic++;
      run++;
      if (run > longestRun) longestRun = run;
      continue;
    }
    run = 0;
    if ((byte >= 0x41 && byte <= 0x5A) ||
        (byte >= 0x61 && byte <= 0x7A)) {
      latin++;
    }
  }
  if (cyrillic == 0) return false;
  return longestRun >= 2 &&
      cyrillic / (cyrillic + latin) > _cyrillicShareThreshold;
}

/// Байт, который в cp1251 — кириллическая буква.
///
/// Диапазон 0xC0–0xFF — А–Я и а–я; отдельно стоят Ё и ё, без которых короткое
/// «Ёж» выглядело бы латиницей.
bool _isCyrillicByte(int byte) =>
    byte >= 0xC0 || byte == 0xA8 || byte == 0xB8;

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
