import 'package:flutter/material.dart';

/// Пустая коллекция — карточка в стиле ArchiveTune.
///
/// Форма из `LibraryEmptyState` (`LibraryEmptyState.kt:37-90`): `Surface`
/// скругления `extraLarge` (в ArchiveTune это 32 — `Theme.kt:183-184`) на
/// `surfaceContainerLow`, содержимое по центру: круглая подложка 64
/// `primaryContainer` со значком 30, заголовок `titleLarge` полужирный и
/// (при необходимости) кнопка действия `primary`/`onPrimary`.
///
/// Почему не общий `EmptyState` из `lib/widgets`: у ArchiveTune пустая
/// библиотека — именно карточка, встроенная в список, а не центрированная
/// страница. Общий виджет лежит в чужой зоне и переиспользуется другими
/// экранами, поэтому здесь отдельная форма.
class LibraryEmptyState extends StatelessWidget {
  const LibraryEmptyState({
    super.key,
    required this.title,
    this.icon = Icons.inbox_outlined,
    this.action,
  });

  final String title;
  final IconData icon;

  /// Кнопка действия внутри карточки. В оригинале она есть всегда
  /// («Создать плейлист» / «Поиск в YouTube Music»); в mOps часть разделов
  /// действий не имеет, поэтому она необязательна.
  final Widget? action;

  /// Радиус карточки: `MaterialTheme.shapes.extraLarge` = 32 (`Theme.kt:183`).
  static const double radius = 32;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(radius),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        // Отступы карточки: 24 по горизонтали, 28 по вертикали
        // (`LibraryEmptyState.kt:53`).
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // Круглая подложка значка: 64, `primaryContainer` на
            // `onPrimaryContainer`, сам значок 30 (`LibraryEmptyState.kt:55-68`).
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 30, color: scheme.onPrimaryContainer),
            ),
            // `Arrangement.spacedBy(12.dp)` между подложкой и заголовком.
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (action != null) ...<Widget>[
              // В оригинале между заголовком и кнопкой стоит `Spacer(4)`
              // плюс те же промежутки по 12 — суммарно 28.
              const SizedBox(height: 28),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
