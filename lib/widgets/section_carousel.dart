import 'package:flutter/material.dart';

import '../core/theme/layout.dart';
import '../data/models/models.dart';
import 'horizontal_list.dart';
import 'media_card.dart';

/// Горизонтальная карусель секции: заголовок + прокручиваемые карточки.
///
/// Размеры — как у `GridItem` из ArchiveTune (`Items.kt:264-310`): обложка
/// `GridThumbnailHeight` = 128, внешний отступ 12, зазор между карточками 24
/// (12 справа у одной + 12 слева у следующей). Заголовок — `titleLarge`
/// semibold (как `HomeSectionHeader`), кнопка `play_all` («Прослушать все») —
/// `OutlinedButton` с `heightIn(min = 40)` и `widthIn(min = 88)`.
class SectionCarousel extends StatelessWidget {
  const SectionCarousel({
    super.key,
    required this.section,
    required this.onItemTap,
    this.onShowAll,
    this.cardWidth = AppLayout.gridThumbnailHeight,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
  });

  final BrowseSection section;
  final void Function(BrowseItem item) onItemTap;
  final VoidCallback? onShowAll;
  final double cardWidth;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    if (section.items.isEmpty) return const SizedBox.shrink();

    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Padding(
      // Промежуток между секциями — 18, как `HomeSectionSpacing`.
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // Заголовок — как `HomeSectionHeader`: отступ 16 по горизонтали,
          // 8 по вертикали, высота не меньше 64.
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        if (section.subtitle != null &&
                            section.subtitle!.isNotEmpty)
                          Text(
                            section.subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelLarge?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        Text(
                          section.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onShowAll != null) ...<Widget>[
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: onShowAll,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(88, 40),
                      ),
                      child: const Text('Прослушать все'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          HorizontalList(
            height: _carouselHeight(context, cardWidth),
            // Карточка в оригинале (`GridItem`) имеет внешний отступ 12,
            // поэтому между карточками 24, а край — на 12.
            padding: padding,
            separator: 24,
            itemCount: section.items.length,
            itemBuilder: (BuildContext context, int index) {
              final BrowseItem item = section.items[index];
              return BrowseItemCard(
                item: item,
                width: cardWidth,
                onTap: onItemTap,
              );
            },
          ),
        ],
      ),
    );
  }

  /// Высота = обложка + заголовок в одну строку + подпись до двух строк.
  double _carouselHeight(BuildContext context, double cardWidth) {
    final double textScale = MediaQuery.textScalerOf(context).scale(1.0);
    return cardWidth + 62 * textScale + 16;
  }
}
