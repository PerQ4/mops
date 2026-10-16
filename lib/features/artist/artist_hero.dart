import 'package:flutter/material.dart';

import '../../data/models/models.dart';
import '../../widgets/artwork.dart';
import '../album/media_hero.dart';

/// Шапка страницы исполнителя — перенос из `ArtistScreen.kt` (строки 390-588).
///
/// В ArchiveTune страница исполнителя НЕ использует общий `MediaDetailHero`:
/// шапка собрана прямо в экране и отличается от общей двумя деталями:
///
///  * под именем идут ДВЕ строки метаданных — «аудитория» (подписчики) и
///    «каталог» (треки/альбомы), обе `labelMedium`, альфа 0.62
///    (`ArtistScreen.kt:465-502`);
///  * описание вынесено ОТДЕЛЬНЫМ блоком под шапкой
///    (`ArtistScreen.kt:590-617`), а не лежит внутри неё.
///
/// Обложка растянута на всю шапку, поверх неё — градиент из пяти остановок,
/// содержимое прижато к низу по центру. Все числа совпадают с оригиналом:
/// minHeight 560, боковой отступ 24, предельная ширина текста 720.
class ArtistHero extends StatelessWidget {
  const ArtistHero({
    super.key,
    required this.name,
    required this.actions,
    this.imageUrl,
    this.audience,
    this.catalog,
  });

  final String name;

  /// Действия шапки: перемешать, слушать, в очередь.
  final List<Widget> actions;

  final String? imageUrl;

  /// Строка «аудитории»: подписчики (`ArtistStatsUi.audience`).
  final String? audience;

  /// Строка каталога: «N треков  •  M альбомов» (`ArtistStatsUi.catalog`).
  final String? catalog;

  /// `ArtistHeroMinHeight` из `ArtistScreen.kt:1155`.
  static const double minHeight = 560;

  /// `ArtistHorizontalPadding` из `ArtistScreen.kt:1156`.
  static const double horizontalPadding = 24;

  /// `ArtistContentMaxWidth` из `ArtistScreen.kt:1157`.
  static const double contentMaxWidth = 720;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Цвет содержимого шапки — по яркости поверхности: на тёмной теме белый,
    // на светлой `onSurface` (`ArtistScreen.kt:226-232`).
    final Color heroContent = heroContentColor(scheme);

    return SizedBox(
      height: minHeight,
      width: double.infinity,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: imageUrl == null || imageUrl!.isEmpty
                // Заглушка, когда обложки нет: `surfaceContainerHigh` и иконка
                // человека 96 цветом `onSurfaceVariant` (`ArtistScreen.kt:410-424`).
                ? ColoredBox(
                    color: scheme.surfaceContainerHigh,
                    child: Center(
                      child: Icon(
                        Icons.person,
                        size: 96,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : Artwork(
                    url: imageUrl,
                    size: 200,
                    radius: BorderRadius.zero,
                    fit: BoxFit.cover,
                  ),
          ),
          // Градиент из пяти остановок (`ArtistScreen.kt:431-439`): тёмный верх,
          // прозрачная середина, переход в цвет поверхности снизу.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Colors.black.withValues(alpha: 0.42),
                    Colors.transparent,
                    Colors.transparent,
                    scheme.surface.withValues(alpha: 0.78),
                    scheme.surface,
                  ],
                  stops: const <double>[0, 0.18, 0.42, 0.72, 1],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                horizontalPadding,
                0,
                horizontalPadding,
                24,
              ),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: contentMaxWidth),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      Text(
                        name,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.headlineLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: heroContent,
                        ),
                      ),
                      // Аудитория — только при наличии (`ArtistScreen.kt:465-479`):
                      // `labelMedium` вес medium, альфа 0.62, отступ сверху 16.
                      if (audience != null && audience!.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: Text(
                            audience!,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                              color: heroContent.withValues(alpha: 0.62),
                            ),
                          ),
                        ),
                      ],
                      // Каталог — отступ сверху 4, если аудитория уже показана,
                      // иначе 16 (`ArtistScreen.kt:481-502`).
                      if (catalog != null && catalog!.isNotEmpty) ...<Widget>[
                        SizedBox(
                          height: (audience != null && audience!.isNotEmpty)
                              ? 4
                              : 16,
                        ),
                        SizedBox(
                          width: double.infinity,
                          child: Text(
                            catalog!,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                              color: heroContent.withValues(alpha: 0.62),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      // Размеры и цвета кнопок уже выверены в HeroCircleButton
                      // и HeroPlayButton (`MediaDetailHero.kt`), поэтому берём
                      // их, а не собираем заново.
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: actions,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Описание исполнителя отдельным блоком под шапкой (`ArtistScreen.kt:590-617`).
///
/// Стиль — `bodyMedium` цветом `onSurfaceVariant` (не цветом шапки), по центру,
/// три строки в свёрнутом виде; нажатие разворачивает и сворачивает текст
/// (`combinedClickable`). Предельная ширина — 720, отступы 24/12.
class ArtistDescription extends StatefulWidget {
  const ArtistDescription({super.key, required this.text});

  final String text;

  @override
  State<ArtistDescription> createState() => _ArtistDescriptionState();
}

class _ArtistDescriptionState extends State<ArtistDescription> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ArtistHero.horizontalPadding,
        vertical: 12,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: ArtistHero.contentMaxWidth),
          child: GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Text(
              widget.text,
              textAlign: TextAlign.center,
              // Свёрнуто — три строки, развёрнуто — без ограничения.
              maxLines: _expanded ? null : 3,
              overflow: TextOverflow.ellipsis,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      ),
    );
  }
}

