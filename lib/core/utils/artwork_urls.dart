/// Работа с обложками YouTube.
///
/// Размер обложки зашит в её адрес, и YouTube отдаёт копию любого размера,
/// если поменять его в ссылке. Это точнее, чем выбирать «самую большую из
/// списка»: в разметке часто лежат только мелкие, и крупный вид получался
/// растянутым и мутным.
library;

import 'package:flutter/foundation.dart';

/// Размер для открытого вида: полноэкранный плеер, шапки страниц.
const int kArtworkLarge = 1024;

/// Предел стороны обложки в режиме низкого трафика (задача 6.2).
///
/// 226 — один из реальных размеров YouTube (`w226-h226`): заметно меньше
/// 1024 у открытого вида, но картинка остаётся читаемой. Размеры меньше
/// предела не увеличиваются — режим только понижает запрос.
const int kArtworkLowData = 226;

/// Включён ли сейчас режим низкого трафика.
///
/// Утилиты обложек вызываются из моделей и виджетов, куда не дотянуться
/// `ref`, поэтому настройка живёт здесь общей переменной. `ValueNotifier`
/// ещё и перерисовывает обложки, когда переключатель в настройках срабатывает.
final ValueNotifier<bool> artworkLowDataMode = ValueNotifier<bool>(false);

/// Понижает запрошенный размер до предела низкого режима.
int artworkSizeFor(int size) =>
    artworkLowDataMode.value && size > kArtworkLowData
        ? kArtworkLowData
        : size;

/// Размер для карточек карусели.
/// Размер обложки для карточек сетки.
///
/// Карточка занимает 128–180 логических пикселей, то есть даже при плотности
/// 1.5 нужно около 270. 512 давал вчетверо больше пикселей и памяти — на
/// лентах с десятками карточек это заметно тормозило отрисовку.
const int kArtworkCard = 256;

/// Размер для строки списка.
const int kArtworkRow = 256;

/// Классы превью на `i.ytimg.com` и их ширина.
const List<(String, int)> _ytimgClasses = <(String, int)>[
  ('default', 120),
  ('mqdefault', 320),
  ('hqdefault', 480),
  ('sddefault', 640),
  ('maxresdefault', 1280),
];

/// Подбирает класс превью не меньше запрошенного размера.
String _ytimgClassFor(int size) {
  for (final (String name, int width) in _ytimgClasses) {
    if (width >= size) return name;
  }
  return 'maxresdefault';
}

bool _isYtimg(String url) => url.contains('ytimg.com/vi/');

String _swapYtimgClass(String url, String name) {
  return url.replaceFirstMapped(
    RegExp(r'/(default|mqdefault|hqdefault|sddefault|maxresdefault)(\.\w+)$'),
    (Match match) => '/$name${match.group(2)}',
  );
}

/// Имя класса превью в адресе `i.ytimg.com`, иначе пустая строка.
String _ytimgClassIn(String url) {
  final RegExpMatch? match = RegExp(
    r'/(default|mqdefault|hqdefault|sddefault|maxresdefault)\.\w+$',
  ).firstMatch(url);
  return match?.group(1) ?? '';
}

/// Ширина класса превью по [name], 0 — класс неизвестен.
int _ytimgWidth(String name) {
  for (final (String className, int width) in _ytimgClasses) {
    if (className == name) return width;
  }
  return 0;
}

/// Переписывает размер в ссылке на обложку.
///
/// Поддерживаются оба вида адресов:
///  * `https://lh3.googleusercontent.com/...=w120-h120-l90-rj`
///  * `https://i.ytimg.com/vi/<id>/mqdefault.jpg`
///
/// Если формат незнаком, ссылка возвращается как есть. В режиме низкого
/// трафика запрошенный размер понижается до [kArtworkLowData].
String upgradeArtwork(String url, int size) {
  if (url.isEmpty) return url;

  final int target = artworkSizeFor(size);
  final RegExpMatch? wh = RegExp(r'=w(\d+)-h(\d+)').firstMatch(url);
  if (wh != null) {
    return url.replaceRange(wh.start, wh.end, '=w$target-h$target');
  }
  final RegExpMatch? s = RegExp(r'=s(\d+)$').firstMatch(url);
  if (s != null) {
    return url.replaceRange(s.start, s.end, '=s$target');
  }
  if (_isYtimg(url)) {
    return _swapYtimgClass(url, _ytimgClassFor(target));
  }
  return url;
}

/// Понижает размер, уже стоящий в адресе, не увеличивая его.
///
/// Нужен там, где адрес пришёл готовым (обложка из снимка очереди, ссылка из
/// разметки): [upgradeArtwork] привёл бы его к заданному размеру, а здесь
/// важно только не тянуть больше [kArtworkLowData]. Пропорция сохраняется:
/// обе стороны уменьшаются на один множитель.
String shrinkArtwork(String url) {
  if (url.isEmpty || !artworkLowDataMode.value) return url;

  final RegExpMatch? wh = RegExp(r'=w(\d+)-h(\d+)').firstMatch(url);
  if (wh != null) {
    final int width = int.tryParse(wh.group(1)!) ?? 0;
    final int height = int.tryParse(wh.group(2)!) ?? 0;
    final int longest = width > height ? width : height;
    if (longest <= kArtworkLowData) return url;
    final double scale = kArtworkLowData / longest;
    final int newWidth = (width * scale).round().clamp(1, kArtworkLowData);
    final int newHeight = (height * scale).round().clamp(1, kArtworkLowData);
    return url.replaceRange(wh.start, wh.end, '=w$newWidth-h$newHeight');
  }
  final RegExpMatch? s = RegExp(r'=s(\d+)$').firstMatch(url);
  if (s != null) {
    final int side = int.tryParse(s.group(1)!) ?? 0;
    if (side <= kArtworkLowData) return url;
    return url.replaceRange(s.start, s.end, '=s$kArtworkLowData');
  }
  if (_isYtimg(url)) {
    // `default` (120×90) и `hqdefault`/`sddefault` (4:3) дают другую
    // пропорцию, чем исходное 16:9-превью, поэтому в низком режиме
    // останавливаемся на `mqdefault` — наименьшем классе 16:9.
    final String current = _ytimgClassIn(url);
    if (current.isEmpty ||
        _ytimgWidth(current) <= kArtworkLowData ||
        current == 'mqdefault') {
      return url;
    }
    return _swapYtimgClass(url, 'mqdefault');
  }
  return url;
}

/// Ссылки от лучшей к худшей — на случай, если максимального превью нет.
///
/// У части видео `maxresdefault` отсутствует, и сервер отвечает 404.
/// Перебор по убыванию даёт картинку в любом случае.
List<String> artworkVariants(String url, int size) {
  final String upgraded = upgradeArtwork(url, size);
  final List<String> result = <String>[upgraded];

  if (!_isYtimg(url)) return result;

  final String current = _ytimgClassFor(artworkSizeFor(size));
  final int index = _ytimgClasses
      .indexWhere(((String, int) c) => c.$1 == current)
      .clamp(0, _ytimgClasses.length - 1);
  final bool lowData = artworkLowDataMode.value;

  // Ниже по списку — меньше размер. В низком режиме классы мельче предела
  // не добавляем: это либо 4:3-кадры (`default`), либо лишний запрос.
  for (int i = index - 1; i >= 0; i--) {
    if (lowData && _ytimgClasses[i].$2 < kArtworkLowData) continue;
    final String variant = _swapYtimgClass(url, _ytimgClasses[i].$1);
    if (variant != upgraded && !result.contains(variant)) {
      result.add(variant);
    }
  }
  return result;
}
