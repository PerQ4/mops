import 'package:flutter/material.dart';

/// Сообщение состояния поиска: «ничего не найдено» или ошибка.
///
/// Форма из `SearchStateMessage` (`SearchScreen.kt:740-771`): по центру,
/// отступ 32, колонка с шагом 16, значок `search_off` цветом `outline`,
/// текст `bodyLarge` цветом `onSurfaceVariant` и (при ошибке) кнопка
/// действия. Общий `EmptyState` из `lib/widgets` выглядит иначе — крупный
/// заголовок и значок `primary`, поэтому здесь отдельная форма.
class SearchStateMessage extends StatelessWidget {
  const SearchStateMessage({super.key, required this.message, this.action});

  final String message;

  /// Кнопка действия под сообщением — например, «Повторить» при ошибке.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.search_off, color: scheme.outline),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (action != null) ...<Widget>[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Скелетон выдачи поиска.
///
/// Размеры — из `SearchDiscoveryLoading` (`SearchScreen.kt:709-738`): строки
/// высотой 84 с отступами 16 по горизонтали и 6 по вертикали. Анимация
/// «шиммера» не переносится: в приложении скелетоны статичные
/// (`lib/features/album/media_hero.dart:270-274`), меняются только форма и
/// размеры.
class SearchResultsSkeleton extends StatelessWidget {
  const SearchResultsSkeleton({super.key, this.rows = 6});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: rows,
      itemBuilder: (BuildContext context, int index) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Container(
          height: 84,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}
