import 'package:flutter/material.dart';



/// Сборка темы Material 3 / Material 3 Expressive.
///
/// Тема строится вокруг готового [ColorScheme] (сгенерированного из seed-цвета
/// или из обложки трека), а не из seed внутри виджета — так плеер может менять
/// палитру «на лету» под текущий трек.
class AppTheme {
  const AppTheme._();

  /// Вариант схемы, который даёт более сочные и контрастные роли —
  /// это и есть «expressive»-палитра Material 3.
  static const DynamicSchemeVariant expressiveVariant =
      DynamicSchemeVariant.expressive;

  /// Вариант по умолчанию, если пользователь отключил Expressive.
  static const DynamicSchemeVariant standardVariant =
      DynamicSchemeVariant.tonalSpot;

  static DynamicSchemeVariant variantFor(bool expressive) =>
      expressive ? expressiveVariant : standardVariant;

  /// Палитра из seed-цвета.
  static ColorScheme schemeFromSeed({
    required Color seed,
    required Brightness brightness,
    bool expressive = true,
  }) {
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: variantFor(expressive),
    );
  }

  /// Палитра из обложки трека.
  static Future<ColorScheme> schemeFromArtwork({
    required ImageProvider provider,
    required Brightness brightness,
    bool expressive = true,
  }) {
    return ColorScheme.fromImageProvider(
      provider: provider,
      brightness: brightness,
      dynamicSchemeVariant: variantFor(expressive),
    );
  }

  /// Собирает [ThemeData] для светлой и тёмной темы.
  static ThemeData build({
    required ColorScheme scheme,
    bool expressive = true,
  }) {
    final TextTheme textTheme = _textTheme(scheme);
    final bool isDark = scheme.brightness == Brightness.dark;

    return ThemeData(
      colorScheme: scheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      splashFactory: InkRipple.splashFactory,
      visualDensity: VisualDensity.standard,
      // Полосы прокрутки на десктопе: тонкие и неяркие, чтобы не спорить
      // с содержимым.
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll<double>(8),
        radius: const Radius.circular(4),
        thumbColor: WidgetStatePropertyAll<Color>(scheme.outlineVariant),
        crossAxisMargin: 2,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surfaceTint,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 3,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.secondaryContainer,
        selectedIconTheme: IconThemeData(color: scheme.onSecondaryContainer),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        selectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.secondaryContainer,
        elevation: 0,
        height: 72,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: _radius(16)),
        clipBehavior: Clip.antiAlias,
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: _radius(16)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: _radius(20)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          textStyle: textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: _radius(20)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: _radius(16)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          highlightColor: scheme.primary.withValues(alpha: 0.12),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: _radius(12)),
        side: BorderSide(color: scheme.outlineVariant),
        backgroundColor: scheme.surfaceContainerLow,
        selectedColor: scheme.secondaryContainer,
        labelStyle: textTheme.labelLarge,
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 6,
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.surfaceContainerHighest,
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: 0.12),
        // Expressive-слайдер тяготеет к «капсульным» формам.
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
        trackShape: const RoundedRectSliderTrackShape(),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: scheme.surfaceContainerHighest,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: _radius(28)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: scheme.surfaceTint,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        showDragHandle: true,
        clipBehavior: Clip.antiAlias,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        shape: RoundedRectangleBorder(borderRadius: _radius(12)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: _radius(8),
        ),
        textStyle: textTheme.bodySmall?.copyWith(
          color: scheme.onInverseSurface,
        ),
      ),
      tabBarTheme: TabBarThemeData(
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        labelStyle: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        unselectedLabelStyle: textTheme.titleSmall,
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: scheme.primary, width: 3),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: _radius(28),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: _radius(28),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: _radius(28),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          if (states.contains(WidgetState.selected)) {
            return scheme.onPrimary;
          }
          return scheme.outline;
        }),
        trackColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          if (states.contains(WidgetState.selected)) {
            return scheme.primary;
          }
          return scheme.surfaceContainerHighest;
        }),
      ),
      extensions: <ThemeExtension<dynamic>>[
        PlayerTheme(
          heroRadius: BorderRadius.circular(expressive ? 36 : 20),
          tileRadius: BorderRadius.circular(expressive ? 20 : 12),
          artworkShadow: BoxShadow(
            color: scheme.shadow.withValues(alpha: isDark ? 0.6 : 0.18),
            blurRadius: 40,
            offset: const Offset(0, 16),
          ),
        ),
      ],
    );
  }

  static BorderRadius _radius(double r) => BorderRadius.circular(r);

  /// Типографика. Expressive-шкала — крупные заголовки и плотный основной текст.
  static TextTheme _textTheme(ColorScheme scheme) {
    return Typography.material2021().black.apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    );
  }
}

/// Дополнительные параметры темы, которых нет в [ColorScheme].
@immutable
class PlayerTheme extends ThemeExtension<PlayerTheme> {
  const PlayerTheme({
    required this.heroRadius,
    required this.tileRadius,
    required this.artworkShadow,
  });

  final BorderRadius heroRadius;
  final BorderRadius tileRadius;
  final BoxShadow artworkShadow;

  @override
  PlayerTheme copyWith({
    BorderRadius? heroRadius,
    BorderRadius? tileRadius,
    BoxShadow? artworkShadow,
  }) {
    return PlayerTheme(
      heroRadius: heroRadius ?? this.heroRadius,
      tileRadius: tileRadius ?? this.tileRadius,
      artworkShadow: artworkShadow ?? this.artworkShadow,
    );
  }

  @override
  PlayerTheme lerp(covariant PlayerTheme? other, double t) {
    if (other == null) return this;
    return PlayerTheme(
      heroRadius: BorderRadius.lerp(heroRadius, other.heroRadius, t)!,
      tileRadius: BorderRadius.lerp(tileRadius, other.tileRadius, t)!,
      artworkShadow: BoxShadow.lerp(artworkShadow, other.artworkShadow, t)!,
    );
  }
}

/// Пружинные кривые, характерные для Motion-системы Material 3 Expressive.
abstract final class AppMotion {
  /// Быстрая «пружина» — для нажатий и переключателей.
  static const Curve snappy = Cubic(0.2, 0.0, 0.0, 1.0);

  /// Мягкое появление контента.
  static const Curve gentle = Cubic(0.05, 0.7, 0.1, 1.0);

  static const Duration fast = Duration(milliseconds: 160);
  static const Duration medium = Duration(milliseconds: 320);
  static const Duration slow = Duration(milliseconds: 520);
}
