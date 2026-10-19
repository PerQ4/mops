import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Корень API ListenBrainz.
const String kListenBrainzEndpoint = 'https://api.listenbrainz.org/1';

/// Страница профиля: здесь пользователь берёт «user token».
const String kListenBrainzProfilePage = 'https://listenbrainz.org/profile/';

/// Ошибка ListenBrainz с текстом для пользователя.
class ListenBrainzException implements Exception {
  const ListenBrainzException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Подтверждённый аккаунт ListenBrainz.
class ListenBrainzUser {
  const ListenBrainzUser(this.username);

  final String username;
}

/// Один «листен» — то, что уходит на сервер ListenBrainz.
class ListenBrainzListen {
  const ListenBrainzListen({
    required this.artist,
    required this.title,
    this.release,
    this.durationMs,
    this.listenedAt,
  });

  final String artist;
  final String title;
  final String? release;
  final int? durationMs;

  /// Когда трек начал играть. Для `playing_now` не нужен.
  final DateTime? listenedAt;

  /// Тело одного элемента `payload`.
  Map<String, dynamic> toJson({required bool playingNow}) {
    return <String, dynamic>{
      if (!playingNow && listenedAt != null)
        'listened_at': listenedAt!.millisecondsSinceEpoch ~/ 1000,
      'track_metadata': <String, dynamic>{
        'artist_name': artist,
        'track_name': title,
        if (release != null && release!.isNotEmpty) 'release_name': release,
        'additional_info': <String, dynamic>{
          if (durationMs != null && durationMs! > 0) 'duration_ms': durationMs,
          'submission_client': 'mOps',
          'media_player': 'mOps',
        },
      },
    };
  }
}

/// Клиент ListenBrainz: проверка токена и отправка прослушиваний.
///
/// Как и у Last.fm, сетевые сбои не должны доходить до воспроизведения:
/// вызывающий код гасит их в лог.
class ListenBrainzClient {
  ListenBrainzClient({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final http.Client _http;

  /// Проверяет токен и возвращает имя аккаунта.
  Future<ListenBrainzUser> validateToken(String token) async {
    final http.Response response = await _http.get(
      Uri.parse('$kListenBrainzEndpoint/validate-token'),
      headers: <String, String>{'Authorization': 'Token $token'},
    ).timeout(const Duration(seconds: 12));

    final Map<String, dynamic>? json = _decode(response.body);
    if (response.statusCode == 200 &&
        json != null &&
        json['valid'] == true &&
        json['user_name'] is String) {
      return ListenBrainzUser(json['user_name'] as String);
    }
    if (response.statusCode == 401) {
      throw const ListenBrainzException('ListenBrainz отклонил токен.');
    }
    throw ListenBrainzException(
      'ListenBrainz ответил кодом ${response.statusCode}.',
    );
  }

  /// Отправляет «сейчас играет» или готовое прослушивание.
  Future<void> submit(
    String token,
    ListenBrainzListen listen, {
    required bool playingNow,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{
      'listen_type': playingNow ? 'playing_now' : 'single',
      'payload': <Map<String, dynamic>>[listen.toJson(playingNow: playingNow)],
    };

    final http.Response response = await _http.post(
      Uri.parse('$kListenBrainzEndpoint/submit-listens'),
      headers: <String, String>{
        'Authorization': 'Token $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 12));

    if (response.statusCode != 200) {
      throw ListenBrainzException(
        'ListenBrainz не принял прослушивание (${response.statusCode}).',
      );
    }
  }

  Map<String, dynamic>? _decode(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  void dispose() => _http.close();
}
