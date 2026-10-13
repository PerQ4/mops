import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/seed_colors.dart';
import 'core/theme/ui_scaler.dart';
import 'core/net/anti_dpi.dart';
import 'core/net/bypass.dart';
import 'core/net/fronting.dart';
import 'data/local/app_settings.dart';
import 'features/shell/app_shell.dart';
import 'state/providers.dart';
import 'state/theme_providers.dart';
import 'state/ui_scale.dart';

/// Корневое приложение.
///
/// Тема и настройки уже прочитаны из хранилища в `main()`, поэтому первый
/// кадр сразу рисуется в правильных цветах — без «вспышки» светлой темы.
class MopsApp extends ConsumerStatefulWidget {
  const MopsApp({super.key});

  @override
  ConsumerState<MopsApp> createState() => _MopsAppState();
}

class _MopsAppState extends ConsumerState<MopsApp> {
  @override
  void initState() {
    super.initState();
    // Проверку удобства ради делаем после первого кадра, чтобы не задерживать
    // запуск: она может занять несколько секунд.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_autoConfigureBypass());
    });
  }

  /// При первом запуске выясняет, нужен ли обход, и включает его.
  ///
  /// Пользователь не должен сам догадываться, что провайдер режет SNI.
  /// Логика простая: если данные недоступны напрямую, но доступны с подменой
  /// хоста — включаем подмену и запоминаем, что проверка выполнена.
  Future<void> _autoConfigureBypass() async {
    final AppSettings settings = ref.read(settingsControllerProvider);
    if (settings.bypassProbed) return;
    if (settings.bypass.isEnabled) return; // уже настроено пользователем

    final SettingsController controller =
        ref.read(settingsControllerProvider.notifier);
    try {
      final bool direct = await ConnectivityCheck.dataReachable(fronting: false);
      if (!direct) {
        final bool fronted = await ConnectivityCheck.dataReachable(fronting: true);
        if (fronted) {
          await controller.setFrontingEnabled(true);
          debugPrint('[Bypass] провайдер блокирует домен — включена подмена хоста');
        }
      }
    } on Object catch (error) {
      debugPrint('[Bypass] проверка не удалась: $error');
    } finally {
      await controller.markBypassProbed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ({ThemeData light, ThemeData dark}) themes =
        ref.watch(themeDataProvider);
    final ThemeModePreference preference = ref.watch(
      settingsControllerProvider.select((s) => s.themeMode),
    );

    // Смена настроек обхода должна применяться сразу, без перезапуска.
    ref.listen(bypassProvider, (AntiDpiConfig? previous, AntiDpiConfig next) {
      BypassManager.instance.apply(next);
    });

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
        final Widget content = child ?? const SizedBox.shrink();
        final double scale = resolveUiScale(context, ref);

        return _ScaleShortcuts(
          child: UiScaler(
            scale: scale,
            child: _ClampedTextScale(child: content),
          ),
        );
      },
    );
  }
}

/// Итоговый масштаб интерфейса — см. `lib/state/ui_scale.dart`.

/// Ограничивает системный масштаб текста: на десктопе он иногда даёт
/// нечитаемо крупный интерфейс, а уменьшить его пользователь не может.
class _ClampedTextScale extends StatelessWidget {
  const _ClampedTextScale({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: media.textScaler.clamp(
          minScaleFactor: 0.9,
          maxScaleFactor: 1.4,
        ),
      ),
      child: child,
    );
  }
}

/// Горячие клавиши масштаба: Ctrl + / Ctrl - / Ctrl 0.
///
/// Порядок привычен по браузерам, поэтому не требует объяснений.
class _ScaleShortcuts extends ConsumerWidget {
  const _ScaleShortcuts({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SettingsController controller =
        ref.read(settingsControllerProvider.notifier);
    final AppSettings settings = ref.watch(settingsControllerProvider);

    // В автоматическом режиме отсчёт идёт от фактического масштаба,
    // иначе первое нажатие «сбросило» бы компенсацию к 100%.
    final double current = settings.uiScale > 0
        ? settings.uiScale
        : resolveUiScale(context, ref);

    double step(double from, int direction) {
      final List<double> steps = kUiScaleSteps;
      int index = steps.indexOf(from);
      if (index < 0) {
        // Текущее значение не совпало со ступенью — подбираем ближайшую.
        index = 0;
        for (int i = 0; i < steps.length; i++) {
          if (steps[i] <= from) index = i;
        }
      }
      final int next = (index + direction).clamp(0, steps.length - 1);
      return steps[next];
    }

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.equal, control: true):
            _ScaleUpIntent(),
        SingleActivator(LogicalKeyboardKey.add, control: true):
            _ScaleUpIntent(),
        SingleActivator(LogicalKeyboardKey.minus, control: true):
            _ScaleDownIntent(),
        SingleActivator(LogicalKeyboardKey.digit0, control: true):
            _ScaleResetIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _ScaleUpIntent: CallbackAction<_ScaleUpIntent>(
            onInvoke: (_) {
              controller.setUiScale(step(current, 1));
              return null;
            },
          ),
          _ScaleDownIntent: CallbackAction<_ScaleDownIntent>(
            onInvoke: (_) {
              controller.setUiScale(step(current, -1));
              return null;
            },
          ),
          _ScaleResetIntent: CallbackAction<_ScaleResetIntent>(
            onInvoke: (_) {
              // Ноль — автоматический режим.
              controller.setUiScale(0);
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

class _ScaleUpIntent extends Intent {
  const _ScaleUpIntent();
}

class _ScaleDownIntent extends Intent {
  const _ScaleDownIntent();
}

class _ScaleResetIntent extends Intent {
  const _ScaleResetIntent();
}
