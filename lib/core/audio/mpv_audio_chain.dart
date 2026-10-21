import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// Единственный владелец свойства `af` для одного плеера libmpv.
///
/// **Почему владелец один.** В `af` пишут трое: движок (эквалайзер, пропуск
/// тишины, нормализация), монитор уровня (`astats` визуализатора) и сам
/// media_kit (`scaletempo` при смене темпа/питча). Если каждый читает `af`,
/// дописывает свой кусок и возвращает цепочку, вторая запись собирается из
/// устаревшего состояния и теряет первую. Кроме того `open` сбрасывает `af`
/// целиком — и это тоже запись, которую нужно пережить.
///
/// Поэтому участники не трогают `af` сами, а держат свою «долю»
/// ([setPart]): набор фильтров с метками. Очередь [MpvAudioChain] по одному
/// разу читает текущую цепочку, сохраняет чужие фильтры (всё, что не с меткой
/// `@mops`), дописывает доли в порядке приоритета и ставит результат одним
/// `setProperty('af', …)`. После установки цепочка читается обратно — по ней
/// видно, принял ли mpv всё или оставил прежнюю.
///
/// **Почему приоритет, а не просто порядок регистрации.** Порядок фильтров
/// слышен: эквалайзер, тишина и нормализация должны стоять до `astats`, иначе
/// визуализатор покажет уровень до обработки.
///
/// [exclusive] — для операций, которые сами переписывают `af` (`open`,
/// `setRate`, `setPitch` в media_kit): они выполняются в той же очереди, а
/// сразу после них цепочка собирается заново, поэтому между сбросом и
/// восстановлением никто не вклинится.
class MpvAudioChain {
  MpvAudioChain._(this._native);

  /// Очередь отдаётся по плееру, а не по объекту движка/монитора: движок и
  /// монитор создаются разными провайдерами, но делят один `NativePlayer`,
  /// и именно его свойство `af` они обязаны беречь сообща.
  static final Expando<MpvAudioChain> _chains = Expando<MpvAudioChain>(
    'mopsAudioChain',
  );

  /// Владелец для плеера; `null` — у платформы нет свойств mpv.
  static MpvAudioChain? forPlayer(Player player) {
    final PlatformPlayer? platform = player.platform;
    if (platform is! NativePlayer) return null;
    return _chains[platform] ??= MpvAudioChain._(platform);
  }

  /// Все метки наших фильтров начинаются так: по этому префиксу владелец
  /// отличает своё от чужого (`scaletempo`) при пересборке.
  static const String ownedPrefix = '@mops';

  /// Чья доля идёт раньше. Эквалайзер/тишина/нормализация — до анализатора.
  static const int enginePriority = 10;
  static const int visualizerPriority = 20;

  final NativePlayer _native;

  /// Доли в порядке добавления. Ключ — имя участника, чтобы обновление доли
  /// не плодило копий.
  final Map<String, _ChainPart> _parts = <String, _ChainPart>{};

  final StreamController<String> _applied =
      StreamController<String>.broadcast();

  /// Хвост очереди. Никогда не завершается ошибкой: иначе следующая задача
  /// не пошла бы.
  Future<void> _tail = Future<void>.value();

  /// Последняя цепочка, прочитанная из mpv после установки.
  String _lastApplied = '';

  /// Каждая пересборка цепочки: для тех, кто хочет знать, что его фильтр
  /// вернулся (монитор уровня — после `open`).
  Stream<String> get applied => _applied.stream;

  /// Добавляет или обновляет долю участника и пересобирает цепочку.
  ///
  /// [filters] — готовые записи фильтров с метками. [apply] = false только
  /// запоминает долю, не трогая mpv: движок так делает, пока поток не открыт.
  /// Возвращает цепочку, которую mpv действительно оставил, — по меткам в ней
  /// видно, принял ли он фильтры (при отказе mpv сохраняет прежнюю цепочку).
  Future<String?> setPart(
    String id,
    int priority,
    List<String> filters, {
    bool apply = true,
  }) {
    _parts[id] = _ChainPart(priority, List<String>.of(filters));
    if (!apply) {
      return Future<String?>.value(_lastApplied.isEmpty ? null : _lastApplied);
    }
    return refresh();
  }

  /// Убирает долю участника (например, визуализатор выключили).
  Future<String?> removePart(String id) {
    if (_parts.remove(id) == null) return Future<String?>.value(_lastApplied);
    return refresh();
  }

  /// Пересобирает цепочку из текущих долей.
  Future<String?> refresh() => _enqueue(_apply);

