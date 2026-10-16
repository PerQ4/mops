import 'dart:convert';
import 'dart:io';

import '../local/app_settings.dart';

/// Романизация текста — латиница для песен на японском, корейском, китайском,
/// хинди и других языках с нелатинской письменностью.
///
/// Перевод при этом НЕ делается: нужен именно «слепок» произношения, чтобы
/// читать незнакомый текст, а не подмена смысла. Механизм повторяет BetterLyrics
/// (`src/core/constants.ts`): тот же публичный эндпоинт Google Translate, где
/// `dt=rm` просит транслитерацию, а `sl == tl` (с суффиксом `-Latn`) не даёт
/// сервису перевести текст вместо транслитерации.
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

  /// Романизирует непустые строки и возвращает соответствие
  /// «номер строки → романизация».
  ///
  /// Запрос один на весь текст (строки склеены `\n`), а не по строке: у сервиса
  /// заметная задержка, а строк в песне десятки. Если сервис недоступен или
  /// вернул другое число строк — отдаём `null`, и текст показывается без
  /// романизации. Ничего не ломаем и не выдумываем.
  Future<Map<int, String>?> romanize({
    required String videoId,
    required RomanizationLanguage language,
    required List<String> lines,
  }) async {
    // Пустые строки в запрос не отправляем: сервис схлопывает их сам, и
    // соответствие строкам после этого поехало бы.
    final List<int> indexes = <int>[
      for (int i = 0; i < lines.length; i++)
        if (lines[i].trim().isNotEmpty) i,
    ];
    if (indexes.isEmpty) return null;

    final String text = indexes.map((int i) => lines[i]).join('\n');
    final String key = '$videoId|${language.name}';
    final int signature = Object.hash(text, text.length);
    final _CacheEntry? cached = _cache[key];
    if (cached != null && cached.signature == signature) return cached.value;

    final String? romanized = await _request(text, language.code);
    if (romanized == null) return null;

    final Map<int, String>? mapped = _mapToLines(romanized, indexes);
    if (mapped == null) return null;

    // Ограничиваем кэш: за долгую сессию треков много, а хранить романизацию
    // всех незачем — она восстанавливается одним запросом.
    if (_cache.length >= _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = _CacheEntry(signature, mapped);
    return mapped;
  }

  /// Просит транслитерацию. Для кодов вида `zh-CN` сервис иногда ждёт базовый
  /// `zh` — тогда повторяем запрос с ним, прежде чем сдаться.
  Future<String?> _request(String text, String code) async {
    final String? primary = await _ask(text, code);
    if (primary != null) return primary;

    final String base = code.split('-').first;
    if (base == code) return null;
    return _ask(text, base);
  }

  Future<String?> _ask(String text, String lang) async {
    try {
      final Uri uri = Uri.parse(_host).replace(
        queryParameters: <String, dynamic>{
          'client': 'gtx',
          'sl': lang,
          'tl': '$lang-Latn',
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

  /// Раскладывает ответ обратно по строкам. Если число строк не совпало —
  /// романизацию не показываем: сдвинутые строки хуже, чем их отсутствие.
  Map<int, String>? _mapToLines(String romanized, List<int> indexes) {
    final List<String> parts = romanized.split('\n');
    if (parts.length != indexes.length) return null;
    return <int, String>{
      for (int i = 0; i < indexes.length; i++) indexes[i]: parts[i],
    };
  }

  void dispose() => _client.close(force: true);
}

/// Сигнатура закэшированного текста и его романизация.
class _CacheEntry {
  const _CacheEntry(this.signature, this.value);

  final int signature;
  final Map<int, String> value;
}
