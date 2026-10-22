// Резолвер через веб-сессию: разбор ссылок и правила включения.
//
// WebView2 в тестах не поднимается: проверяется то, что решает судьбу трека, —
// разбор ссылки из перехвата, выбор дорожки из ответа плеера и то, что веб-путь
// включается только при явном отказе сервера.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mops/core/audio/audio_engine.dart';
import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/data/local/app_settings.dart';
import 'package:mops/data/sources/stream_resolver.dart';
import 'package:mops/data/sources/web_session_resolver.dart';

/// Сервер, который ведёт себя как медиасервер: отказ или один байт данных.
class _FakeMediaServer {
  _FakeMediaServer._(this._server);

  final HttpServer _server;
  final List<String> requested = <String>[];

  static Future<_FakeMediaServer> start() async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final _FakeMediaServer fake = _FakeMediaServer._(server);
    server.listen(fake._handle);
    return fake;
  }

  String get origin => 'http://127.0.0.1:${_server.port}';

  Uri url(String path) => Uri.parse('$origin$path');

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    requested.add(request.uri.path);
    final HttpResponse response = request.response;
    try {
      if (request.uri.path == '/refused') {
        response.statusCode = HttpStatus.serviceUnavailable;
      } else {
        response
          ..statusCode = HttpStatus.partialContent
          ..headers.contentLength = 1
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/1024')
          ..add(<int>[0]);
      }
      await response.close();
    } on Object {
      // Проверка обрывает соединение после первого байта — так и надо.
    }
  }
}

class _FakeInnerTube extends InnerTubeClient {
  _FakeInnerTube({this.response, this.error});

  final Map<String, dynamic>? response;
  final Object? error;

  @override
  Future<Map<String, dynamic>> post(
    String endpoint, {
    Map<String, dynamic> body = const <String, dynamic>{},
    Map<String, String> query = const <String, String>{},
    bool authenticated = false,
    Map<String, String> extraHeaders = const <String, String>{},
  }) async {
    final Object? failure = error;
    if (failure != null) throw failure;
    return response ?? <String, dynamic>{};
  }
}

/// Заглушка веб-сессии: браузер не нужен, важно только, позвали её или нет.
class _FakeWebSession implements StreamResolver {
  _FakeWebSession({this.result, this.failure, this.available = true});

  final ResolvedStream? result;
  final Object? failure;
  final bool available;
  int calls = 0;

  @override
  bool get isAvailable => available;

  @override
  Future<ResolvedStream> resolve(
    String videoId, {
    required AudioQuality quality,
    String? preferContainer,
  }) async {
    calls++;
    final Object? error = failure;
    if (error != null) throw error;
    return result!;
  }

  @override
  void dispose() {}
}

Map<String, dynamic> _playerResponse(List<Map<String, dynamic>> formats) =>
    <String, dynamic>{
      'playabilityStatus': <String, dynamic>{'status': 'OK'},
      'streamingData': <String, dynamic>{'adaptiveFormats': formats},
    };

Map<String, dynamic> _format(
  String mime,
  int bitrate,
  String url, {
  bool cipher = false,
}) =>
    <String, dynamic>{
      'mimeType': mime,
      'bitrate': bitrate,
      if (cipher)
        'signatureCipher': 'url=$url&s=signature'
      else
        'url': url,
    };

ResolvedStream _stream(Uri url, {Map<String, String>? headers}) =>
    ResolvedStream(
      url: url,
      bitrateKbps: 128,
      container: 'm4a',
      mimeType: 'audio/mp4',
      userAgent: 'TestAgent/1.0',
      httpHeaders: headers,
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );

YoutubeStreamResolver _resolver({
  required _FakeMediaServer server,
  Map<String, dynamic>? player,
  Object? playerError,
  StreamResolver? web,
}) =>
    YoutubeStreamResolver(
      innerTube: _FakeInnerTube(response: player, error: playerError),
      locale: 'ru',
      region: 'RU',
      clientChoice: StreamSource.visionOs,
      webSession: web,
      fallbackLinks: (String videoId) async => playerError != null
          ? throw playerError
          : const <ResolvedStream>[],
    );

