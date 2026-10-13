import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../core/utils/format.dart';
import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/catalog_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/artwork.dart';
import 'lyrics_view.dart';
import 'player_controls.dart';

/// Полноэкранный плеер для узких экранов.
///
/// На широких экранах он не нужен: там плеер всегда виден в правой панели,
/// поэтому дублирующего маршрута нет. Оформление — как у ArchiveTune:
/// размытая обложка сверху, тёмная панель с управлением снизу, крупный
/// транспорт и тонкая полоса перемотки.
class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  bool _showLyrics = false;

  @override
  Widget build(BuildContext context) {
    final PlayerUiState player = ref.watch(playerControllerProvider);
    final Track? track = player.current;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: track == null
          ? _Empty(onClose: () => Navigator.maybePop(context))
          : Stack(
              children: <Widget>[
                // Фон: размытая обложка, плавно переходящая в тёмную панель.
                Positioned.fill(child: _BlurredBackdrop(track: track)),
                SafeArea(
                  child: Column(
                    children: <Widget>[
                      _TopBar(
                        showLyrics: _showLyrics,
                        onToggleLyrics: () =>
                            setState(() => _showLyrics = !_showLyrics),
                      ),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          child: _showLyrics
                              ? LyricsView(
                                  key: ValueKey<String>('lyr-${track.id}'),
                                  videoId: track.id,
                                )
                              : _ArtworkStage(track: track),
                        ),
                      ),
                      _InfoRow(track: track, player: player),
                      const SizedBox(height: 4),
                      PlayerSeekBar(player: player),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: PlayerTransportBar(player: player),
                      ),
                      PlayerVolumeBar(player: player),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _BlurredBackdrop extends StatelessWidget {
  const _BlurredBackdrop({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? url = track.thumbnails.sized(512) ?? track.artwork;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (url != null)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
            child: Artwork(
              url: url,
              fit: BoxFit.cover,
              radius: BorderRadius.zero,
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                scheme.surface.withValues(alpha: 0.45),
                scheme.surface.withValues(alpha: 0.8),
                scheme.surface,
              ],
              stops: const <double>[0.25, 0.62, 0.95],
            ),
          ),
        ),
      ],
    );
  }
}

class _ArtworkStage extends StatelessWidget {
  const _ArtworkStage({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppLayout.gutter),
      child: Center(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // Обложка квадратная и вписывается в доступное место.
            final double side = constraints.biggest.shortestSide;
            return SizedBox(
              width: side,
              height: side,
              child: Artwork(
                url: track.thumbnails.sized(1024) ?? track.artwork,
                radius: BorderRadius.circular(AppLayout.radiusXL),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.showLyrics, required this.onToggleLyrics});

  final bool showLyrics;
  final VoidCallback onToggleLyrics;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: 'Свернуть',
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
            onPressed: () => Navigator.maybePop(context),
          ),
          const Spacer(),
          Text(
            'Сейчас играет',
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          IconButton.filledTonal(
            tooltip: showLyrics ? 'Скрыть текст' : 'Показать текст',
            isSelected: showLyrics,
            icon: const Icon(Icons.lyrics_outlined, size: 20),
            selectedIcon: const Icon(Icons.lyrics, size: 20),
            onPressed: onToggleLyrics,
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// Название, исполнитель и кнопка «нравится».
class _InfoRow extends ConsumerWidget {
  const _InfoRow({required this.track, required this.player});

  final Track track;
  final PlayerUiState player;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppLayout.gutter, 12, 8, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  track.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  player.error ?? track.artistLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(
                    color: player.error != null
                        ? scheme.error
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: signedIn ? 'Нравится' : 'Войдите, чтобы ставить лайки',
            icon: const Icon(Icons.favorite_border, size: 20),
            onPressed: signedIn ? () => _like(context, ref) : null,
          ),
        ],
      ),
    );
  }

  Future<void> _like(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(librarySourceProvider).setLiked(track.id, liked: true);
      messenger.showSnackBar(
        const SnackBar(content: Text('Добавлено в «Мне нравится»')),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Не удалось поставить лайк. Проверьте вход в аккаунт.'),
        ),
      );
    }
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
              onPressed: onClose,
            ),
          ),
          const Expanded(
            child: Center(child: Text('Ничего не играет')),
          ),
        ],
      ),
    );
  }
}

/// Подпись длительности для панелей — оставлена для совместимости со старым
/// кодом; использует общий форматтер.
String progressLabel(PlayerUiState player) =>
    '${formatDurationClock(player.playback.position)} / '
    '${formatDurationClock(player.playback.duration)}';
