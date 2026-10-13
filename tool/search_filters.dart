import 'dart:io';
import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';
import 'package:mops/data/models/models.dart';
import 'package:mops/data/sources/catalog_source.dart';

void main() async {
  await BypassManager.instance.apply(const AntiDpiConfig());
  final catalog = CatalogSource(InnerTubeClient(locale: 'ru', region: 'RU'));
  for (final f in SearchFilter.values) {
    try {
      final sections = await catalog.search('radiohead', filter: f);
      final tracks = sections
          .expand((s) => s.items.whereType<TrackItem>())
          .map((t) => t.track)
          .toList();
      final withArtist = tracks.where((t) => t.artists.isNotEmpty).length;
      stdout.writeln('${f.label.padRight(12)} секций=${sections.length} '
          'треков=${tracks.length} с исполнителем=$withArtist');
      for (final t in tracks.take(2)) {
        stdout.writeln('    · ${t.title} — ${t.artistLine}');
      }
    } on Object catch (e) {
      stdout.writeln('${f.label.padRight(12)} ОШИБКА: $e');
    }
  }
  await BypassManager.instance.dispose();
  exit(0);
}
