import 'package:flutter/material.dart';

import '../core/theme/layout.dart';

/// Заглушка «здесь пока пусто».
///
/// Единственная реализация на всё приложение: раньше таких виджетов было два
/// (`EmptyState` и `EmptyState`), и они расходились по оформлению.
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

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 56, color: scheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(
                title,
                style: text.titleMedium,
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
        ),
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

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.cloud_off_outlined,
                size: compact ? 40 : 56,
                color: scheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                'Не удалось загрузить',
                style: text.titleLarge,
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
                const SizedBox(height: AppLayout.gutter),
                FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Повторить'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
