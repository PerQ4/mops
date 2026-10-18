import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../data/models/models.dart';

/// Экспорт плейлиста в M3U — файл для другого плеера.
///
/// Формат выбран потому, что его понимают почти все плееры, а данных у нас
/// ровно столько, сколько нужно: идентификатор трека (`videoId`), название,
/// исполнители и длительность. Идентификатор отдельного поля в M3U не имеет,
/// поэтому он идёт в самой ссылке на трек (`watch?v=…`).

/// Расширение файла экспорта.
const String m3uExtension = 'm3u';

/// Собирает текст плейлиста в формате M3U.
///
/// На каждый трек — строка `#EXTINF` с длительностью в секундах и подписью
/// «Исполнители - Название», под ней ссылка. Длительность неизвестна —
/// `-1`: так велит формат, и плеер тогда считает время сам.
String buildM3uPlaylist(Playlist playlist) {
  final StringBuffer buffer = StringBuffer('#EXTM3U\n');
  buffer.write('#PLAYLIST:${_singleLine(playlist.title)}\n');

  for (final Track track in playlist.tracks) {
    final int seconds = track.duration.inSeconds;
    final String artists =
        track.artists.map((ArtistRef artist) => artist.name).join(', ');
    final String title = _singleLine(track.title);
    final String label = artists.isEmpty ? title : '$artists - $title';
    buffer.write('#EXTINF:${seconds > 0 ? seconds : -1},$label\n');
    buffer.write('https://music.youtube.com/watch?v=${track.id}\n');
  }

  return buffer.toString();
}

/// Имя файла по названию плейлиста.
///
/// Запрещённые в именах файлов символы заменяются подчёркиванием: иначе
/// сохранение упало бы на плейлисте вроде «Rock/Pop».
String suggestedM3uFileName(String title) {
  final String safe = title
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  return '${safe.isEmpty ? 'playlist' : safe}.$m3uExtension';
}

/// Путь по умолчанию: «Загрузки», а если системы их не отдали — документы.
///
/// Как в резервной копии настроек: сначала пробуем «Загрузки», потому что
/// файл почти всегда несут в другой плеер, а не оставляют в недрах профиля.
Future<String> defaultM3uPath(String title) async {
  Directory? dir;
  try {
    dir = await getDownloadsDirectory();
  } on Object {
    // На части платформ «Загрузок» нет — не повод не предложить путь.
  }
  dir ??= await getApplicationDocumentsDirectory();
  return '${dir.path}${Platform.pathSeparator}${suggestedM3uFileName(title)}';
}

/// Записывает плейлист в файл по указанному пути.
///
/// Ошибки не глушим: вызывающий показывает их пользователю честно.
Future<void> writeM3uFile(Playlist playlist, String path) async {
  final File file = File(path);
  // Родительский каталог может не существовать — создаём, иначе запись
  // упадёт с «путь не найден» на ровном месте.
  await file.parent.create(recursive: true);
  await file.writeAsString(buildM3uPlaylist(playlist), flush: true);
}

/// Схлопывает переводы строк: M3U построчный, и название с `\n` сломало бы
/// разбор файла у плеера.
String _singleLine(String value) =>
    value.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
