import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart' as m3e;

import '../../core/theme/layout.dart';
import '../../core/utils/artwork_urls.dart';
import '../../core/utils/format.dart';
import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
import '../../widgets/artist_line.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/horizontal_list.dart';
import '../../widgets/track_menu.dart';
import '../../widgets/track_tile.dart';

/// Сколько ближайших треков показывать в карусели.
///
/// Верхняя граница рабочего диапазона 5–7: больше — и лента начинает
/// дублировать список «Далее»; меньше — и она теряет смысл как обзор.
const int _kCarouselMaxItems = 6;

/// Ниже этой высоты очереди карусель скрывается.
///
/// Блок «сейчас» (шапка ≈231 + строка текущего трека 72 ≈ 303) занимает верх
/// очереди и до карусели виден всегда. Если после него остаётся меньше трети
/// карточки, лента почти целиком уходит под сгиб — тогда она не обзор, а лишняя
/// прокрутка, и её лучше спрятать (островок, низкое окно).
const double _kCarouselMinHeight = 400;

/// Очередь воспроизведения.
///
/// Один виджет на все поверхности: в панели плеера на десктопе и в нижнем
/// листе на телефоне. Раньше это было продублировано.
///
/// Оформление шапки и строк перенесено из ArchiveTune (`ui/player/Queue.kt`,
/// `ui/player/QueueComponents.kt` — `CurrentSongHeader`, `ui/component/Items.kt`
/// — `ListItem`): обложка 64 с радиусом 12, отступ между колонками 14,
/// панель действий со скруглением 24, переключатели 48 с соединёнными
/// углами, разделитель с альфой 0.08.
class QueueList extends ConsumerWidget {
  const QueueList({
    super.key,
    this.scrollController,
    this.padding,
    this.showHeader = true,
    this.showCurrent = true,
    this.showCarousel = true,
  });

  final ScrollController? scrollController;
  final EdgeInsets? padding;

  /// Показывать шапку с текущим треком.
  ///
  /// На полном экране в широкой раскладке очередь стоит рядом с блоком
  /// управления, где название и действия уже есть, — там шапку выключаем,
  /// чтобы не дублировать. В панели плеера её тоже нет: текущий трек уже
  /// показан строкой сверху, и шапка повторяла его вместе с кнопкой лайка.
  /// Остаётся она только в островке, где другого блока «сейчас» нет.
  final bool showHeader;

  /// Показывать строку текущего трека вверху очереди.
  ///
  /// Панель и полный экран уже показывают текущий трек отдельным блоком, и
  /// строка в очереди давала лишние повторы. В островке строка остаётся.
  final bool showCurrent;

