import 'package:flutter/material.dart';

/// Формы, которые переключатель «Material 3 Expressive» включает вместе
/// с палитрой.
///
/// Флаг живёт в теме, а не в настройках внутри `Artwork`: обложка не должна
/// знать о состоянии приложения, а `Hero` получает форму из того же дерева
/// темы, что и цвета, — перелёт и конечный кадр совпадают.
@immutable
class ExpressiveShape extends ThemeExtension<ExpressiveShape> {
  const ExpressiveShape({required this.superellipse});

  /// Рисовать крупные обложки суперэллипсом.
  final bool superellipse;

  @override
  ExpressiveShape copyWith({bool? superellipse}) {
    return ExpressiveShape(superellipse: superellipse ?? this.superellipse);
  }

  // Форма не интерполируется: суперэллипс либо есть, либо нет. Переключение
  // происходит на середине анимации темы, когда смены уже не видно за цветом.
  @override
  ExpressiveShape lerp(covariant ExpressiveShape? other, double t) {
    return t < 0.5 ? this : (other ?? this);
  }
}
