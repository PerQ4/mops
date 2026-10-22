// Проверка ссылки на поток перед выдачей её плееру.
//
// Сеть не нужна: поднимается локальный сервер, который отвечает как
// googlevideo — на рабочий адрес отдаёт байт по `Range`, на «недоступный»
// трек отвечает 503 с пустым телом.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/playback/playback_failure.dart';
import 'package:mops/data/local/app_settings.dart';
import 'package:mops/data/sources/stream_resolver.dart';

/// Заглушка медиасервера YouTube.
class _FakeMediaServer {
  _FakeMediaServer._(this._server);

  final HttpServer _server;

  /// Пути запросов в порядке поступления — по ним видно перебор вариантов.
  final List<String> requested = <String>[];

  /// Заголовок `Range` последнего запроса.
  String? lastRange;

  static Future<_FakeMediaServer> start() async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final _FakeMediaServer fake = _FakeMediaServer._(server);
    server.listen(fake._handle);
    return fake;
  }

  int get port => _server.port;

  Uri url(String path) => Uri.parse('http://127.0.0.1:$port$path');

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    requested.add(request.uri.path);
    lastRange = request.headers.value(HttpHeaders.rangeHeader);

    final HttpResponse response = request.response;
    try {
      if (request.uri.path == '/stall') {
        // Заголовки ушли, тело не приходит: проверка должна сработать по
        // таймауту, а не ждать вечно.
        response
          ..statusCode = HttpStatus.ok
          ..headers.contentLength = 1024
          ..bufferOutput = false;
        await response.flush();
        return;
      }

      switch (request.uri.path) {
        case '/ok206':
          response
            ..statusCode = HttpStatus.partialContent
            ..headers.contentLength = 1
            ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/1024')
            ..add(<int>[0]);
        case '/ok200':
          response
            ..statusCode = HttpStatus.ok
            ..headers.contentLength = 512
            ..add(List<int>.filled(512, 0));
        case '/refused':
          response.statusCode = HttpStatus.serviceUnavailable;
        case '/empty':
          response
            ..statusCode = HttpStatus.ok
            ..headers.contentLength = 0;
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    } on Object {
      // Клиент обрывает соединение сразу после первого байта — так и должно
      // быть: проверке не нужен весь файл.
    }
  }
}

/// InnerTube, который на любой запрос отдаёт заранее собранный ответ.
class _FakeInnerTube extends InnerTubeClient {
  _FakeInnerTube(this.response);

  final Map<String, dynamic> response;

  @override
  Future<Map<String, dynamic>> post(
    String endpoint, {
    Map<String, dynamic> body = const <String, dynamic>{},
    Map<String, String> query = const <String, String>{},
    bool authenticated = false,
    Map<String, String> extraHeaders = const <String, String>{},
  }) async {
    return response;
  }
}

Map<String, dynamic> _format(String mime, int bitrate, Uri url) =>
    <String, dynamic>{
      'mimeType': mime,
      'bitrate': bitrate,
      'url': url.toString(),
    };

Map<String, dynamic> _playerResponse(List<Map<String, dynamic>> formats) =>
    <String, dynamic>{
      'playabilityStatus': <String, dynamic>{'status': 'OK'},
      'streamingData': <String, dynamic>{'adaptiveFormats': formats},
    };

ResolvedStream _link(Uri url) => ResolvedStream(
      url: url,
      bitrateKbps: 128,
      container: 'm4a',
      mimeType: 'audio/mp4',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );

YoutubeStreamResolver _resolver({
  Map<String, dynamic>? player,
  Future<List<ResolvedStream>> Function(String videoId)? fallback,
  Future<String?> Function(String videoId)? localFile,
}) {
  return YoutubeStreamResolver(
    innerTube: _FakeInnerTube(
      player ??
          <String, dynamic>{
            'playabilityStatus': <String, dynamic>{'status': 'OK'},
          },
    ),
    locale: 'ru',
    region: 'RU',
    // Один профиль и подставленный запасной источник: настоящая библиотека в
    // тесте не должна ходить в сеть.
    clientChoice: StreamSource.visionOs,
    fallbackLinks: fallback ?? (String _) async => const <ResolvedStream>[],
    localFile: localFile,
  );
}

/// Порт, на котором заведомо никто не слушает.
Future<int> _closedPort() async {
  final ServerSocket socket =
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final int port = socket.port;
  await socket.close();
  return port;
}

