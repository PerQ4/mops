import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../state/auth_controller.dart';
import '../../widgets/async_views.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/horizontal_list.dart';
import '../../widgets/media_card.dart';
import 'podcast_models.dart';
import 'podcast_playback.dart';
import 'podcast_providers.dart';
import 'podcast_screen.dart';

/// Раздел «Подкасты» коллекции.
///
/// Сверху — то, что пользователь уже слушал (локальная история), ниже —
/// подписки из библиотеки YouTube Music и обзор `FEmusic_podcasts`. Обзор
/// публичный, поэтому раздел полезен и без входа: гость видит полки и может
/// открыть шоу, а подписки появятся после входа.
class PodcastLibrarySection extends ConsumerWidget {
  const PodcastLibrarySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PodcastLocalState local = ref.watch(podcastLocalProvider);
    final AsyncValue<List<PodcastShow>> subscriptions =
        ref.watch(podcastSubscriptionsProvider);
    final AsyncValue<List<PodcastSection>> overview =
        ref.watch(podcastSectionsProvider);
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );

    final List<PodcastShow> shows =
        subscriptions.value ?? const <PodcastShow>[];
    final List<PodcastSection> sections =
        overview.value ?? const <PodcastSection>[];
    final bool loading = subscriptions.isLoading || overview.isLoading;
    final bool hasContent = local.recent.isNotEmpty ||
        shows.isNotEmpty ||
        sections.isNotEmpty;

    // Первый запуск без истории: пока сеть отвечает, показываем скелетон
    // каруселей, а не пустую страницу с «ничего нет».
    if (!hasContent && loading) {
      return const SectionSkeleton(rows: 3);
    }

    // Ни истории, ни подписок, ни обзора — и при этом запрос упал. Без
    // отдельной ветки пользователь увидел бы «Подкастов пока нет» вместо
    // причины, по которой их нет.
    final Object? firstError = subscriptions.error ?? overview.error;
    final bool failedWithoutData = !hasContent && !loading && firstError != null;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final _ShowGrid grid = _showGrid(constraints.maxWidth);

        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(podcastSubscriptionsProvider);
            ref.invalidate(podcastSectionsProvider);
            await ref.read(podcastSectionsProvider.future);
          },
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: <Widget>[
              if (local.recent.isNotEmpty)
                SliverToBoxAdapter(
                  child: _RecentShelf(entries: local.recent),
                ),
              if (signedIn) ..._subscriptionSlivers(
                context,
                ref,
                subscriptions,
                shows,
                grid,
              ),
              if (failedWithoutData)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: ErrorState(
                    message: describeError(firstError),
                    onRetry: () {
                      ref.invalidate(podcastSubscriptionsProvider);
                      ref.invalidate(podcastSectionsProvider);
                    },
                  ),
                )
              else if (!hasContent && !loading)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: Icons.podcasts,
                    title: 'Подкастов пока нет',
                    subtitle: signedIn
                        ? 'Подпишитесь на шоу в YouTube Music — они появятся '
                            'здесь вместе с новыми выпусками.'
                        : 'Войдите в аккаунт, чтобы видеть свои подписки, '
                            'или откройте любое шоу из обзора.',
                  ),
                )
              else ..._overviewSlivers(ref, context, overview, sections),
              const SliverToBoxAdapter(
                child: SizedBox(height: AppLayout.floatingDockClearance),
              ),
            ],
          ),
        );
      },
    );
  }

  /// «Недавно игравшие» и «Подписки» — то, что уже своё.
  List<Widget> _subscriptionSlivers(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<PodcastShow>> subscriptions,
    List<PodcastShow> shows,
    _ShowGrid grid,
  ) {
    final Object? error = subscriptions.error;
    final bool loading = subscriptions.isLoading;

    final List<Widget> slivers = <Widget>[
      const SliverToBoxAdapter(child: _ShelfHeader('Подписки')),
    ];

    if (shows.isEmpty && loading) {
      slivers.add(const SliverToBoxAdapter(child: _InlineLoading()));
    } else if (shows.isEmpty && error != null) {
      slivers.add(
        SliverToBoxAdapter(
          child: _InlineError(
            message: describeError(error),
            onRetry: () => ref.invalidate(podcastSubscriptionsProvider),
          ),
        ),
      );
    } else if (shows.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'Подписок нет. Откройте шоу из обзора и нажмите «Подписаться» — '
              'оно появится здесь.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ),
      );
    } else {
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            _gridPadding,
            0,
            _gridPadding,
            8,
          ),
          sliver: SliverGrid(
            gridDelegate: grid.delegate,
            delegate: SliverChildBuilderDelegate(
              (BuildContext context, int index) {
                final PodcastShow show = shows[index];
                return MediaCard(
                  title: show.title,
                  subtitle: show.author,
                  imageUrl: show.artwork,
                  width: grid.tileWidth,
                  icon: Icons.podcasts,
                  onTap: () => openPodcastShow(context, show.key),
                );
              },
              childCount: shows.length,
            ),
          ),
        ),
      );
    }

    return slivers;
  }

  /// Обзор подкастов — полки YouTube Music.
  List<Widget> _overviewSlivers(
    WidgetRef ref,
    BuildContext context,
    AsyncValue<List<PodcastSection>> overview,
    List<PodcastSection> sections,
  ) {
    if (sections.isNotEmpty) {
      return <Widget>[
        const SliverToBoxAdapter(child: _ShelfHeader('Обзор подкастов')),
        for (final PodcastSection section in sections)
          if (section.shows.isNotEmpty)
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _ShelfHeader(section.title, small: true),
                  HorizontalList(
                    height: AppLayout.gridThumbnailHeight + 96,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    separator: 24,
                    itemCount: section.shows.length,
                    itemBuilder: (BuildContext context, int index) {
                      final PodcastShow show = section.shows[index];
                      return MediaCard(
                        title: show.title,
                        subtitle: show.author,
                        imageUrl: show.artwork,
                        width: AppLayout.gridThumbnailHeight,
                        icon: Icons.podcasts,
                        onTap: () => openPodcastShow(context, show.key),
                      );
                    },
                  ),
                ],
              ),
            ),
      ];
    }

    if (overview.isLoading) {
      return const <Widget>[
        SliverToBoxAdapter(child: _InlineLoading()),
      ];
    }

    final Object? error = overview.error;
    if (error != null) {
      return <Widget>[
        SliverToBoxAdapter(
          child: _InlineError(
            message: describeError(error),
            onRetry: () => ref.invalidate(podcastSectionsProvider),
          ),
        ),
      ];
    }

    return const <Widget>[];
  }
}

