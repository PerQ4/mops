import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../core/theme/motion.dart';
import '../../core/utils/format.dart';
import '../../state/auth_controller.dart';
import '../../state/player_controller.dart';
import '../../widgets/artwork.dart';
import '../../widgets/async_views.dart';
import '../../widgets/back_gesture.dart';
import '../../widgets/empty_state.dart';
import '../album/media_hero.dart';
import '../shell/content_navigator.dart';
import 'podcast_models.dart';
import 'podcast_playback.dart';
import 'podcast_providers.dart';

/// Открывает страницу шоу в навигаторе содержимого.
///
/// Переход повторяет форму `AppRoutes._push`: подэкраны живут во вложенном
/// навигаторе, поэтому плавающий док остаётся на месте. Общий `AppRoutes` не
/// расширяется — `features/common/navigation.dart` в этой задаче не меняется.
Future<void> openPodcastShow(BuildContext context, String showId) {
  final NavigatorState navigator =
      contentNavigatorKey.currentState ?? Navigator.of(context);
  final MotionTransition motion = AppMotion.pageEnter;

  return navigator.push<void>(
    PageRouteBuilder<void>(
      barrierDismissible: true,
      pageBuilder: (
        BuildContext context,
        Animation<double> animation,
        Animation<double> secondaryAnimation,
      ) =>
          PodcastScreen(showId: showId),
      transitionDuration: motion.duration,
      reverseTransitionDuration: motion.reverseDuration ?? motion.duration,
      transitionsBuilder: (
        BuildContext context,
        Animation<double> animation,
        Animation<double> secondaryAnimation,
        Widget child,
      ) =>
          motion.routeTransition(
        animation: animation,
        begin: const Offset(0, 0.02),
        child: PredictiveBack(child: child),
      ),
    ),
  );
}

/// Страница подкаст-шоу: шапка с описанием и список выпусков.
class PodcastScreen extends ConsumerWidget {
  const PodcastScreen({super.key, required this.showId});

  /// Ключ шоу — звуковой id плейлиста (`PL…`) или browse-id (`MPSP…`).
  final String showId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<PodcastShow> show = ref.watch(
      podcastShowProvider(showId),
    );

    return Scaffold(
      body: show.when(
        data: (PodcastShow data) => _PodcastBody(show: data),
        loading: () => const MediaDetailSkeleton(),
        error: (Object error, StackTrace _) => Scaffold(
          appBar: AppBar(),
          body: ErrorState(
            message: describeError(error),
            onRetry: () => ref.invalidate(podcastShowProvider(showId)),
          ),
        ),
      ),
    );
  }
}

class _PodcastBody extends ConsumerWidget {
  const _PodcastBody({required this.show});

