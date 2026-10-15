import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/app_settings.dart';
import '../../data/models/models.dart';
import '../../state/catalog_providers.dart';
import '../../state/player_controller.dart';
import '../../state/providers.dart';
import '../../widgets/async_views.dart';
import '../../widgets/empty_state.dart';
import 'lyrics_actions.dart';

/// Текст песни: синхронизированный (с автопрокруткой) или обычный.
class LyricsView extends ConsumerWidget {
  const LyricsView({
    super.key,
    required this.videoId,
    this.compact = false,
  });

  final String videoId;

  /// Компактный режим — для показа поверх обложки.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Метаданные берём у играющего трека: внешняя база (LRCLIB) ищет текст
    // по названию и исполнителю, а не по id YouTube.
    final Track? current = ref.watch(currentTrackProvider);
    final LyricsRequest request = (current != null && current.id == videoId)
        ? LyricsRequest.fromTrack(current)
        : LyricsRequest(videoId: videoId);

    final AsyncValue<Lyrics> lyrics = ref.watch(lyricsProvider(request));

    return Column(
      children: <Widget>[
        _LyricsToolbar(
          request: request,
          // Показываем настоящий источник строк, а не только выбранный:
          // основной источник умеет подтягивать синхронизацию из LRCLIB.
          actualSource: lyrics.value?.source,
        ),
        Expanded(
          child: lyrics.when(
            data: (Lyrics data) {
              if (data.isEmpty) {
                return EmptyState(
                  icon: Icons.lyrics_outlined,
                  title: 'Текста нет',
                  subtitle: data.source == 'Субтитры'
                      ? 'У этого видео нет субтитров. Выберите другой источник.'
                      : 'Для этого трека текст не нашёлся ни в YouTube Music, '
                          'ни в открытой базе. Попробуйте субтитры.',
                  action: compact
                      ? null
                      : TextButton.icon(
                          icon: const Icon(Icons.travel_explore, size: 18),
                          label: const Text('Найти в другом источнике'),
                          onPressed: () => showLyricsMenu(context, request),
                        ),
                );
              }
              if (data.isSynced) {
                return _SyncedLyrics(lines: data.timed!);
              }
              // Обычный текст: подсветки и автопрокрутки нет — их честно
              // показывает подпись, иначе казалось бы, что плеер «сломался».
              return _PlainLyrics(
                text: data.plain ?? '',
                source: data.source,
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
}

/// Шапка текста: откуда он и кнопка меню.
///
/// Нужна во всех поверхностях: и на полном экране, и в правой панели, и в
/// островке — поэтому живёт внутри самого [LyricsView], а не в шапке плеера.
class _LyricsToolbar extends ConsumerWidget {
  const _LyricsToolbar({required this.request, this.actualSource});

  final LyricsRequest request;

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
          LyricsMenuButton(request: request, iconSize: 20),
        ],
      ),
    );
  }
}

/// Обычный текст: просто прокручиваемый блок, без выделения строк.
class _PlainLyrics extends ConsumerWidget {
  const _PlainLyrics({
    required this.text,
    required this.source,
    required this.onFindSource,
  });

  final String text;
  final String? source;
  final VoidCallback onFindSource;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme theme = Theme.of(context).textTheme;
    final double scale = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.lyricsTextScale),
    );
    final double baseSize = theme.titleMedium?.fontSize ?? 16;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // Честно предупреждаем: у этого текста нет времён, поэтому плеер
          // не подсвечивает строки и не прокручивает их.
          const SizedBox(height: 16),
          Text(
            text,
            style: theme.titleMedium?.copyWith(
              height: 1.7,
              fontSize: baseSize * scale,
            ),
          ),
        ],
      ),
    );
  }
}

/// Синхронизированный текст с подсветкой активной строки.
class _SyncedLyrics extends ConsumerStatefulWidget {
  const _SyncedLyrics({required this.lines});

  final List<TimedLyric> lines;

  @override
  ConsumerState<_SyncedLyrics> createState() => _SyncedLyricsState();
}

class _SyncedLyricsState extends ConsumerState<_SyncedLyrics> {
  /// Ключ на каждую строку — по нему прокручиваем к активной.
  late List<GlobalKey> _keys = _buildKeys();

