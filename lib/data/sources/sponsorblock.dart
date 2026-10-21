import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// Категории вставок SponsorBlock, которые можно пропускать.
///
/// Список сверен с сервером (`SponsorBlockServer/src/config.ts`): это его
/// `sponsorTimes`-категории. Сюда не входят `exclusive_access` (метка на всё
/// видео — пропускать нечего), `poi_highlight` (точка, а не отрезок) и
/// `chapter` (глава, а не вставка): у них другой смысл, и «пропуск» для них
/// был бы неверным.
///
/// [apiName] — строка, которую понимает API; [label] и [description] — для
/// интерфейса настроек.
enum SponsorBlockCategory {
  sponsor(
    'sponsor',
    'Спонсорские вставки',
    'Оплаченная реклама внутри видео',
  ),
  selfpromo(
    'selfpromo',
    'Самореклама',
    'Ссылки на merch, Patreon и другие видео автора',
  ),
  interaction(
    'interaction',
    'Призывы к действию',
    'Просьбы поставить лайк, подписаться, нажать колокольчик',
  ),
  intro(
    'intro',
    'Вступление',
    'Заставка и анонс в начале видео',
  ),
  outro(
    'outro',
    'Концовка',
    'Титры и прощание в конце',
  ),
  preview(
    'preview',
    'Превью',
    'Краткий пересказ содержимого',
  ),
  hook(
    'hook',
    'Хук',
    'Завлекающее начало до основной части',
  ),
  musicOfftopic(
    'music_offtopic',
    'Не-музыкальные вставки',
    'Разговоры и шутки в клипах и живых записях',
  ),
  filler(
    'filler',
    'Вода',
    'Паузы и пустые места без содержания',
  );

  const SponsorBlockCategory(this.apiName, this.label, this.description);

  final String apiName;
  final String label;
  final String description;

  /// Категория по имени из API. Неизвестную пропускаем: сервер может добавить
  /// новую, и это не повод считать ответ ошибкой.
  static SponsorBlockCategory? fromApiName(String name) {
    for (final SponsorBlockCategory category in values) {
      if (category.apiName == name) return category;
    }
    return null;
  }
}

/// Категории, которые пропускаются по умолчанию.
///
/// Те же, что в стандартном пресете SponsorBlock: реклама, самореклама,
/// вступление, концовка и разговоры в музыкальных видео. Остальные включаются
/// вручную — «вода» и «хук» на музыке чаще часть записи, чем помеха.
const List<SponsorBlockCategory> kDefaultSponsorBlockCategories =
    <SponsorBlockCategory>[
  SponsorBlockCategory.sponsor,
  SponsorBlockCategory.selfpromo,
  SponsorBlockCategory.intro,
  SponsorBlockCategory.outro,
  SponsorBlockCategory.musicOfftopic,
];

/// Отрезок видео, помеченный как вставка.
@immutable
class SponsorSegment {
  const SponsorSegment({
    required this.uuid,
    required this.category,
    required this.start,
    required this.end,
  });

  /// UUID отметки: по нему отличаем уже пропущенный отрезок от нового.
  final String uuid;
  final SponsorBlockCategory category;
  final Duration start;

  /// Конец вставки — сюда перематываем.
  final Duration end;
}

/// Клиент SponsorBlock.
///
/// Запрос идёт по префиксу хеша: `sha256(videoId)` и первые четыре символа.
/// Так сервер не получает историю просмотров — он не знает, какое именно
/// видео спрашивают (API это и требует). Ответ по префиксу содержит несколько
/// видео, поэтому свой id отбираем на месте.
///
/// Сеть здесь вспомогательная: любая ошибка — это «вставок нет», а не ошибка
/// воспроизведения. Пользователь не должен видеть сообщений из-за того, что
/// публичный сервер не ответил.
class SponsorBlockClient {
  SponsorBlockClient({
    HttpClient? httpClient,
    this.timeout = const Duration(seconds: 4),
  })  : _http = httpClient ?? HttpClient(),
        _ownsClient = httpClient == null {
    // Не только таймаут на ответ, но и на установку соединения: иначе при
    // недоступном хосте запрос висел бы до системного таймаута.
    _http.connectionTimeout = timeout;
  }

  static const String _host = 'sponsor.ajay.app';

  /// Предел числа запомненных ответов. Ответы маленькие, но радио может
  /// пролистать сотни треков за сеанс, а кэш живёт до закрытия приложения.
  static const int maxEntries = 120;

  final HttpClient _http;
  final bool _ownsClient;

  /// Таймаут на весь запрос. Без него пропавшая сеть держала бы соединение
  /// минутами, а пропуск вставки давно был бы не нужен.
  final Duration timeout;

  /// Ответы по ключу «id + набор категорий». `Map` помнит порядок вставки —
  /// этого достаточно для простого LRU: при переполнении убираем первый.
  final Map<String, List<SponsorSegment>> _cache =
      <String, List<SponsorSegment>>{};

