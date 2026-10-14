import 'package:flutter/material.dart';

import '../core/innertube/innertube_client.dart';
import '../core/theme/layout.dart';

/// Приводит техническую ошибку к тексту, который не стыдно показать.
String describeError(Object error) {
  if (error is InnerTubeException) {
    if (error.isUnauthorized) {
      return 'Нужен вход в аккаунт: YouTube отклонил запрос без авторизации.';
    }
    if (error.statusCode == null) return error.message;
    return '${error.message}\nПроверьте соединение или смените регион в настройках.';
  }
  final String text = error.toString();
  if (text.contains('SocketException') || text.contains('ClientException')) {
    return 'Нет соединения с YouTube Music. Проверьте интернет и попробуйте снова.';
  }
  if (text.contains('TimeoutException')) {
    return 'YouTube Music не ответил вовремя. Попробуйте ещё раз.';
  }
  return text.replaceFirst('Exception: ', '');
}

/// Скелетон-заглушка списка с каруселями — не «прыгающий» при загрузке.
class SectionSkeleton extends StatelessWidget {
  const SectionSkeleton({
    super.key,
    this.rows = 4,
    this.cardWidth = AppLayout.gridThumbnailHeight,
  });

  final int rows;
  final double cardWidth;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 16),
      itemCount: rows,
      itemBuilder: (BuildContext context, int row) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                width: 180,
                height: 22,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: cardWidth + 84,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: 4,
                separatorBuilder: (BuildContext context, int _) =>
                    const SizedBox(width: 8),
                itemBuilder: (BuildContext context, int index) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Container(
                        width: cardWidth,
                        height: cardWidth,
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(
                            AppLayout.gridThumbnailRadius,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        width: cardWidth * 0.7,
                        height: 12,
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }
}
