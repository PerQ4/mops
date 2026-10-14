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
    final bool matches = current != null && current.id == videoId;
    final LyricsRequest request = LyricsRequest(
      videoId: videoId,
      title: matches ? current.title : null,
      artist: matches && current.artists.isNotEmpty
          ? current.artists.first.name
          : null,
      album: matches ? current.album?.name : null,
      duration: matches ? current.duration : null,
    );

    final AsyncValue<Lyrics> lyrics = ref.watch(lyricsProvider(request));

    return Column(
      children: <Widget>[
        _LyricsToolbar(request: request),
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
                          onPressed: () => showLyricsMenu(context, ref, request),
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
                onFindSource: () => showLyricsMenu(context, ref, request),
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
  const _LyricsToolbar({required this.request});

  final LyricsRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final LyricsSource source =
        ref.watch(lyricsSourceOverrideProvider)[request.videoId] ??
            ref.watch(
              settingsControllerProvider.select(
                (AppSettings s) => s.lyricsSource,
              ),
            );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
      child: Row(
        children: <Widget>[
          Icon(Icons.lyrics_outlined, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              source.label,
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
    final ColorScheme scheme = Theme.of(context).colorScheme;
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    source == null || source!.isEmpty
                        ? 'Текст без синхронизации — автопрокрутки нет.'
                        : 'Текст без синхронизации ($source) — автопрокрутки нет.',
                    style: theme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: onFindSource,
                  child: const Text('Другой источник'),
                ),
              ],
            ),
          ),
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
    // Позиция приходит часто, но перестраивать весь список не нужно:
    // отслеживаем только момент смены строки.
    final Duration position = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.playback.position),
    );

    final int index = _indexForPosition(position);
    if (index != _activeIndex) {
      _activeIndex = index;
      if (!_userScrolling) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scrollTo(index);
        });
      }
    }

    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme theme = Theme.of(context).textTheme;
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
          return AnimatedContainer(
            key: _keys[index],
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              // Подсветка активной строки: цветом акцента и мягкой подложкой.
              color: active
                  ? scheme.primary.withValues(alpha: 0.10)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              style: (theme.titleLarge ?? const TextStyle()).copyWith(
                height: 1.45,
                fontSize: baseSize * scale,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active
                    ? scheme.primary
                    : scheme.onSurfaceVariant.withValues(alpha: 0.55),
              ),
              child: Text(widget.lines[index].text),
            ),
          );
        },
      ),
    );
  }
}
