import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/local/lyrics_cache.dart';
import 'providers.dart';

/// Оффсет синхронизации и ручная правка текста — обе вещи привязаны к треку,
/// а не к приложению целиком: у одного клипа времена врут, у другого текст
/// кривой. Поэтому храним их по `videoId`, как BetterLyrics
/// (`blyricsOffset_<videoId>`), а не в общих настройках.

/// Префикс ключа оффсета в `shared_preferences`.
const String kLyricsOffsetPrefix = 'blyricsOffset_';

/// Шаг кнопок оффсета, мс.
const int kLyricsOffsetStepMs = 500;

/// Предел сдвига: дальше ±30 с ошибка синхронизации уже не ошибка, и кнопки
/// превратились бы в перемотку вслепую.
const int kLyricsOffsetLimitMs = 30000;

/// Сдвиг синхронизации текста по треку.
///
/// Положительное значение задерживает подсветку: строка загорается позже, чем
/// без оффсета (см. `lyrics_view.dart`). Хранится на диске под ключом
/// `blyricsOffset_<videoId>` — как в BetterLyrics.
class LyricsOffsets extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() {
    final SharedPreferences prefs = ref.watch(sharedPreferencesProvider);
    final Map<String, int> offsets = <String, int>{};
    for (final String key in prefs.getKeys()) {
      if (!key.startsWith(kLyricsOffsetPrefix)) continue;
      final int? value = prefs.getInt(key);
      if (value != null && value != 0) {
        offsets[key.substring(kLyricsOffsetPrefix.length)] = value;
      }
    }
    return offsets;
  }

  /// Сдвигает оффсет трека на [deltaMs]. Результат сразу виден в тексте:
  /// перезапрашивать ничего не нужно.
  Future<void> nudge(String videoId, int deltaMs) async {
    final int next =
        ((state[videoId] ?? 0) + deltaMs).clamp(-kLyricsOffsetLimitMs, kLyricsOffsetLimitMs);
    if (next == 0) return reset(videoId);
    await _write(videoId, next);
  }

  Future<void> reset(String videoId) async {
    if (!state.containsKey(videoId)) return;
    await ref.read(sharedPreferencesProvider).remove('$kLyricsOffsetPrefix$videoId');
    state = <String, int>{...state}..remove(videoId);
  }

  Future<void> _write(String videoId, int value) async {
    await ref
        .read(sharedPreferencesProvider)
        .setInt('$kLyricsOffsetPrefix$videoId', value);
    state = <String, int>{...state, videoId: value};
  }
}

final NotifierProvider<LyricsOffsets, Map<String, int>> lyricsOffsetProvider =
    NotifierProvider<LyricsOffsets, Map<String, int>>(LyricsOffsets.new);

/// Хранилище ручных правок — одно на приложение: держит файл и очередь записи.
final Provider<LyricsEditsStore> lyricsEditsStoreProvider =
    Provider<LyricsEditsStore>((ref) => LyricsEditsStore());

/// Ручная правка текста по треку.
///
/// Храним именно текст строками: при показе он ложится поверх найденного
/// варианта. Если у оригинала были времена и число строк совпало — времена
/// сохраняются по индексу; если нет — показываем как обычный текст, ничего не
/// выдумывая (см. `_applyEdit` в `lyrics_view.dart`).
///
/// Правки лежат на диске рядом с кэшем текстов, поэтому перезапуск их не
/// теряет. Чтение файла асинхронное, а состояние нужно синхронно: первый кадр
/// обходится без правок, и они поднимаются, как только файл прочитан.
class LyricsEdits extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() {
    final LyricsEditsStore store = ref.watch(lyricsEditsStoreProvider);
    unawaited(
      store.readAll().then((Map<String, String> loaded) {
        if (!ref.mounted) return;
        // Правки, сделанные в этой сессии, важнее прочитанных: они появились
        // позже и уже лежат на диске.
        state = <String, String>{...loaded, ...state};
      }),
    );
    return const <String, String>{};
  }

  /// Сохраняет правку. Пустой текст означает «снять правку» — тогда трек
  /// снова показывается как есть.
  Future<void> set(String videoId, String? text) async {
    final LyricsEditsStore store = ref.read(lyricsEditsStoreProvider);
    final Map<String, String> next = Map<String, String>.of(state);
    if (text == null || text.trim().isEmpty) {
      next.remove(videoId);
      await store.remove(videoId);
    } else {
      next[videoId] = text;
      await store.write(videoId, text);
    }
    state = next;
  }
}

final NotifierProvider<LyricsEdits, Map<String, String>> lyricsEditsProvider =
    NotifierProvider<LyricsEdits, Map<String, String>>(LyricsEdits.new);