  int _activeIndex = -1;
  bool _userScrolling = false;

  /// Текущая позиция в миллисекундах — для пословной подсветки.
  int _positionMs = 0;

  List<GlobalKey> _buildKeys() =>
      List<GlobalKey>.generate(widget.lines.length, (_) => GlobalKey());

  @override
  void didUpdateWidget(covariant _SyncedLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lines.length != widget.lines.length) {
      _keys = _buildKeys();
      _activeIndex = -1;
    }
  }

  int _indexForPosition(Duration position) {
    int index = -1;
    for (int i = 0; i < widget.lines.length; i++) {
      if (widget.lines[i].time <= position) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  void _scrollTo(int index) {
    if (index < 0 || index >= _keys.length) return;
    final BuildContext? lineContext = _keys[index].currentContext;
    if (lineContext == null) return;
    Scrollable.ensureVisible(
      lineContext,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: 0.35,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Позиция приходит несколько раз в секунду. Подписываемся не на неё, а на
    // номер активной строки: список перестраивается только когда строка
    // действительно сменилась, а не на каждом тике — иначе все анимации
    // подсветки перезапускались бы несколько раз в секунду.
    // Позицию слушаем по миллисекундам: активная строка может подсвечиваться
    // по словам («караоке»), поэтому одного номера строки уже мало.
    final int positionMs = ref.watch(
      playerControllerProvider.select(
        (PlayerUiState s) => s.playback.position.inMilliseconds,
      ),
    );
    _positionMs = positionMs;
    final int index = _indexForPosition(Duration(milliseconds: positionMs));

    if (index != _activeIndex) {
      _activeIndex = index;
      if (!_userScrolling) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scrollTo(index);
        });
      }
    }

    final TextTheme theme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double scale = ref.watch(
      settingsControllerProvider.select((AppSettings s) => s.lyricsTextScale),
    );
    final double baseSize = theme.titleLarge?.fontSize ?? 22;

    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification notification) {
        // Пока пользователь листает сам — не мешаем автопрокруткой.
        if (notification is ScrollStartNotification &&
            notification.dragDetails != null) {
          _userScrolling = true;
        } else if (notification is ScrollEndNotification) {
          _userScrolling = false;
        }
        return false;
      },
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(24, 72, 24, 160),
        itemCount: widget.lines.length,
        itemBuilder: (BuildContext context, int index) {
          final bool active = index == _activeIndex;
          // Как в `LyricsV2` (ArchiveTune): активная строка — полной
          // непрозрачности и веса ExtraBold, остальные — с альфой 0.52 и
          // SemiBold; размер строки не меняется, чтобы текст не «прыгал».
          // Плавно перетекает между строками по мере воспроизведения.
          return Padding(
            key: _keys[index],
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              style: (theme.titleLarge ?? const TextStyle()).copyWith(
                height: 1.45,
                fontSize: baseSize * scale,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                color: active
                    ? scheme.onSurface
                    : scheme.onSurface.withValues(alpha: 0.52),
              ),
              child: _lineText(context, index, active, scheme),
            ),
          );
        },
      ),
    );
  }

  /// Текст строки: обычный, а для активной строки с пословной разметкой —
  /// «караоке»: спетые слова цветом акцента, остальные приглушены.
  Widget _lineText(
    BuildContext context,
    int index,
    bool active,
    ColorScheme scheme,
  ) {
    final TimedLyric line = widget.lines[index];
    if (!active || !line.hasWords) return Text(line.text);

    final List<InlineSpan> spans = <InlineSpan>[];
    for (final TimedWord word in line.words!) {
      final bool sung = word.time.inMilliseconds <= _positionMs;
      spans.add(
        TextSpan(
          text: '${word.text} ',
          style: TextStyle(
            // Спетые слова — акцентом (как подсветка в ArchiveTune),
            // оставшиеся — приглушённым текстом с альфой 0.52.
            color: sung
                ? scheme.primary
                : scheme.onSurface.withValues(alpha: 0.52),
          ),
        ),
      );
    }
    return Text.rich(TextSpan(children: spans));
  }
}
