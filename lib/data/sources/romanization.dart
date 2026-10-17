import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Романизация текста — латиница для песен на японском, корейском, китайском,
/// хинди и других языках с нелатинской письменностью.
///
/// Перевод при этом НЕ делается: нужен именно «слепок» произношения, чтобы
/// читать незнакомый текст, а не подмена смысла. Механизм повторяет ArchiveTune
/// (`lyrics/LyricsUtils.kt`): язык определяется по самому тексту, а не выбирается
/// пользователем, и романизация считается по строке, а не по всему тексту.
///
/// Готового офлайн-транслитератора в Dart нет, поэтому строку отправляем
/// публичному эндпоинту Google Translate с `dt=rm` (транслитерация) и
/// `tl=<язык>-Latn`. Так сервис не переводит текст, а записывает произношение.
class RomanizationService {
  RomanizationService({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  static const String _host =
      'https://translate.googleapis.com/translate_a/single';

  /// Только ASCII: заголовки HTTP кодируются как latin-1, и кириллица в
  /// `User-Agent` уронила бы запрос ещё до отправки.
  static const String _userAgent = 'mOps/1.0 (YouTube Music client)';

  /// Кэш по треку: за один и тот же текст второй раз в сеть не идём.
  /// Сигнатура отличает тексты одного трека, пришедшие из разных источников.
  final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};

  /// Предел кэша: помним романизацию последних треков.
  static const int _maxCacheEntries = 32;

  final Random _random = Random();

  /// Романизирует строки и возвращает соответствие «номер строки → латиница».
  ///
  /// Строки группируются по цели (язык/письменность), и на каждую группу уходит
  /// один запрос: по одному запросу на строку сервис упёрся бы в лимит уже на
  /// пятидесяти строках. Если сервис недоступен или ничего не романизировалось —
  /// отдаём `null`, и текст показывается без романизации.
  Future<Map<int, String>?> romanize({
    required String videoId,
    required RomanizationOptions options,
    required List<String> lines,
  }) async {
    // Пустые строки в запрос не отправляем: сервис схлопывает их сам, и
    // соответствие строкам после этого поехало бы.
    final List<int> indexes = <int>[
      for (int i = 0; i < lines.length; i++)
        if (lines[i].trim().isNotEmpty) i,
    ];
    if (indexes.isEmpty) return null;

    // Ключ включает и текст, и набор включённых языков: при смене настроек
    // результат пересчитывается, а не берётся из старого кэша.
    final String key = '$videoId|${options.cacheKey}';
    final int signature = Object.hash(Object.hashAll(lines), lines.length);
    final _CacheEntry? cached = _cache[key];
    if (cached != null && cached.signature == signature) return cached.value;

    // Группируем строки по цели: у каждой группы свой `sl`/`tl`, поэтому одним
    // запросом их не объединить.
    final Map<RomanizationTarget, List<int>> groups =
        <RomanizationTarget, List<int>>{};
    for (final int i in indexes) {
      final RomanizationTarget? target = detectRomanizationTarget(lines[i]);
      if (target == null || !options.allows(target.group)) continue;
      groups.putIfAbsent(target, () => <int>[]).add(i);
    }
    if (groups.isEmpty) return null;

    final Map<int, String> mapped = <int, String>{};
    for (final MapEntry<RomanizationTarget, List<int>> group in groups.entries) {
      final List<int> groupIndexes = group.value;
      final List<String> groupLines = <String>[
        for (final int i in groupIndexes) lines[i],
      ];
      final List<String?> parts = await _romanizeGroup(group.key, groupLines);
      for (int i = 0; i < groupIndexes.length; i++) {
        final String? part = parts[i];
        if (part != null && part.isNotEmpty) mapped[groupIndexes[i]] = part;
      }
    }

    // Совсем ничего не вышло — не кэшируем: сервис мог просто не ответить, и
    // следующий показ текста честно попробует снова.
    if (mapped.isEmpty) return null;

    // Ограничиваем кэш: за долгую сессию треков много, а хранить романизацию
    // всех незачем — она восстанавливается одним запросом.
    if (_cache.length >= _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = _CacheEntry(signature, mapped);
    return mapped;
  }

  /// Романизация одной группы строк. Обычно хватает одного запроса, но если
  /// сервис вернул не то число частей — спрашиваем строки поштучно.
  Future<List<String?>> _romanizeGroup(
    RomanizationTarget target,
    List<String> lines,
  ) async {
    if (lines.length == 1) {
      final String? single = await _ask(lines.first, target);
      return <String?>[single?.trim()];
    }

    final String separator = _uniqueSeparator(lines);
    final String? joined = await _ask(lines.join(separator), target);
    if (joined != null) {
      final List<String> parts = joined.split(separator);
      // Число частей совпало — границы строк сервис не склеил, раскладываем.
      if (parts.length == lines.length) {
        return <String?>[for (final String part in parts) part.trim()];
      }
    }

    // Единственный допустимый откат: сервис мог изменить границы строк, и
    // сдвинутая романизация хуже, чем её отсутствие. Проходим поштучно.
    final List<String?> fallback = List<String?>.filled(lines.length, null);
    for (int i = 0; i < lines.length; i++) {
      fallback[i] = await _ask(lines[i], target);
    }
    return fallback;
  }

  /// Разделитель, которого нет ни в одной строке группы: иначе разбить ответ
  /// обратно по строкам было бы нельзя.
  String _uniqueSeparator(List<String> lines) {
    while (true) {
      final String separator = '<<<SEP-${_randomToken()}>>>';
      if (!lines.any((String line) => line.contains(separator))) {
        return separator;
      }
    }
  }

  String _randomToken() {
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < 32; i++) {
      buffer.write(_random.nextInt(16).toRadixString(16));
    }
    return buffer.toString();
  }

  /// Просит транслитерацию одной порции текста.
  Future<String?> _ask(String text, RomanizationTarget target) async {
    try {
      final Uri uri = Uri.parse(_host).replace(
        queryParameters: <String, dynamic>{
          'client': 'gtx',
          'sl': target.source,
          'tl': target.target,
          // `dt` повторяется: `t` — сам ответ, `rm` — транслитерация.
          'dt': <String>['t', 'rm'],
          'q': text,
        },
      );

      final HttpClientRequest request = await _client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final HttpClientResponse response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }

      final String body = await response.transform(utf8.decoder).join();
      final dynamic decoded = jsonDecode(body);
      if (decoded is! List || decoded.isEmpty) return null;

      final dynamic chunks = decoded[0];
      if (chunks is! List) return null;

      // Ответ — массив кусков, где романизация лежит в четвёртом элементе
      // (`[0][*][3]`); склеиваем все непустые куски в один текст.
      final StringBuffer buffer = StringBuffer();
      for (final dynamic chunk in chunks) {
        if (chunk is List && chunk.length > 3 && chunk[3] is String) {
          buffer.write(chunk[3] as String);
        }
      }
      final String result = buffer.toString();
      return result.isEmpty ? null : result;
    } on Object {
      // Сервис может быть недоступен — это не ошибка приложения.
      return null;
    }
  }

