// Пробник сети: проверяет, что InnerTube-клиент реально работает.
//
// Запуск: dart run tool/probe.dart
// Зависит только от чистого Dart (http + crypto), поэтому запускается
// без Flutter-движка и не требует графики.
import 'dart:io';

import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/innertube/renderer.dart';

Future<void> main() async {
  final InnerTubeClient client = InnerTubeClient(locale: 'ru', region: 'RU');

  try {
    stdout.writeln('== 1. Получение конфигурации ==');
    final InnerTubeConfig config = await client.bootstrap();
    stdout.writeln('  apiKey       : ${config.apiKey.substring(0, 10)}…');
    stdout.writeln('  apiVersion   : ${config.apiVersion}');
    stdout.writeln('  clientName   : ${config.clientName}');
    stdout.writeln('  clientVersion: ${config.clientVersion}');
    stdout.writeln('  visitorData  : ${config.visitorData.isEmpty ? "ПУСТО (плохо)" : "есть"}');
    stdout.writeln('  gl/hl        : ${config.gl}/${config.hl}');

    stdout.writeln('\n== 2. Главная страница (FEmusic_home) ==');
    final Map<String, dynamic> home = await client.browse('FEmusic_home');
    final List<dynamic> contents =
        traverseList(home, <String>['sectionListRenderer', 'contents']);
    stdout.writeln('  элементов в sectionList : ${contents.length}');
    stdout.writeln('  каруселей               : ${traverseList(home, <String>["musicCarouselShelfRenderer"]).length}');
    stdout.writeln('  полок (shelf)           : ${traverseList(home, <String>["musicShelfRenderer"]).length}');
    stdout.writeln('  плиток two-row          : ${traverseList(home, <String>["musicTwoRowItemRenderer"]).length}');
    stdout.writeln('  строк-треков            : ${traverseList(home, <String>["musicResponsiveListItemRenderer"]).length}');

    final List<String> titles = traverseStrings(
      home,
      <String>[
        'musicCarouselShelfRenderer',
        'header',
        'musicCarouselShelfHeaderRenderer',
        'title',
        'runs',
        'text',
      ],
    );
    stdout.writeln('  заголовки секций        : ${titles.take(6).toList()}');

    stdout.writeln('\n== 3. Поиск "radiohead" (только треки) ==');
    final Map<String, dynamic> search = await client.search(
      'radiohead',
      params: 'Eg-KAQwIARAAGAAgACgAMABqChAEEAMQCRAFEAo=',
    );
    final List<dynamic> songs =
        traverseList(search, <String>['musicResponsiveListItemRenderer']);
    stdout.writeln('  найдено треков: ${songs.length}');
    for (final dynamic song in songs.take(3)) {
      final String? title = traverseString(song, <String>[
        'flexColumns',
        'musicResponsiveListItemFlexColumnRenderer',
        'text',
        'runs',
        'text',
      ]);
      final String? videoId = traverseString(song, <String>['playlistItemData', 'videoId']);
      stdout.writeln('    • $title  [$videoId]');
    }

    stdout.writeln('\n== 4. Проверка выбора видео-id из строки ==');
    if (songs.isNotEmpty) {
      final dynamic first = songs.first;
      final String? viaRoot = traverseString(first, <String>['videoId']);
      final String? viaOverlay = traverseString(first, <String>[
        'overlay',
        'musicItemThumbnailOverlayRenderer',
        'content',
        'musicPlayButtonRenderer',
        'playNavigationEndpoint',
        'watchEndpoint',
        'videoId',
      ]);
      stdout.writeln('  videoId в корне    : $viaRoot');
      stdout.writeln('  videoId в overlay  : $viaOverlay');
      stdout.writeln('  playlistItemData   : ${traverseString(first, <String>["playlistItemData", "videoId"])}');
      stdout.writeln('  watchEndpoint      : ${traverseString(first, <String>["navigationEndpoint", "watchEndpoint", "videoId"])}');
    }

    stdout.writeln('\nPROBE_OK');
  } on Exception catch (error, stack) {
    stdout.writeln('\nPROBE_FAILED: $error');
    stdout.writeln(stack);
    exitCode = 1;
  } finally {
    client.dispose();
  }
}
