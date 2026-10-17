import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/app_settings.dart';
import '../../data/models/models.dart';
import '../../data/sources/romanization.dart';
import '../../state/catalog_providers.dart';
import '../../state/lyrics_edits.dart';
import '../../state/player_controller.dart';
import '../../state/providers.dart';
import '../../widgets/async_views.dart';
import '../../widgets/empty_state.dart';
import 'lyrics_actions.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Константы — перенесены из ArchiveTune (`ui/component/LyricsV2.kt`,
// `ui/component/LyricsEnhanced.kt`, `ui/component/Lyrics.kt`).
// Значения в комментариях указывают исходник, чтобы при сверке было видно,
// что именно и откуда взято.
// ─────────────────────────────────────────────────────────────────────────────

/// Задержка строчного LRC: строка подсвечивается чуть раньше метки
/// (`LyricsV2.kt:129 LRC_LEAD_MS = 300`).
const int _lrcLeadMs = 300;

/// Для пословной синхронизации задержки нет (`LyricsV2.kt:132`).
const int _wordSyncLeadMs = 0;

/// Сколько ждать после ручной прокрутки, прежде чем вернуться к автопрокрутке
/// (`LyricsV2.kt:135 MANUAL_SCROLL_TIMEOUT_MS = 3000`).
const int _manualScrollTimeoutMs = 3000;

/// Якорь активной строки: она встаёт на 35% высоты от верха
/// (`LyricsV2.kt:293 targetOffset = viewportHeight * 0.35`).
const double _viewportAnchor = 0.35;

/// Прозрачность непоющегося слова/строки (`LyricsV2.kt:203 inactiveAlpha`).
const double _inactiveAlpha = 0.35;

/// Оформление строк по расстоянию до активной (`LyricsV2.kt:549-583`).
const List<double> _alphaTable = <double>[1, 0.52, 0.30, 0.18, 0.10];
const List<double> _manualAlphaTable = <double>[1, 0.72, 0.56, 0.40, 0.28];

/// То же для ноты-вставки: дальше третьей ступени она гаснет до
/// `_inactiveAlpha`, а не до 0.10 как текст. Совсем погасшая нота теряла бы
/// смысл — по ней видно, что в этом месте песни пауза, а не конец текста.
const List<double> _interludeAlphaTable =
    <double>[1, 0.52, 0.30, 0.18, _inactiveAlpha];

/// Сторона квадрата с нотой (`LyricsV2.kt`, instrumental-строка: 48 dp).
const double _interludeNoteSize = 48;


/// То же, но пока пользователь листает вручную (`LyricsV2.kt:559-565`).

/// Радиус размытия неактивных строк (`LyricsV2.kt:584-590`).
///
/// Размытие — это и есть смысл эффекта: текст уходит в глубину по мере
/// удаления от активной строки, а не просто гаснет. Значения как в оригинале.
const List<double> _blurTable = <double>[0, 2, 5, 12];

/// Предельная ширина колонки текста.
///
/// Ограничение из практики чтения: строка длиннее ~560 px уже не читается
/// как строка. В ArchiveTune такого ограничения нет только потому, что там
/// телефон.
const double _lyricsColumnWidth = 560;

/// Сколько строк помещается на экране телефона — эталон оригинала.
///
/// В ArchiveTune затухание задано ступенями 1/2/3 именно потому, что на
/// телефоне видно около семи строк: четвёртая уже за краем. На большом окне
/// строк видно втрое больше, и те же ступени гасили бы почти весь текст —
/// поэтому расстояние делим на отношение числа видимых строк к семи.
const double _phoneVisibleLines = 7;

/// Значение из таблицы по дробному индексу.
///
/// Нужно, чтобы ступени оригинала растягивались на экранах, где видно больше
/// строк, и в точности совпадали с оригиналом на телефоне (там индекс
/// получается целым).
double tableValue(List<double> table, double index) {
  if (index <= 0) return table.first;
  final int low = index.floor();
  if (low >= table.length - 1) return table.last;
  final double t = index - low;
  return table[low] + (table[low + 1] - table[low]) * t;
}

/// Анимации строк (`LyricsV2.kt:600-617`).
const int _scaleDurationMs = 166;
const int _alphaActiveMs = 330;
const int _alphaIdleMs = 500;
const int _blurDurationMs = 300;

/// Оформление «караоке» (`LyricsV2.kt:1207-1228`).
const double _wordBounceFactor = 1;
const double _wordGlowFactor = 1;
const double _wordFillEdgeDp = 8;

/// Сглаживание позиции между обновлениями движка
/// (`LyricsEnhanced.kt:118-121`): за кадр позиция доезжает сама, а к движку
/// подтягивается малыми шагами, иначе подсветка слов «дёргалась» бы на каждом
/// обновлении позиции.
const double _smoothMaxForwardDriftMs = 250;
const double _smoothMaxBackwardDriftMs = 250;
const double _smoothDriftCorrection = 0.08;
const double _smoothMaxCorrectionPerFrameMs = 2;

/// Пружина плавной автопрокрутки: `spring(dampingRatio = NoBouncy,
/// stiffness = StiffnessLow)` из `Lyrics.kt:713-726`. В Compose StiffnessLow —
/// это 200, демпфирование без отскока — критическое (2·√k).
final SpringDescription _autoScrollSpring = SpringDescription(
  mass: 1,
  stiffness: 200,
  damping: 2 * math.sqrt(200),
);

/// Пружина заливки ноты: `spring(stiffness = StiffnessHigh,
/// dampingRatio = NoBouncy)` из `LyricsV2.kt`. В Compose StiffnessHigh — это
/// 10000, демпфирование без отскока — критическое (2·√k).
final SpringDescription _interludeFillSpring = SpringDescription(
  mass: 1,
  stiffness: 10000,
  damping: 2 * math.sqrt(10000),
);

/// Прокрутка без полосы.
///
/// На десктопе Material сам добавляет `Scrollbar` к каждой вертикальной
/// прокрутке, и в тексте песни он висел серой полосой посреди строк — там,
/// где никакого ползунка быть не должно (текст листается колесом или пальцем).
/// Оставляем прокрутку и инерцию, но убираем полосу.
class _LyricsScrollBehavior extends MaterialScrollBehavior {
  const _LyricsScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      child;
}

/// Текст песни: синхронизированный (с автопрокруткой) или обычный.
class LyricsView extends ConsumerStatefulWidget {
  const LyricsView({
    super.key,
    required this.videoId,
    this.compact = false,
  });

  final String videoId;

  /// Компактный режим — для показа поверх обложки.
  final bool compact;

  @override
  ConsumerState<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends ConsumerState<LyricsView> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  bool _searchOpen = false;

  /// Номер выбранного совпадения в списке найденных строк.
  int _matchCursor = 0;

