// Проверка сборки ресайзбл-загрузки: протокол не описан официально, поэтому
// фиксируем тестами, что заголовки обоих шагов именно такие. Сеть не нужна —
// подставляем фиктивный http-клиент.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mops/core/innertube/innertube_client.dart';

void main() {
  test('resumable-загрузка: заголовки start и upload, finalize', () async {
    final List<http.Request> requests = <http.Request>[];

    final MockClient mock = MockClient((http.Request request) async {
      requests.add(request);

      // Bootstrap страницы YouTube Music: без ключа клиент берёт публичный
      // и работает дальше.
      if (request.url.path == '/') {
        return http.Response('<html></html>', 200);
      }

      if (request.headers['X-Goog-Upload-Command'] == 'start') {
        return http.Response(
          '',
          200,
          headers: <String, String>{
            // Имя намеренно в другом регистре: клиент обязан найти заголовок
            // без учёта регистра.
            'X-Goog-Upload-URL':
                'https://music.youtube.com/upload/done?upload_id=abc',
          },
        );
      }

      return http.Response('{"encryptedBlobId":"BLOB"}', 200);
    });

    final InnerTubeClient client = InnerTubeClient(httpClient: mock);
    final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);

    final Map<String, dynamic> result = await client.uploadResumable(
      '/playlist_image_upload/playlist_custom_thumbnail',
      bytes: bytes,
      contentType: 'image/png',
    );

    expect(result['encryptedBlobId'], 'BLOB');
    // bootstrap + start + upload.
    expect(requests, hasLength(3));

    final http.Request start = requests[1];
    expect(start.method, 'POST');
    expect(
      start.url.path,
      '/playlist_image_upload/playlist_custom_thumbnail',
    );
    expect(start.headers['X-Goog-Upload-Protocol'], 'resumable');
    expect(start.headers['X-Goog-Upload-Command'], 'start');
    expect(start.headers['X-Goog-Upload-Header-Content-Length'], '5');
    expect(start.headers['X-Goog-Upload-Header-Content-Type'], 'image/png');
    // Метаданные картинки уходят заголовками, тело пустое.
    expect(start.bodyBytes, isEmpty);

    final http.Request upload = requests[2];
    expect(upload.url.toString(), contains('upload_id=abc'));
    expect(upload.headers['X-Goog-Upload-Command'], 'upload, finalize');
    expect(upload.headers['X-Goog-Upload-Offset'], '0');
    expect(upload.bodyBytes, bytes);
  });

  test('resumable-загрузка: без X-Goog-Upload-URL — честная ошибка', () async {
    final MockClient mock = MockClient((http.Request request) async {
      if (request.url.path == '/') return http.Response('<html></html>', 200);
      return http.Response('', 200);
    });

    final InnerTubeClient client = InnerTubeClient(httpClient: mock);

    expect(
      () => client.uploadResumable(
        '/playlist_image_upload/playlist_custom_thumbnail',
        bytes: Uint8List.fromList(<int>[1]),
        contentType: 'image/png',
      ),
      throwsA(isA<InnerTubeException>()),
    );
  });
}
