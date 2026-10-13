import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'oauth_device_flow.dart';

/// Способ входа, которым получена сессия.
enum AuthMethod {
  /// OAuth Device Flow — «правильный» путь, токен обновляется автоматически.
  oauth('Вход через Google'),

  /// Cookie браузера + подпись SAPISIDHASH.
  cookies('Cookie браузера');

  const AuthMethod(this.label);

  final String label;
}

/// Сохранённая сессия: либо OAuth-токены, либо cookie.
@immutable
class AuthSession {
  const AuthSession({
    required this.method,
    this.tokens,
    this.cookieString,
    this.displayName,
    this.channelId,
    this.avatarUrl,
  });

  final AuthMethod method;
  final OAuthTokenSet? tokens;
  final String? cookieString;

  /// Имя аккаунта (подтягивается из account/account_menu).
  final String? displayName;
  final String? channelId;
  final String? avatarUrl;

  bool get isOAuth => method == AuthMethod.oauth && tokens != null;
  bool get isCookie => method == AuthMethod.cookies && (cookieString?.isNotEmpty ?? false);

  AuthSession copyWith({
    AuthMethod? method,
    OAuthTokenSet? tokens,
    String? cookieString,
    String? displayName,
    String? channelId,
    String? avatarUrl,
  }) {
    return AuthSession(
      method: method ?? this.method,
      tokens: tokens ?? this.tokens,
      cookieString: cookieString ?? this.cookieString,
      displayName: displayName ?? this.displayName,
      channelId: channelId ?? this.channelId,
      avatarUrl: avatarUrl ?? this.avatarUrl,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'method': method.name,
        'tokens': tokens?.toJson(),
        'cookieString': cookieString,
        'displayName': displayName,
        'channelId': channelId,
        'avatarUrl': avatarUrl,
      };

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    final dynamic rawTokens = json['tokens'];
    return AuthSession(
      method: AuthMethod.values.firstWhere(
        (AuthMethod m) => m.name == json['method'],
        orElse: () => AuthMethod.oauth,
      ),
      tokens: rawTokens is Map<String, dynamic>
          ? OAuthTokenSet.fromJson(rawTokens)
          : null,
      cookieString: json['cookieString'] as String?,
      displayName: json['displayName'] as String?,
      channelId: json['channelId'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
    );
  }
}

/// Хранит сессию на диске.
///
/// Файл кладётся в каталог поддержки приложения и закрывается правами `0600`
/// на POSIX-системах. Это не шифрование: доступ ограничен правами файловой
/// системы. Для полноценного хранилища на десктопе понадобился бы `libsecret`,
/// которого на целевой машине нет.
class TokenStore {
  TokenStore({this.fileName = 'session.json'});

  final String fileName;

  File? _cachedFile;

  Future<File> _file() async {
    if (_cachedFile != null) return _cachedFile!;
    final Directory dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final File file = File('${dir.path}/$fileName');
    _cachedFile = file;
    return file;
  }

  Future<AuthSession?> read() async {
    try {
      final File file = await _file();
      if (!file.existsSync()) return null;
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final dynamic decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return AuthSession.fromJson(decoded);
    } on FileSystemException {
      // Нет доступа к файлу — считаем, что сессии нет.
    } on FormatException {
      // Повреждённый файл — перезапишем при следующем сохранении.
    }
    return null;
  }

  Future<void> write(AuthSession session) async {
    final File file = await _file();
    await file.writeAsString(jsonEncode(session.toJson()), flush: true);
    await _restrictPermissions(file);
  }

  Future<void> clear() async {
    try {
      final File file = await _file();
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // Ничего не делаем: цель — отсутствие файла.
    }
  }

  Future<void> _restrictPermissions(File file) async {
    if (kIsWeb || Platform.isWindows) return;
    try {
      final ProcessResult result =
          await Process.run('chmod', <String>['600', file.path]);
      if (result.exitCode != 0) {
        debugPrint('Не удалось выставить права 600 на ${file.path}');
      }
    } on ProcessException {
      // chmod может отсутствовать — не критично.
    }
  }
}
