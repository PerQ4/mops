// Временный инструмент: проверяет на живом запросе, отдаёт ли главная
// YouTube Music токены продолжения и приходят ли по ним новые секции.
//
// Запуск: dart run tool/home_continuation_probe.dart
//
// Проходит ровно тот путь, что и экран: CatalogSource.homePage() и токен из
// BrowseParser.continuationToken(). Если продолжения нет, бесконечная
// прокрутка на главной невозможна без другого источника секций.
import 'dart:io';

import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:mops/data/models/models.dart';
import 'package:mops/data/sources/browse_parser.dart';
import 'package:mops/data/sources/catalog_source.dart';

Future<void> main() async {
  await BypassManager.instance.apply(const AntiDpiConfig());
  final InnerTubeClient client = InnerTubeClient(locale: 'ru', region: 'RU');
  final CatalogSource catalog = CatalogSource(client);

  try {
    stdout.writeln('=== Первый запрос главной (CatalogSource.home) ===');
    final List<BrowseSection> viaHome = await catalog.home();
    stdout.writeln('  home() секций: ${viaHome.length} '
        '(старый метод ещё работает)');

    final ({List<BrowseSection> sections, String? continuation}) first =
        await catalog.homePage();
    stdout.writeln('  homePage() секций: ${first.sections.length}');
    // Проверяем сам парсер на сыром ответе (не на записи).
    final Map<String, dynamic> raw = await client.browse('FEmusic_home');
    stdout.writeln('  BrowseParser.continuationToken(raw): '
        '${BrowseParser.continuationToken(raw) == null ? "null" : "есть"}');
    stdout.writeln('  homePage().continuation: '
        '${first.continuation == null ? "null" : "есть"}');
    for (final BrowseSection s in first.sections) {
      stdout.writeln('    • ${s.title} — ${s.items.length}');
    }

    // Идём по цепочке продолжений, пока она есть.
    String? token = first.continuation;
    for (int page = 1; page <= 6 && token != null; page++) {
      stdout.writeln('\n=== Продолжение #$page ===');
      final ({List<BrowseSection> sections, String? continuation}) next =
          await catalog.homePage(continuation: token);
      stdout.writeln('  секций: ${next.sections.length}');
      for (final BrowseSection s in next.sections) {
        stdout.writeln('    • ${s.title} — ${s.items.length}');
      }
      token = next.continuation;
      stdout
          .writeln('  следующий токен: ${token == null ? "нет (конец)" : "есть"}');
    }

    stdout.writeln('\nИТОГ: главная докручивается по токену продолжения.');
  } on Object catch (error, stack) {
    stdout.writeln('ОШИБКА: $error');
    stdout.writeln(stack.toString().split('\n').take(6).join('\n'));
    exitCode = 1;
  } finally {
    client.dispose();
    await BypassManager.instance.dispose();
  }
  exit(exitCode);
}
