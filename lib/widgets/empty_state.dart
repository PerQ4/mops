import 'package:flutter/material.dart';

import '../core/theme/layout.dart';

/// Общая обёртка заглушек: центрирует содержимое, когда места хватает, и
/// даёт прокрутить, когда его мало.
///
/// Раньше это была колонка фиксированной высоты, и в узком контейнере —
/// например, в панели плеера или в коротком окне — она переполнялась снизу.
class _CenteredPane extends StatelessWidget {
  const _CenteredPane({required this.maxWidth, required this.child});

  final double maxWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            // Растягиваем на всю высоту, чтобы `Center` центрировал по
            // вертикали, а не прижимал содержимое к верху.
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Заглушка «здесь пока пусто».
///
/// Единственная реализация на всё приложение: раньше таких виджетов было два,
/// и они расходились по оформлению.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.subtitle,
    this.icon = Icons.inbox_outlined,
    this.action,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    return _CenteredPane(
      maxWidth: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 48, color: scheme.primary),
          const SizedBox(height: 16),
          // Заголовок заглушки — как сообщение у `HomeStatePane`
          // (ArchiveTune): `titleLarge`, цвет `onSurface`, по центру.
          Text(
            title,
            style: text.titleLarge,
            textAlign: TextAlign.center,
          ),
          if (subtitle != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          if (action != null) ...<Widget>[
            const SizedBox(height: AppLayout.gutter),
            action!,
          ],
        ],
      ),
    );
  }
}

/// Заглушка «ошибка с кнопкой повторить» — тоже в единственном экземпляре.
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.message,
    this.onRetry,
    this.compact = false,
  });

  final String message;
  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    return _CenteredPane(
      maxWidth: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.cloud_off_outlined,
            size: compact ? 40 : 48,
            color: scheme.error,
          ),
          const SizedBox(height: 16),
          Text(
            'Не удалось загрузить',
            style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: 20),
            // Кнопка повтора — `FilledTonalButton` из `HomeStatePane`.
            FilledButton.tonal(
              onPressed: onRetry,
              child: const Text('Повторить'),
            ),
          ],
        ],
      ),
    );
  }
}