void main() {
  late _FakeMediaServer server;

  setUp(() async {
    server = await _FakeMediaServer.start();
  });

  tearDown(() async {
    await server.close();
  });

  group('проверка ссылки', () {
    test('206 на короткий диапазон — ссылка годная', () async {
      final YoutubeStreamResolver resolver = _resolver(
        player: _playerResponse(<Map<String, dynamic>>[
          _format('audio/mp4', 131000, server.url('/ok206')),
        ]),
      );
      addTearDown(resolver.dispose);

      final ResolvedStream stream =
          await resolver.resolve('vid', quality: AudioQuality.high);

      expect(stream.url.path, '/ok206');
      // Проверка просит ровно один байт, а не файл целиком.
      expect(server.requested, <String>['/ok206']);
      expect(server.lastRange, 'bytes=0-0');
    });

    test('200 с телом — тоже годная', () async {
      final YoutubeStreamResolver resolver = _resolver(
        player: _playerResponse(<Map<String, dynamic>>[
          _format('audio/webm', 160000, server.url('/ok200')),
        ]),
      );
      addTearDown(resolver.dispose);

      final ResolvedStream stream =
          await resolver.resolve('vid', quality: AudioQuality.high);

      expect(stream.url.path, '/ok200');
      expect(server.requested, <String>['/ok200']);
    });

    test('200 с пустым телом — отказ: данных не будет', () async {
      final YoutubeStreamResolver resolver = _resolver(
        player: _playerResponse(<Map<String, dynamic>>[
          _format('audio/mp4', 131000, server.url('/empty')),
        ]),
      );
      addTearDown(resolver.dispose);

      await expectLater(
        resolver.resolve('vid', quality: AudioQuality.high),
        throwsA(
          isA<StreamResolutionException>()
              .having((StreamResolutionException e) => e.message, 'сообщение',
                  contains('200'))
              .having((StreamResolutionException e) => e.unavailable,
                  'недоступен', isTrue),
        ),
      );
    });
  });

  group('перебор вариантов', () {
    test('503 на лучшей дорожке — играет следующая', () async {
      final YoutubeStreamResolver resolver = _resolver(
        player: _playerResponse(<Map<String, dynamic>>[
          // «Максимум» берёт дорожку с большим битрейтом — она и откажет.
          _format('audio/mp4', 160000, server.url('/refused')),
          _format('audio/webm', 70000, server.url('/ok206')),
        ]),
      );
      addTearDown(resolver.dispose);

      final ResolvedStream stream =
          await resolver.resolve('vid', quality: AudioQuality.high);

      expect(stream.url.path, '/ok206');
      expect(server.requested, <String>['/refused', '/ok206']);
    });

    test('все дорожки 503 — ошибка с кодом и пометкой «недоступен»', () async {
      final YoutubeStreamResolver resolver = _resolver(
        player: _playerResponse(<Map<String, dynamic>>[
          _format('audio/mp4', 160000, server.url('/refused')),
          _format('audio/webm', 70000, server.url('/refused')),
        ]),
      );
      addTearDown(resolver.dispose);

      Object? failure;
      try {
        await resolver.resolve('vid', quality: AudioQuality.high);
      } on Object catch (error) {
        failure = error;
      }

      expect(failure, isA<StreamResolutionException>());
      final StreamResolutionException error =
          failure! as StreamResolutionException;
      expect(error.message, contains('503'));
      expect(error.message, contains('недоступен'));
      expect(error.unavailable, isTrue);
      // Именно этот признак включает в списках «Недоступен» и «Найти замену».
      expect(failureOfResolution(error), PlaybackFailure.unavailable);
      // Оба варианта проверены, прежде чем сдаться.
      expect(server.requested, <String>['/refused', '/refused']);
    });

    test('основной клиент не дал ссылок — пробуем запасной источник', () async {
      final YoutubeStreamResolver resolver = _resolver(
        // Ответ без `streamingData`: у клиента ссылок нет.
        fallback: (String _) async => <ResolvedStream>[
          _link(server.url('/refused')),
          _link(server.url('/ok206')),
        ],
      );
      addTearDown(resolver.dispose);

      final ResolvedStream stream =
          await resolver.resolve('vid', quality: AudioQuality.high);

      expect(stream.url.path, '/ok206');
      expect(server.requested, <String>['/refused', '/ok206']);
    });

    test('отказ запасного источника — та же понятная ошибка', () async {
      final YoutubeStreamResolver resolver = _resolver(
        fallback: (String _) async => <ResolvedStream>[
          _link(server.url('/refused')),
        ],
      );
      addTearDown(resolver.dispose);

      await expectLater(
        resolver.resolve('vid', quality: AudioQuality.high),
        throwsA(
          isA<StreamResolutionException>()
              .having((StreamResolutionException e) => e.message, 'сообщение',
                  contains('503'))
              .having((StreamResolutionException e) => e.unavailable,
                  'недоступен', isTrue),
        ),
      );
    });
  });

  group('сеть, а не отказ', () {
    test('сервер замолчал после заголовков — проверка не состоялась', () async {
      final StreamLinkChecker checker = StreamLinkChecker(
        timeout: const Duration(milliseconds: 300),
      );
      addTearDown(checker.dispose);

      final StreamLinkProbe probe = await checker.check(server.url('/stall'));

      // Таймаут — это отсутствие ответа, а не отказ: по нему нельзя сказать,
      // что трек недоступен.
      expect(probe.state, StreamLinkState.unchecked);
    });

    test('обрыв проверки не делает трек недоступным', () async {
      final Uri dead = Uri.parse('http://127.0.0.1:${await _closedPort()}/x');
      final YoutubeStreamResolver resolver = _resolver(
        player: _playerResponse(<Map<String, dynamic>>[
          _format('audio/mp4', 131000, dead),
        ]),
      );
      addTearDown(resolver.dispose);

      // Ссылка отдаётся как раньше: проверка не состоялась, судить о треке
      // не по чему.
      final ResolvedStream stream =
          await resolver.resolve('vid', quality: AudioQuality.high);
      expect(stream.url, dead);
    });

    test('скачанный файл не проверяется по сети', () async {
      final Directory dir = Directory.systemTemp.createTempSync('mops-verify-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File file = File('${dir.path}/track.m4a')
        ..writeAsBytesSync(<int>[0, 1, 2]);

      final YoutubeStreamResolver resolver = _resolver(
        player: _playerResponse(<Map<String, dynamic>>[
          _format('audio/mp4', 131000, server.url('/ok206')),
        ]),
        localFile: (String _) async => file.path,
      );
      addTearDown(resolver.dispose);

      final ResolvedStream stream =
          await resolver.resolve('vid', quality: AudioQuality.high);

      expect(stream.isLocal, isTrue);
      expect(stream.url.scheme, 'file');
      // Диск проверять не нужно: медиасервер запросов не получил.
      expect(server.requested, isEmpty);
    });
  });
}