  /// Текущее содержимое `af` — тоже через очередь, чтобы не читать свойство
  /// посреди чужой записи.
  Future<String> current() => _enqueue(() async {
    try {
      return (await _native.getProperty('af')).trim();
    } on Object catch (error) {
      debugPrint('Не удалось прочитать аудиоцепочку: $error');
      return '';
    }
  });

  /// Выполняет [action] в очереди и сразу после неё возвращает цепочку.
  ///
  /// Нужно для операций media_kit, которые переписывают `af` целиком:
  /// `open`, `setRate`, `setPitch`. Внутри [action] нельзя звать методы этого
  /// класса — они встанут в ту же очередь и будут ждать сами себя.
  Future<T> exclusive<T>(Future<T> Function() action) => _enqueue(() async {
    try {
      return await action();
    } finally {
      await _apply();
    }
  });

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final Completer<T> completer = Completer<T>();
    final Future<void> next = _tail.then((_) async {
      try {
        completer.complete(await action());
      } on Object catch (error, stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      }
    });
    // Хвост не должен падать: следующая задача обязана выполниться.
    _tail = next.then((_) {}, onError: (Object _) {});
    return completer.future;
  }

  /// Собирает и ставит цепочку одним значением.
  Future<String?> _apply() async {
    final String raw;
    try {
      raw = (await _native.getProperty('af')).trim();
    } on Object catch (error) {
      debugPrint('Не удалось прочитать аудиоцепочку: $error');
      return null;
    }

    // Чужое сохраняем на месте: `scaletempo` media_kit ставит сам, и снимать
    // его нельзя — пропала бы компенсация высоты тона.
    final List<String> foreign = splitChain(raw)
        .where((String segment) => !isOwned(segment))
        .toList();

    final List<_ChainPart> ordered = _parts.values.toList()
      ..sort((_ChainPart a, _ChainPart b) => a.priority.compareTo(b.priority));

    final String chain = <String>[
      ...foreign,
      for (final _ChainPart part in ordered) ...part.filters,
    ].join(',');

    try {
      // Один `setProperty`. По частям нельзя: при отказе mpv оставляет всю
      // прежнюю цепочку, и тогда непонятно, что применилось.
      if (chain != raw) await _native.setProperty('af', chain);
      final String applied = (await _native.getProperty('af')).trim();
      _lastApplied = applied;
      if (!_applied.isClosed) _applied.add(applied);
      return applied;
    } on Object catch (error) {
      debugPrint('Не удалось применить аудиоцепочку: $error');
      return null;
    }
  }

  /// Наша ли это запись фильтра.
  static bool isOwned(String segment) => segment.trim().startsWith(ownedPrefix);

  /// Есть ли в цепочке метка [label] (без собаки: `mopsvis`).
  static bool containsLabel(String chain, String label) =>
      splitChain(chain).any((String segment) => segment.startsWith('@$label'));

  /// Разбирает цепочку `af` на отдельные фильтры.
  ///
  /// Запятые внутри параметров mpv отдаёт в «экранированном» виде:
  /// `%<длина>%` и ровно столько символов после него — один литерал. Именно так
  /// приходит граф `lavfi` (`graph=%750%asplit=9…,astats=…`): без разбора этих
  /// литералов запятые графа считались бы разделителями фильтров, и цепочка
  /// визуализатора разваливалась бы на куски при пересборке.
  static List<String> splitChain(String raw) {
    final List<String> segments = <String>[];
    final StringBuffer current = StringBuffer();
    int depth = 0;
    int i = 0;
    while (i < raw.length) {
      final String ch = raw[i];
      if (ch == '%') {
        final int close = raw.indexOf('%', i + 1);
        if (close > i + 1) {
          final int? length = int.tryParse(raw.substring(i + 1, close));
          if (length != null && close + 1 + length <= raw.length) {
            // Литерал целиком, вместе с запятыми и двоеточиями внутри.
            current.write(raw.substring(i, close + 1 + length));
            i = close + 1 + length;
            continue;
          }
        }
      }
      if (ch == '[') depth++;
      if (ch == ']' && depth > 0) depth--;
      if (ch == ',' && depth == 0) {
        final String segment = current.toString().trim();
        if (segment.isNotEmpty) segments.add(segment);
        current.clear();
      } else {
        current.write(ch);
      }
      i++;
    }
    final String last = current.toString().trim();
    if (last.isNotEmpty) segments.add(last);
    return segments;
  }
}

class _ChainPart {
  const _ChainPart(this.priority, this.filters);

  final int priority;
  final List<String> filters;
}