/// Скелетон страницы исполнителя до загрузки (`ArtistScreen.kt:319-357`).
///
/// Форма `ShimmerHost`: блок высотой 560 с прижатым к низу содержимым
/// (заголовок 36, аудитория 16, каталог 14, кнопка 56 на всю ширину) и пять
/// строк-заглушек. Анимация не нужна — в приложении шиммер статичный.
class ArtistDetailSkeleton extends StatelessWidget {
  const ArtistDetailSkeleton({super.key, this.rows = 5});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color fill = scheme.surfaceContainerHighest;

    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      children: <Widget>[
        SizedBox(
          height: ArtistHero.minHeight,
          width: double.infinity,
          child: Container(
            color: scheme.surfaceContainerLow,
            padding: const EdgeInsets.all(ArtistHero.horizontalPadding),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                _bar(fill, widthFactor: 0.55, height: 36),
                const SizedBox(height: 12),
                _bar(fill, widthFactor: 0.72, height: 16),
                const SizedBox(height: 20),
                _bar(fill, widthFactor: 0.82, height: 14),
                const SizedBox(height: 12),
                // Кнопка-заглушка: высота `MediumContainerHeight` (56),
                // капсула (`ArtistScreen.kt:344-349`).
                Container(
                  width: double.infinity,
                  height: 56,
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(28),
                  ),
                ),
              ],
            ),
          ),
        ),
        for (int i = 0; i < rows; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: <Widget>[
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _bar(fill, widthFactor: 0.6, height: 14),
                      const SizedBox(height: 8),
                      _bar(fill, widthFactor: 0.35, height: 12),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static Widget _bar(
    Color color, {
    required double widthFactor,
    required double height,
  }) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}

/// Строка каталога шапки: «N треков  •  M альбомов» (`ArtistStatsUi.catalog`).
///
/// В ArchiveTune считаются все песни и альбомы из секций; в наших данных песни
/// уже сведены в [Artist.topTracks], а альбомы и синглы — в два списка. Числа
/// объединяются разделителем `mediaDetailMetadataSeparator` (два пробела,
/// точка, два пробела), как в остальных шапках приложения.
String artistCatalogLine(Artist artist) {
  final List<String> parts = <String>[];
  if (artist.topTracks.isNotEmpty) {
    parts.add(_countLabel(artist.topTracks.length, 'трек', 'трека', 'треков'));
  }
  final int albumCount = artist.albums.length + artist.singles.length;
  if (albumCount > 0) {
    parts.add(_countLabel(albumCount, 'альбом', 'альбома', 'альбомов'));
  }
  return parts.join(mediaDetailMetadataSeparator);
}

/// Согласование числительного с существительным — как `_plural` в `format.dart`.
String _countLabel(int count, String one, String few, String many) {
  final int n = count.abs() % 100;
  final int n1 = n % 10;
  final String word;
  if (n >= 11 && n <= 14) {
    word = many;
  } else if (n1 == 1) {
    word = one;
  } else if (n1 >= 2 && n1 <= 4) {
    word = few;
  } else {
    word = many;
  }
  return '$count $word';
}
