import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/auth/token_store.dart';
import 'data/local/app_settings.dart';
import 'state/providers.dart';

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

  runApp(
    ProviderScope(
      overrides: <Override>[
        sharedPreferencesProvider.overrideWithValue(prefs),
        initialSettingsProvider.overrideWithValue(settings),
        initialSessionProvider.overrideWithValue(session),
      ],
      child: const MopsApp(),
    ),
  );
}