  /// Показывать горизонтальную карусель ближайших треков.
  ///
  /// В боковой панели она не нужна — там узкая колонка, и карусель только
  /// дублировала список «Далее» да мешала прокрутке.
  final bool showCarousel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Следим только за составом очереди и текущим треком. Позиция
    // воспроизведения меняется несколько раз в секунду, и если смотреть на
    // неё, весь список перестраивался бы на каждом тике — это и подтормаживало.
    final (List<Track> queue, int currentIndex, bool isPlaying) = ref.watch(
      playerControllerProvider.select(
        (PlayerUiState s) => (s.queue, s.index, s.isPlaying),
      ),
    );
    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);

    final Track? current = (currentIndex >= 0 && currentIndex < queue.length)
        ? queue[currentIndex]
        : null;
    final List<Track> upNext = (currentIndex < 0 || queue.isEmpty)
        ? queue
        : queue.sublist(currentIndex + 1);
    final List<Track> played = currentIndex <= 0
        ? const <Track>[]
        : queue.sublist(0, currentIndex);

    if (queue.isEmpty) {
      return const EmptyState(
        icon: Icons.queue_music,
        title: 'Очередь пуста',
        subtitle: 'Включите трек — он появится здесь.',
      );
    }

    final int playedCount = played.length;

    // Карусель — только ближайшие треки: растянутая на всю очередь, она была
    // бы дублем списка «Далее». Для одного трека лента не нужна — там хватает
    // обычной строки списка.
    final List<Track> featured = upNext.length >= 2
        ? upNext.take(_kCarouselMaxItems).toList(growable: false)
        : const <Track>[];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // На коротком окне (островок, сжатая панель) карусель заняла бы почти
        // весь видимый верх очереди и всё равно потребовала прокрутки — тогда
        // показываем только список. Высота ограничена на всех трёх
        // поверхностях (`Expanded`/`Flexible`), но проверяем безопасно: при
        // бесконечном ограничении карусель не прячем.
        final bool carouselVisible = showCarousel &&
            featured.isNotEmpty &&
            (!constraints.hasBoundedHeight ||
                constraints.maxHeight >= _kCarouselMinHeight);

        return CustomScrollView(
          controller: scrollController,
          // Очередь всегда владеет своей прокруткой и не претендует на роль
          // «главного» скролла: на полном экране рядом стоит блок управления
          // со своим `SingleChildScrollView`, и общий `PrimaryScrollController`
          // на телефоне тянул бы обе прокрутки одновременно.
          primary: false,
          slivers: <Widget>[
            // Шапка с текущим треком — как `CurrentSongHeader` в ArchiveTune.
            if (showHeader) const SliverToBoxAdapter(child: _QueueHeader()),

            // Строка текущего трека. На полном экране и в панели её скрываем:
            // название и действия уже стоят отдельным блоком рядом, и трек
            // показывался несколько раз.
            if (showCurrent && current != null) ...<Widget>[
              SliverToBoxAdapter(
                child: TrackTile(
                  track: current,
                  isCurrent: true,
                  isPlaying: isPlaying,
                  onTap: () {},
                  // В очереди свайп выключен: трек уже здесь, а горизонтальный
                  // жест мешал бы перетаскиванию строк.
                  enableSwipe: false,
                ),
              ),
            ],

            // Карусель ближайших треков — сразу после блока «сейчас» (шапка и
            // строка текущего трека) и перед списком «Далее». Список остаётся
            // без изменений: строки, перетаскивание и группы на месте.
            if (carouselVisible)
              SliverToBoxAdapter(
                child: _UpNextCarousel(
                  tracks: featured,
                  onTap: (int index) =>
                      controller.jumpTo(currentIndex + 1 + index),
                ),
              ),

            if (upNext.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(AppLayout.gutter),
                  child: Text('Дальше треков нет — включится радио по текущему.'),
                ),
              )
            else ...<Widget>[
              SliverToBoxAdapter(
                child: _GroupLabel('Далее — ${upNext.length}'),
              ),
              SliverReorderableList(
                itemCount: upNext.length,
                // onReorderItem отдаёт уже скорректированный индекс.
                onReorderItem: (int oldIndex, int newIndex) {
                  final int base = currentIndex + 1;
                  controller.reorderQueue(oldIndex + base, newIndex + base);
                },
                itemBuilder: (BuildContext context, int index) {
                  final Track track = upNext[index];
                  return _ReorderableTile(
                    key: ValueKey<String>('${track.id}-$index'),
                    index: index,
                    track: track,
                    onTap: () => controller.jumpTo(currentIndex + 1 + index),
                    onRemove: () =>
                        controller.removeFromQueue(currentIndex + 1 + index),
                  );
                },
              ),
            ],

            if (playedCount > 0) ...<Widget>[
              SliverToBoxAdapter(
                child: _GroupLabel('Уже проиграно — $playedCount'),
              ),
              SliverList.builder(
                itemCount: playedCount,
                itemBuilder: (BuildContext context, int index) {
                  return TrackTile(
                    track: played[index],
                    isDimmed: true,
                    onTap: () => controller.jumpTo(index),
                    enableSwipe: false,
                  );
                },
              ),
            ],

            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }
}

