import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/seed_colors.dart';
import 'features/shell/app_shell.dart';
import 'state/providers.dart';
import 'state/theme_providers.dart';

/// Корневое приложение.
///
/// Тема и настройки уже прочитаны из хранилища в `main()`, поэтому первый
/// кадр сразу рисуется в правильных цветах — без «вспышки» светлой темы.
class MopsApp extends ConsumerWidget {
  const MopsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ({ThemeData light, ThemeData dark}) themes =
        ref.watch(themeDataProvider);
    final ThemeModePreference preference = ref.watch(
      settingsControllerProvider.select((s) => s.themeMode),
    );

    return MaterialApp(
      title: 'mOps',
      debugShowCheckedModeBanner: false,
      theme: themes.light,
      darkTheme: themes.dark,
      themeMode: preference.themeMode,
      locale: const Locale('ru'),
      supportedLocales: const <Locale>[Locale('ru'), Locale('en')],
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const AppShell(),
      builder: (BuildContext context, Widget? child) {
        // Ограничиваем максимальный масштаб текста: на десктопе системные
        // настройки иногда дают нечитаемо крупный интерфейс.
        final MediaQueryData media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: media.textScaler.clamp(
              minScaleFactor: 0.9,
              maxScaleFactor: 1.4,
            ),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
