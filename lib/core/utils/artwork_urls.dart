/// Работа с обложками YouTube.
///
/// Размер обложки зашит в её адрес, и YouTube отдаёт копию любого размера,
/// если поменять его в ссылке. Это точнее, чем выбирать «самую большую из
/// списка»: в разметке часто лежат только мелкие, и крупный вид получался
/// растянутым и мутным.
library;

/// Размер для открытого вида: полноэкранный плеер, шапки страниц.
const int kArtworkLarge = 1024;

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
  return url.replaceFirst(
    RegExp(r'/(default|mqdefault|hqdefault|sddefault|maxresdefault)(\.\w+)$'),
    '/$name\$2',
  );
}

/// Переписывает размер в ссылке на обложку.
///
/// Поддерживаются оба вида адресов:
///  * `https://lh3.googleusercontent.com/...=w120-h120-l90-rj`
///  * `https://i.ytimg.com/vi/<id>/mqdefault.jpg`
///
/// Если формат незнаком, ссылка возвращается как есть.
String upgradeArtwork(String url, int size) {
  if (url.isEmpty) return url;

  final RegExpMatch? wh = RegExp(r'=w(\d+)-h(\d+)').firstMatch(url);
  if (wh != null) {
    return url.replaceRange(wh.start, wh.end, '=w$size-h$size');
  }
  final RegExpMatch? s = RegExp(r'=s(\d+)$').firstMatch(url);
  if (s != null) {
    return url.replaceRange(s.start, s.end, '=s$size');
  }
  if (_isYtimg(url)) {
    return _swapYtimgClass(url, _ytimgClassFor(size));
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

  final String current = _ytimgClassFor(size);
  final int index = _ytimgClasses
      .indexWhere(((String, int) c) => c.$1 == current)
      .clamp(0, _ytimgClasses.length - 1);

  // Ниже по списку — меньше размер.
  for (int i = index - 1; i >= 0; i--) {
    final String variant = _swapYtimgClass(url, _ytimgClasses[i].$1);
    if (variant != upgraded && !result.contains(variant)) {
      result.add(variant);
    }
  }
  return result;
}