  final PodcastShow show;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? currentId = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.current?.id),
    );
    final bool playing = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.isPlaying),
    );
    final PodcastLocalState local = ref.watch(podcastLocalProvider);

    final bool hasEpisodes = show.episodes.isNotEmpty;
    final bool isCurrentShow = currentId != null &&
        show.episodes.any((PodcastEpisode e) => e.id == currentId);

    // «Продолжить» ведёт на последний недослушанный выпуск именно этого шоу.
    final PodcastEntry? resume = local.progressForShow(show.key);
    final int resumeIndex = resume == null
        ? -1
        : show.episodes.indexWhere(
            (PodcastEpisode e) => e.id == resume.episodeId,
          );
    final bool canResume = resumeIndex >= 0;

    final String playLabel = isCurrentShow && playing
        ? 'Пауза'
        : canResume
            ? 'Продолжить'
            : 'Слушать';
    final IconData playIcon = isCurrentShow && playing
        ? Icons.pause
        : canResume
            ? Icons.play_arrow
            : Icons.play_arrow;

    return CustomScrollView(
      slivers: <Widget>[
        SliverAppBar(
          pinned: true,
          expandedHeight: AppLayout.appBarHeight,
          title: Text(
            show.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: <Widget>[
            IconButton(
              tooltip: 'Обновить',
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.invalidate(podcastShowProvider(show.key)),
            ),
            const SizedBox(width: 4),
          ],
        ),
        SliverToBoxAdapter(
          child: MediaHero(
            title: show.title,
            subtitle: show.author,
            meta: _metaLine(show),
            description: show.description,
            imageUrl: show.artwork,
            fallbackIcon: Icons.podcasts,
            actions: <Widget>[
              HeroCircleButton(
                icon: Icons.shuffle,
                tooltip: 'Перемешать',
                size: 52,
                onPressed: hasEpisodes
                    ? () => PodcastPlayback.playShow(ref, show, shuffle: true)
                    : null,
              ),
              HeroPlayButton(
                label: playLabel,
                icon: playIcon,
                onPressed: !hasEpisodes
                    ? null
                    : () {
                        if (isCurrentShow && playing) {
                          ref
                              .read(playerControllerProvider.notifier)
                              .togglePlayPause();
                          return;
                        }
                        PodcastPlayback.playShow(
                          ref,
                          show,
                          startIndex: canResume ? resumeIndex : 0,
                        );
                      },
              ),
              _SubscribeButton(show: show),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Выпуски',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                if (hasEpisodes)
                  Text(
                    _episodeCountLabel(show.episodes.length),
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
              ],
            ),
          ),
        ),
        if (!hasEpisodes)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: MediaDetailStatePanel(
                icon: Icons.podcasts,
                title: 'Выпусков нет',
                description:
                    'YouTube Music не вернул эпизоды этого шоу. Возможно, '
                    'они доступны только в приложении или в другом регионе.',
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: show.episodes.length,
            itemBuilder: (BuildContext context, int index) {
              final PodcastEpisode episode = show.episodes[index];
              final bool isCurrent = currentId == episode.id;
              final PodcastEntry? progress = local.progress[episode.id];
              return _EpisodeTile(
                episode: episode,
                showArtwork: show.artwork,
                progress: progress,
                isCurrent: isCurrent,
                isPlaying: isCurrent && playing,
                onTap: () => PodcastPlayback.playEpisode(
                  ref,
                  show,
                  episode,
                  context: show.episodes,
                ),
                onShowDescription: episode.description == null
                    ? null
                    : () => _showDescription(context, episode),
              );
            },
          ),
        const SliverToBoxAdapter(
          child: SizedBox(height: AppLayout.floatingDockClearance),
        ),
      ],
    );
  }

  /// «12 выпусков • 8 ч 40 мин» — строка метаданных героя.
  String? _metaLine(PodcastShow show) {
    final List<String> parts = <String>[];
    if (show.episodes.isNotEmpty) {
      parts.add(_episodeCountLabel(show.episodes.length));
    }
    Duration total = Duration.zero;
    for (final PodcastEpisode episode in show.episodes) {
      total += episode.track.duration;
    }
    // У одного выпуска длительность уже видна в строке — дублировать нечего.
    if (show.episodes.length > 1 && total > Duration.zero) {
      parts.add(formatTotalDuration(total));
    }
    return parts.isEmpty ? null : parts.join(mediaDetailMetadataSeparator);
  }

  void _showDescription(BuildContext context, PodcastEpisode episode) {
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(
          episode.track.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (episode.date != null) ...<Widget>[
                  Text(
                    episode.date!,
                    style: Theme.of(dialogContext)
                        .textTheme
                        .labelLarge
                        ?.copyWith(
                          color: Theme.of(dialogContext)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 12),
                ],
                Text(episode.description!),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }
}

/// Подписка на шоу. Состояние оптимистичное: иконка меняется сразу, а при
/// ошибке сервера откатывается и показывается сообщение.
class _SubscribeButton extends ConsumerWidget {
  const _SubscribeButton({required this.show});

  final PodcastShow show;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );
    final bool subscribed = ref.watch(
      podcastSubscriptionsControllerProvider.select(
        (Set<String> keys) => keys.contains(show.key),
      ),
    );
    final bool enabled = signedIn && show.canSubscribe;

    final String tooltip;
    if (!signedIn) {
      tooltip = 'Войдите, чтобы подписаться';
    } else if (!show.canSubscribe) {
      tooltip = 'YouTube не вернул id этого шоу';
    } else {
      tooltip = subscribed ? 'Вы подписаны' : 'Подписаться';
    }

    return HeroCircleButton(
      icon: subscribed
          ? Icons.check_circle_outline
          : Icons.add_circle_outline,
      tooltip: tooltip,
      size: 52,
      onPressed: enabled ? () => _toggle(context, ref) : null,
    );
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(podcastSubscriptionsControllerProvider.notifier).toggle(
            show,
          );
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(describeError(error))),
      );
    }
  }
}