  /// Счётчик переходов: по нему дочерний список понимает, что нужно
  /// прокрутить к строке совпадения, даже если та же строка выбрана снова.
  int _jumpSeq = 0;

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  String get _query => _searchController.text.trim();

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _searchController.clear();
        _matchCursor = 0;
      }
    });
    if (_searchOpen) {
      // Поле появляется только после перестройки — фокус просим кадром позже.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
  }

  void _onQueryChanged(String _) {
    // Сбрасываем выбор на первом совпадении и просим список прокрутиться.
    setState(() {
      _matchCursor = 0;
      _jumpSeq++;
    });
  }

  void _step(int delta, List<int> matches) {
    if (matches.isEmpty) return;
    setState(() {
      _matchCursor = (_matchCursor + delta) % matches.length;
      if (_matchCursor < 0) _matchCursor += matches.length;
      _jumpSeq++;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Метаданные берём у играющего трека: внешняя база (LRCLIB) ищет текст
    // по названию и исполнителю, а не по id YouTube. Ручной поиск для трека
    // важнее — если пользователь ввёл свои данные, ищем по ним.
    final Track? current = ref.watch(currentTrackProvider);
    final LyricsRequest? manual = ref.watch(
      manualLyricsRequestsProvider
          .select((Map<String, LyricsRequest> m) => m[widget.videoId]),
    );
    final LyricsRequest request = manual ??
        ((current != null && current.id == widget.videoId)
            ? LyricsRequest.fromTrack(current)
            : LyricsRequest(videoId: widget.videoId));

    // Источник: ручной выбор для этого трека важнее настройки.
    final LyricsSource selected =
        ref.watch(lyricsSourceOverrideProvider)[request.videoId] ??
            ref.watch(
              settingsControllerProvider.select(
                (AppSettings s) => s.lyricsSource,
              ),
            );

    // Порядок источников из настроек: внутри одного типа синхронизации он
    // решает, какой источник приоритетнее.
    final List<LyricsSource> order = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => s.lyricsProviderOrder,
      ),
    );

    final AsyncValue<LyricsSearchState> searchAsync =
        ref.watch(lyricsProvider(request));
    final LyricsSearchState state =
        searchAsync.value ?? const LyricsSearchState();

    // Правка текста и оффсет привязаны к треку, поэтому читаем их по его id.
    final String? edit = ref.watch(
      lyricsEditsProvider.select((Map<String, String> m) => m[widget.videoId]),
    );
    final int offsetMs = ref.watch(
      lyricsOffsetProvider.select((Map<String, int> m) => m[widget.videoId] ?? 0),
    );

    // Что показываем: в «Авто» — лучший по механизму приоритета (сначала тип
    // синхронизации, затем порядок источников), иначе — ровно выбранную базу.
    // Пустота выбранной базы остаётся пустотой, подмены нет. Ручная правка
    // ложится поверх найденного текста.
    final Lyrics? data = _applyEdit(_resolve(state, selected, order), edit);
    final LyricsCandidate? shown = selected == LyricsSource.auto
        ? state.bestByOrder(order)
        : state.candidateFor(selected);

    // Подсветку и переходы считаем по уже загруженному тексту: держать это в
    // состоянии было бы рассинхронизацией, а строк в песне немного.
    final List<String> lineTexts = _lineTexts(data);
    final List<int> matches = _findMatches(lineTexts, _query);
    final int cursor = matches.isEmpty
        ? -1
        : _matchCursor.clamp(0, matches.length - 1);
    final _LyricsSearch search = _LyricsSearch(
      query: _query,
      currentLine: cursor >= 0 ? matches[cursor] : -1,
      jumpSeq: _jumpSeq,
    );

    // Романизацию спрашиваем только при включённых переключателях: выключенные
    // не должны тянуть сеть. Язык определяется по строкам в сервисе, результат —
    // соответствие «строка → латиница».
    final RomanizationOptions romanization = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => RomanizationOptions(
          japanese: s.romanizeJapanese,
          korean: s.romanizeKorean,
          chinese: s.romanizeChinese,
          hindi: s.romanizeHindi,
          other: s.romanizeOther,
        ),
      ),
    );
    Map<int, String> romanized = const <int, String>{};
    if (romanization.isEnabled && lineTexts.isNotEmpty) {
      romanized = ref.watch(
            romanizationProvider(
              RomanizationQuery(
                videoId: widget.videoId,
                options: romanization,
                lines: lineTexts,
              ),
            ),
          ).value ??
          const <int, String>{};
    }

    return Column(
      children: <Widget>[
        _LyricsToolbar(
          request: request,
          // Показываем настоящий источник строк: в «Авто» это лучший вариант,
          // а не слово «Авто»; выбранный вручную источник тоже виден.
          actualSource: shown?.source.label,
          searchOpen: _searchOpen,
          onToggleSearch: _toggleSearch,
          // Кнопки оффсета нужны только там, где есть времена: у обычного
          // текста сдвигать нечего.
          showOffset: data?.isSynced ?? false,
        ),
        if (_searchOpen)
          _LyricsSearchBar(
            controller: _searchController,
            focusNode: _searchFocus,
            matchCount: matches.length,
            current: cursor,
            onChanged: _onQueryChanged,
            onPrevious: () => _step(-1, matches),
            onNext: () => _step(1, matches),
            onClose: _toggleSearch,
          ),
        Expanded(
          child: searchAsync.when(
            data: (LyricsSearchState value) {
              final Lyrics? resolved =
                  _applyEdit(_resolve(value, selected, order), edit);
              // Поиск ещё идёт и показывать нечего — честное ожидание вместо
              // пустого экрана: вариант может появиться в любой момент.
              if (resolved == null && value.loading) {
                return const Center(child: CircularProgressIndicator());
              }
              final Lyrics lyricsValue = resolved ?? Lyrics.none;
              if (lyricsValue.isEmpty) {
                return EmptyState(
                  icon: Icons.lyrics_outlined,
                  title: 'Текста нет',
                  subtitle: selected == LyricsSource.subtitles
                      ? 'У этого видео нет субтитров. Выберите другой источник.'
                      : 'Для этого трека текст не нашёлся ни в YouTube Music, '
                          'ни в открытой базе. Попробуйте субтитры.',
                  action: widget.compact
                      ? null
                      : TextButton.icon(
                          icon: const Icon(Icons.travel_explore, size: 18),
                          label: const Text('Найти в другом источнике'),
                          onPressed: () => showLyricsMenu(context, request),
                        ),
                );
              }
              if (lyricsValue.isSynced) {
                return _SyncedLyrics(
                  lines: lyricsValue.timed!,
                  search: search,
                  offsetMs: offsetMs,
                  romanized: romanized,
                );
              }
              // Обычный текст: подсветки и автопрокрутки нет — их честно
              // показывает подпись, иначе казалось бы, что плеер «сломался».
              return _PlainLyrics(
                text: lyricsValue.plain ?? '',
                source: lyricsValue.source,
                search: search,
                romanized: romanized,
                onFindSource: () => showLyricsMenu(context, request),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object error, StackTrace _) =>
                ErrorState(message: describeError(error), compact: true),
          ),
        ),
      ],
    );
  }

  /// Текст, который нужно показать для текущего выбора источника.
  ///
  /// В «Авто» показываем лучший по приоритету вариант (тип синхронизации,
  /// затем порядок источников), при явном выборе — только результат выбранной
  /// базы (её отсутствие не подменяем чужой выдачей — так честнее и понятнее,
  /// почему текста нет).
  Lyrics? _resolve(
    LyricsSearchState state,
    LyricsSource selected,
    List<LyricsSource> order,
  ) {
    if (selected == LyricsSource.auto) return state.bestByOrder(order)?.lyrics;
    return state.candidateFor(selected)?.lyrics;
  }

  /// Кладёт ручную правку поверх найденного текста.
  ///
  /// Времена сохраняем по индексу строки, когда число строк совпало: тогда
  /// подсветка и автопрокрутка продолжают работать. Пословную разметку при
  /// этом отбрасываем — она привязана к старым словам и после правки врала бы.
  /// Если строки не совпали — показываем как обычный текст без времён: лучше
  /// без синхронизации, чем с выдуманной.
  Lyrics? _applyEdit(Lyrics? base, String? edit) {
    if (edit == null) return base;
    final List<String> edited = edit.split('\n');
    final List<TimedLyric>? timed = base?.timed;
    if (timed != null && timed.length == edited.length) {
      return Lyrics(
        timed: <TimedLyric>[
          for (int i = 0; i < edited.length; i++)
            TimedLyric(time: timed[i].time, text: edited[i]),
        ],
        plain: edit,
        source: base?.source,
        match: base?.match,
      );
    }
    return Lyrics(plain: edit, source: base?.source, match: base?.match);
  }

  /// Тексты строк для подсветки поиска — из синхронизации или из обычного
  /// текста, разбитого по строкам.
  List<String> _lineTexts(Lyrics? data) {
    if (data == null || data.isEmpty) return const <String>[];
    final List<TimedLyric>? timed = data.timed;
    if (data.isSynced && timed != null) {
      return timed.map((TimedLyric l) => l.text).toList(growable: false);
    }
    return (data.plain ?? '').split('\n');
  }

  List<int> _findMatches(List<String> lines, String query) {
    if (query.isEmpty) return const <int>[];
    final String needle = query.toLowerCase();
    final List<int> result = <int>[];
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].toLowerCase().contains(needle)) result.add(i);
    }
    return result;
  }
}

/// Состояние поиска, спускаемое в списки текста.
@immutable
class _LyricsSearch {
  const _LyricsSearch({
    required this.query,
    required this.currentLine,
    required this.jumpSeq,
  });

  final String query;

  /// Строка текущего совпадения (-1, если совпадений нет).
  final int currentLine;

  /// Меняется при каждом переходе — сигнал списку прокрутиться.
  final int jumpSeq;

  bool get isActive => query.isNotEmpty;
}

