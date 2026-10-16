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
import 'core/net/local_proxy.dart';
import 'data/local/app_settings.dart';
import 'features/shell/app_shell.dart';
import 'features/shell/content_navigator.dart';
import 'widgets/back_gesture.dart';
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
      unawaited(_configureAccess());
    });
  }

  /// Приводит доступ к сети в рабочее состояние — всё автоматически.
  ///
  /// Два независимых шага:
  ///
  ///  1. Если подмена хоста через узел не работает, а прямой доступ есть —
  ///     выключаем её, чтобы приложение не осталось без данных.
  ///  2. Если медиахост (звук) недоступен, ищем локальный прокси. Провайдер
  ///     блокирует медиасерверы отдельно, и подменить их хост нельзя:
  ///     у них собственный backend. Зато обычный локальный прокси решает
  ///     задачу целиком, а он есть почти у каждого, кто обходит блокировки.
  ///
  /// Пользователю ничего настраивать не нужно.
  Future<void> _configureAccess() async {
    if (!ref.read(bypassAutoVerifyProvider)) return;

    final SettingsController controller =
        ref.read(settingsControllerProvider.notifier);

    try {
      AppSettings settings = ref.read(settingsControllerProvider);

      // Шаг 1: не сломана ли подмена хоста.
      if (settings.bypass.fronting.enabled &&
          !settings.bypass.usesProxy &&
          !await ConnectivityCheck.dataReachable(fronting: true)) {
        if (await ConnectivityCheck.dataReachable(fronting: false)) {
          await controller.setFrontingEnabled(false);
          debugPrint('[Access] подмена хоста недоступна — выключена');
        }
      }

      // Шаг 2: доступен ли звук. Если да — искать прокси незачем.
      if (await ConnectivityCheck.mediaReachable()) {
        debugPrint('[Access] медиахост доступен напрямую — прокси не нужен');
        return;
      }

      settings = ref.read(settingsControllerProvider);
      if (!settings.autoDetectProxy || settings.bypass.usesProxy) return;

      debugPrint('[Access] медиахост заблокирован — ищу локальный прокси');
      final LocalProxy? proxy = await LocalProxyDetector.find(
        onFound: (LocalProxy found) =>
            debugPrint('[Access] найден прокси: $found'),
      );

      if (proxy == null) {
        debugPrint('[Access] локальный прокси не найден');
        return;
      }

      // Прокси закрывает всё сразу — подмена хоста больше не нужна.
      await controller.setProxy(
        kind: proxy.kind,
        host: proxy.host,
        port: proxy.port,
      );
      await controller.setFrontingEnabled(false);
      debugPrint('[Access] включён прокси ${proxy.label}');
    } on Object catch (error) {
      debugPrint('[Access] проверка не удалась: $error');
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
      navigatorKey: rootNavigatorKey,
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
          // Жест «назад» ставим внутри корневого навигатора: тогда к нему
          // всплывают события и от подэкранов, и от полноэкранного плеера.
          child: BackGesture(
            child: UiScaler(
              scale: scale,
              child: _RenderScale(
                child: _ClampedTextScale(child: content),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Итоговый масштаб интерфейса — см. `lib/state/ui_scale.dart`.

/// Ограничивает разрешение отрисовки, не меняя раскладку.
///
/// На этом экране движок рисовал в двойном разрешении (DPR 2.0 при физическом
/// масштабе 1.25): это вчетверо больше пикселей, чем нужно, и анимации заметно
/// лагали. Здесь плотность ограничивается, а логический размер остаётся тем
/// же — то есть раскладка не меняется, картинка чуть мягче.
class _RenderScale extends StatelessWidget {
  const _RenderScale({required this.child});

  final Widget child;

  /// Предел плотности. 1.5 — компромисс: текст остаётся чётким, а пикселей
  /// примерно на треть меньше, чем при 2.0.
  static const double maxDevicePixelRatio = 1.5;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    if (media.devicePixelRatio <= maxDevicePixelRatio) return child;
    return MediaQuery(
      data: media.copyWith(devicePixelRatio: maxDevicePixelRatio),
      child: child,
    );
  }
}

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
