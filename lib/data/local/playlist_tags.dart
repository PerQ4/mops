import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'json_store.dart';
import 'lyrics_cache.dart';

/// Локальные теги плейлистов: «плейлист → набор тегов».
///
/// Теги — только локальные: в YouTube Music их нет, серверного поля под них не
/// существует, поэтому хранить их больше негде. Файл лежит рядом с кэшем
/// текстов в каталоге данных приложения ([appDataDirectory]) и переживает
/// перезапуск — в этом весь смысл: разложить плейлисты по своим ярлыкам, пока
/// сервис этого не умеет.
///
/// TTL у тегов нет: это ручная разметка пользователя, а не ответ сервера, и
/// устареть сама по себе она не может. Предел числа записей всё же есть —
/// иначе файл рос бы без предела.
class PlaylistTagsStore {
  PlaylistTagsStore({this.fileName = 'playlist_tags.json'});

  final String fileName;

  /// Предел числа записей. При переполнении вытесняются самые старые: тегов
  /// у давно забытого плейлиста уже никто не увидит.
  static const int maxEntries = 500;

  File? _file;

  /// Общий файл: атомарная запись, копия повреждённого файла, запрет записи
  /// до успешного чтения (см. [JsonStore]).
  late final JsonStore _json = JsonStore(
    resolve: _tagsFile,
    label: 'PlaylistTagsStore',
  );

  /// Теги в памяти: нужны, чтобы запись одного плейлиста не перечитывала файл
  /// целиком и чтобы повторные чтения не били по диску.
  Map<String, _StoredTags>? _memory;

  /// Загрузка файла идёт один раз: параллельные чтения ждут её же.
  Future<void>? _loading;

  /// Все сохранённые наборы тегов: id плейлиста → теги.
  ///
  /// Ошибки файла и JSON наружу не пробрасываются: недоступное хранилище —
  /// это отсутствие тегов, а не повод не показать библиотеку. Но ошибка
  /// чтения видна в [readFailed], и тогда запись не выполняется.
  Future<Map<String, Set<String>>> readAll() async {
    final Map<String, _StoredTags> entries = await _entries();
    return <String, Set<String>>{
      for (final MapEntry<String, _StoredTags> item in entries.entries)
        item.key: item.value.tags,
    };
  }

  /// Файл не прочитался: тегов в памяти нет, писать в файл нельзя.
  bool get readFailed => _json.readFailed;

  /// Сохраняет набор тегов плейлиста. Пустой набор не пишется: снятие всех
  /// тегов — это [remove], а не запись пустоты.
  Future<void> write(String playlistId, Set<String> tags) async {
    if (playlistId.isEmpty) return;
    final Set<String> clean = _clean(tags);
    if (clean.isEmpty) return remove(playlistId);

    final Map<String, _StoredTags> entries = await _entries();
    entries[playlistId] = _StoredTags(
      tags: clean,
      at: DateTime.now().millisecondsSinceEpoch,
    );
    _evictOldest(entries);
    await _persist(entries);
  }

  /// Убирает теги плейлиста — и в памяти, и на диске.
  Future<void> remove(String playlistId) async {
    if (playlistId.isEmpty) return;
    final Map<String, _StoredTags> entries = await _entries();
    if (entries.remove(playlistId) == null) return;
    await _persist(entries);
  }

  /// Полная очистка — и в памяти, и на диске.
  Future<void> clear() async {
    _memory = <String, _StoredTags>{};
    await _json.deleteFile();
  }

  /// Возвращает записи из памяти, загрузив файл при первом обращении.
  Future<Map<String, _StoredTags>> _entries() async {
    final Map<String, _StoredTags>? ready = _memory;
    if (ready != null) return ready;
    _loading ??= _loadFromDisk();
    await _loading;
    return _memory ?? <String, _StoredTags>{};
  }

