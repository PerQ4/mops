/// Знание о встроенном плеере YouTube: адреса, заголовки запроса и признаки
/// отказа.
///
/// Почему отдельным файлом: это правила YouTube, а не разметка экрана. Их
/// удобно держать рядом и объяснять проверенным поведением сервиса, а не
/// догадками (см. комментарии ниже — все тексты и значения сняты с реальных
/// ответов YouTube).
library;

/// Домен, с которого открывается страница клипа.
///
/// Основной адрес — обычный `www.youtube.com`. Запасной —
/// `www.youtube-nocookie.com`: он не отправляет cookie YouTube до начала
/// воспроизведения. Требование к заголовку `Referer` у обоих доменов
/// одинаковое, поэтому nocookie — именно вторая попытка, а не другой способ
/// обойти отказ.
enum ClipEmbedHost {
  youTube('www.youtube.com'),
  youTubeNoCookie('www.youtube-nocookie.com');

  const ClipEmbedHost(this.host);

  /// Домен страницы клипа.
  final String host;
}

/// Значение заголовка `Referer` для запроса страницы клипа.
///
/// Без него YouTube отвечает «Ошибка 153»: отказ виден уже в исходном HTML —
/// `previewPlayabilityStatus` с текстом «Ошибка настройки видеопроигрывателя.»
/// и «Ошибка 153» (в английской версии — «Video player configuration error» /
/// «Error 153»). Причина в том, что WebView открывает `/embed/...` напрямую,
/// и у запроса нет ни `Referer`, ни `document.referrer`, по которым YouTube
/// понимает, с какого сайта показывают клип.
///
/// Проверено вручную (запрос страницы `/embed/<id>` с этим заголовком):
/// с `https://music.youtube.com/` плеер отдаётся нормально. А вот
/// `https://www.youtube.com/` брать нельзя: YouTube видит, что встраивает сам
/// себя, и отвечает «Код ошибки: 152 - 4». Поэтому берём `music.youtube.com` —
/// mOps и есть клиент YouTube Music, все его ссылки ведут туда же.
///
/// Параметр `origin` в адресе embed не помогает: запрос с одним лишь
/// `?origin=...` всё равно получает «Ошибку 153». Лечит именно заголовок.
const String clipReferer = 'https://music.youtube.com/';

/// Адрес страницы клипа во встроенном плеере.
///
/// `autoplay=1` запускает клип сразу, `rel=0` убирает чужие видео в конце.
String clipEmbedUrl(String videoId, ClipEmbedHost host) =>
    'https://${host.host}/embed/$videoId?autoplay=1&rel=0';

/// Заголовки запроса страницы клипа.
Map<String, String> clipEmbedHeaders() => <String, String>{
      'Referer': clipReferer,
    };

/// Признаки того, что встроенный плеер отказался играть клип.
///
/// Тексты сняты с реальных страниц отказа, русской и английской:
///  * нет `Referer` — «Ошибка настройки видеопроигрывателя.» / «Ошибка 153»
///    и «Video player configuration error» / «Error 153»;
///  * встраивает сам YouTube — «Код ошибки: 152 - 4» / «Error code: 152 - 4»;
///  * видео запрещено к встраиванию — кнопка «Посмотреть видео на YouTube» /
///    «Watch video on YouTube» (в старом оформлении — «Смотреть на YouTube» /
///    «Watch on YouTube»).
///
/// Заведомо узкие строки, а не просто «Ошибка»: иначе отказ ловился бы на
/// клипе, в названии которого есть это слово, и рабочий плеер закрывался бы
/// сообщением об ошибке.
const List<String> clipRefusalMarkers = <String>[
  'error 153',
  'ошибка 153',
  'video player configuration error',
  'ошибка настройки видеопроигрывателя',
  'error code: 152',
  'код ошибки: 152',
  'watch video on youtube',
  'посмотреть видео на youtube',
  'watch on youtube',
  'смотреть на youtube',
];

/// Отказался ли плеер играть клип — по заголовку и тексту страницы.
bool clipLooksRefused(String title, String bodyText) {
  final String haystack = '$title\n$bodyText'.toLowerCase();
  return clipRefusalMarkers.any(haystack.contains);
}

/// Забирает заголовок и текст страницы, чтобы проверить её на отказ.
///
/// Возвращает объект, а не строку: `evaluateJavascript` разбирает ответ как
/// JSON, и так заголовок и текст не приходится склеивать и разрезать обратно.
/// Текст обрезаем: страница клипа весит сотни килобайт, а признаки отказа
/// лежат в самом начале.
const String clipProbeScript = '''
(function () {
  try {
    var text = document.body && document.body.innerText ? document.body.innerText : '';
    return { title: document.title || '', text: text.slice(0, 4000) };
  } catch (e) {
    return { title: '', text: '' };
  }
})()
''';

/// Заголовок и текст страницы клипа.
class ClipPageProbe {
  const ClipPageProbe({required this.title, required this.text});

  /// Заголовок страницы.
  final String title;

  /// Видимый текст страницы (обрезан).
  final String text;
}

/// Разбирает ответ на [clipProbeScript].
///
/// Если платформа вернула не объект (например, сбой самого скрипта), считаем
/// весь ответ текстом — так отказ всё равно заметим, а не пропустим молча.
ClipPageProbe clipParseProbe(Object? value) {
  if (value is Map) {
    return ClipPageProbe(
      title: value['title']?.toString() ?? '',
      text: value['text']?.toString() ?? '',
    );
  }
  return ClipPageProbe(title: '', text: value?.toString() ?? '');
}
