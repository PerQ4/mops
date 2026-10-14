import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/auth/token_store.dart';
import 'core/net/bypass.dart';
import 'core/theme/ui_scaler.dart';
import 'data/local/app_settings.dart';
import 'state/providers.dart';
import 'state/ui_scale.dart';

/// Асинхронно готовит всё, что нужно для первого кадра (настройки и сессию),
/// после чего сразу отдаёт управление интерфейсу.
/// Путь к libmpv, если она лежит рядом с приложением или задана переменной.
String? _libmpvPath() {
  final String? fromEnv = Platform.environment['LIBMPV_LIBRARY_PATH'];
  final List<String> candidates = <String>[
    if (fromEnv != null && fromEnv.isNotEmpty) '$fromEnv/libmpv.so.2',
    '${Platform.environment['HOME'] ?? ''}/.local/lib/mops/libmpv.so.2',
  ];
  for (final String path in candidates) {
    if (path.isNotEmpty && File(path).existsSync()) return path;
  }
  return null;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Аудиодвижок — media_kit (libmpv). Нативные библиотеки нужно подготовить
  // до создания первого `Player`, иначе плеер не инициализируется.
  // media_kit (libmpv) сам библиотеку не находит: в поставке
  // media_kit_libs_linux её нет. Ищем по переменной окружения, затем в
  // пользовательском каталоге, иначе отдаём выбор системе.
  MediaKit.ensureInitialized(libmpv: _libmpvPath());

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

  // Обход блокировок провайдера (подмена хоста / прокси) нужно применить
  // до первого сетевого запроса — до него приложение не дойдёт.
  await BypassManager.instance.apply(settings.bypass);

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
