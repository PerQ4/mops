import 'package:flutter/material.dart';

import '../data/models/models.dart';
import 'media_card.dart';

/// Горизонтальная карусель секции: заголовок + прокручиваемые карточки.
///
/// На широких экранах элементы выравниваются по высоте, чтобы длинные
/// подписи не «дёргали» layout.
class SectionCarousel extends StatelessWidget {
  const SectionCarousel({
    super.key,
    required this.section,
    required this.onItemTap,
    this.onShowAll,
    this.cardWidth = 160,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
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

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: padding,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    section.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (onShowAll != null)
                  OutlinedButton(
                    onPressed: onShowAll,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(88, 40),
                    ),
                    child: const Text('Слушать все'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: _carouselHeight(context, cardWidth),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              // Карточка в оригинале (`GridItem`) имеет внешний отступ 12,
              // поэтому между карточками 24, а край — на 12.
              padding: padding.copyWith(left: 12, right: 12),
              itemCount: section.items.length,
              separatorBuilder: (BuildContext context, int _) =>
                  const SizedBox(width: 24),
              itemBuilder: (BuildContext context, int index) {
                final BrowseItem item = section.items[index];
                return BrowseItemCard(
                  item: item,
                  width: cardWidth,
                  onTap: onItemTap,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Высота = карточка + две строки заголовка + подпись.
  double _carouselHeight(BuildContext context, double cardWidth) {
    final double textScale = MediaQuery.textScalerOf(context).scale(1.0);
    return cardWidth + 62 * textScale + 16;
  }
}