/// «Недавно игравшие»: реально запущенные выпуски, свежие первыми.
class _RecentShelf extends ConsumerWidget {
  const _RecentShelf({required this.entries});

  final List<PodcastEntry> entries;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _ShelfHeader('Недавно игравшие'),
        HorizontalList(
          height: AppLayout.gridThumbnailHeight + 96,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          separator: 24,
          itemCount: entries.length,
          itemBuilder: (BuildContext context, int index) {
            final PodcastEntry entry = entries[index];
            final int percent = (entry.fraction * 100).round();
            return MediaCard(
              title: entry.episode.track.title,
              subtitle: percent > 0 && percent < 100
                  ? '${entry.showTitle} • $percent%'
                  : entry.showTitle,
              imageUrl: entry.artwork,
              width: AppLayout.gridThumbnailHeight,
              icon: Icons.podcasts,
              showPlay: true,
              onTap: () => openPodcastShow(context, entry.showId),
              onPlay: () => PodcastPlayback.resumeEntry(ref, entry),
            );
          },
        ),
      ],
    );
  }
}

/// Заголовок раздела коллекции.
class _ShelfHeader extends StatelessWidget {
  const _ShelfHeader(this.title, {this.small = false});

  final String title;

  /// Меньший заголовок — у полок обзора: главный раздел уже назван выше.
  final bool small;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: (small ? text.titleMedium : text.titleLarge)?.copyWith(
          fontWeight: small ? FontWeight.w600 : FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}

/// Индикатор загрузки внутри прокручиваемой страницы.
class _InlineLoading extends StatelessWidget {
  const _InlineLoading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
      ),
    );
  }
}

/// Ошибка загрузки одной части раздела: остальное содержимое остаётся.
class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Icon(Icons.cloud_off_outlined, color: scheme.error),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ),
          const SizedBox(width: 12),
          TextButton(onPressed: onRetry, child: const Text('Повторить')),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- сетка подписок

const double _gridPadding = 24;
const double _gridSpacing = 16;
const double _minTileWidth = 180;

/// Параметры сетки подписок: делегат и ширина плитки.
class _ShowGrid {
  const _ShowGrid({required this.delegate, required this.tileWidth});

  final SliverGridDelegate delegate;
  final double tileWidth;
}

/// Сетка как у остальных разделов библиотеки: колонок тем больше, чем шире
/// окно, высота плитки — её ширина плюс место под две строки подписи.
_ShowGrid _showGrid(double availableWidth) {
  final double width = math.max(availableWidth - _gridPadding * 2, 1);
  final int columns = math.max(
    1,
    (width / (_minTileWidth + _gridSpacing)).ceil(),
  );
  final double tileWidth =
      (width - _gridSpacing * (columns - 1)) / columns;
  return _ShowGrid(
    tileWidth: tileWidth,
    delegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: _gridSpacing,
      mainAxisSpacing: _gridSpacing,
      // Обложка-квадрат и подпись под ней: заголовок 20, зазор 2, автор 16
      // (две строки — 40) и запас на округление метрик строки.
      mainAxisExtent: tileWidth + 78,
    ),
  );
}