  Future<void> _loadFromDisk() async {
    final dynamic decoded = await _json.read();
    final Map<String, _StoredTags> parsed = <String, _StoredTags>{};
    if (decoded != null) _readEntries(decoded, parsed);
    if (_json.readFailed) {
      debugPrint('[PlaylistTagsStore] теги не прочитаны — запись отключена');
    }
    _memory = parsed;
  }

  /// Разбирает содержимое файла. Битая запись пропускается целиком — один
  /// испорченный набор не должен обнулять остальные.
  void _readEntries(dynamic decoded, Map<String, _StoredTags> into) {
    final dynamic raw =
        decoded is Map<String, dynamic> ? decoded['entries'] : null;
    if (raw is! List) return;

    final int now = DateTime.now().millisecondsSinceEpoch;
    for (final dynamic item in raw) {
      if (item is! Map<String, dynamic>) continue;
      final dynamic playlistId = item['playlistId'];
      final dynamic tags = item['tags'];
      if (playlistId is! String || playlistId.isEmpty) continue;
      if (tags is! List) continue;

      final Set<String> clean = _clean(
        tags.whereType<String>(),
      );
      if (clean.isEmpty) continue;

      final dynamic at = item['at'];
      into[playlistId] = _StoredTags(
        tags: clean,
        at: at is num ? at.toInt() : now,
      );
    }
  }

  /// Вытесняет самые старые наборы, если записей стало больше [maxEntries].
  void _evictOldest(Map<String, _StoredTags> entries) {
    if (entries.length <= maxEntries) return;
    final List<MapEntry<String, _StoredTags>> all = entries.entries.toList()
      ..sort(
        (MapEntry<String, _StoredTags> a, MapEntry<String, _StoredTags> b) =>
            a.value.at.compareTo(b.value.at),
      );
    for (int i = 0; i < all.length - maxEntries; i++) {
      entries.remove(all[i].key);
    }
  }

  /// Пишет снимок в файл. Снимок кодируется сразу: пока ждём очередь, память
  /// могла измениться, а на диск должно попасть согласованное состояние.
  Future<void> _persist(Map<String, _StoredTags> entries) async {
    final List<Map<String, dynamic>> flat = <Map<String, dynamic>>[];
    for (final MapEntry<String, _StoredTags> item in entries.entries) {
      flat.add(<String, dynamic>{
        'playlistId': item.key,
        'at': item.value.at,
        'tags': item.value.tags.toList(),
      });
    }
    final String payload =
        jsonEncode(<String, dynamic>{'version': 1, 'entries': flat});
    if (!await _json.writeString(payload)) {
      debugPrint('[PlaylistTagsStore] теги остались только в памяти');
    }
  }

  Future<File> _tagsFile() async {
    final File? ready = _file;
    if (ready != null) return ready;
    final Directory dir = await appDataDirectory();
    final File file =
        File('${dir.path}${Platform.pathSeparator}$fileName');
    _file = file;
    return file;
  }

  /// Приводит набор к виду хранения: теги обрезаны, пустые выброшены,
  /// повторы убраны.
  static Set<String> _clean(Iterable<String> tags) {
    final Set<String> clean = <String>{};
    for (final String raw in tags) {
      final String? tag = normalizePlaylistTag(raw);
      if (tag != null) clean.add(tag);
    }
    return clean;
  }
}

/// Приводит тег к виду хранения: обрезает пробелы по краям, пустой отбрасывает.
///
/// Тег без букв нечего показывать в чипе, поэтому пустой строкой набор не
/// пополняется. Регистр не меняем — это ярлык пользователя, а не ключ.
String? normalizePlaylistTag(String raw) {
  final String tag = raw.trim();
  return tag.isEmpty ? null : tag;
}

/// Запись тегов: набор ярлыков и время записи (мс от эпохи) — по нему
/// выбираются самые старые при вытеснении.
@immutable
class _StoredTags {
  const _StoredTags({required this.tags, required this.at});

  final Set<String> tags;
  final int at;
}