/// Шапка текста: откуда он, поиск и кнопка меню.
///
/// Нужна во всех поверхностях: и на полном экране, и в правой панели, и в
/// островке — поэтому живёт внутри самого [LyricsView], а не в шапке плеера.
class _LyricsToolbar extends ConsumerWidget {
  const _LyricsToolbar({
    required this.request,
    required this.searchOpen,
    required this.onToggleSearch,
    this.actualSource,
    this.showOffset = false,
  });

  final LyricsRequest request;
  final bool searchOpen;
  final VoidCallback onToggleSearch;

  /// Источник, из которого пришёл текст (может отличаться от выбранного:
  /// основной источник подтягивает синхронизацию из LRCLIB).
  final String? actualSource;

  /// Показывать ли кнопки сдвига синхронизации (есть ли времена).
  final bool showOffset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final LyricsSource selected =
        ref.watch(lyricsSourceOverrideProvider)[request.videoId] ??
            ref.watch(
              settingsControllerProvider.select(
                (AppSettings s) => s.lyricsSource,
              ),
            );
    final String label = actualSource ?? selected.label;

    return Padding(
      // Отступ шапки текста — как у экрана текста в ArchiveTune
      // (`LyricsScreen`, горизонталь 24, вертикаль 8).
      padding: const EdgeInsets.fromLTRB(24, 8, 4, 0),
      child: Row(
        children: <Widget>[
          Icon(Icons.lyrics_outlined, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ),
          IconButton(
            tooltip: searchOpen ? 'Закрыть поиск' : 'Поиск по тексту',
            iconSize: 20,
            icon: Icon(searchOpen ? Icons.search_off : Icons.search),
            onPressed: onToggleSearch,
          ),
          if (showOffset) _OffsetControls(videoId: request.videoId),
          LyricsMenuButton(request: request, iconSize: 20),
        ],
      ),
    );
  }
}

/// Кнопки сдвига синхронизации текста: «−0.5 с», «+0.5 с» и сброс.
///
/// Оффсет хранится на трек (см. `lyrics_edits.dart`) и применяется сразу:
/// перезапрашивать текст не нужно. Текущее значение показываем только когда оно
/// не ноль — в обычном состоянии шапка не должна пестреть лишними цифрами.
class _OffsetControls extends ConsumerWidget {
  const _OffsetControls({required this.videoId});

  final String videoId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int offset = ref.watch(
      lyricsOffsetProvider.select((Map<String, int> m) => m[videoId] ?? 0),
    );
    final LyricsOffsets notifier = ref.read(lyricsOffsetProvider.notifier);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _offsetButton(
          context,
          '−0.5 с',
          'Текст раньше на 0.5 с',
          () => notifier.nudge(videoId, -kLyricsOffsetStepMs),
        ),
        _offsetButton(
          context,
          '+0.5 с',
          'Текст позже на 0.5 с',
          () => notifier.nudge(videoId, kLyricsOffsetStepMs),
        ),
        if (offset != 0) ...<Widget>[
          Text(
            _offsetLabel(offset),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                ),
          ),
          IconButton(
            tooltip: 'Сбросить сдвиг',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.restart_alt),
            onPressed: () => notifier.reset(videoId),
          ),
        ],
      ],
    );
  }

  /// Компактная кнопка: в шапке уже есть поиск и меню, и обычный `TextButton`
  /// растянул бы строку.
  Widget _offsetButton(
    BuildContext context,
    String label,
    String tooltip,
    VoidCallback onPressed,
  ) {
    return Tooltip(
      message: tooltip,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: Size.zero,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: Theme.of(context).textTheme.labelMedium,
        ),
        child: Text(label),
      ),
    );
  }

  String _offsetLabel(int offsetMs) {
    final double seconds = offsetMs / 1000;
    final String sign = seconds > 0 ? '+' : '−';
    return '$sign${seconds.abs().toStringAsFixed(1)} с';
  }
}

