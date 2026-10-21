import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/layout.dart';
import '../core/theme/motion.dart';
import '../core/utils/format.dart';
import '../data/models/models.dart';
import '../features/common/navigation.dart';
import '../state/catalog_providers.dart';
import '../state/player_controller.dart';
import 'artwork.dart';
import 'track_menu.dart';

/// Строка трека в списке.
///
/// Форма взята у ArchiveTune: крупная обложка, название и исполнитель двумя
/// строками, справа длительность и меню. Никаких «прыгающих» размеров —
/// высота строки зафиксирована, поэтому список не дёргается при прокрутке
/// и при изменении системного масштаба.
class TrackTile extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    // Отметка ставится только после того, как YouTube действительно отказал
    // в потоке из-за недоступности (см. PlayerController): до первой попытки
    // трек считается обычным.
    final bool unavailable = ref.watch(
      playerControllerProvider.select(
        (PlayerUiState s) => s.unavailableIds.contains(track.id),
      ),
    );

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
      // Внешний отступ строки — 8, как `padding(horizontal = 8.dp)` у `ListItem`
      // в Items.kt. Обложка лежит в `Box(padding(8))`, текст — в колонке с
      // `padding(horizontal = 6)`: вместе это даёт прежний зазор 14 между
      // обложкой и подписью.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Material(
          // Активная строка подсвечивается `secondaryContainer`, радиус 12 —
          // как `RoundedCornerShape(12.dp)` у `ListItem`.
          color: isCurrent ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(AppLayout.radiusS),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: openMenu,
            // Правый клик — то же меню, что «…» и долгое нажатие: на десктопе
            // это привычный способ до него добраться, а не искать кнопку.
            onSecondaryTap: openMenu,
            child: Row(
              children: <Widget>[
                // Внутренний отступ обложки 8 — это `Box(padding(8.dp))`,
                // в который `ListItem` заворачивает `thumbnailContent`.
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: SizedBox(
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
                ),
                Expanded(
                  // Отступ подписи по горизонтали 6 — как у `Column` в `ListItem`.
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
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
                        // Бейджи и подпись — в одной строке: в `ListItem`
                        // бейджи идут перед текстом подписи с зазором 4.
                        Row(
                          children: <Widget>[
                            _LyricsMark(videoId: track.id),
                            Flexible(
                              child: _TrackSubtitle(
                                track: track,
                                subtitleOverride: subtitleOverride,
                                showDuration: showDuration,
                                unavailable: unavailable,
                                style: text.bodySmall?.copyWith(
                                  color: subtitleColor.withValues(
                                    alpha: isDimmed
                                        ? subtitleColor.a * 0.6
                                        : subtitleColor.a,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (trailing != null)
                  trailing!
                else
                  IconButton(
                    tooltip: 'Действия',
                    iconSize: 20,
                    color: scheme.onSurfaceVariant,
                    icon: const Icon(Icons.more_vert),
                    onPressed: openMenu,
                  ),
              ],
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

}

/// Дописывает длительность к готовой подписи через « • ».
///
/// Пустая/нулевая длительность ничего не добавляет — «0:00» в строке было бы
/// мусором, когда YouTube её не отдал.
String _withDuration(String base, Duration duration, bool show) {
  if (!show || duration <= Duration.zero) return base;
  return '$base • ${formatDuration(duration)}';
}

/// Подпись строки: имена исполнителей кликабельны и ведут на их страницы,
/// альбом — просто текст. Собирается как `Text.rich`, поэтому длинные
/// подписи по-прежнему обрезаются многоточием, а не переносятся.
class _TrackSubtitle extends StatefulWidget {
  const _TrackSubtitle({
    required this.track,
    required this.style,
    this.subtitleOverride,
    this.showDuration = true,
    this.unavailable = false,
  });

  final Track track;
  final TextStyle? style;
  final String? subtitleOverride;

  /// Помечать ли трек как недоступный: YouTube не отдал для него поток.
  final bool unavailable;

  /// Длительность идёт частью подписи (через « • »), а не отдельным хвостом —
  /// так устроена подпись в `SongListItem`/`MediaMetadataListItem`.
  final bool showDuration;

  @override
  State<_TrackSubtitle> createState() => _TrackSubtitleState();
}

class _TrackSubtitleState extends State<_TrackSubtitle> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final TapGestureRecognizer recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    final String? override = widget.subtitleOverride;
    if (override != null) {
      // Подпись задана снаружи (список альбома/исполнителя) — длительность
      // всё равно дописываем через « • », как это делает `joinByBullet`.
      final String text =
          _withDuration(override, widget.track.duration, widget.showDuration);
      return Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(text: text),
            if (widget.unavailable)
              TextSpan(
                text: ' • Недоступен',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: widget.style,
      );
    }

    // Набор исполнителей мог смениться — распознаватели пересобираем.
    _disposeRecognizers();

    final List<ArtistRef> artists = widget.track.artists;
    final List<InlineSpan> spans = <InlineSpan>[];
    if (artists.isEmpty) {
      spans.add(const TextSpan(text: 'Неизвестный исполнитель'));
    } else {
      for (int i = 0; i < artists.length; i++) {
        if (i > 0) spans.add(const TextSpan(text: ', '));
        final ArtistRef artist = artists[i];
        final String name = cleanArtistName(artist.name);
        if (artist.isNavigable) {
          final TapGestureRecognizer recognizer = TapGestureRecognizer()
            ..onTap = () => AppRoutes.artist(context, artist.id!);
          _recognizers.add(recognizer);
          spans.add(TextSpan(text: name, recognizer: recognizer));
        } else {
          spans.add(TextSpan(text: name));
        }
      }
    }

    // Длительность — сразу после исполнителей, затем название альбома. Порядок
    // повторяет `joinByBullet(artists, duration, …)` из `SongListItem`.
    if (widget.showDuration && widget.track.duration > Duration.zero) {
      spans.add(TextSpan(text: ' • ${formatDuration(widget.track.duration)}'));
    }

    final String? album = widget.track.album?.name;
    if (album != null && album.isNotEmpty && album != widget.track.title) {
      spans.add(TextSpan(text: ' • $album'));
    }

    if (widget.unavailable) {
      spans.add(
        TextSpan(
          text: ' • Недоступен',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
    }

    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: widget.style,
    );
  }
}

/// Значок «у этого трека есть текст» — появляется, если текст уже находили.
class _LyricsMark extends ConsumerWidget {
  const _LyricsMark({required this.videoId});

  final String videoId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool has = ref.watch(
      lyricsAvailabilityProvider.select(
        (Set<String> ids) => ids.contains(videoId),
      ),
    );
    if (!has) return const SizedBox.shrink();
    // Бейдж-«значок текста». Размер и отступ как у остальных бейджей
    // `ListItem` (18 с отступом 2 справа), чтобы строка не «плясала».
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: Icon(
        Icons.lyrics_outlined,
        size: 18,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
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
            // Затемнение и белый значок поверх него — как `PlayingIndicatorBox`
            // в `ItemThumbnail` (Items.kt): `Color.Black` с альфой 0.6
            // (`ActiveBoxAlpha`) и `Color.White` независимо от темы.
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(
                  AppLayout.thumbnailRadius,
                ),
              ),
              child: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white,
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

  /// Предел хода строки. `SwipeToSongBox` держит смещение в `±threshold`,
  /// поэтому и здесь не даём уехать дальше — иначе строка «висела» бы
  /// подсвеченной после возврата.
  static const double _maxReveal = _threshold;

  /// Быстрый «щелчок» срабатывает раньше, чем набрано расстояние.
  static const double _flickVelocity = 700;

  /// Высота полосы под свайпом. ArchiveTune: 60.
  static const double _bandHeight = 60;

  /// Смещение строки под пальцем; знак задаёт сторону действия.
  double _offset = 0;

  /// Идёт перетаскивание — тогда возврат к нулю должен быть мгновенным.
  bool _dragging = false;

  /// Разрешён ли свайп для текущего жеста: мышь строку не листает.
  bool _pointerAllowed = true;

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
      onHorizontalDragStart: (DragStartDetails details) {
        // Мышь строку не листает: горизонтальное движение мышью (выделение,
        // случайный сдвиг) отправляло трек в очередь. Свайп — жест пальца
        // и стилуса, на десктопе он остаётся для тач-экранов и трекпада.
        _pointerAllowed = details.kind == PointerDeviceKind.touch ||
            details.kind == PointerDeviceKind.stylus ||
            details.kind == PointerDeviceKind.invertedStylus ||
            details.kind == null;
        setState(() => _dragging = _pointerAllowed);
      },
      onHorizontalDragUpdate: (DragUpdateDetails details) {
        if (!_pointerAllowed) return;
        _onDragUpdate(details);
      },
      onHorizontalDragEnd: (DragEndDetails details) {
        if (!_pointerAllowed) {
          _reset();
          return;
        }
        _onDragEnd(details);
      },
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
            // после отпускания плавно возвращается на место — тем же
            // переходом, что и экран из-под жеста «назад».
            duration: _dragging ? Duration.zero : AppMotion.snapBack.duration,
            curve: AppMotion.snapBack.curve,
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
    // Цвета сторон — из `SwipeToSongBox` (Items.kt): вправо («играть
    // следующим») полоса `secondary`, влево («в очередь») — `primary`.
    // Подписи в оригинале нет, только значок с альфой 0.9.
    final Color background = toEnd ? scheme.secondary : scheme.primary;
    final Color foreground = toEnd ? scheme.onSecondary : scheme.onPrimary;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppLayout.radiusS),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Align(
          alignment: toEnd ? Alignment.centerLeft : Alignment.centerRight,
          child: Icon(
            toEnd ? Icons.queue_play_next : Icons.playlist_add,
            size: 30,
            color: foreground.withValues(alpha: 0.9),
          ),
        ),
      ),
    );
  }
}


