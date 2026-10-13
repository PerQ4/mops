// Сквозная проверка обхода блокировок настоящим кодом приложения.
//
// Запуск: dart run tool/front_probe.dart [запрос]
//
// Проверяет ровно тот путь, которым пользуется интерфейс: InnerTubeClient,
// разбор ответов и слой каталога. Запускается обычным `dart run`, без
// тестовой подмены сети, поэтому результат отражает реальность.
import 'dart:io';

import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:mops/core/net/fronting.dart';
import 'package:mops/data/models/models.dart';
import 'package:mops/data/sources/catalog_source.dart';

Future<void> main(List<String> args) async {
  final String query = args.isNotEmpty ? args.first : 'radiohead';

  stdout.writeln('=== Диагностика ===');
  final ConnectivityReport report = await ConnectivityCheck.run();
  stdout.writeln('  ${report.ok ? "✓" : "✗"} ${report.summary}');
  for (final String line in report.details) {
    stdout.writeln('    · $line');
  }

  stdout.writeln('\n=== Настройки по умолчанию ===');
  const AntiDpiConfig defaults = AntiDpiConfig();
  stdout.writeln('  обход включён по умолчанию: ${defaults.isEnabled}');
  await BypassManager.instance.apply(defaults);
  stdout.writeln('  применён                  : ${BypassManager.instance.isActive}');

  final InnerTubeClient client = InnerTubeClient(locale: 'ru', region: 'RU');
  final CatalogSource catalog = CatalogSource(client);

  try {
    stdout.writeln('\n=== Главная страница ===');
    final List<BrowseSection> sections = await catalog.home();
    stdout.writeln('  секций: ${sections.length}');
    for (final BrowseSection section in sections.take(6)) {
      stdout.writeln('    • ${section.title} — ${section.items.length}');
    }
    if (sections.isEmpty) {
      stdout.writeln('  ПУСТО — вероятна ошибка');
      exitCode = 1;
    }

    stdout.writeln('\n=== Поиск «$query» ===');
    final List<BrowseSection> found = await catalog.search(query);
    stdout.writeln('  секций: ${found.length}');
    int tracks = 0;
    for (final BrowseSection section in found.take(6)) {
      final int trackCount =
          section.items.whereType<TrackItem>().length;
      tracks += trackCount;
      stdout.writeln('    • ${section.title} — ${section.items.length} '
          '(треков: $trackCount)');
    }
    final List<Track> allTracks = found
        .expand((BrowseSection s) => s.items.whereType<TrackItem>())
        .map((TrackItem item) => item.track)
        .toList();
    for (final Track track in allTracks.take(5)) {
      stdout.writeln('      – ${track.title} · ${track.artistLine} '
          '[${track.id}]');
    }
    if (tracks == 0) {
      stdout.writeln('  треков не найдено — вероятна ошибка');
      exitCode = 1;
    }

    stdout.writeln('\n=== Текст песни ===');
    if (allTracks.isNotEmpty) {
      final Lyrics lyrics = await catalog.lyrics(allTracks.first.id);
      stdout.writeln('  синхронизирован: ${lyrics.isSynced}, '
          'пусто: ${lyrics.isEmpty}');
    }

    stdout.writeln(
      exitCode == 0
          ? '\nИТОГ: приложение получает данные через обход без настройки.'
          : '\nИТОГ: что-то не работает.',
    );
  } on Object catch (error, stack) {
    stdout.writeln('\nОШИБКА: $error');
    stdout.writeln(stack.toString().split('\n').take(5).join('\n'));
    exitCode = 1;
  } finally {
    client.dispose();
    await BypassManager.instance.dispose();
  }
  exit(exitCode);
}