/// Шапка очереди с текущим треком.
///
/// Перенесена из `CurrentSongHeader` (ArchiveTune, `ui/player/QueueComponents.kt`):
/// обложка 64 с радиусом 12, название `titleLarge` жирным, исполнитель
/// `bodyMedium` с альфой 0.6, лайк 44 с иконкой 26; ниже — панель действий
/// (`RoundedCornerShape(24)`, фон с альфой 0.06, отступы 6/4) со счётчиком
/// треков и общей длительностью, и ряд переключателей 48 высотой.
class _QueueHeader extends ConsumerWidget {
  const _QueueHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? current = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.current),
    );
    if (current == null) return const SizedBox.shrink();

    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);

    final bool liked = ref.watch(
      likedIdsProvider.select((Set<String> ids) => ids.contains(current.id)),
    );
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );
    final (List<Track> queue, bool shuffle, PlayerRepeatMode repeat) =
        ref.watch(
      playerControllerProvider.select(
        (PlayerUiState s) => (s.queue, s.shuffle, s.repeat),
      ),
    );

    final Duration total = queue.fold(
      Duration.zero,
      (Duration acc, Track track) => acc + track.duration,
    );
    final List<String> variants = current.artworkFallbacks(kArtworkLarge);

    // Соединённые углы переключателей — как `connectedLeading/TrailingButtonShapes`
    // в ArchiveTune: крупное скругление с внешней стороны, малое с внутренней.
    const Radius big = Radius.circular(24);
    const Radius small = Radius.circular(6);
    const BorderRadius leadingShape = BorderRadius.only(
      topLeft: big,
      bottomLeft: big,
      topRight: small,
      bottomRight: small,
    );
    const BorderRadius trailingShape = BorderRadius.only(
      topLeft: small,
      bottomLeft: small,
      topRight: big,
      bottomRight: big,
    );

    return Padding(
      // Отступы шапки: по бокам 16, сверху 20, снизу 8.
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 64,
                  height: 64,
                  color: scheme.onSurface.withValues(alpha: 0.06),
                  child: Artwork(
                    url: variants.isEmpty ? null : variants.first,
                    fallbacks: variants.length > 1
                        ? variants.sublist(1)
                        : const <String>[],
                    radius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      current.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: scheme.onSurface,
                      ),
                    ),
                    ArtistLine(
                      artists: current.artists,
                      style: text.bodyMedium?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: liked ? 'Убрать из «Мне нравится»' : 'Нравится',
                iconSize: 26,
                constraints: const BoxConstraints.tightFor(width: 44, height: 44),
                padding: EdgeInsets.zero,
                icon: Icon(
                  liked ? Icons.favorite : Icons.favorite_border,
                  color: liked ? scheme.primary : scheme.onSurface,
                ),
                onPressed: signedIn
                    ? () => _toggleLike(context, ref, current)
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: scheme.onSurface.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              children: <Widget>[
                IconButton(
                  tooltip: 'Действия',
                  iconSize: 20,
                  constraints:
                      const BoxConstraints.tightFor(width: 40, height: 40),
                  padding: EdgeInsets.zero,
                  color: scheme.onSurface.withValues(alpha: 0.7),
                  icon: const Icon(Icons.more_vert),
                  onPressed: () => showTrackMenu(context, current),
                ),
                IconButton(
                  tooltip: 'Очистить',
                  iconSize: 20,
                  constraints:
                      const BoxConstraints.tightFor(width: 40, height: 40),
                  padding: EdgeInsets.zero,
                  color: scheme.error,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: controller.clearQueue,
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: Text(
                    '${trackCountLabel(queue.length)}  •  '
                    '${formatDurationClock(total)}',
                    style: text.labelMedium?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: _HeaderToggle(
                  tooltip: shuffle ? 'Перемешивание включено' : 'Перемешать',
                  icon: Icons.shuffle,
                  selected: shuffle,
                  shape: leadingShape,
                  onTap: controller.toggleShuffle,
                ),
              ),
              Expanded(
                child: _HeaderToggle(
                  tooltip: repeat.label,
                  icon: repeat == PlayerRepeatMode.one
                      ? Icons.repeat_one
                      : Icons.repeat,
                  selected: repeat != PlayerRepeatMode.off,
                  shape: trailingShape,
                  onTap: controller.cycleRepeat,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Divider(
            height: 1,
            thickness: 1,
            color: scheme.onSurface.withValues(alpha: 0.08),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleLike(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) async {
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

/// Переключатель шапки очереди — `ToggleButton` высотой 48 из ArchiveTune.
///
/// Заливка: 0.12 в покое и 0.22 во включённом виде, иконка 22 — точные
/// значения `CurrentSongHeader`.
class _HeaderToggle extends StatelessWidget {
  const _HeaderToggle({
    required this.tooltip,
    required this.icon,
    required this.selected,
    required this.shape,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final bool selected;
  final BorderRadius shape;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: scheme.onSurface.withValues(alpha: selected ? 0.22 : 0.12),
        borderRadius: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: shape,
          onTap: onTap,
          child: SizedBox(
            height: 48,
            child: Center(
              child: Icon(icon, size: 22, color: scheme.onSurface),
            ),
          ),
        ),
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppLayout.gutter,
        16,
        AppLayout.gutter,
        4,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

/// Элемент очереди с ручкой для перетаскивания.
class _ReorderableTile extends StatelessWidget {
  const _ReorderableTile({
    super.key,
    required this.index,
    required this.track,
    required this.onTap,
    required this.onRemove,
  });

  final int index;
  final Track track;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: TrackTile(
            track: track,
            onTap: onTap,
            // У строки очереди свой хвост (убрать + ручка перетаскивания),
            // поэтому штатная кнопка «…» не рисуется — добавляем её сами,
            // иначе из очереди не открыть меню трека.
            // Свайп выключен: здесь он конфликтовал бы с перетаскиванием.
            enableSwipe: false,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  tooltip: 'Действия',
                  iconSize: 22,
                  icon: const Icon(Icons.more_vert),
                  onPressed: () => showTrackMenu(context, track),
                ),
                IconButton(
                  tooltip: 'Убрать',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onRemove,
                ),
              ],
            ),
          ),
        ),
        ReorderableDragStartListener(
          index: index,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Icon(Icons.drag_indicator, size: 20),
          ),
        ),
      ],
    );
  }
}

/// Горизонтальная карусель ближайших треков очереди.
///
/// Крупные карточки с обложкой, названием и исполнителем; нажатие переводит
/// воспроизведение на этот трек. Прокрутка — через общий [HorizontalList]:
/// он умеет то, чего нет у голого `ListView` на десктопе (колесо мыши,
/// перетаскивание мышью, полоса прокрутки).
///
/// В `material_3_expressive` есть и готовый `M3ECarousel`, но он не подходит:
/// у него своя физика прокрутки и собственный слой жестов, поэтому ленту
/// нельзя отдать общему `HorizontalList` (а именно он требуется для колеса
/// мыши); вдобавок он рассчитан на широкий контейнер и требует ограниченной
/// высоты. Экспрессивную форму берём у пакета точечно — для обложки карточки.
///
/// Ширина карточки подстраивается под доступное место: в узкой правой панели
/// (минимум 260) она компактнее, на широкой колонке полного экрана — крупнее.
/// Поэтому лента не переполняется и остаётся читаемой на всех поверхностях.
class _UpNextCarousel extends StatelessWidget {
  const _UpNextCarousel({required this.tracks, required this.onTap});

  final List<Track> tracks;

  /// Нажатие на карточку: индекс в [tracks].
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Подписи масштабируются вместе с системным шрифтом: высоту ленты
        // считаем от масштаба, иначе при крупном тексте карточки обрезались
        // бы (лента задаёт детям фиксированную высоту).
        final double scale = MediaQuery.textScalerOf(context).scale(1.0);
        final double available =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 360;
        // 124 в узкой панели — заметно крупнее строки списка (56); 168 —
        // предел, чтобы на широком экране карточка не «распухала».
        final double cardWidth = (available * 0.46).clamp(124.0, 168.0);
        // Квадратная обложка + две подписи по одной строке + запас.
        final double height = cardWidth + 58 * scale + 16;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: HorizontalList(
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: AppLayout.gutter),
            separator: 12,
            itemCount: tracks.length,
            itemBuilder: (BuildContext context, int index) {
              return _UpNextCarouselCard(
                track: tracks[index],
                width: cardWidth,
                onTap: () => onTap(index),
              );
            },
          ),
        );
      },
    );
  }
}

