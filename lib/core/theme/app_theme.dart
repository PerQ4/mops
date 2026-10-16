import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/local/app_settings.dart';



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

  static DynamicSchemeVariant variantFor(
    bool expressive, [
    PaletteStylePreference style = PaletteStylePreference.tonal,
  ]) {
    switch (style) {
      case PaletteStylePreference.monochrome:
        return DynamicSchemeVariant.monochrome;
      case PaletteStylePreference.neutral:
        return DynamicSchemeVariant.neutral;
      case PaletteStylePreference.tonal:
        return expressive ? expressiveVariant : standardVariant;
    }
  }

  /// Палитра из seed-цвета.
  static ColorScheme schemeFromSeed({
    required Color seed,
    required Brightness brightness,
    bool expressive = true,
    PaletteStylePreference style = PaletteStylePreference.tonal,
  }) {
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: variantFor(expressive, style),
    );
  }

  /// Палитра из обложки трека.
  static Future<ColorScheme> schemeFromArtwork({
    required ImageProvider provider,
    required Brightness brightness,
    bool expressive = true,
    PaletteStylePreference style = PaletteStylePreference.tonal,
  }) {
    return ColorScheme.fromImageProvider(
      provider: provider,
      brightness: brightness,
      dynamicSchemeVariant: variantFor(expressive, style),
    );
  }

  /// Делает тёмную схему «чисто чёрной»: фон и поверхности — #000000.
  ///
  /// Так в ArchiveTune выглядит отдельный переключатель: акценты остаются
  /// прежними, а подложка становится абсолютно чёрной (удобно на OLED).
  static ColorScheme pureBlack(ColorScheme scheme) {
    if (scheme.brightness != Brightness.dark) return scheme;
    return scheme.copyWith(
      surface: Colors.black,
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: Colors.black,
      surfaceContainer: Colors.black,
    );
  }

  /// Собирает [ThemeData] для светлой и тёмной темы.
  static ThemeData build({
    required ColorScheme scheme,
    bool expressive = true,
  }) {
    final TextTheme textTheme = _textTheme(scheme);
    return ThemeData(
      colorScheme: scheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      splashFactory: InkRipple.splashFactory,
      visualDensity: VisualDensity.standard,
      // Полосы прокрутки на десктопе: тонкие и неяркие, чтобы не спорить
      // с содержимым.
      // Выделение текста и курсор: в M3 это primary, а не системный синий.
      // Раньше подсветка бралась из системной темы и выбивалась из палитры.
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: scheme.primary,
        selectionColor: scheme.primary.withValues(alpha: 0.4),
        selectionHandleColor: scheme.primary,
      ),
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
        // Панель экрана не подкрашивается при прокрутке: в M3 она получает
        // тон `surfaceTint`, и под шапкой окна появлялась более светлая полоса,
        // неотличимая от артефакта отрисовки.
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        // Заголовок экрана в ArchiveTune — titleLarge, bold, цветом primary:
        // он читается как акцент, а не как обычный текст.
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w700,
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
      // Чипы-капсулы без обводки: в ArchiveTune они отличаются от фона только
      // заливкой, а выбранный — цветом secondaryContainer.
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide.none,
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.secondaryContainer,
        labelStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
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
        shape: RoundedRectangleBorder(borderRadius: _radius(24)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: scheme.surfaceTint,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
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
        // Текст поиска — как в ArchiveTune: обычный bodyLarge, подсказка
        // приглушена, курсор цветом акцента.
        hintStyle: textTheme.bodyLarge?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
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
          // Тень обложки убрана: интерфейс плоский, обложка отделяется
          // размером и скруглением.
          artworkShadow: const BoxShadow(
            color: Colors.transparent,
            blurRadius: 0,
            offset: Offset.zero,
          ),
        ),
      ],
    );
  }

  static BorderRadius _radius(double r) => BorderRadius.circular(r);

  /// Типографика. Expressive-шкала — крупные заголовки и плотный основной текст.
  static TextTheme _textTheme(ColorScheme scheme) {
    // Основной шрифт — Poppins, как в ArchiveTune. Кириллицы в нём нет
    // (0 из 64 букв), поэтому русские буквы берутся из фоллбека — Montserrat,
    // ближайшего по стилю геометрического шрифта с полной кириллицей. Так
    // латиница выглядит как в оригинале, а русский текст — не «чужим»
    // системным шрифтом.
    final TextTheme base = Typography.material2021().black
        .apply(
          bodyColor: scheme.onSurface,
          displayColor: scheme.onSurface,
          fontFamily: 'Poppins',
          fontFamilyFallback: const <String>['Montserrat'],
        );

    // Веса по спецификации ArchiveTune: заголовки экранов и секций — semibold,
    // названия треков — semibold, подписи — обычные и приглушённые.
    return base.copyWith(
      titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w500),
      bodyLarge: base.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
      bodyMedium: base.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      bodySmall: base.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w600),
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

/// Кривая-пружина: приближает Motion-систему Material 3 Expressive.
///
/// В ArchiveTune переходы заданы пружинами (`Spring.StiffnessLow`,
/// `DampingRatioNoBouncy`), а во Flutter пружинных кривых нет — есть только
/// кубические. Здесь та же пружина, посчитанная как кривая: критически
/// затухающий осциллятор, который без отскока приходит в цель.
///
/// Критическое затухание даёт формулу `1 - (1 + w·t)·e^(-w·t)`, где `w` —
/// жёсткость. Чем больше `w`, тем резче движение.
class SpringCurve extends Curve {
  const SpringCurve({this.stiffness = 8});

  /// Жёсткость: 8 — спокойно, 12 — живее.
  final double stiffness;

  @override
  double transformInternal(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    final double w = stiffness;
    return 1 - (1 + w * t) * math.exp(-w * t);
  }
}

/// Пружинные кривые, характерные для Motion-системы Material 3 Expressive.
abstract final class AppMotion {
  /// Пружина для размеров и положения: мягкая, без отскока.
  static const Curve spring = SpringCurve();

  /// Пружина порезче — для нажатий и переключателей.
  static const Curve springSnappy = SpringCurve(stiffness: 12);

  /// Быстрая «пружина» — для нажатий и переключателей.
  static const Curve snappy = Cubic(0.2, 0.0, 0.0, 1.0);

  /// Мягкое появление контента.
  static const Curve gentle = Cubic(0.05, 0.7, 0.1, 1.0);

  static const Duration fast = Duration(milliseconds: 160);
  static const Duration medium = Duration(milliseconds: 320);
  static const Duration slow = Duration(milliseconds: 520);
}