  void dispose() => _client.close(force: true);
}

/// Вид романизации — по нему берётся переключатель в настройках.
///
/// Пять групп ровно как `LyricsRomanize*Key` в ArchiveTune
/// (`lyrics/LyricsUtils.kt`).
enum RomanizationGroup { japanese, korean, chinese, hindi, other }

/// Включённые виды романизации.
///
/// Отдельный класс с равенством по значению: так набор переключателей можно
/// положить в ключ провайдера, и повторная отрисовка не тянет сеть заново.
class RomanizationOptions {
  const RomanizationOptions({
    this.japanese = true,
    this.korean = true,
    this.chinese = true,
    this.hindi = true,
    this.other = true,
  });

  final bool japanese;
  final bool korean;
  final bool chinese;
  final bool hindi;
  final bool other;

  /// Хоть что-то включено — иначе запрос к сервису не нужен.
  bool get isEnabled => japanese || korean || chinese || hindi || other;

  bool allows(RomanizationGroup group) => switch (group) {
        RomanizationGroup.japanese => japanese,
        RomanizationGroup.korean => korean,
        RomanizationGroup.chinese => chinese,
        RomanizationGroup.hindi => hindi,
        RomanizationGroup.other => other,
      };

  /// Подпись набора для кэша сервиса.
  String get cacheKey => <String>[
        if (japanese) 'ja',
        if (korean) 'ko',
        if (chinese) 'zh',
        if (hindi) 'hi',
        if (other) 'other',
      ].join(',');

