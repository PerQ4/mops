import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/catalog_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/async_views.dart';
import '../../widgets/empty_state.dart';

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
    final AsyncValue<Lyrics> lyrics = ref.watch(lyricsProvider(videoId));

    return lyrics.when(
      data: (Lyrics data) {
        if (data.isEmpty) {
          return EmptyState(
            icon: Icons.lyrics_outlined,
            title: 'Текста нет',
            subtitle: 'Для этого трека YouTube Music не предоставил текст.',
            action: compact ? null : const SizedBox.shrink(),
          );
        }
        if (data.isSynced) {
          return _SyncedLyrics(lines: data.timed!);
        }
        return _PlainLyrics(text: data.plain ?? '');
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace _) =>
          ErrorState(
          message: describeError(error), compact: true),
    );
  }
}

/// Обычный текст: просто прокручиваемый блок.
class _PlainLyrics extends StatelessWidget {
  const _PlainLyrics({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final TextTheme theme = Theme.of(context).textTheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
      child: Text(
        text,
        style: theme.titleMedium?.copyWith(height: 1.7),
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
        padding: const EdgeInsets.fromLTRB(24, 120, 24, 160),
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
              // Раньше разница была только в жирности и оттенке, поэтому
              // казалось, что подсветки нет вовсе.
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
