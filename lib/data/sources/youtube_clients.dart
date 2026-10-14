import '../local/app_settings.dart';

/// Профиль клиента YouTube: чем приложение представляется в запросе.
///
/// YouTube выдаёт ссылку на поток по-разному в зависимости от клиента:
/// одним он требует PO-токен, другим — вход. Профили ниже проверены на живых
/// запросах и не требуют ни того, ни другого.
///
/// Библиотека `youtube_explode_dart` умеет принимать такие профили, но её
/// собственный путь получения манифеста с ними падает (`403`), поэтому запрос
/// делает наш InnerTube-клиент — см. `stream_resolver.dart`.
class YoutubeClientProfile {
  const YoutubeClientProfile({
    required this.label,
    required this.name,
    required this.version,
    required this.numericId,
    required this.userAgent,
    this.extra = const <String, Object?>{},
  });

  /// Название для интерфейса и логов.
  final String label;

  /// Имя клиента в теле запроса (`clientName`).
  final String name;

  /// Версия клиента (`clientVersion`).
  final String version;

  /// Числовой идентификатор для заголовка `X-Youtube-Client-Name`.
  final String numericId;

  /// Пользовательский агент клиента.
  final String userAgent;

  /// Дополнительные поля контекста (`osName`, `deviceModel` и прочие).
  final Map<String, Object?> extra;

  /// Контекст клиента для тела запроса.
  Map<String, dynamic> context({
    required String locale,
    required String region,
  }) =>
      <String, dynamic>{
        'clientName': name,
        'clientVersion': version,
        'hl': locale,
        'gl': region,
        'utcOffsetMinutes': 0,
        'userAgent': userAgent,
        ...extra,
      };

  /// Заголовки, которыми клиент представляется.
  Map<String, String> get headers => <String, String>{
        'X-Youtube-Client-Name': numericId,
        'X-Youtube-Client-Version': version,
        'User-Agent': userAgent,
      };
}

/// Профили клиентов YouTube, проверенные на живых запросах.
abstract final class YoutubeClients {
  /// Клиент очков Apple Vision Pro.
  ///
  /// Внутренний клиент YouTube (может перестать работать в любой момент), но
  /// именно он отдаёт поток целиком: Android VR и iOS получают только первый
  /// мегабайт, а этот — весь файл. Проверено на живом соединении.
  static const YoutubeClientProfile visionOs = YoutubeClientProfile(
    label: 'visionOS',
    name: 'VISIONOS',
    version: '1.02',
    numericId: '101',
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 '
        'Safari/605.1.15',
    extra: <String, Object?>{
      'osName': 'visionOS',
      'osVersion': '26.5.23O471',
      'deviceMake': 'Apple',
      'deviceModel': 'RealityDevice17,1',
    },
  );

  /// Клиент очков Oculus — не требует ни входа, ни PO-токена.
  ///
  /// Версия 1.65.10 отдаёт поток, а 1.61.48 уже отвечает «войдите, чтобы
  /// подтвердить, что вы не робот».
  static const YoutubeClientProfile androidVr = YoutubeClientProfile(
    label: 'Android VR',
    name: 'ANDROID_VR',
    version: '1.65.10',
    numericId: '28',
    userAgent: 'com.google.android.apps.youtube.vr.oculus/1.65.10 '
        '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
    extra: <String, Object?>{
      'osName': 'Android',
      'osVersion': '12L',
      'deviceMake': 'Oculus',
      'deviceModel': 'Quest 3',
      'androidSdkVersion': 32,
    },
  );

  /// Клиент iPhone — запасной вариант, тоже без входа и PO-токена.
  static const YoutubeClientProfile ios = YoutubeClientProfile(
    label: 'iOS',
    name: 'IOS',
    version: '20.10.4',
    numericId: '5',
    userAgent: 'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 '
        'like Mac OS X;)',
    extra: <String, Object?>{
      'deviceMake': 'Apple',
      'deviceModel': 'iPhone16,2',
      'osName': 'IOS',
      'osVersion': '18.3.2.22B83',
    },
  );

  /// Профили в порядке попыток для выбранного в настройках варианта.
  ///
  /// Пустой список означает «клиент библиотеки по умолчанию» — тогда запрос
  /// делает `youtube_explode_dart` своим обычным клиентом.
  static List<YoutubeClientProfile> forChoice(StreamSource choice) {
    switch (choice) {
      case StreamSource.auto:
        return <YoutubeClientProfile>[visionOs, androidVr, ios];
      case StreamSource.visionOs:
        return <YoutubeClientProfile>[visionOs];
      case StreamSource.androidVr:
        return <YoutubeClientProfile>[androidVr];
      case StreamSource.ios:
        return <YoutubeClientProfile>[ios];
      case StreamSource.library:
        return const <YoutubeClientProfile>[];
    }
  }
}