  /// Отрезки для видео в указанных категориях.
  ///
  /// Пустой список — обычный ответ: у видео может не быть ни одной отметки
  /// или сервер вернул 404. Такой ответ кэшируется, чтобы не спрашивать
  /// повторно. Сетевые сбои не кэшируются: следующий запуск трека может
  /// пройти нормально.
  Future<List<SponsorSegment>> segments(
    String videoId, {
    required Set<SponsorBlockCategory> categories,
  }) async {
    if (videoId.isEmpty || categories.isEmpty) {
      return const <SponsorSegment>[];
    }

    final String key = _cacheKey(videoId, categories);
    final List<SponsorSegment>? cached = _cache.remove(key);
    if (cached != null) {
      // Повторно кладём в конец — запись считается свежей.
      _cache[key] = cached;
      return cached;
    }

    final List<SponsorSegment> fetched;
    try {
      fetched = await _fetch(videoId, categories);
    } on Object catch (error) {
      // Сеть, таймаут, битый JSON — всё это «вставок нет».
      debugPrint('[SponsorBlock] не удалось получить вставки: $error');
      return const <SponsorSegment>[];
    }

    _cache[key] = fetched;
    if (_cache.length > maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    return fetched;
  }

  Future<List<SponsorSegment>> _fetch(
    String videoId,
    Set<SponsorBlockCategory> categories,
  ) async {
    final String prefix =
        sha256.convert(utf8.encode(videoId)).toString().substring(0, 4);
    final List<String> names = categories
        .map((SponsorBlockCategory category) => category.apiName)
        .toList()
      ..sort();

    // Категории передаются JSON-массивом в query; `Uri.https` сам кодирует
    // кавычки и скобки.
    final Uri uri = Uri.https(
      _host,
      '/api/skipSegments/$prefix',
      <String, String>{'categories': jsonEncode(names)},
    );

    final List<SponsorSegment> result = await _request(uri, videoId, categories)
        .timeout(timeout);
    result.sort(
      (SponsorSegment a, SponsorSegment b) => a.start.compareTo(b.start),
    );
    return result;
  }

  Future<List<SponsorSegment>> _request(
    Uri uri,
    String videoId,
    Set<SponsorBlockCategory> categories,
  ) async {
    final HttpClientRequest request = await _http.getUrl(uri);
    // User-Agent только ASCII: сервер отвергает заголовки с не-ASCII
    // символами, а название приложения у нас латиницей.
    request.headers.set(HttpHeaders.userAgentHeader, 'mops-sponsorblock/1.0');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');

    final HttpClientResponse response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      // 404 — у видео нет отметок (частый и нормальный случай).
      await response.drain<void>();
      return const <SponsorSegment>[];
    }

    final String body = await response.transform(utf8.decoder).join();
    final dynamic decoded = jsonDecode(body);
    if (decoded is! List) return const <SponsorSegment>[];

    final List<SponsorSegment> segments = <SponsorSegment>[];
    for (final dynamic entry in decoded) {
      if (entry is! Map) continue;
      // По четырём символам префикса приходят и чужие видео — берём только
      // своё.
      if (entry['videoID'] != videoId) continue;

      final dynamic rawSegments = entry['segments'];
      if (rawSegments is! List) continue;
      for (final dynamic raw in rawSegments) {
        final SponsorSegment? segment =
            _parseSegment(raw, categories, videoId);
        if (segment != null) segments.add(segment);
      }
    }
    return segments;
  }

  SponsorSegment? _parseSegment(
    dynamic raw,
    Set<SponsorBlockCategory> categories,
    String videoId,
  ) {
    if (raw is! Map) return null;

    // `skipSegments` отдаёт и точки (`poi`), и полные видео; пропускаем
    // только отрезки. Поле `actionType` может отсутствовать — по умолчанию
    // сервер считает отметку пропуском.
    final String action =
        '${raw['actionType'] ?? 'skip'}'.trim().toLowerCase();
    if (action.isNotEmpty && action != 'skip') return null;

    final SponsorBlockCategory? category =
        SponsorBlockCategory.fromApiName('${raw['category'] ?? ''}');
    if (category == null || !categories.contains(category)) return null;

    final dynamic range = raw['segment'];
    if (range is! List || range.length < 2) return null;
    final dynamic start = range[0];
    final dynamic end = range[1];
    if (start is! num || end is! num) return null;

    final Duration from = Duration(milliseconds: (start * 1000).round());
    final Duration to = Duration(milliseconds: (end * 1000).round());
    if (to <= from) return null;

    // UUID приходит от сервера всегда, но если его нет — синтезируем
    // стабильный ключ из самого отрезка: повторного пропуска это не сломает.
    final String uuid =
        '${raw['UUID'] ?? '$videoId-$start-$end-$category'}'.trim();
    if (uuid.isEmpty) return null;

    return SponsorSegment(
      uuid: uuid,
      category: category,
      start: from,
      end: to,
    );
  }

  /// Ключ кэша: набор категорий в стабильном порядке, чтобы `{intro, outro}`
  /// и `{outro, intro}` попадали в одну запись.
  String _cacheKey(String videoId, Set<SponsorBlockCategory> categories) {
    final List<String> names = categories
        .map((SponsorBlockCategory category) => category.apiName)
        .toList()
      ..sort();
    return '$videoId|${names.join(',')}';
  }

  /// Закрывает соединения. Клиент живёт столько же, сколько провайдер.
  void dispose() {
    if (_ownsClient) _http.close(force: true);
  }
}
