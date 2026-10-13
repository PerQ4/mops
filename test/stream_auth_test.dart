// Авторизация в клиенте YouTube. Сеть не нужна: проверяются только заголовки,
// которые получает библиотека получения потока.
import 'package:flutter_test/flutter_test.dart';
import 'package:mops/data/sources/stream_resolver.dart';

void main() {
  group('заголовки сессии', () {
    test('cookie из браузера попадает в запросы', () {
      final Map<String, String> headers =
          AuthenticatedYoutubeClient.headersForSession(
        cookieString: 'SAPISID=abc123; __Secure-3PAPISID=abc123',
        bearerToken: null,
      );

      expect(headers['cookie'], contains('SAPISID=abc123'));
      // Cookie согласия добавляется, если её нет, — иначе YouTube покажет
      // страницу согласия вместо данных.
      expect(headers['cookie'], contains('CONSENT='));
      expect(headers.containsKey('authorization'), isFalse);
    });

    test('своя cookie согласия не дублируется', () {
      final Map<String, String> headers =
          AuthenticatedYoutubeClient.headersForSession(
        cookieString: 'CONSENT=YES+cb; SAPISID=abc123',
        bearerToken: null,
      );

      final String cookies = headers['cookie']!;
      expect('CONSENT='.allMatches(cookies).length, 1);
      expect(cookies, contains('SAPISID=abc123'));
    });

    test('токен OAuth превращается в заголовок Authorization', () {
      final Map<String, String> headers =
          AuthenticatedYoutubeClient.headersForSession(
        cookieString: null,
        bearerToken: 'ya29.token',
      );

      expect(headers['authorization'], 'Bearer ya29.token');
      expect(headers.containsKey('cookie'), isFalse);
    });

    test('без входа заголовков авторизации нет', () {
      expect(
        AuthenticatedYoutubeClient.headersForSession(
          cookieString: null,
          bearerToken: null,
        ),
        isEmpty,
      );
      expect(
        AuthenticatedYoutubeClient.headersForSession(
          cookieString: '   ',
          bearerToken: '',
        ),
        isEmpty,
      );
    });
  });

  group('клиент с авторизацией', () {
    test('добавляет заголовки поверх стандартных', () {
      final AuthenticatedYoutubeClient client = AuthenticatedYoutubeClient(
        <String, String>{'cookie': 'SAPISID=abc'},
      );
      addTearDown(client.close);

      final Map<String, String> headers = client.headers;
      // Своя cookie подменяет стандартную.
      expect(headers['cookie'], 'SAPISID=abc');
      // Остальные стандартные заголовки остаются на месте.
      expect(headers['user-agent'], isNotEmpty);
      expect(headers['accept'], isNotEmpty);
    });

    test('без авторизации остаются только стандартные заголовки', () {
      final AuthenticatedYoutubeClient client =
          AuthenticatedYoutubeClient(const <String, String>{});
      addTearDown(client.close);

      expect(client.headers['cookie'], 'CONSENT=YES+cb');
      expect(client.headers.containsKey('authorization'), isFalse);
    });
  });
}