  @override
  bool operator ==(Object other) =>
      other is RomanizationOptions &&
      other.japanese == japanese &&
      other.korean == korean &&
      other.chinese == chinese &&
      other.hindi == hindi &&
      other.other == this.other;

  @override
  int get hashCode => Object.hash(japanese, korean, chinese, hindi, other);
}

/// Цель романизации строки: к какой группе относится и с какими кодами идти
/// в сервис.
///
/// `source` — исходный язык (`sl`), `target` — куда транслитерировать (`tl`).
class RomanizationTarget {
  const RomanizationTarget(this.group, this.source, this.target);

  final RomanizationGroup group;
  final String source;
  final String target;

  @override
  bool operator ==(Object other) =>
      other is RomanizationTarget &&
      other.group == group &&
      other.source == source &&
      other.target == target;

  @override
  int get hashCode => Object.hash(group, source, target);
}

/// Определяет по тексту строки, что и как романизировать.
///
/// Порядок проверок как в ArchiveTune (`shouldRomanizeLyricsLine`): японский →
/// корейский → хинди → китайский → прочие. Именно такой порядок важен: строка с
/// каной и иероглифами — японская, а не китайская, хотя иероглифы есть в обеих.
/// `null` — романизировать нечего (латиница, цифры, неизвестная письменность).
RomanizationTarget? detectRomanizationTarget(String text) {
  bool hasKana = false;
  bool hasHangul = false;
  bool hasHan = false;
  bool hasDevanagari = false;
  String? otherCode;

  for (final int rune in text.runes) {
    if (_isKana(rune) || rune == 0x3005 /* 々 */ || rune == 0x3006 /* 〆 */) {
      hasKana = true;
      continue;
    }
    if (rune >= 0xAC00 && rune <= 0xD7A3) {
      hasHangul = true;
      continue;
    }
    if (rune >= 0x0900 && rune <= 0x097F) {
      hasDevanagari = true;
      continue;
    }
    if (_isHan(rune)) {
      hasHan = true;
      continue;
    }
    // «Прочие» — письменности вне исключённого набора. Язык берём по письменности;
    // если её нет в списке поддерживаемых — романизации для строки нет.
    otherCode ??= _otherLanguageCode(rune);
  }

  if (hasKana) {
    return const RomanizationTarget(RomanizationGroup.japanese, 'ja', 'ja-Latn');
  }
  if (hasHangul) {
    return const RomanizationTarget(RomanizationGroup.korean, 'ko', 'ko-Latn');
  }
  if (hasDevanagari) {
    return const RomanizationTarget(RomanizationGroup.hindi, 'hi', 'hi-Latn');
  }
  // Китайский — только иероглифы без каны и хангыля (иначе это японский).
  if (hasHan) {
    // ВАЖНО: цель `zh-Latn`, а не `zh-CN-Latn`: второй вариант заставляет
    // сервис переводить текст вместо транслитерации.
    return const RomanizationTarget(RomanizationGroup.chinese, 'zh-CN', 'zh-Latn');
  }
  if (otherCode == null) return null;
  return RomanizationTarget(
    RomanizationGroup.other,
    otherCode,
    '$otherCode-Latn',
  );
}