/// Строка выпуска: дата, длительность, прогресс и запуск.
class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.episode,
    required this.showArtwork,
    required this.progress,
    required this.isCurrent,
    required this.isPlaying,
    required this.onTap,
    required this.onShowDescription,
  });

  final PodcastEpisode episode;
  final String? showArtwork;
  final PodcastEntry? progress;
  final bool isCurrent;
  final bool isPlaying;
  final VoidCallback onTap;

  /// Открыть полное описание. `null` — описания нет, и значок не нужен.
  final VoidCallback? onShowDescription;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    final Color titleColor =
        isCurrent ? scheme.onSecondaryContainer : scheme.onSurface;
    final Color subtitleColor = isCurrent
        ? scheme.onSecondaryContainer.withValues(alpha: 0.7)
        : scheme.onSurfaceVariant;

    final double fraction = progress?.fraction ?? 0;
    // Почти дослушанный выпуск прогрессом не считаем — трекер его уже забыл
    // бы, а полоска у самого конца выглядела бы как незаконченный.
    final bool showProgress = fraction > 0 && fraction < 0.99;

    final List<String> meta = <String>[
      if (episode.date != null && episode.date!.isNotEmpty) episode.date!,
      if (episode.track.duration > Duration.zero)
        formatDuration(episode.track.duration),
      if (showProgress) '${(fraction * 100).round()}%',
    ];

    return SizedBox(
      height: AppLayout.trackRowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Material(
          color: isCurrent ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(AppLayout.radiusS),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onShowDescription,
            child: Row(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: SizedBox(
                    width: AppLayout.trackArtwork,
                    height: AppLayout.trackArtwork,
                    child: Stack(
                      alignment: Alignment.center,
                      children: <Widget>[
                        Artwork(
                          url: episode.track.artwork ?? showArtwork,
                          size: AppLayout.trackArtwork,
                          radius: BorderRadius.circular(
                            AppLayout.thumbnailRadius,
                          ),
                          icon: Icons.podcasts,
                        ),
                        if (isCurrent)
                          Container(
                            width: AppLayout.trackArtwork,
                            height: AppLayout.trackArtwork,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(
                                AppLayout.thumbnailRadius,
                              ),
                            ),
                            child: Icon(
                              isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 26,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          episode.track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyLarge?.copyWith(
                            color: titleColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (meta.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 2),
                          Text(
                            meta.join(mediaDetailMetadataSeparator),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(
                              color: subtitleColor,
                            ),
                          ),
                        ],
                        if (showProgress) ...<Widget>[
                          const SizedBox(height: 4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: fraction,
                              minHeight: 3,
                              backgroundColor:
                                  subtitleColor.withValues(alpha: 0.2),
                              color: isCurrent
                                  ? scheme.onSecondaryContainer
                                  : scheme.primary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (onShowDescription != null)
                  IconButton(
                    tooltip: 'Описание выпуска',
                    iconSize: 20,
                    color: subtitleColor,
                    icon: const Icon(Icons.notes),
                    onPressed: onShowDescription,
                  )
                else
                  const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// «5 выпусков», «1 выпуск», «21 выпуск».
String _episodeCountLabel(int count) {
  final int last = count.abs() % 100;
  final int digit = last % 10;
  final String word;
  if (last >= 11 && last <= 14) {
    word = 'выпусков';
  } else if (digit == 1) {
    word = 'выпуск';
  } else if (digit >= 2 && digit <= 4) {
    word = 'выпуска';
  } else {
    word = 'выпусков';
  }
  return '$count $word';
}
