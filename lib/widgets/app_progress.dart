import 'package:flutter/widgets.dart';
import 'package:material_3_expressive/material_3_expressive.dart' as m3e;

/// Индикатор загрузки приложения — один на весь интерфейс.
///
/// До 11.8 в проекте жили 35 обычных `CircularProgressIndicator` и пара
/// `M3ELoadingIndicator` на главной: соседние экраны крутили индикаторы разной
/// формы, толщины и цвета. Теперь все места «идёт загрузка» рисует эта обёртка,
/// а форму задаёт `M3ELoadingIndicator` из `material_3_expressive`
/// (порт `LoadingIndicator` из Compose Material 3).
///
/// `strokeWidth` у компонента нет: толщина фигуры задаётся её размером, поэтому
/// снаружи доступны только `size` и `color`.
///
/// Индикатор выполнения с известным прогрессом (`value` в
/// `CircularProgressIndicator`) сюда не переводится: там нужно движение к цели,
/// а не бесконечное вращение. Такое место в проекте одно — строка загрузки на
/// экране «Загрузки».
///
/// Анимация у пакета бесконечная (морфинг и вращение на `repeat()`), поэтому в
/// тестах рядом с видимым индикатором нужен `pump`, а не `pumpAndSettle`.
class AppProgress extends StatelessWidget {
  /// [size] — внешний размер, [color] — цвет фигуры.
  const AppProgress({super.key, this.size, this.color});

  /// Внешний размер в логических пикселях. `null` — 48 по спецификации M3E.
  ///
  /// Пакет принимает только 24–240 и в отладочной сборке падает на остальных
  /// значениях, а вызывающий код часто хочет «как прежние 18». Поэтому границы
  /// прижимаются здесь: лучше индикатор на 6 пикселей крупнее, чем упавший
  /// экран из-за неверного размера.
  final double? size;

  /// Цвет фигуры. `null` — `primary` из текущей схемы, как у прежнего
  /// `CircularProgressIndicator`.
  final Color? color;

  /// Нижняя граница размера из спецификации пакета.
  static const double minSize = 24;

  /// Верхняя граница размера из спецификации пакета.
  static const double maxSize = 240;

  @override
  Widget build(BuildContext context) {
    final double? outer = size?.clamp(minSize, maxSize).toDouble();
    return m3e.M3ELoadingIndicator(size: outer, color: color);
  }
}
