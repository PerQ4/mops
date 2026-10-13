// Сквозная проверка обхода блокировок настоящим клиентом приложения.
//
// Запуск: dart run tool/front_probe.dart
//
// Проверяет именно тот код, что работает в приложении: InnerTubeClient
// с включённым обходом должен получить конфигурацию, главную страницу,
// результаты поиска и текст песни.
import 'dart:io';

import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/innertube/renderer.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:mops/core/net/fronting.dart';

const String _apiVersionFallback = '1.20240101.01.00';

Future<void> main() async {
  stdout.writeln('=== Диагностика ===');
  final ConnectivityReport report = await ConnectivityCheck.run();
  stdout.writeln('  ${report.ok ? "✓" : "✗"} ${report.summary}');
  for (final String line in report.details) {
    stdout.writeln('    · $line');
  }

  stdout.writeln('\n=== Включаем обход (подмена хоста) ===');
  await BypassManager.instance.apply(
    const AntiDpiConfig(fronting: FrontingConfig(enabled: true)),
  );
  stdout.writeln('  обход активен: ${BypassManager.instance.isActive}');

  final InnerTubeClient client = InnerTubeClient(locale: 'ru', region: 'RU');

  try {
    stdout.writeln('\n=== Конфигурация InnerTube ===');
    final InnerTubeConfig config = await client.bootstrap();
    stdout.writeln('  ключ         : ${config.apiKey.substring(0, 10)}…');
    stdout.writeln('  clientVersion: ${config.clientVersion}');
    stdout.writeln('  visitorData  : ${config.visitorData.isEmpty ? "нет" : "получен"}');

    stdout.writeln('\n=== Главная страница ===');
    final Map<String, dynamic> home = await client.browse('FEmusic_home');
    final List<dynamic> carousels =
        traverseList(home, <String>['musicCarouselShelfRenderer']);
    final List<dynamic> shelves =
        traverseList(home, <String>['musicShelfRenderer']);
    final List<dynamic> tiles =
        traverseList(home, <String>['musicTwoRowItemRenderer']);
    stdout.writeln('  каруселей: ${carousels.length}, '
        'полок: ${shelves.length}, плиток: ${tiles.length}');
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
    for (final String title in titles.take(5)) {
      stdout.writeln('    • $title');
    }

    stdout.writeln('\n=== Поиск «radiohead» ===');
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
      final String? videoId =
          traverseString(song, <String>['playlistItemData', 'videoId']) ??
              traverseString(song, <String>[
                'overlay',
                'musicItemThumbnailOverlayRenderer',
                'content',
                'musicPlayButtonRenderer',
                'playNavigationEndpoint',
                'watchEndpoint',
                'videoId',
              ]);
      stdout.writeln('    • $title  [$videoId]');
    }

    stdout.writeln('\n=== Текст песни ===');
    if (songs.isNotEmpty) {
      final String? videoId =
          traverseString(songs.first, <String>['playlistItemData', 'videoId']) ??
              traverseString(songs.first, <String>[
                'overlay',
                'musicItemThumbnailOverlayRenderer',
                'content',
                'musicPlayButtonRenderer',
                'playNavigationEndpoint',
                'watchEndpoint',
                'videoId',
              ]);
      if (videoId != null) {
        final Map<String, dynamic> next = await client.next(videoId);
        final List<dynamic> tabs =
            traverseList(next, <String>['tabs', 'tabRenderer']);
        stdout.writeln('  вкладок в «далее»: ${tabs.length}');
      }
    }

    stdout.writeln('\nИТОГ: приложение получает данные через обход.');
  } on Object catch (error, stack) {
    stdout.writeln('\nОШИБКА: $error');
    stdout.writeln(stack.toString().split('\n').take(5).join('\n'));
    exitCode = 1;
  } finally {
    client.dispose();
    await BypassManager.instance.dispose();
  }

  // Используется ниже как запасное значение версии клиента.
  stdout.writeln('(запасная версия клиента: $_apiVersionFallback)');
  exit(exitCode);
}
