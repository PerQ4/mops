import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Строит заголовок `Authorization: SAPISIDHASH ...`.
///
/// Это тот же механизм, которым пользуется веб-клиент youtube.com:
/// берётся cookie `SAPISID` (или `__Secure-3PAPISID`), текущее время и origin,
/// после чего считается SHA1. Сервер проверяет подпись и не требует OAuth-токена.
class SapisidHash {
  /// Origin обязан совпадать с тем, к которому идёт запрос.
  static const String defaultOrigin = 'https://music.youtube.com';

  /// Возвращает значение заголовка `Authorization`.
  static String build(
    String sapisid, {
    DateTime? now,
    String origin = defaultOrigin,
  }) {
    final int timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final String raw = '$timestamp $sapisid $origin';
    final String digest = sha1.convert(utf8.encode(raw)).toString();
    return 'SAPISIDHASH ${timestamp}_$digest';
  }

  /// Извлекает `SAPISID` из строки cookie в формате `a=1; b=2`.
  ///
  /// Предпочитает `__Secure-3PAPISID`, затем `SAPISID`, затем `APISID`.
  static String? extractSapisid(String cookieString) {
    final Map<String, String> jar = parseCookieString(cookieString);
    return jar['__Secure-3PAPISID'] ?? jar['SAPISID'] ?? jar['APISID'];
  }

  /// Парсит строку cookie в карту. Значения не URL-декодируются —
  /// этого достаточно для `SAPISID`, который состоит из base64-подобных символов.
  static Map<String, String> parseCookieString(String cookieString) {
    final Map<String, String> jar = <String, String>{};
    for (final String part in cookieString.split(';')) {
      final String trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final int eq = trimmed.indexOf('=');
      if (eq <= 0) continue;
      jar[trimmed.substring(0, eq).trim()] = trimmed.substring(eq + 1).trim();
    }
    return jar;
  }
}
