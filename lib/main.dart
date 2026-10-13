import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/auth/token_store.dart';
import 'core/theme/ui_scaler.dart';
import 'data/local/app_settings.dart';
import 'state/providers.dart';
import 'state/ui_scale.dart';

/// Асинхронно готовит всё, что нужно для первого кадра (настройки и сессию),
/// после чего сразу отдаёт управление интерфейсу.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final AppSettings settings =
      AppSettings.decode(prefs.getString(kSettingsKey));

  // Сессию читаем до запуска: иначе при первом кадре пользователь
  // на мгновение увидел бы «гостевой» интерфейс.
  final AuthSession? session = await TokenStore().read();

  // Масштаб, который просит оконная система (GNOME/KDE/GTK/Qt).
  // Если он расходится с DPR движка, интерфейс компенсируется — см. ui_scale.dart.
  final DesktopScaleInfo desktopScale = detectDesktopScaleInfo();
  final double engineDpr = _engineDevicePixelRatio();
  final double compensation =
      computeUiCompensation(desktopScale, engineDpr);

  // Полезно при разборе «слишком мелкого/крупного» интерфейса: сравниваем
  // логический размер окна с логическим размером рабочего стола.
  debugPrint(
    '[DPI] система: ×${desktopScale.scale.toStringAsFixed(2)} '
    '(${desktopScale.source}); DPR движка: $engineDpr; '
    'физический размер: ${_enginePhysicalSize()}; '
    'логический размер: ${_engineLogicalSize()}; '
    'компенсация: ×${compensation.toStringAsFixed(3)}',
  );

  runApp(
    ProviderScope(
      // Тип списка выводится сам: `Override` — деталь реализации Riverpod.
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        initialSettingsProvider.overrideWithValue(settings),
        initialSessionProvider.overrideWithValue(session),
        desktopScaleProvider.overrideWithValue(desktopScale),
      ],
      child: const MopsApp(),
    ),
  );
}

/// DPR, который сообщает движок. Если он расходится с системным масштабом,
/// интерфейс нужно компенсировать — см. `resolveUiScale`.
double _engineDevicePixelRatio() {
  final views = WidgetsBinding.instance.platformDispatcher.views;
  if (views.isEmpty) return 1.0;
  return views.first.devicePixelRatio;
}

String _enginePhysicalSize() {
  final views = WidgetsBinding.instance.platformDispatcher.views;
  if (views.isEmpty) return '—';
  final Size size = views.first.physicalSize;
  return '${size.width.toInt()}×${size.height.toInt()}';
}

String _engineLogicalSize() {
  final views = WidgetsBinding.instance.platformDispatcher.views;
  if (views.isEmpty) return '—';
  final double dpr = views.first.devicePixelRatio;
  if (dpr <= 0) return '—';
  final Size size = views.first.physicalSize / dpr;
  return '${size.width.toInt()}×${size.height.toInt()}';
}
