import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../local/app_settings.dart';

/// Профили клиентов YouTube для получения потока.
///
/// Библиотека по умолчанию использует `androidSdkless` — клиент, которому
/// YouTube всё чаще требует PO-токен. Профили ниже взяты из каталога клиентов
/// Metrolist (`innertubex`): они проверены на живых запросах и не требуют
/// ни входа, ни PO-токена.
///
/// Порядок в [defaultPlaybackClients] — это порядок попыток: сначала Android VR,
/// затем iOS как запасной вариант.
abstract final class YoutubeClients {
  static const String _webUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0';

  /// Клиент очков — не требует ни входа, ни PO-токена.
  ///
  /// Версия 1.65.10 отдаёт поток, а 1.61.48 уже отвечает «войдите, чтобы
  /// подтвердить, что вы не робот».
  static YoutubeApiClient androidVr() {
    const String version = '1.65.10';
    const String userAgent =
        'com.google.android.apps.youtube.vr.oculus/1.65.10 '
        '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';

    return YoutubeApiClient(
      <String, dynamic>{
        'context': <String, dynamic>{
          'client': <String, dynamic>{
            'clientName': 'ANDROID_VR',
            'clientVersion': version,
            'osName': 'Android',
            'osVersion': '12L',
            'deviceMake': 'Oculus',
            'deviceModel': 'Quest 3',
            'androidSdkVersion': 32,
            'userAgent': userAgent,
            'hl': 'en',
            'gl': 'US',
            'utcOffsetMinutes': 0,
          },
        },
      },
      // Плеерный эндпоинт именно музыкальный — так делают и в Metrolist.
      'https://music.youtube.com/youtubei/v1/player?prettyPrint=false',
      headers: <String, String>{
        'X-Youtube-Client-Name': '28',
        'X-Youtube-Client-Version': version,
        'User-Agent': userAgent,
      },
    );
  }

  /// Запасной клиент для iPhone — тоже без входа и без PO-токена.
  static YoutubeApiClient ios() {
    const String version = '20.10.4';
    const String userAgent =
        'com.google.ios.youtube/$version (iPhone16,2; U; CPU iOS 18_3_2 '
        'like Mac OS X;)';

    return YoutubeApiClient(
      <String, dynamic>{
        'context': <String, dynamic>{
          'client': <String, dynamic>{
            'clientName': 'IOS',
            'clientVersion': version,
            'deviceMake': 'Apple',
            'deviceModel': 'iPhone16,2',
            'osName': 'IOS',
            'osVersion': '18.3.2.22B83',
            'userAgent': userAgent,
            'hl': 'en',
            'gl': 'US',
            'utcOffsetMinutes': 0,
          },
        },
      },
      'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
      headers: <String, String>{
        'X-Youtube-Client-Name': '5',
        'X-Youtube-Client-Version': version,
        'User-Agent': userAgent,
      },
    );
  }

  /// Список клиентов в порядке попыток (по умолчанию — автоматически).
  static List<YoutubeApiClient> playbackOrder() => forChoice(StreamSource.auto);

  /// Клиенты для выбранного в настройках варианта.
  ///
  /// Пустой список означает «клиент библиотеки по умолчанию»: библиотека
  /// сама подставит его, если список не передан.
  static List<YoutubeApiClient> forChoice(StreamSource choice) {
    switch (choice) {
      case StreamSource.auto:
        return <YoutubeApiClient>[androidVr(), ios()];
      case StreamSource.androidVr:
        return <YoutubeApiClient>[androidVr()];
      case StreamSource.ios:
        return <YoutubeApiClient>[ios()];
      case StreamSource.library:
        return <YoutubeApiClient>[];
    }
  }

  /// Пользовательский агент веб-клиента — для запросов обложек и прочего.
  static String get webUserAgent => _webUserAgent;
}