/// Ссылка в том виде, в каком её запрашивает веб-плеер YouTube.
String _mediaUrl({
  String host = 'rr1---sn-test.googlevideo.com',
  String mime = 'audio/webm',
  int bitrate = 160000,
  int expireInSeconds = 21600,
}) {
  final int expire =
      DateTime.now().millisecondsSinceEpoch ~/ 1000 + expireInSeconds;
  return Uri.https(host, '/videoplayback', <String, String>{
    'expire': '$expire',
    'mime': mime,
    'bitrate': '$bitrate',
    'itag': '251',
    'range': '0-65535',
    'rn': '3',
  }).toString();
}

void main() {
  late _FakeMediaServer server;

  setUp(() async {
    StreamRequestHeaders.clear();
    server = await _FakeMediaServer.start();
  });

  tearDown(() async {
    await server.close();
  });

  group('разбор перехваченного запроса', () {
    test('аудио с googlevideo — ссылка, range убран', () {
      final SessionMediaLink? link =
          WebSessionResolver.mediaRequestLink(_mediaUrl());

      expect(link, isNotNull);
      expect(link!.mimeType, 'audio/webm');
      expect(link.container, 'webm');
      expect(link.bitrateKbps, 160);
      expect(link.url.host, 'rr1---sn-test.googlevideo.com');
      // Кусок, который просил браузер, плееру не нужен: иначе играл бы только
      // первый запрошенный диапазон.
      expect(link.url.queryParameters.containsKey('range'), isFalse);
      expect(link.expiresAt.isAfter(DateTime.now()), isTrue);
    });

    test('видеодорожка и чужие адреса не подходят', () {
      expect(
        WebSessionResolver.mediaRequestLink(_mediaUrl(mime: 'video/mp4')),
        isNull,
      );
      expect(
        WebSessionResolver.mediaRequestLink(
          _mediaUrl(host: 'notgooglevideo.com'),
        ),
        isNull,
      );
      expect(
        WebSessionResolver.mediaRequestLink(
          'https://rr1---sn-test.googlevideo.com/other?mime=audio/webm',
        ),
        isNull,
      );
      expect(WebSessionResolver.mediaRequestLink('не адрес'), isNull);
    });
  });

  group('выбор дорожки из ответа веб-плеера', () {
    test('максимум — лучший битрейт, среднее — ближайший к 128', () {
      final Map<String, dynamic> response = _playerResponse(
        <Map<String, dynamic>>[
          _format('audio/webm; codecs="opus"', 70000, _mediaUrl(bitrate: 70000)),
          _format('audio/mp4; codecs="mp4a"', 130000, _mediaUrl(mime: 'audio/mp4', bitrate: 130000)),
          _format('audio/webm; codecs="opus"', 160000, _mediaUrl(bitrate: 160000)),
        ],
      );

      final SessionMediaLink high =
          WebSessionResolver.pickFromPlayerResponse(
        response,
        quality: AudioQuality.high,
      )!;
      expect(high.bitrateKbps, 160);
      expect(high.mimeType, 'audio/webm');

      final SessionMediaLink medium =
          WebSessionResolver.pickFromPlayerResponse(
        response,
        quality: AudioQuality.medium,
      )!;
      expect(medium.bitrateKbps, 130);
      expect(medium.mimeType, 'audio/mp4');
    });

    test('предпочтительный контейнер важнее битрейта', () {
      final Map<String, dynamic> response = _playerResponse(
        <Map<String, dynamic>>[
          _format('audio/webm', 160000, _mediaUrl(bitrate: 160000)),
          _format('audio/mp4', 130000, _mediaUrl(mime: 'audio/mp4', bitrate: 130000)),
        ],
      );

      final SessionMediaLink link = WebSessionResolver.pickFromPlayerResponse(
        response,
        quality: AudioQuality.high,
        preferContainer: 'm4a',
      )!;
      expect(link.container, 'm4a');
    });

    test('без готовой ссылки дорожка не годится', () {
      final Map<String, dynamic> response = _playerResponse(
        <Map<String, dynamic>>[
          _format('audio/webm', 160000, _mediaUrl(), cipher: true),
        ],
      );

      expect(
        WebSessionResolver.pickFromPlayerResponse(
          response,
          quality: AudioQuality.high,
        ),
        isNull,
      );
    });
  });

  group('когда включается веб-сессия', () {
    test('обычный профиль дал ссылку — браузер не поднимается', () async {
      final _FakeWebSession web = _FakeWebSession(
        result: _stream(server.url('/web')),
      );
      final YoutubeStreamResolver resolver = _resolver(
        server: server,
        player: _playerResponse(<Map<String, dynamic>>[
          _format('audio/mp4', 131000, server.url('/ok').toString()),
        ]),
        web: web,
      );
      addTearDown(resolver.dispose);

      final ResolvedStream stream =
          await resolver.resolve('vid', quality: AudioQuality.high);

      expect(stream.url.path, '/ok');
      expect(web.calls, 0);
    });

    test('все форматы отказали — включается веб-сессия', () async {
      final _FakeWebSession web = _FakeWebSession(
        result: _stream(server.url('/web')),
      );
      final YoutubeStreamResolver resolver = _resolver(
        server: server,
        player: _playerResponse(<Map<String, dynamic>>[
          _format('audio/mp4', 131000, server.url('/refused').toString()),
        ]),
        web: web,
      );
      addTearDown(resolver.dispose);

      final ResolvedStream stream =
          await resolver.resolve('vid', quality: AudioQuality.high);

      expect(web.calls, 1);
      expect(stream.url.path, '/web');
    });

    test('веб-сессия не справилась — остаётся честный отказ сервера', () async {
      final _FakeWebSession web = _FakeWebSession(
        failure: StreamResolutionException('страница не заиграла'),
      );
      final YoutubeStreamResolver resolver = _resolver(
        server: server,
        player: _playerResponse(<Map<String, dynamic>>[
          _format('audio/mp4', 131000, server.url('/refused').toString()),
        ]),
        web: web,
      );
      addTearDown(resolver.dispose);

      Object? failure;
      try {
        await resolver.resolve('vid', quality: AudioQuality.high);
      } on Object catch (error) {
        failure = error;
      }

      expect(web.calls, 1);
      expect(failure, isA<StreamResolutionException>());
      final StreamResolutionException error =
          failure! as StreamResolutionException;
      expect(error.message, contains('503'));
      expect(error.unavailable, isTrue);
    });

    test('сетевая ошибка — браузер не поднимается', () async {
      final _FakeWebSession web = _FakeWebSession(
        result: _stream(server.url('/web')),
      );
      final YoutubeStreamResolver resolver = _resolver(
        server: server,
        playerError: const SocketException('нет сети'),
        web: web,
      );
      addTearDown(resolver.dispose);

      await expectLater(
        resolver.resolve('vid', quality: AudioQuality.high),
        throwsA(isA<StreamResolutionException>()),
      );
      expect(web.calls, 0);
    });

    test('недоступный источник не зовётся вовсе', () async {
      final _FakeWebSession web = _FakeWebSession(
        result: _stream(server.url('/web')),
        available: false,
      );
      final YoutubeStreamResolver resolver = _resolver(
        server: server,
        player: _playerResponse(<Map<String, dynamic>>[
          _format('audio/mp4', 131000, server.url('/refused').toString()),
        ]),
        web: web,
      );
      addTearDown(resolver.dispose);

      await expectLater(
        resolver.resolve('vid', quality: AudioQuality.high),
        throwsA(isA<StreamResolutionException>()),
      );
      expect(web.calls, 0);
    });

    test('заголовки веб-ссылки доходят до движка', () async {
      const Map<String, String> headers = <String, String>{
        'User-Agent': 'TestAgent/1.0',
        'Cookie': 'SID=secret',
      };
      final Uri url = server.url('/web');
      final _FakeWebSession web = _FakeWebSession(
        result: _stream(url, headers: headers),
      );
      final YoutubeStreamResolver resolver = _resolver(
        server: server,
        player: _playerResponse(<Map<String, dynamic>>[
          _format('audio/mp4', 131000, server.url('/refused').toString()),
        ]),
        web: web,
      );
      addTearDown(resolver.dispose);

      await resolver.resolve('vid', quality: AudioQuality.high);

      // Движок получает от контроллера только адрес — заголовки он находит по
      // нему в общем хранилище.
      expect(StreamRequestHeaders.forUrl(url.toString()), headers);
    });
  });

  group('хранилище заголовков', () {
    test('запоминает и забывает по адресу', () {
      final Uri url = Uri.parse('https://example.test/stream');
      StreamRequestHeaders.remember(url, <String, String>{
        'Cookie': 'SID=1',
      });
      expect(StreamRequestHeaders.forUrl(url.toString()), <String, String>{
        'Cookie': 'SID=1',
      });

      // У обычного потока заголовков нет — старую запись нужно снять.
      StreamRequestHeaders.remember(url, null);
      expect(StreamRequestHeaders.forUrl(url.toString()), isNull);
    });
  });
}
