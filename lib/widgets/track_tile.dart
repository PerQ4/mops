import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/layout.dart';
import '../core/utils/format.dart';
import '../data/models/models.dart';
import '../state/player_controller.dart';
import 'artwork.dart';
import 'track_menu.dart';

/// Строка трека в списке.
///
/// Форма взята у ArchiveTune: крупная обложка, название и исполнитель двумя
/// строками, справа длительность и меню. Никаких «прыгающих» размеров —
/// высота строки зафиксирована, поэтому список не дёргается при прокрутке
/// и при изменении системного масштаба.
class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    this.onTap,
    this.onMenu,
    this.trailing,
    this.isCurrent = false,
    this.isPlaying = false,
    this.isDimmed = false,
    this.subtitleOverride,
    this.showDuration = true,
    this.leadingNumber,
    this.enableSwipe = true,
  });

  final Track track;
  final VoidCallback? onTap;

  /// Действие кнопки «три точки». Если не задано — показывается меню
  /// с типовыми действиями.
  final VoidCallback? onMenu;
  final Widget? trailing;

  final bool isCurrent;
  final bool isPlaying;

  /// Приглушённый вид — для уже проигранных треков.
  final bool isDimmed;
  final String? subtitleOverride;
  final bool showDuration;

  /// Показывать номер вместо обложки (страницы альбомов и плейлистов).
  final int? leadingNumber;

  /// Включён ли свайп по строке: вправо — «играть следующим», влево —
  /// «в очередь». В очереди выключаем: там эти действия дублируют саму
  /// очередь, а горизонтальный жест мешал бы перетаскиванию.
  final bool enableSwipe;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    // Активная строка идёт на `secondaryContainer`, поэтому цвет текста —
    // `onSecondaryContainer`, а не `primary`: иначе подпись сливается с фоном.
    final Color titleColor =
        isCurrent ? scheme.onSecondaryContainer : scheme.onSurface;
    final Color subtitleColor = isCurrent
        ? scheme.onSecondaryContainer.withValues(alpha: 0.7)
        : scheme.onSurfaceVariant;
    final double artworkSize = AppLayout.trackArtwork;

    // Одна точка входа в меню: и кнопка «…», и долгое нажатие открывают одно
    // и то же, поэтому действие не приходится искать по интерфейсу.
    final VoidCallback openMenu =
        onMenu ?? () => showTrackMenu(context, track);

    final Widget tile = SizedBox(
      height: AppLayout.trackRowHeight,
      // Внешний отступ строки — 8 по спецификации; внутренний добираем до
      // прежних 20, чтобы обложка не съезжала относительно заголовков секций.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Material(
          // Активная строка подсвечивается `secondaryContainer`, радиус 12.
          color: isCurrent ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(AppLayout.radiusS),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: openMenu,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: artworkSize,
                    height: artworkSize,
                    child: leadingNumber != null
                        ? Center(
                            child: Text(
                              '$leadingNumber',
                              style: text.titleSmall?.copyWith(
                                color: isCurrent
                                    ? scheme.onSecondaryContainer
                                    : scheme.onSurfaceVariant,
                                fontFeatures: const <FontFeature>[
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          )
                        : _Leading(
                            track: track,
                            size: artworkSize,
                            isCurrent: isCurrent,
                            isPlaying: isPlaying,
                            isDimmed: isDimmed,
                          ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyLarge?.copyWith(
                            color: isDimmed
                                ? titleColor.withValues(alpha: 0.6)
                                : titleColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitleOverride ?? _subtitle(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(
                            color: subtitleColor.withValues(
                              alpha: isDimmed
                                  ? subtitleColor.a * 0.6
                                  : subtitleColor.a,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (trailing != null)
                    trailing!
                  else ...<Widget>[
                    if (showDuration && track.duration > Duration.zero)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          formatDuration(track.duration),
                          style: text.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                    IconButton(
                      tooltip: 'Действия',
                      iconSize: 20,
                      color: scheme.onSurfaceVariant,
                      icon: const Icon(Icons.more_vert),
                      onPressed: openMenu,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // В очереди свайп не нужен, поэтому он отключается флагом; сам виджет
    // ещё и не даёт свайпать играющий трек — у него действия бессмысленны.
    if (!enableSwipe) return tile;
    return SwipeToSongBox(track: track, child: tile);
  }

  String _subtitle() {
    final List<String> parts = <String>[];
    if (track.artists.isNotEmpty) {
      parts.add(cleanArtistName(track.artistLine));
    }
    final String? album = track.album?.name;
    if (album != null && album.isNotEmpty && album != track.title) {
      parts.add(album);
    }
    return parts.isEmpty ? 'Неизвестный исполнитель' : parts.join(' • ');
  }
}

/// Обложка с индикатором воспроизведения поверх неё.
class _Leading extends StatelessWidget {
  const _Leading({
    required this.track,
    required this.size,
    required this.isCurrent,
    required this.isPlaying,
    required this.isDimmed,
  });

  final Track track;
  final double size;
  final bool isCurrent;
  final bool isPlaying;
  final bool isDimmed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Обложку просим под плотность экрана: ссылка переписывается на нужный
    // размер, поэтому картинка не растягивается из мелкого превью.
    final int physical =
        (size * MediaQuery.devicePixelRatioOf(context)).round();
    final List<String> variants = track.artworkFallbacks(physical);

    return Opacity(
      opacity: isDimmed ? 0.5 : 1,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Artwork(
            url: variants.isEmpty ? null : variants.first,
            fallbacks:
                variants.length > 1 ? variants.sublist(1) : const <String>[],
            size: size,
            radius: BorderRadius.circular(AppLayout.thumbnailRadius),
          ),
          if (isCurrent)
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: scheme.scrim.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(
                  AppLayout.thumbnailRadius,
                ),
              ),
              child: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: scheme.onPrimary,
                size: 26,
              ),
            ),
        ],
      ),
    );
  }
}

/// Свайп по строке трека — форма взята у `SwipeToSongBox` из ArchiveTune.
///
/// Вправо — «играть следующим», влево — «в очередь». Под строкой выезжает
/// цветная полоса высотой 60 с иконкой и подписью; строка следует за пальцем
/// на расстояние до 340. Жест только горизонтальный: арена жестов отдаёт
/// победу тому направлению, по которому пошло движение, поэтому вертикальная
/// прокрутка списка не ломается, а долгое нажатие на строке по-прежнему
/// открывает меню.
class SwipeToSongBox extends ConsumerStatefulWidget {
  const SwipeToSongBox({super.key, required this.track, required this.child});

  final Track track;
  final Widget child;

  @override
  ConsumerState<SwipeToSongBox> createState() => _SwipeToSongBoxState();
}

class _SwipeToSongBoxState extends ConsumerState<SwipeToSongBox> {
  /// Порог срабатывания по расстоянию. ArchiveTune: 300.
  static const double _threshold = 300;

  /// Предел хода строки. Чуть больше порога — иначе порог был бы недостижим
  /// медленным свайпом.
  static const double _maxReveal = 340;

  /// Быстрый «щелчок» срабатывает раньше, чем набрано расстояние.
  static const double _flickVelocity = 700;

  /// Высота полосы под свайпом. ArchiveTune: 60.
  static const double _bandHeight = 60;

  /// Смещение строки под пальцем; знак задаёт сторону действия.
  double _offset = 0;

  /// Идёт перетаскивание — тогда возврат к нулю должен быть мгновенным.
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    // У играющего трека «играть следующим» и «в очередь» бессмысленны —
    // свайп не включаем, строку отдаём как есть.
    final String? currentId = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.current?.id),
    );
    if (currentId != null && currentId == widget.track.id) {
      return widget.child;
    }

    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Насколько проявлена полоса: 0 — строка на месте, 1 — порог набран.
    final double progress = (_offset.abs() / _threshold).clamp(0.0, 1.0);

    return GestureDetector(
      // Ловим жест по всей строке, включая промежутки между элементами.
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => setState(() => _dragging = true),
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: _reset,
      child: Stack(
        children: <Widget>[
          // Полоса фона — всегда под строкой, видна по мере сдвига.
          Positioned.fill(
            child: Opacity(
              opacity: progress,
              child: Center(
                child: SizedBox(
                  height: _bandHeight,
                  width: double.infinity,
                  child: _SwipeBand(
                    // Знак смещения задаёт сторону: вправо — «следующим».
                    toEnd: _offset > 0,
                    scheme: scheme,
                  ),
                ),
              ),
            ),
          ),
          AnimatedContainer(
            // Во время перетаскивания строка идёт за пальцем без задержки, а
            // после отпускания плавно возвращается на место.
            duration: _dragging
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(_offset, 0, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _offset = (_offset + details.delta.dx).clamp(-_maxReveal, _maxReveal);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    final double velocity = details.primaryVelocity ?? 0;
    // По расстоянию или по скорости — что раньше.
    final bool playNext = _offset >= _threshold || velocity > _flickVelocity;
    final bool enqueue = _offset <= -_threshold || velocity < -_flickVelocity;

    // Строку возвращаем сразу: решение уже принято.
    _reset();

    final PlayerController controller =
        ref.read(playerControllerProvider.notifier);
    if (playNext) {
      controller.playNext(widget.track);
      _toast('Играет следующим');
    } else if (enqueue) {
      controller.enqueue(widget.track);
      _toast('Добавлено в очередь');
    }
  }

  void _reset() {
    if (!mounted) return;
    setState(() {
      _offset = 0;
      _dragging = false;
    });
  }

  /// Короткое подтверждение действия. `maybeOf` — потому что строка может
  /// оказаться вне `Scaffold` (например, в тесте) — тогда просто молчим.
  void _toast(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

/// Полоса под свайпом: иконка и подпись у той стороны, откуда тянут строку.
class _SwipeBand extends StatelessWidget {
  const _SwipeBand({required this.toEnd, required this.scheme});

  /// `true` — вправо («играть следующим»), `false` — влево («в очередь»).
  final bool toEnd;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final Color background =
        toEnd ? scheme.primaryContainer : scheme.secondaryContainer;
    final Color foreground =
        toEnd ? scheme.onPrimaryContainer : scheme.onSecondaryContainer;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppLayout.radiusS),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Align(
          alignment: toEnd ? Alignment.centerLeft : Alignment.centerRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                toEnd ? Icons.queue_play_next : Icons.playlist_add,
                size: 24,
                color: foreground,
              ),
              const SizedBox(width: 10),
              Text(
                toEnd ? 'Играть следующим' : 'В очередь',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