/// Карточка ближайшего трека в карусели.
///
/// Обложка — квадрат во всю ширину карточки, обрезанный экспрессивной формой
/// из `material_3_expressive` (`M3EShapeContainer.square` — «круглый квадрат»
/// из каталога форм M3). Название и исполнитель — по одной строке с
/// многоточием: размер карточки фиксирован, поэтому лента не «дёргается» от
/// разной длины подписей.
class _UpNextCarouselCard extends StatelessWidget {
  const _UpNextCarouselCard({
    required this.track,
    required this.width,
    required this.onTap,
  });

  final Track track;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    // Размер карточки — не 1024: обложка крупная по площади, но не по числу
    // пикселей, иначе лента из десятков карточек тормозила бы отрисовку.
    final List<String> variants = track.artworkFallbacks(kArtworkCard);

    return SizedBox(
      width: width,
      // `Material` нужен `InkWell`-у: на островке поверхность — это
      // `DecoratedBox`, а не `Material`, и без своей подложки нажатие упало
      // бы с «No Material widget found».
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppLayout.radiusM),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppLayout.radiusM),
          // Долгое нажатие — то же меню трека, что у строки списка.
          onLongPress: () => showTrackMenu(context, track),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              m3e.M3EShapeContainer.square(
                width: width,
                height: width,
                color: scheme.surfaceContainerHighest,
                child: Artwork(
                  url: variants.isEmpty ? null : variants.first,
                  fallbacks: variants.length > 1
                      ? variants.sublist(1)
                      : const <String>[],
                  size: width,
                  // Форму задаёт внешний ClipPath, поэтому своё скругление у
                  // картинки выключено — иначе по углам проступал бы фон.
                  radius: BorderRadius.zero,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              Text(
                track.artistLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
