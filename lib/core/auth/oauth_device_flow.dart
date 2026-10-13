import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Область доступа, которую запрашивает `ytmusicapi` и совместимые клиенты.
const String kYtmOAuthScope = 'https://www.googleapis.com/auth/youtube';

const String _deviceCodeUrl = 'https://www.youtube.com/o/oauth2/device/code';
const String _tokenUrl = 'https://oauth2.googleapis.com/token';

/// User-Agent обязателен: Google отдаёт `device/code` только известным клиентам.
const String _oauthUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0 Cobalt/Version';

/// Первый шаг device-flow: код, который пользователь вводит в браузере.
class DeviceCodeResponse {
  const DeviceCodeResponse({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.expiresIn,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUrl;
  final int expiresIn;
  final int interval;

  /// Готовая ссылка, где уже подставлен код — её удобно открыть в браузере.
  String get verificationUrlWithCode => '$verificationUrl?user_code=$userCode';

  factory DeviceCodeResponse.fromJson(Map<String, dynamic> json) {
    return DeviceCodeResponse(
      deviceCode: json['device_code'] as String,
      userCode: json['user_code'] as String,
      verificationUrl:
          (json['verification_url'] ?? json['verification_uri']) as String,
      expiresIn: (json['expires_in'] as num?)?.toInt() ?? 1800,
      interval: (json['interval'] as num?)?.toInt() ?? 5,
    );
  }
}

/// Токены, полученные после подтверждения входа.
class OAuthTokenSet {
  const OAuthTokenSet({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    this.scope = kYtmOAuthScope,
    this.tokenType = 'Bearer',
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final String scope;
  final String tokenType;

  bool get isExpired => DateTime.now().isAfter(
        expiresAt.subtract(const Duration(minutes: 1)),
      );

  String get authorization => '$tokenType $accessToken';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_at': expiresAt.millisecondsSinceEpoch,
        'scope': scope,
        'token_type': tokenType,
      };

  factory OAuthTokenSet.fromJson(Map<String, dynamic> json) {
    return OAuthTokenSet(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (json['expires_at'] as num).toInt(),
      ),
      scope: (json['scope'] as String?) ?? kYtmOAuthScope,
      tokenType: (json['token_type'] as String?) ?? 'Bearer',
    );
  }
}

/// Ошибка, которую нужно показать пользователю без стектрейса.
class OAuthException implements Exception {
  OAuthException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

/// Реализация Google OAuth 2.0 Device Authorization Grant.
///
/// Google **не выдаёт** готовые client_id/client_secret для сторонних клиентов:
/// пользователь создаёт бесплатный OAuth-клиент типа
/// «TVs and Limited Input devices» в Google Cloud Console и вставляет его
/// данные в настройках приложения.
class OAuthDeviceFlow {
  OAuthDeviceFlow({
    required this.clientId,
    required this.clientSecret,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String clientId;
  final String clientSecret;
  final http.Client _http;

  /// Шаг 1. Запрашивает у Google пару `user_code` / `device_code`.
  Future<DeviceCodeResponse> requestDeviceCode() async {
    final http.Response res = await _http.post(
      Uri.parse(_deviceCodeUrl),
      headers: <String, String>{
        'User-Agent': _oauthUserAgent,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: <String, String>{
        'client_id': clientId,
        'scope': kYtmOAuthScope,
      },
    );

    final Map<String, dynamic> json = _decode(res);
    if (res.statusCode != 200) {
      throw OAuthException(
        _humanError(json, fallback: 'Не удалось получить код устройства'),
        code: json['error'] as String?,
      );
    }
    return DeviceCodeResponse.fromJson(json);
  }

  /// Шаг 2. Опрашивает Google, пока пользователь не подтвердит вход.
  ///
  /// `onTick` вызывается на каждой итерации — удобно показать «ожидание…».
  Future<OAuthTokenSet> pollForToken(
    DeviceCodeResponse code, {
    void Function(Duration remaining)? onTick,
  }) async {
    final DateTime deadline =
        DateTime.now().add(Duration(seconds: code.expiresIn));
    Duration interval = Duration(seconds: code.interval);

    while (DateTime.now().isBefore(deadline)) {
      onTick?.call(deadline.difference(DateTime.now()));
      await Future<void>.delayed(interval);

      final http.Response res = await _http.post(
        Uri.parse(_tokenUrl),
        headers: <String, String>{
          'User-Agent': _oauthUserAgent,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: <String, String>{
          'client_id': clientId,
          'client_secret': clientSecret,
          'grant_type': 'http://oauth.net/grant_type/device/1.0',
          'code': code.deviceCode,
        },
      );

      final Map<String, dynamic> json = _decode(res);

      if (res.statusCode == 200) {
        return _tokenFromJson(json);
      }

      final String? error = json['error'] as String?;
      switch (error) {
        case 'authorization_pending':
          continue; // пользователь ещё не нажал «Разрешить»
        case 'slow_down':
          interval += const Duration(seconds: 5);
          continue;
        case 'access_denied':
          throw OAuthException('Вход отклонён пользователем.', code: error);
        case 'expired_token':
          throw OAuthException('Код устройства истёк. Попробуйте снова.',
              code: error);
        default:
          throw OAuthException(
            _humanError(json, fallback: 'Ошибка авторизации'),
            code: error,
          );
      }
    }

    throw OAuthException('Время ожидания входа истекло.');
  }

  /// Обновляет истёкший access_token по refresh_token.
  Future<OAuthTokenSet> refresh(String refreshToken) async {
    final http.Response res = await _http.post(
      Uri.parse(_tokenUrl),
      headers: <String, String>{
        'User-Agent': _oauthUserAgent,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: <String, String>{
        'client_id': clientId,
        'client_secret': clientSecret,
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      },
    );

    final Map<String, dynamic> json = _decode(res);
    if (res.statusCode != 200) {
      throw OAuthException(
        _humanError(json, fallback: 'Не удалось обновить токен'),
        code: json['error'] as String?,
      );
    }
    // Google не возвращает refresh_token при обновлении — переносим старый.
    return _tokenFromJson(<String, dynamic>{...json, 'refresh_token': refreshToken});
  }

  OAuthTokenSet _tokenFromJson(Map<String, dynamic> json) {
    final int expiresIn = (json['expires_in'] as num?)?.toInt() ?? 3600;
    return OAuthTokenSet(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      scope: (json['scope'] as String?) ?? kYtmOAuthScope,
      tokenType: (json['token_type'] as String?) ?? 'Bearer',
    );
  }

  Map<String, dynamic> _decode(http.Response res) {
    try {
      final dynamic decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{'raw': res.body};
    } on FormatException {
      return <String, dynamic>{'raw': res.body};
    }
  }

  String _humanError(Map<String, dynamic> json, {required String fallback}) {
    final Object? description = json['error_description'] ?? json['error'];
    if (description is String && description.isNotEmpty) {
      return '$fallback: $description';
    }
    return fallback;
  }

  void dispose() => _http.close();
}
