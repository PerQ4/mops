import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Выбранный раздел верхнего уровня.
///
/// Хранится в провайдере, а не в состоянии виджета: навигация живёт в островке
/// внизу, и ей нужно управлять оболочкой снаружи.
class ShellIndexController extends Notifier<int> {
  @override
  int build() => 0;

  void select(int index) => state = index;
}

final NotifierProvider<ShellIndexController, int> shellIndexProvider =
    NotifierProvider<ShellIndexController, int>(ShellIndexController.new);