/// Хирагана и катакана (вместе с фонетическими расширениями).
bool _isKana(int rune) =>
    (rune >= 0x3040 && rune <= 0x309F) ||
    (rune >= 0x30A0 && rune <= 0x30FF) ||
    (rune >= 0x31F0 && rune <= 0x31FF);

/// Иероглифы Han (CJK) — общие для китайского и японского.
bool _isHan(int rune) =>
    (rune >= 0x4E00 && rune <= 0x9FFF) ||
    (rune >= 0x3400 && rune <= 0x4DBF) ||
    (rune >= 0xF900 && rune <= 0xFAFF) ||
    (rune >= 0x20000 && rune <= 0x2A6DF) ||
    (rune >= 0x2F800 && rune <= 0x2FA1F);

/// Язык по письменности для группы «прочие».
///
/// Поддерживаются те языки, у которых Google Translate умеет `*-Latn`
/// (проверено вживую). Неизвестная письменность возвращает `null`.
String? _otherLanguageCode(int rune) {
  if (_inRange(rune, 0x0E00, 0x0E7F)) return 'th'; // тайский
  if (_inRange(rune, 0x0E80, 0x0EFF)) return 'lo'; // лаосский
  if (_inRange(rune, 0x1780, 0x17FF) || _inRange(rune, 0x19E0, 0x19FF)) {
    return 'km'; // кхмерский
  }
  if (_inRange(rune, 0x1000, 0x109F) || _inRange(rune, 0xAA60, 0xAA7F)) {
    return 'my'; // бирманский
  }
  if (_inRange(rune, 0x0D80, 0x0DFF)) return 'si'; // сингальский
  if (_inRange(rune, 0x0A00, 0x0A7F)) return 'pa'; // панджаби (гурмукхи)
  if (_inRange(rune, 0x0A80, 0x0AFF)) return 'gu'; // гуджарати
  if (_inRange(rune, 0x0980, 0x09FF)) return 'bn'; // бенгальский
  if (_inRange(rune, 0x0B80, 0x0BFF)) return 'ta'; // тамильский
  if (_inRange(rune, 0x0C00, 0x0C7F)) return 'te'; // телугу
  if (_inRange(rune, 0x0C80, 0x0CFF)) return 'kn'; // каннада
  if (_inRange(rune, 0x0D00, 0x0D7F)) return 'ml'; // малаялам
  if (_inRange(rune, 0x0590, 0x05FF) || _inRange(rune, 0xFB1D, 0xFB4F)) {
    return 'he'; // иврит
  }
  if (_inRange(rune, 0x0600, 0x06FF) ||
      _inRange(rune, 0x0750, 0x077F) ||
      _inRange(rune, 0x08A0, 0x08FF) ||
      _inRange(rune, 0xFB50, 0xFDFF) ||
      _inRange(rune, 0xFE70, 0xFEFF)) {
    return 'ar'; // арабский
  }
  if (_inRange(rune, 0x0370, 0x03FF) || _inRange(rune, 0x1F00, 0x1FFF)) {
    return 'el'; // греческий
  }
  if (_inRange(rune, 0x0400, 0x04FF) ||
      _inRange(rune, 0x0500, 0x052F) ||
      _inRange(rune, 0x2DE0, 0x2DFF) ||
      _inRange(rune, 0xA640, 0xA69F)) {
    return 'ru'; // кириллица
  }
  if (_inRange(rune, 0x10A0, 0x10FF) ||
      _inRange(rune, 0x1C90, 0x1CBF) ||
      _inRange(rune, 0x2D00, 0x2D2F)) {
    return 'ka'; // грузинский
  }
  return null;
}

bool _inRange(int rune, int start, int end) => rune >= start && rune <= end;

/// Сигнатура закэшированного текста и его романизация.
class _CacheEntry {
  const _CacheEntry(this.signature, this.value);

  final int signature;
  final Map<int, String> value;
}