/// Строка поиска по тексту: запрос, счётчик совпадений и переходы.
class _LyricsSearchBar extends StatelessWidget {
  const _LyricsSearchBar({
    required this.controller,
    required this.focusNode,
    required this.matchCount,
    required this.current,
    required this.onChanged,
    required this.onPrevious,
    required this.onNext,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final int matchCount;
  final int current;
  final ValueChanged<String> onChanged;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool empty = controller.text.isEmpty;
    final bool hasMatches = matchCount > 0;
    final String counter = empty
        ? ''
        : (hasMatches ? '${current + 1}/$matchCount' : 'Нет совпадений');

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 8, 0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              style: Theme.of(context).textTheme.bodyMedium,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Поиск по тексту',
                prefixIcon: const Icon(Icons.search, size: 18),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 40, minHeight: 36),
                suffixIcon: empty
                    ? null
                    : IconButton(
                        tooltip: 'Очистить',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          controller.clear();
                          onChanged('');
                        },
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: scheme.outlineVariant),
                ),
              ),
            ),
          ),
          if (counter.isNotEmpty) ...<Widget>[
            const SizedBox(width: 8),
            Text(
              counter,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
          IconButton(
            tooltip: 'Предыдущее совпадение',
            iconSize: 20,
            onPressed: hasMatches ? onPrevious : null,
            icon: const Icon(Icons.keyboard_arrow_up),
          ),
          IconButton(
            tooltip: 'Следующее совпадение',
            iconSize: 20,
            onPressed: hasMatches ? onNext : null,
            icon: const Icon(Icons.keyboard_arrow_down),
          ),
          IconButton(
            tooltip: 'Закрыть поиск',
            iconSize: 20,
            onPressed: onClose,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

/// Разбивает строку на участки и подсвечивает найденный запрос.
List<InlineSpan> _highlightSpans(
  String text,
  String query, {
  required TextStyle matchStyle,
}) {
  if (query.isEmpty) return <InlineSpan>[TextSpan(text: text)];

  final String lower = text.toLowerCase();
  final String needle = query.toLowerCase();
  final List<InlineSpan> spans = <InlineSpan>[];
  int start = 0;
  while (true) {
    final int index = lower.indexOf(needle, start);
    if (index < 0) {
      if (start < text.length) {
        spans.add(TextSpan(text: text.substring(start)));
      }
      break;
    }
    if (index > start) {
      spans.add(TextSpan(text: text.substring(start, index)));
    }
    spans.add(TextSpan(
      text: text.substring(index, index + needle.length),
      style: matchStyle,
    ));
    start = index + needle.length;
  }
  return spans;
}

/// Обычный текст: прокручиваемый блок без выделения строк, но с подсветкой
/// найденного запроса и переходом к совпадению.
class _PlainLyrics extends ConsumerStatefulWidget {
  const _PlainLyrics({
    required this.text,
    required this.source,
    required this.search,
    required this.onFindSource,
    this.romanized = const <int, String>{},
  });

  final String text;
  final String? source;
  final _LyricsSearch search;
  final VoidCallback onFindSource;

  /// Романизация по номерам строк (латиница под оригиналом).
  final Map<int, String> romanized;

  @override
  ConsumerState<_PlainLyrics> createState() => _PlainLyricsState();
}

class _PlainLyricsState extends ConsumerState<_PlainLyrics> {
  late List<GlobalKey> _keys = _buildKeys();

  List<GlobalKey> _buildKeys() {
    final int count = widget.text.isEmpty ? 0 : widget.text.split('\n').length;
    return List<GlobalKey>.generate(count, (_) => GlobalKey());
  }

  @override
  void didUpdateWidget(covariant _PlainLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _keys = _buildKeys();
    }
    if (oldWidget.search.jumpSeq != widget.search.jumpSeq) {
      _scrollToCurrentMatch();
    }
  }

  void _scrollToCurrentMatch() {
    final int line = widget.search.currentLine;
    if (line < 0 || line >= _keys.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final BuildContext? lineContext = _keys[line].currentContext;
      if (lineContext == null) return;
      Scrollable.ensureVisible(
        lineContext,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        alignment: _viewportAnchor,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme theme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double scale = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.lyricsTextScale),
    );
    final double baseSize = (theme.titleMedium?.fontSize ?? 16) * scale;
    final TextStyle baseStyle = (theme.titleMedium ?? const TextStyle())
        .copyWith(height: 1.7, fontSize: baseSize);
    final TextStyle matchStyle = baseStyle.copyWith(
      backgroundColor: scheme.primary.withValues(alpha: 0.28),
      color: scheme.onSurface,
      fontWeight: FontWeight.w700,
    );
    final TextStyle currentStyle = baseStyle.copyWith(
      backgroundColor: scheme.primary,
      color: scheme.onPrimary,
      fontWeight: FontWeight.w700,
    );

    final List<String> lines = widget.text.split('\n');
    return ScrollConfiguration(
      behavior: const _LyricsScrollBehavior(),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // Честно предупреждаем: у этого текста нет времён, поэтому плеер
            // не подсвечивает строки и не прокручивает их.
            const SizedBox(height: 16),
            for (int i = 0; i < lines.length; i++)
              Padding(
                key: i < _keys.length ? _keys[i] : null,
                padding: const EdgeInsets.only(bottom: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text.rich(
                      TextSpan(
                        children: _highlightSpans(
                          lines[i],
                          widget.search.query,
                          matchStyle: widget.search.currentLine == i
                              ? currentStyle
                              : matchStyle,
                        ),
                      ),
                      style: baseStyle,
                    ),
                    // Романизация идёт строкой под оригиналом и не заменяет
                    // его: нужны оба текста.
                    if (widget.romanized[i] != null)
                      Text(
                        widget.romanized[i]!,
                        style: baseStyle.copyWith(
                          fontSize: baseSize * 0.7,
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Пословная разметка с выведенным концом слова: TTML его отдаёт не всегда,
/// поэтому недостающее берём из начала следующего слова или из конца строки.
class _WordTiming {
  const _WordTiming({
    required this.text,
    required this.startMs,
    required this.endMs,
  });

  final String text;
  final int startMs;
  final int endMs;
}

/// Строка списка отображения: настоящая строка текста либо инструментальная
/// вставка.
///
/// Вставка живёт в списке как обычная строка — так же, как `isInstrumental`
/// у ArchiveTune (`lyrics/LyricsUtils.kt`, `insertInstrumentalBreaks`): она
/// прокручивается, подсвечивается и тускнеет по расстоянию наравне с текстом,
/// а не рисуется поверх него.
@immutable
class _DisplayLine {
  const _DisplayLine({
    required this.startMs,
    required this.endMs,
    this.lineIndex = -1,
  });

  /// Когда строка становится активной.
  final int startMs;

  /// Когда она «заканчивается»: у вставки это начало следующей строки — по
  /// нему считается доля заливки ноты; у настоящей строки — конец пропевания.
  final int endMs;

  /// Номер строки в `widget.lines`; `-1` — это вставка.
  final int lineIndex;

  bool get isInstrumental => lineIndex < 0;
}

/// Синхронизированный текст: плавная автопрокрутка, подсветка активной строки
/// и пословное «караоке», как в `LyricsV2` (ArchiveTune).
class _SyncedLyrics extends ConsumerStatefulWidget {
  const _SyncedLyrics({
    required this.lines,
    required this.search,
    this.offsetMs = 0,
    this.romanized = const <int, String>{},
  });

  final List<TimedLyric> lines;
  final _LyricsSearch search;

  /// Сдвиг синхронизации в миллисекундах — на трек, хранится на диске.
  /// Положительное значение задерживает подсветку.
  final int offsetMs;

  /// Романизация по номерам строк (латиница под оригиналом).
  final Map<int, String> romanized;

  @override
  ConsumerState<_SyncedLyrics> createState() => _SyncedLyricsState();
}

class _SyncedLyricsState extends ConsumerState<_SyncedLyrics>
    with TickerProviderStateMixin {
  /// Ключ на каждую строку списка отображения — по нему считаем позицию для
  /// автопрокрутки.
  late List<GlobalKey> _keys = _buildKeys();

  /// Список отображения: настоящие строки плюс строки-вставки, в порядке
  /// времени. Пересчитываем при построении: строк немного, а времена могут
  /// смениться вместе с источником текста.
  late List<_DisplayLine> _display = _buildDisplayLines();

  final ScrollController _controller = ScrollController();

  /// Ключ самой прокручиваемой области: по нему берём её границы в тех же
  /// координатах, что и у строк, — так и считаем, что сейчас видно.
  final GlobalKey _viewportKey = GlobalKey();

  /// Диапазон строк, попадающих на экран. Нужен, чтобы размывать только
  /// видимое: `ImageFilter` дорогой, а строки за краем всё равно не видны.
  int _firstVisible = 0;
  int _lastVisible = 0;

  /// Высота строки: по ней считаем, сколько строк помещается на экране.
  double _lineHeight = 40;

  /// Отношение числа видимых строк к эталонным семи (`_phoneVisibleLines`).
  /// Единица — экран как на телефоне, где снят оригинал.
  double _lineStep = 1;

  /// Сглаженная позиция в миллисекундах — по ней рисуется «караоке».
  final ValueNotifier<int> _positionMs = ValueNotifier<int>(0);

  /// Номер активной строки СПИСКА ОТОБРАЖЕНИЯ (с учётом вставок) — список
  /// перестраивается только при её смене, а не на каждом тике позиции.
  final ValueNotifier<int> _activeIndex = ValueNotifier<int>(-1);

  /// С какого момента вступление считается паузой — и с какого момента
  /// начинает действовать строка-вставка вступления. Как
  /// `INSTRUMENTAL_INTRO_START_MS` у ArchiveTune.
  static const int _introStartMs = 1000;

  /// С какой паузы между строками считать её инструментальной вставкой.
  static const int _interludeMinGapMs = 5000;

  /// Сколько «звучит» строка без пословной разметки: точнее база не знает,
  /// а 4 с — тот же запас, что у конца последней строки.
  static const int _lineSungTailMs = 4000;

  Ticker? _ticker;
  Duration _lastTick = Duration.zero;
  double _smoothMs = 0;
  int _engineMs = 0;
  bool _playing = false;

  /// Скорость воспроизведения — за кадр позиция идёт на `delta * speed`
  /// (`LyricsEnhanced.kt:258-260`).
  double _speed = 1;

  /// Ручная прокрутка: пока true, автопрокрутка молчит и видна кнопка возврата.
  bool _manualScrolling = false;
  Timer? _manualTimer;

  /// Индекс, к которому прокручивали в прошлый раз — для двухшагового перехода
  /// при далёком скачке (как `LyricsV2.kt:295-302`).
  int _lastScrolledIndex = -1;

  AnimationController? _scrollAnimation;

  bool get _wordSynced =>
      widget.lines.any((TimedLyric line) => line.hasWords);

  int get _leadMs => _wordSynced ? _wordSyncLeadMs : _lrcLeadMs;

  @override
  void initState() {
    super.initState();
    final PlayerUiState state = ref.read(playerControllerProvider);
    _engineMs = state.playback.position.inMilliseconds;
    _playing = state.isPlaying;
    _speed = state.playback.speed;
    _smoothMs = _engineMs.toDouble();

    _scrollAnimation = AnimationController.unbounded(vsync: this)
      ..addListener(() {
        if (!_controller.hasClients) return;
        _controller.jumpTo(_clampOffset(_scrollAnimation!.value));
      });
    _ticker = createTicker(_onTick)..start();
    _controller.addListener(_scheduleVisibleUpdate);
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _controller.removeListener(_scheduleVisibleUpdate);
    _manualTimer?.cancel();
    _scrollAnimation?.dispose();
    _controller.dispose();
    _positionMs.dispose();
    _activeIndex.dispose();
    super.dispose();
  }

  List<GlobalKey> _buildKeys() =>
      List<GlobalKey>.generate(_display.length, (_) => GlobalKey());

  /// Пересобирает список отображения и, если строк стало другое число, ключи.
  void _refreshDisplay() {
    _display = _buildDisplayLines();
    if (_keys.length != _display.length) _keys = _buildKeys();
  }

  /// Строит список отображения: к настоящим строкам добавляет строки-вставки
  /// там, где перед строкой есть тишина.
  List<_DisplayLine> _buildDisplayLines() {
    final List<TimedLyric> lines = widget.lines;
    final List<_DisplayLine> result = <_DisplayLine>[];
    for (int i = 0; i < lines.length; i++) {
      final int start = lines[i].time.inMilliseconds;
      // Вставка идёт ПЕРЕД строкой и заканчивается её началом — так заливка
      // ноты доходит до края ровно к первой ноте следующей строки.
      final int? gapStart = _gapStartBefore(i);
      if (gapStart != null) {
        result.add(_DisplayLine(startMs: gapStart, endMs: start));
      }
      result.add(_DisplayLine(
        startMs: start,
        endMs: _sungEndMs(i),
        lineIndex: i,
      ));
    }
    return result;
  }

  /// Индекс в списке отображения для настоящей строки текста.
  ///
  /// Нужен переходам поиска: они приходят в координатах строк текста, а
  /// прокрутка идёт по строкам отображения (со вставками между ними).
  int _displayIndexForLine(int line) {
    for (int i = 0; i < _display.length; i++) {
      if (_display[i].lineIndex == line) return i;
    }
    return -1;
  }

  /// Пересчитывает видимый диапазон после кадра.
  ///
  /// Во время самой прокрутки трогать разметку нельзя — только после кадра,
  /// иначе получим «setState во время построения».
  void _scheduleVisibleUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateVisible());
  }

  void _updateVisible() {
    if (!mounted) return;
    final RenderBox? viewport =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.attached) return;

    final double top = viewport.localToGlobal(Offset.zero).dy;
    final double bottom = top + viewport.size.height;

    int first = -1;
    int last = -1;
    for (int i = 0; i < _keys.length; i++) {
      final RenderObject? object = _keys[i].currentContext?.findRenderObject();
      if (object is! RenderBox || !object.attached) continue;
      final double lineTop = object.localToGlobal(Offset.zero).dy;
      final double lineBottom = lineTop + object.size.height;
      // Строка попадает на экран, если её полоса пересекается с областью.
      if (lineBottom < top || lineTop > bottom) continue;
      if (first == -1) first = i;
      last = i;
    }
    if (first == -1) return;
    // Запас в одну строку сверху и снизу: при быстрой прокрутке строка
    // появляется раньше, чем успевает размыться, и «вспыхивала» бы резкой.
    first -= 1;
    last += 1;

    // Насколько этот экран «длиннее» телефонного. Ограничиваем сверху
    // четвёркой: дальше разница всё равно не читается, а затухание стало бы
    // совсем плоским.
    final double step =
        (viewport.size.height / _lineHeight / _phoneVisibleLines)
            .clamp(1.0, 4.0);

    if (first == _firstVisible &&
        last == _lastVisible &&
        step == _lineStep) {
      return;
    }
    setState(() {
      _firstVisible = first;
      _lastVisible = last;
      _lineStep = step;
    });
  }

  @override
  void didUpdateWidget(covariant _SyncedLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Текст мог прийти от другого источника — список отображения пересобираем
    // до всего остального, чтобы индексы ниже были по нему.
    _refreshDisplay();
    if (oldWidget.lines.length != widget.lines.length) {
      _activeIndex.value = -1;
      _lastScrolledIndex = -1;
    }
    if (oldWidget.search.jumpSeq != widget.search.jumpSeq &&
        widget.search.currentLine >= 0) {
      // Совпадение пришло номером настоящей строки — переводим в строку
      // отображения, иначе вставки сдвинули бы прокрутку.
      final int display = _displayIndexForLine(widget.search.currentLine);
      if (display >= 0) _scheduleScroll(display);
    }
  }

  double _clampOffset(double value) {
    if (!_controller.hasClients) return value;
    final ScrollPosition position = _controller.position;
    return value.clamp(position.minScrollExtent, position.maxScrollExtent);
  }

  int _indexForPosition(int positionMs) {
    int index = -1;
    for (int i = 0; i < _display.length; i++) {
      if (_display[i].startMs <= positionMs) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  void _onTick(Duration elapsed) {
    final double deltaMs = _lastTick == Duration.zero
        ? 0
        : (elapsed - _lastTick).inMicroseconds / 1000.0;
    _lastTick = elapsed;

    if (!_playing) {
      _smoothMs = _engineMs.toDouble();
    } else {
      // Позиция движка приходит рывками; между ними ведём время сами и
      // подтягиваемся к движку — иначе «караоке» шло бы ступеньками.
      final double projected = _smoothMs + deltaMs * _speed;
      final double drift = _engineMs - projected;
      if (drift > _smoothMaxForwardDriftMs ||
          drift < -_smoothMaxBackwardDriftMs) {
        _smoothMs = _engineMs.toDouble();
      } else {
        final double correction =
            (drift * _smoothDriftCorrection).clamp(
          -_smoothMaxCorrectionPerFrameMs,
          _smoothMaxCorrectionPerFrameMs,
        );
        _smoothMs = projected + correction;
      }
    }

    // Оффсет применяем к самой позиции: по ней же рисуется «караоке», поэтому
    // сдвиг виден сразу, без перезапроса текста.
    final int rounded = _smoothMs.round() - widget.offsetMs;
    if (_positionMs.value != rounded) _positionMs.value = rounded;

    final int index = _indexForPosition(rounded + _leadMs);
    if (index != _activeIndex.value) {
      _activeIndex.value = index;
    }

    // Прокручиваем при смене строки, а также один раз после первой раскладки
    // (`_lastScrolledIndex` обновляется только после удачной прокрутки).
    // Вставка — такая же строка списка, поэтому к ней ведёт как к обычной.
    if (_canAutoScroll && index >= 0 && _lastScrolledIndex != index) {
      _scheduleScroll(index);
    }
  }

  /// Автопрокрутка молчит, пока пользователь листает сам и пока идёт поиск:
  /// иначе список уводило бы от найденных строк.
  bool get _canAutoScroll =>
      _controller.hasClients && !_manualScrolling && !widget.search.isActive;

  void _scheduleScroll(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollTo(index);
    });
  }

  double? _offsetFor(int index) {
    if (index < 0 || index >= _keys.length) return null;
    final BuildContext? lineContext = _keys[index].currentContext;
    if (lineContext == null) return null;
    final RenderObject? renderObject = lineContext.findRenderObject();
    if (renderObject == null) return null;
    final RenderAbstractViewport viewport =
        RenderAbstractViewport.of(renderObject);
    return viewport.getOffsetToReveal(renderObject, _viewportAnchor).offset;
  }

  void _scrollTo(int index) {
    final double? target = _offsetFor(index);
    if (target == null) return;

    // Далёкий скачок: сначала мгновенно переносим список на пару строк выше,
    // чтобы пружина не тянулась через сотни строк.
    if (_lastScrolledIndex >= 0 && (index - _lastScrolledIndex).abs() > 15) {
      final double? snap = _offsetFor((index - 2).clamp(0, _keys.length - 1));
      if (snap != null) _controller.jumpTo(_clampOffset(snap));
    }
    _animateTo(target);
    _lastScrolledIndex = index;
  }

  void _animateTo(double target) {
    if (!_controller.hasClients) return;
    final double from = _controller.offset;
    if ((target - from).abs() < 0.5) return;
    _scrollAnimation!
      ..stop()
      ..value = from
      ..animateWith(SpringSimulation(_autoScrollSpring, from, target, 0));
  }

  bool _onScrollNotification(ScrollNotification notification) {
    // Прокрутка пальцем/колесом — это ручной ввод. Наши собственные прыжки
    // (jumpTo) не шлют эти уведомления, поэтому автопрокрутку не выключают.
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _markManual();
    } else if (notification is ScrollEndNotification &&
        notification.dragDetails != null) {
      _markManual();
    }
    return false;
  }

  void _markManual() {
    _scrollAnimation?.stop();
    _manualTimer?.cancel();
    if (!_manualScrolling) setState(() => _manualScrolling = true);
    // Возвращаемся к активной строке через 3 с после последнего касания —
    // ровно как `MANUAL_SCROLL_TIMEOUT_MS` в `LyricsV2.kt`.
    _manualTimer = Timer(const Duration(milliseconds: _manualScrollTimeoutMs), () {
      if (!mounted) return;
      setState(() => _manualScrolling = false);
      _scrollTo(_activeIndex.value);
    });
  }

  void _resumeAutoScroll() {
    _manualTimer?.cancel();
    setState(() => _manualScrolling = false);
    _scrollTo(_activeIndex.value);
  }

  /// Конец строки: начало следующей, а для последней — запас в 4 с
  /// (`LyricsV2.kt`/`LyricsEnhanced.kt` тоже берут `entry.time + 4000`).
  int _lineEndMs(int index) {
    final int start = widget.lines[index].time.inMilliseconds;
    if (index + 1 < widget.lines.length) {
      final int next = widget.lines[index + 1].time.inMilliseconds;
      if (next > start) return next;
    }
    return start + 4000;
  }

  /// Начало паузы перед строкой [index], если тишина достаточно длинная,
  /// иначе `null` — тогда строки-вставки перед ней не будет.
  ///
  /// Тишиной считаем две вещи: вступление, когда текст начинается позже, чем
  /// через секунду после старта трека, и паузу не короче пяти секунд между
  /// пропеванием предыдущей строки и началом следующей. Конец пропевания
  /// берём из `_sungEndMs`: у пословного текста это конец последнего слова,
  /// у построчного — начало плюс запас, точнее база не знает.
  int? _gapStartBefore(int index) {
    if (index == 0) {
      final int firstStart = widget.lines.first.time.inMilliseconds;
      // Вставка вступления начинается не с нуля, а с `_introStartMs`: в первую
      // секунду плеер ещё может отдавать нулевую позицию, и «Проигрыш» мигал бы.
      return firstStart > _introStartMs ? _introStartMs : null;
    }
    final int sungEnd = _sungEndMs(index - 1);
    final int start = widget.lines[index].time.inMilliseconds;
    if (start - sungEnd < _interludeMinGapMs) return null;
    return sungEnd;
  }

  /// Конец пропевания строки.
  int _sungEndMs(int index) {
    final int start = widget.lines[index].time.inMilliseconds;
    final List<TimedWord>? words = widget.lines[index].words;
    if (words == null || words.isEmpty) return start + _lineSungTailMs;

    int end = start;
    for (final TimedWord word in words) {
      final int wordEnd = word.end?.inMilliseconds ?? word.time.inMilliseconds;
      if (wordEnd > end) end = wordEnd;
    }
    return end;
  }

  List<_WordTiming> _wordTimings(int index) {
    final List<TimedWord>? words = widget.lines[index].words;
    if (words == null || words.isEmpty) return const <_WordTiming>[];
    final int lineEnd = _lineEndMs(index);
    return List<_WordTiming>.generate(words.length, (int i) {
      final int start = words[i].time.inMilliseconds;
      int end = words[i].end?.inMilliseconds ??
          (i + 1 < words.length ? words[i + 1].time.inMilliseconds : lineEnd);
      if (end <= start) end = start + 1;
      return _WordTiming(text: words[i].text, startMs: start, endMs: end);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Позицию и признак воспроизведения слушаем, но не перестраиваемся на
    // каждое обновление: список трогаем только при смене активной строки.
    ref.listen<int>(
      playerControllerProvider
          .select((PlayerUiState s) => s.playback.position.inMilliseconds),
      (int? _, int next) => _engineMs = next,
    );
    ref.listen<bool>(
      playerControllerProvider.select((PlayerUiState s) => s.isPlaying),
      (bool? _, bool next) {
        _playing = next;
        if (!next) _smoothMs = _engineMs.toDouble();
      },
    );
    ref.listen<double>(
      playerControllerProvider.select((PlayerUiState s) => s.playback.speed),
      (double? _, double next) => _speed = next,
    );

    final TextTheme theme = Theme.of(context).textTheme;
    final double scale = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.lyricsTextScale),
    );
    final double baseSize = (theme.titleLarge?.fontSize ?? 22) * scale;
    // Высота строки: межстрочный 1.35 плюс отступы строки (10 сверху и 10
    // снизу, см. `_LyricLine`). Вставка держит ту же высоту, поэтому текст под
    // ней не дёргается, когда в ней появляется содержимое.
    _lineHeight = baseSize * 1.35 + 20;

    // Список отображения пересобираем перед раскладкой: он задаёт и число
    // ключей, и индексы для прокрутки.
    _refreshDisplay();

    // Видимый диапазон пересчитываем и после построения: при первом показе и
    // при смене активной строки прокрутка не срабатывает, а без пересчёта
    // размытие оставалось бы только на первой строке — то есть работало бы
    // «криво». Сам пересчёт ничего не делает, если диапазон не изменился,
    // поэтому лишних перестроек не будет.
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateVisible());

    final Widget list = ValueListenableBuilder<int>(
      valueListenable: _activeIndex,
      builder: (BuildContext context, int active, Widget? _) {
        return ScrollConfiguration(
          behavior: const _LyricsScrollBehavior(),
          child: SingleChildScrollView(
            key: _viewportKey,
            controller: _controller,
            padding: const EdgeInsets.fromLTRB(24, 72, 24, 160),
            child: Center(
              // Ширину колонки ограничиваем: строка во весь экран — это уже
              // не текст, а полоса, и читать её неудобно. В оригинале такой
              // ширины просто не бывает — там телефон.
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: _lyricsColumnWidth),
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // Один список на всё: настоящие строки и строки-вставки. Так
                // вставка прокручивается, подсвечивается и тускнеет наравне
                // с текстом — ровно как `isInstrumental` в ArchiveTune.
                for (int i = 0; i < _display.length; i++)
                  if (_display[i].isInstrumental)
                    _InterludeLine(
                      key: _keys[i],
                      first: i == 0,
                      active: i == active,
                      startMs: _display[i].startMs,
                      endMs: _display[i].endMs,
                      distance: (i - active).abs(),
                      manualScrolling: _manualScrolling,
                      blurVisible: i >= _firstVisible && i <= _lastVisible,
                      step: _lineStep,
                      positionMs: _positionMs,
                      // Пауза в тексте сдвинута оффсетом так же, как строки:
                      // чтобы попасть в её начало, сдвигаем и цель перемотки.
                      onSeek: () => ref
                          .read(playerControllerProvider.notifier)
                          .seek(Duration(
                            milliseconds:
                                _display[i].startMs + widget.offsetMs,
                          )),
                    )
                  else
                    _LyricLine(
                      key: _keys[i],
                      first: i == 0,
                      index: _display[i].lineIndex,
                      line: widget.lines[_display[i].lineIndex],
                      active: i == active,
                      // До первой строки активной нет (active == -1): тогда
                      // расстояние считаем от «минус первой», чтобы строки не
                      // гасли все разом, а читались как близкие/дальние.
                      distance: (i - active).abs(),
                      manualScrolling: _manualScrolling,
                      blurVisible: i >= _firstVisible && i <= _lastVisible,
                      step: _lineStep,
                      positionMs: _positionMs,
                      words: _wordTimings(_display[i].lineIndex),
                      baseSize: baseSize,
                      search: widget.search,
                      romanized: widget.romanized[_display[i].lineIndex],
                    ),
              ],
                ),
              ),
            ),
          ),
        );
      },
    );

    return Listener(
      // Колесо мыши не даёт drag-уведомлений — ловим его отдельно.
      onPointerSignal: (PointerSignalEvent event) {
        if (event is PointerScrollEvent) _markManual();
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: Stack(
          children: <Widget>[
            list,
            if (_manualScrolling && !widget.search.isActive)
              Positioned(
                left: 0,
                right: 0,
                bottom: 16,
                child: Center(
                  child: FilledButton.tonal(
                    onPressed: _resumeAutoScroll,
                    child: const Text('Продолжить'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Одна строка текста: оформляется по расстоянию до активной, активная с
/// пословной разметкой рисуется «караоке».
class _LyricLine extends StatelessWidget {
  const _LyricLine({
    super.key,
    required this.first,
    required this.index,
    required this.line,
    required this.active,
    required this.distance,
    required this.manualScrolling,
    required this.blurVisible,
    required this.step,
    required this.positionMs,
    required this.words,
    required this.baseSize,
    required this.search,
    this.romanized,
  });

  /// Первая строка списка отображения — у неё нет верхнего отступа.
  final bool first;

  /// Номер строки в тексте песни. Нужен подсветке поиска: она работает в
  /// координатах настоящих строк, а не списка отображения со вставками.
  final int index;
  final TimedLyric line;
  final bool active;
  final int distance;
  final bool manualScrolling;

  /// Видна ли строка на экране прямо сейчас.
  final bool blurVisible;

  /// Во сколько раз «дальше» строка на этом экране по сравнению с телефоном.
  /// Единица — как в оригинале.
  final double step;
  final ValueNotifier<int> positionMs;
  final List<_WordTiming> words;
  final double baseSize;
  final _LyricsSearch search;

  /// Латиница под строкой; `null` — романизации нет.
  final String? romanized;

  /// Прозрачность строки по расстоянию (`LyricsV2.kt:549-583`).
  ///
  /// Расстояние делим на [step]: на телефоне он равен единице, и таблица
  /// выдаёт ровно оригинальные значения; на большом экране, где видно больше
  /// строк, ступени растягиваются — иначе погас бы почти весь текст.
  double get _alpha {
    if (active) return 1;
    return tableValue(
      manualScrolling ? _manualAlphaTable : _alphaTable,
      distance / step,
    );
  }

  /// Размытие строки по расстоянию (`LyricsV2.kt:584-590`).
  ///
  /// Размываются ВСЕ строки, которые сейчас видны на экране: размытие — это и
  /// есть смысл эффекта, текст уходит в глубину по мере удаления от активной
  /// строки, а не просто гаснет. Строки за краем экрана не размываем только
  /// потому, что их не видно: `ImageFilter` — самый дорогой слой в строке, и
  /// платить за невидимое незачем.
  double get _blur {
    if (active || !blurVisible) return 0;
    // Ручная прокрутка — размытие снимаем: человек ушёл от активной строки и
    // читает то, что перед ним. Размывать по расстоянию от строки, которая
    // осталась выше, значит гасить именно то, за чем он листал.
    if (manualScrolling) return 0;
    return tableValue(_blurTable, distance / step);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Между строками — `lineSpacing * 8`, где lineSpacing по умолчанию 1.3
    // (`LyricsV2.kt:677-679`).
    final EdgeInsets padding = EdgeInsets.only(
      top: first ? 0 : 10,
      bottom: 10,
    );
    final double targetAlpha = _alpha;
    final double targetBlur = _blur;
    final double targetScale = active ? 1 : 0.95;

    return Padding(
      padding: padding,
      child: TweenAnimationBuilder<double>(
        // Прозрачность: активная строка загорается за 330 мс, гаснет за 500 мс
        // (`LyricsV2.kt:609-617`).
        tween: Tween<double>(begin: targetAlpha, end: targetAlpha),
        duration: Duration(milliseconds: active ? _alphaActiveMs : _alphaIdleMs),
        curve: Curves.fastOutSlowIn,
        builder: (BuildContext context, double alpha, Widget? _) {
          return TweenAnimationBuilder<double>(
            // Размытие: 300 мс (`LyricsV2.kt:591-599`).
            tween: Tween<double>(begin: targetBlur, end: targetBlur),
            duration: const Duration(milliseconds: _blurDurationMs),
            curve: Curves.fastOutSlowIn,
            builder: (BuildContext context, double blur, Widget? _) {
              return TweenAnimationBuilder<double>(
                // Масштаб: 166 мс, 1.0 у активной и 0.95 у остальных
                // (`LyricsV2.kt:600-608`).
                tween: Tween<double>(begin: targetScale, end: targetScale),
                duration: const Duration(milliseconds: _scaleDurationMs),
                curve: Curves.fastOutSlowIn,
                builder: (BuildContext context, double scaleValue, Widget? _) {
                  Widget content = active && words.isNotEmpty && !search.isActive
                      ? _karaoke(scheme)
                      : _staticText(scheme, alpha);
                  if (blur > 0.1) {
                    content = ImageFiltered(
                      imageFilter:
                          ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                      child: content,
                    );
                  }
                  final Widget scaled = Transform.scale(
                    scale: scaleValue,
                    alignment: Alignment.centerLeft,
                    child: content,
                  );
                  if (romanized == null) return scaled;
                  // Романизация идёт отдельной строкой под оригиналом: мельче
                  // и приглушённее, чтобы латиница оставалась подсказкой, а не
                  // заменяла текст песни.
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      scaled,
                      Text(
                        romanized!,
                        style: TextStyle(
                          height: 1.35,
                          fontSize: baseSize * 0.7,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurface.withValues(alpha: alpha * 0.7),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  /// Обычная строка: цвет по прозрачности строки, запрос поиска подсвечен.
  Widget _staticText(ColorScheme scheme, double alpha) {
    final TextStyle baseStyle = TextStyle(
      height: 1.35,
      fontSize: baseSize,
      fontWeight: active ? FontWeight.w800 : FontWeight.w600,
      color: scheme.onSurface.withValues(alpha: alpha),
    );
    if (!search.isActive) return Text(line.text, style: baseStyle);

    final TextStyle matchStyle = baseStyle.copyWith(
      backgroundColor: scheme.primary.withValues(alpha: 0.28),
      color: scheme.onSurface,
      fontWeight: FontWeight.w700,
    );
    final TextStyle currentStyle = baseStyle.copyWith(
      backgroundColor: scheme.primary,
      color: scheme.onPrimary,
      fontWeight: FontWeight.w700,
    );
    return Text.rich(
      TextSpan(
        children: _highlightSpans(
          line.text,
          search.query,
          matchStyle: search.currentLine == index ? currentStyle : matchStyle,
        ),
      ),
      style: baseStyle,
    );
  }

  /// Активная строка с пословными временами: слова наливаются по мере пения.
  Widget _karaoke(ColorScheme scheme) {
    return ValueListenableBuilder<int>(
      valueListenable: positionMs,
      builder: (BuildContext context, int pos, Widget? _) {
        final Color dim = scheme.onSurface.withValues(alpha: _inactiveAlpha);
        final Color full = scheme.onSurface;
        return Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            for (final _WordTiming word in words)
              _KaraokeWord(
                word: word,
                positionMs: pos,
                dimColor: dim,
                fullColor: full,
                baseSize: baseSize,
              ),
          ],
        );
      },
    );
  }
}

/// Строка-вставка инструментального проигрыша: нота, которая заливается
/// снизу вверх по ходу паузы (`LyricsV2.kt`, instrumental-строка).
///
/// Она живёт в общем списке строк, поэтому её видно, к ней ведёт автопрокрутка
/// и она гаснет по расстоянию вместе с текстом. Никаких подписей и цифр нет:
/// приглушённая нота — это фон, полный цвет — уже проигранная часть паузы,
/// так что по одной фигуре видно и «здесь пауза», и «сколько ещё ждать».
class _InterludeLine extends StatelessWidget {
  const _InterludeLine({
    super.key,
    required this.first,
    required this.active,
    required this.startMs,
    required this.endMs,
    required this.distance,
    required this.manualScrolling,
    required this.blurVisible,
    required this.step,
    required this.positionMs,
    required this.onSeek,
  });

  /// Первая строка списка — у неё нет верхнего отступа.
  final bool first;

  /// Пауза идёт прямо сейчас: строка подсвечена, как активная.
  final bool active;

  /// Начало и конец паузы — по ним считается доля заливки.
  final int startMs;
  final int endMs;

  final int distance;
  final bool manualScrolling;

  /// Видна ли строка на экране прямо сейчас.
  final bool blurVisible;

  /// Во сколько раз «дальше» строка на этом экране по сравнению с телефоном.
  final double step;
  final ValueNotifier<int> positionMs;

  /// Клик по ноте — перемотка на начало паузы.
  final VoidCallback onSeek;

  /// Прозрачность ноты по расстоянию: как у строк, но с таблицей вставки.
  double get _alpha {
    if (active) return 1;
    return tableValue(
      manualScrolling ? _manualAlphaTable : _interludeAlphaTable,
      distance / step,
    );
  }

  /// Размытие по расстоянию — то же, что у строк; в ручной прокрутке снимаем,
  /// иначе размывалось бы именно то, за чем человек листал.
  double get _blur {
    if (active || !blurVisible || manualScrolling) return 0;
    return tableValue(_blurTable, distance / step);
  }

  /// Доля заливки: до паузы 0, после 1. Считаем по позиции, а не по таймеру,
  /// чтобы при перемотке она сразу оказалась верной.
  double _fillFraction(int positionMs) {
    if (endMs <= startMs) return positionMs >= endMs ? 1 : 0;
    return ((positionMs - startMs) / (endMs - startMs)).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Отступы как у обычной строки — иначе список прыгал бы на месте вставки.
    final EdgeInsets padding = EdgeInsets.only(
      top: first ? 0 : 10,
      bottom: 10,
    );
    final double targetAlpha = _alpha;
    final double targetBlur = _blur;
    final double targetScale = active ? 1 : 0.95;

    return Padding(
      padding: padding,
      child: TweenAnimationBuilder<double>(
        // Прозрачность: активная строка загорается за 330 мс, гаснет за 500 мс
        // (`LyricsV2.kt:609-617`).
        tween: Tween<double>(begin: targetAlpha, end: targetAlpha),
        duration: Duration(milliseconds: active ? _alphaActiveMs : _alphaIdleMs),
        curve: Curves.fastOutSlowIn,
        builder: (BuildContext context, double alpha, Widget? _) {
          return TweenAnimationBuilder<double>(
            // Размытие: 300 мс (`LyricsV2.kt:591-599`).
            tween: Tween<double>(begin: targetBlur, end: targetBlur),
            duration: const Duration(milliseconds: _blurDurationMs),
            curve: Curves.fastOutSlowIn,
            builder: (BuildContext context, double blur, Widget? _) {
              return TweenAnimationBuilder<double>(
                // Масштаб: 166 мс, 1.0 у активной и 0.95 у остальных
                // (`LyricsV2.kt:600-608`).
                tween: Tween<double>(begin: targetScale, end: targetScale),
                duration: const Duration(milliseconds: _scaleDurationMs),
                curve: Curves.fastOutSlowIn,
                builder: (BuildContext context, double scaleValue, Widget? _) {
                  Widget note = ValueListenableBuilder<int>(
                    valueListenable: positionMs,
                    builder: (BuildContext context, int pos, Widget? _) =>
                        _FillNote(
                      fraction: _fillFraction(pos),
                      dimColor:
                          scheme.onSurface.withValues(alpha: _inactiveAlpha),
                      fullColor: scheme.onSurface,
                      onTap: onSeek,
                    ),
                  );
                  if (blur > 0.1) {
                    note = ImageFiltered(
                      imageFilter:
                          ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                      child: note,
                    );
                  }
                  return Opacity(
                    opacity: alpha.clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale: scaleValue,
                      alignment: Alignment.centerLeft,
                      child: note,
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

/// Нота, залитая снизу вверх на [fraction]: фон — приглушённый глиф, заливка —
/// тот же глиф полным цветом, обрезанный по уровню.
class _FillNote extends StatefulWidget {
  const _FillNote({
    required this.fraction,
    required this.dimColor,
    required this.fullColor,
    required this.onTap,
  });

  /// Доля заливки снизу вверх, 0…1.
  final double fraction;
  final Color dimColor;
  final Color fullColor;
  final VoidCallback onTap;

  @override
  State<_FillNote> createState() => _FillNoteState();
}

class _FillNoteState extends State<_FillNote>
    with SingleTickerProviderStateMixin {
  /// Пружина, а не линейная анимация: при перемотке доля догоняет новую
  /// позицию мягко, без рывка, и сразу перестаёт дёргаться.
  late final AnimationController _fill = AnimationController.unbounded(
    vsync: this,
    value: widget.fraction,
  );

  @override
  void didUpdateWidget(covariant _FillNote oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fraction != oldWidget.fraction) {
      // Перезапуск пружины с текущей скоростью: так доля едет непрерывно,
      // хотя цель обновляется каждый кадр.
      _fill.animateWith(
        SpringSimulation(
          _interludeFillSpring,
          _fill.value,
          widget.fraction,
          _fill.velocity,
        ),
      );
    }
  }

  @override
  void dispose() {
    _fill.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: _interludeNoteSize,
        height: _interludeNoteSize,
        child: AnimatedBuilder(
          animation: _fill,
          builder: (BuildContext context, Widget? _) => CustomPaint(
            painter: _NoteFillPainter(
              fraction: _fill.value.clamp(0.0, 1.0),
              dimColor: widget.dimColor,
              fullColor: widget.fullColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// Рисует ноту: целиком приглушённым цветом и залитую часть полным.
class _NoteFillPainter extends CustomPainter {
  const _NoteFillPainter({
    required this.fraction,
    required this.dimColor,
    required this.fullColor,
  });

  final double fraction;
  final Color dimColor;
  final Color fullColor;

  @override
  void paint(Canvas canvas, Size size) {
    // Фон — вся нота: пока пауза не началась, видна только она, и уже понятно,
    // что здесь будет проигрыш.
    _paintGlyph(canvas, size, dimColor);
    if (fraction <= 0) return;
    // Заливка — та же нота полным цветом, обрезанная снизу: залитая часть
    // растёт снизу вверх, как уровень.
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(
      0,
      size.height * (1 - fraction),
      size.width,
      size.height,
    ));
    _paintGlyph(canvas, size, fullColor);
    canvas.restore();
  }

  void _paintGlyph(Canvas canvas, Size size, Color color) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(Icons.music_note.codePoint),
        style: TextStyle(
          fontSize: size.width,
          fontFamily: Icons.music_note.fontFamily,
          package: Icons.music_note.fontPackage,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // Центрируем глиф: иначе нота прижалась бы к левому верхнему углу.
    painter.paint(
      canvas,
      Offset(
        (size.width - painter.width) / 2,
        (size.height - painter.height) / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _NoteFillPainter oldDelegate) =>
      oldDelegate.fraction != fraction ||
      oldDelegate.dimColor != dimColor ||
      oldDelegate.fullColor != fullColor;
}

/// Слово «караоке»: приглушённая подложка и заливка слева направо с мягким
/// краем (`LyricsV2.kt AnimatedWordV2`), плюс лёгкий подскок и свечение.
class _KaraokeWord extends StatelessWidget {
  const _KaraokeWord({
    required this.word,
    required this.positionMs,
    required this.dimColor,
    required this.fullColor,
    required this.baseSize,
  });

  final _WordTiming word;
  final int positionMs;
  final Color dimColor;
  final Color fullColor;
  final double baseSize;

  @override
  Widget build(BuildContext context) {
    final int duration = math.max(1, word.endMs - word.startMs);
    final bool complete = positionMs >= word.endMs;
    final bool singing = positionMs >= word.startMs && positionMs < word.endMs;
    final double progress = complete
        ? 1
        : (positionMs <= word.startMs
            ? 0
            : ((positionMs - word.startMs) / duration).clamp(0.0, 1.0));

    // Подскок: масштаб +1.5% и подъём до -4 px на пике слова
    // (`LyricsV2.kt:1206-1212`).
    final double sinProgress = math.sin(progress * math.pi);
    final double wordScale = 1 + 0.015 * _wordBounceFactor * sinProgress;
    final double floatY = singing ? -4 * _wordBounceFactor * sinProgress : 0;

    // Свечение только у поющегося слова, максимум к половине слова
    // (`LyricsV2.kt:1223-1228`).
    final double glowProgress = math.min(1, progress * 2);
    final double glowAlpha = singing ? glowProgress * 0.45 * _wordGlowFactor : 0;
    final double glowRadius = singing ? glowProgress * 12 * _wordGlowFactor : 0;

    final TextStyle baseStyle = TextStyle(
      height: 1.35,
      fontSize: baseSize,
      fontWeight: FontWeight.w800,
      color: dimColor,
      fontFamily: DefaultTextStyle.of(context).style.fontFamily,
    );
    final TextStyle fullStyle = baseStyle.copyWith(
      color: fullColor,
      shadows: glowAlpha > 0
          ? <Shadow>[
              Shadow(
                color: fullColor.withValues(alpha: glowAlpha),
                blurRadius: math.max(1, glowRadius),
              ),
            ]
          : null,
    );

    // Пробел после слова сохраняем — иначе слова слиплись бы.
    final String text = '${word.text} ';

    Widget content = Stack(
      // Свечение и подскок выходят за границы слова — не обрезаем их.
      clipBehavior: Clip.none,
      children: <Widget>[
        Text(text, style: baseStyle),
        if (complete)
          Text(text, style: fullStyle)
        else if (singing)
          ShaderMask(
            blendMode: BlendMode.modulate,
            shaderCallback: (Rect bounds) => _sweepShader(bounds, progress),
            child: Text(text, style: fullStyle),
          ),
      ],
    );

    content = Transform.translate(
      offset: Offset(0, floatY),
      child: Transform.scale(scale: wordScale, child: content),
    );
    return content;
  }

  /// Градиент заливки: непрозрачно до `progress` слова, затем мягкий край
  /// шириной `_wordFillEdgeDp` (`LyricsV2.kt:1309-1329`).
  Shader _sweepShader(Rect bounds, double progress) {
    final double width = math.max(1, bounds.width);
    final double edge = math.min(_wordFillEdgeDp, width);
    final double center = progress * width;
    final double softStart = ((center - edge / 2) / width).clamp(0.0, 1.0);
    final double softEnd = ((center + edge / 2) / width).clamp(0.0, 1.0);
    return LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: const <Color>[Colors.white, Colors.white, Colors.transparent],
      stops: <double>[
        0,
        softStart,
        math.min(1, math.max(softEnd, softStart + 0.001)),
      ],
    ).createShader(bounds);
  }
}
