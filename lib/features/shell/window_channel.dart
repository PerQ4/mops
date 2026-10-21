import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Канал окна `mops/window` — общая точка для своей шапки на Windows.
///
/// Нативная сторона не только принимает команды, но и сообщает состояние
/// окна: развернуть его можно Win+стрелкой, Aero Snap или двойным кликом по
/// системной шапке, и без события Dart об этом не узнал бы.
class WindowChannel {
  WindowChannel._();

  static const MethodChannel _channel = MethodChannel('mops/window');

  /// Развёрнуто ли окно. Источник истины — нативная сторона.
  static final ValueNotifier<bool> maximized = ValueNotifier<bool>(false);

  /// Подписка одна на всё приложение: `setMethodCallHandler` заменяет
  /// обработчик, и второе подключение молча съело бы первое.
  static bool _listening = false;

  /// Подписаться на события окна и перечитать текущее состояние.
  static Future<void> attach() async {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler(_onMethodCall);
    }
    await refresh();
  }

  /// Перечитать состояние у нативной стороны.
  static Future<void> refresh() async {
    try {
      final bool value =
          await _channel.invokeMethod<bool>('isMaximized') ?? false;
      maximized.value = value;
    } on Object {
      // Канал есть только на Windows.
    }
  }

  /// Выполнить команду окна. Ошибку не показываем: окно могло уже закрыться.
  static void invoke(String method) {
    _channel.invokeMethod<void>(method).catchError((Object _) {});
  }

  static Future<void> _onMethodCall(MethodCall call) async {
    if (call.method != 'maximizedChanged') return;
    final Object? arguments = call.arguments;
    if (arguments is bool) maximized.value = arguments;
  }
}
