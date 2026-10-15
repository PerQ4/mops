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
import '../../state/catalog_providers.dart';
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
const double _closeAlpha1 = 0.52;
const double _closeAlpha2 = 0.30;
const double _closeAlpha3 = 0.18;
const double _farAlpha = 0.10;

/// То же, но пока пользователь листает вручную (`LyricsV2.kt:559-565`).
const double _manualAlpha1 = 0.72;
const double _manualAlpha2 = 0.56;
const double _manualAlpha3 = 0.40;
const double _manualFarAlpha = 0.28;

/// Радиус размытия неактивных строк (`LyricsV2.kt:584-590`).
const double _blur1 = 2;
const double _blur2 = 5;
const double _blurFar = 12;

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
    // по названию и исполнителю, а не по id YouTube.
    final Track? current = ref.watch(currentTrackProvider);
    final LyricsRequest request = (current != null && current.id == widget.videoId)
        ? LyricsRequest.fromTrack(current)
        : LyricsRequest(videoId: widget.videoId);

    final AsyncValue<Lyrics> lyrics = ref.watch(lyricsProvider(request));

    // Подсветку и переходы считаем по уже загруженному тексту: держать это в
    // состоянии было бы рассинхронизацией, а строк в песне немного.
    final Lyrics? data = lyrics.value;
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

    return Column(
      children: <Widget>[
        _LyricsToolbar(
          request: request,
          // Показываем настоящий источник строк, а не только выбранный:
          // основной источник умеет подтягивать синхронизацию из LRCLIB.
          actualSource: data?.source,
          searchOpen: _searchOpen,
          onToggleSearch: _toggleSearch,
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
          child: lyrics.when(
            data: (Lyrics value) {
              if (value.isEmpty) {
                return EmptyState(
                  icon: Icons.lyrics_outlined,
                  title: 'Текста нет',
                  subtitle: value.source == 'Субтитры'
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
              if (value.isSynced) {
                return _SyncedLyrics(lines: value.timed!, search: search);
              }
              // Обычный текст: подсветки и автопрокрутки нет — их честно
              // показывает подпись, иначе казалось бы, что плеер «сломался».
              return _PlainLyrics(
                text: value.plain ?? '',
                source: value.source,
                search: search,
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
  });

  final LyricsRequest request;
  final bool searchOpen;
  final VoidCallback onToggleSearch;

  /// Источник, из которого пришёл текст (может отличаться от выбранного:
  /// основной источник подтягивает синхронизацию из LRCLIB).
  final String? actualSource;

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
          LyricsMenuButton(request: request, iconSize: 20),
        ],
      ),
    );
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
  });

  final String text;
  final String? source;
  final _LyricsSearch search;
  final VoidCallback onFindSource;

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
    return SingleChildScrollView(
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
              child: Text.rich(
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
            ),
        ],
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

/// Синхронизированный текст: плавная автопрокрутка, подсветка активной строки
/// и пословное «караоке», как в `LyricsV2` (ArchiveTune).
class _SyncedLyrics extends ConsumerStatefulWidget {
  const _SyncedLyrics({required this.lines, required this.search});

  final List<TimedLyric> lines;
  final _LyricsSearch search;

  @override
  ConsumerState<_SyncedLyrics> createState() => _SyncedLyricsState();
}

class _SyncedLyricsState extends ConsumerState<_SyncedLyrics>
    with TickerProviderStateMixin {
  /// Ключ на каждую строку — по нему считаем позицию для автопрокрутки.
  late List<GlobalKey> _keys = _buildKeys();

  final ScrollController _controller = ScrollController();

  /// Сглаженная позиция в миллисекундах — по ней рисуется «караоке».
  final ValueNotifier<int> _positionMs = ValueNotifier<int>(0);

  /// Номер активной строки — список перестраивается только при её смене, а не
  /// на каждом тике позиции.
  final ValueNotifier<int> _activeIndex = ValueNotifier<int>(-1);

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
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _manualTimer?.cancel();
    _scrollAnimation?.dispose();
    _controller.dispose();
    _positionMs.dispose();
    _activeIndex.dispose();
    super.dispose();
  }

  List<GlobalKey> _buildKeys() =>
      List<GlobalKey>.generate(widget.lines.length, (_) => GlobalKey());

  @override
  void didUpdateWidget(covariant _SyncedLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lines.length != widget.lines.length) {
      _keys = _buildKeys();
      _activeIndex.value = -1;
      _lastScrolledIndex = -1;
    }
    if (oldWidget.search.jumpSeq != widget.search.jumpSeq &&
        widget.search.currentLine >= 0) {
      _scheduleScroll(widget.search.currentLine);
    }
  }

  double _clampOffset(double value) {
    if (!_controller.hasClients) return value;
    final ScrollPosition position = _controller.position;
    return value.clamp(position.minScrollExtent, position.maxScrollExtent);
  }

  int _indexForPosition(int positionMs) {
    int index = -1;
    for (int i = 0; i < widget.lines.length; i++) {
      if (widget.lines[i].time.inMilliseconds <= positionMs) {
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

    final int rounded = _smoothMs.round();
    if (_positionMs.value != rounded) _positionMs.value = rounded;

    final int index = _indexForPosition(rounded + _leadMs);
    if (index != _activeIndex.value) {
      _activeIndex.value = index;
    }
    // Прокручиваем при смене строки, а также один раз после первой раскладки
    // (`_lastScrolledIndex` обновляется только после удачной прокрутки).
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

    final Widget list = ValueListenableBuilder<int>(
      valueListenable: _activeIndex,
      builder: (BuildContext context, int active, Widget? _) {
        return SingleChildScrollView(
          controller: _controller,
          padding: const EdgeInsets.fromLTRB(24, 72, 24, 160),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (int i = 0; i < widget.lines.length; i++)
                _LyricLine(
                  key: _keys[i],
                  index: i,
                  line: widget.lines[i],
                  active: i == active,
                  // До первой строки активной нет (active == -1): тогда
                  // расстояние считаем от «минус первой», чтобы строки не
                  // гасли все разом, а читались как близкие/дальние.
                  distance: (i - active).abs(),
                  manualScrolling: _manualScrolling,
                  positionMs: _positionMs,
                  words: _wordTimings(i),
                  baseSize: baseSize,
                  search: widget.search,
                ),
            ],
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
    required this.index,
    required this.line,
    required this.active,
    required this.distance,
    required this.manualScrolling,
    required this.positionMs,
    required this.words,
    required this.baseSize,
    required this.search,
  });

  final int index;
  final TimedLyric line;
  final bool active;
  final int distance;
  final bool manualScrolling;
  final ValueNotifier<int> positionMs;
  final List<_WordTiming> words;
  final double baseSize;
  final _LyricsSearch search;

  /// Прозрачность строки по расстоянию (`LyricsV2.kt:549-583`).
  double get _alpha {
    if (active) return 1;
    if (manualScrolling) {
      if (distance == 1) return _manualAlpha1;
      if (distance == 2) return _manualAlpha2;
      if (distance == 3) return _manualAlpha3;
      return _manualFarAlpha;
    }
    if (distance == 1) return _closeAlpha1;
    if (distance == 2) return _closeAlpha2;
    if (distance == 3) return _closeAlpha3;
    return _farAlpha;
  }

  /// Размытие строки по расстоянию (`LyricsV2.kt:584-590`).
  ///
  /// Ограничено ближними строками (до трёх): дальние и без размытия почти
  /// прозрачны (альфа 0.10), а размытие сотен `ImageFilter`-слоёв на слабой
  /// машине заметно тормозит прокрутку. У ближних значения как в оригинале.
  double get _blur {
    if (active || manualScrolling || distance > 3) return 0;
    if (distance == 1) return _blur1;
    if (distance == 2) return _blur2;
    return _blurFar;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Между строками — `lineSpacing * 8`, где lineSpacing по умолчанию 1.3
    // (`LyricsV2.kt:677-679`).
    final EdgeInsets padding = EdgeInsets.only(
      top: index == 0 ? 0 : 10,
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
                  return Transform.scale(
                    scale: scaleValue,
                    alignment: Alignment.centerLeft,
                    child: content,
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
