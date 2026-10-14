import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../core/utils/artwork_urls.dart';
import '../../core/utils/format.dart';
import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/catalog_providers.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/artwork.dart';
import '../../widgets/track_menu.dart';
import 'lyrics_actions.dart';
import 'lyrics_view.dart';
import 'queue_list.dart';
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
                Positioned.fill(child: _ArtworkBackdrop(track: track)),
                SafeArea(
                  child: Column(
                    children: <Widget>[
                      _TopBar(
                        track: track,
                        showLyrics: _showLyrics,
                        onToggleLyrics: () =>
                            setState(() => _showLyrics = !_showLyrics),
                      ),
                      // На широком экране раскладка двухколоночная: обложка
                      // слева, управление справа. Вертикальная «телефонная»
                      // колонка на десктопе растягивала обложку на пол-экрана
                      // и оставляла пустоту по бокам.
                      Expanded(
                        child: context.isExpandedLayout
                            ? Row(
                                children: <Widget>[
                                  Expanded(
                                    flex: 5,
                                    child: _Stage(
                                      showLyrics: _showLyrics,
                                      track: track,
                                    ),
                                  ),
                                  Expanded(
                                    flex: 4,
                                    child: Column(
                                      children: <Widget>[
                                        // Свободное место над полосой трека
                                        // занимает очередь: на широком экране
                                        // она иначе оставалась пустой.
                                        const Expanded(child: QueueList()),
                                        _Controls(
                                          track: track,
                                          player: player,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              )
                            : Column(
                                children: <Widget>[
                                  Expanded(
                                    child: _Stage(
                                      showLyrics: _showLyrics,
                                      track: track,
                                    ),
                                  ),
                                  _Controls(track: track, player: player),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

/// Обложка или текст песни — то, что занимает основную площадь.
class _Stage extends StatelessWidget {
  const _Stage({required this.showLyrics, required this.track});

  final bool showLyrics;
  final Track track;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: showLyrics
          ? LyricsView(
              key: ValueKey<String>('lyr-${track.id}'),
              videoId: track.id,
            )
          : _ArtworkStage(track: track),
    );
  }
}

/// Блок управления: название, шкала, транспорт и громкость.
class _Controls extends StatelessWidget {
  const _Controls({required this.track, required this.player});

  final Track track;
  final PlayerUiState player;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
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
    );
  }
}

/// Фон: сама обложка во всю площадь, притемнённая к низу.
///
/// Без размытия — так дешевле для отрисовки и ближе к ArchiveTune, где
/// виден настоящий рисунок, а не «стекло».
class _ArtworkBackdrop extends StatelessWidget {
  const _ArtworkBackdrop({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<String> variants = track.artworkFallbacks(kArtworkLarge);

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (variants.isNotEmpty)
          // Размытие: резкая обложка на всю площадь отвлекала от управления,
          // а размытая читается как фон.
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
            child: Artwork(
              url: variants.first,
              fallbacks:
                  variants.length > 1 ? variants.sublist(1) : const <String>[],
              fit: BoxFit.cover,
              radius: BorderRadius.zero,
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              // Затемнение сильнее прежнего: фон не должен спорить
              // с обложкой и управлением на переднем плане.
              colors: <Color>[
                scheme.surface.withValues(alpha: 0.72),
                scheme.surface.withValues(alpha: 0.92),
                scheme.surface,
              ],
              stops: const <double>[0.2, 0.6, 0.92],
            ),
          ),
        ),
      ],
    );
  }
}

/// Обложка в открытом виде — крупная и резкая.
class _ArtworkStage extends StatelessWidget {
  const _ArtworkStage({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final List<String> variants = track.artworkFallbacks(kArtworkLarge);

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
                url: variants.isEmpty ? null : variants.first,
                fallbacks: variants.length > 1
                    ? variants.sublist(1)
                    : const <String>[],
                radius: BorderRadius.circular(AppLayout.radiusXL),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({
    required this.track,
    required this.showLyrics,
    required this.onToggleLyrics,
  });

  final Track track;
  final bool showLyrics;
  final VoidCallback onToggleLyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Метаданные для внешней базы текста (LRCLIB) — из играющего трека.
    final LyricsRequest request = LyricsRequest.fromTrack(track);

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
          // Источник текста можно сменить, даже пока текст скрыт: пункт
          // «найти в другом источнике» из меню текста.
          // Одна кнопка вместо двух: меню текста уже содержит
          // «Показать/скрыть», и отдельная кнопка дублировала действие.
          LyricsMenuButton(
            request: request,
            onToggleVisibility: onToggleLyrics,
            lyricsVisible: showLyrics,
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// Название, исполнитель и кнопка «нравится».
///
/// Состояние берём из общего [likedIdsProvider], а не из локального флага:
/// лайк, поставленный здесь, сразу виден в строках треков и островке плеера
/// (и наоборот).
class _InfoRow extends ConsumerWidget {
  const _InfoRow({required this.track, required this.player});

  final Track track;
  final PlayerUiState player;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool liked = ref.watch(
      likedIdsProvider.select((Set<String> ids) => ids.contains(track.id)),
    );
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
          // «…» открывает то же меню, что и из островка: исполнитель, альбом,
          // очередь и лайк. rootNavigator: плеер сам лежит в корневом
          // навигаторе — иначе переход остался бы под его экраном.
          IconButton(
            tooltip: 'Действия',
            icon: const Icon(Icons.more_vert, size: 20),
            onPressed: () =>
                showTrackMenu(context, track, rootNavigator: true),
          ),
          const SizedBox(width: 4),
          IconButton.filledTonal(
            tooltip: liked ? 'Убрать из «Мне нравится»' : 'Нравится',
            icon: Icon(
              liked ? Icons.favorite : Icons.favorite_border,
              size: 20,
              color: liked ? scheme.primary : null,
            ),
            onPressed: signedIn ? () => _like(context, ref) : null,
          ),
        ],
      ),
    );
  }

  Future<void> _like(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool wasLiked = ref.read(likedIdsProvider).contains(track.id);
    try {
      await ref.read(likedIdsProvider.notifier).toggle(track.id);
      messenger.showSnackBar(
        SnackBar(
          content: Text(wasLiked
              ? 'Убрано из «Мне нравится»'
              : 'Добавлено в «Мне нравится»'),
        ),
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
