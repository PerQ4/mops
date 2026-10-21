import 'package:flutter/material.dart';

import '../../data/local/app_settings.dart';
import 'custom_font.dart';
import 'expressive_shape.dart';

// Кривые и длительности живут в `motion.dart` — там весь словарь движений,
// а здесь только тема. Реэкспорт оставлен для тех, кто импортирует тему:
// `import 'core/theme/app_theme.dart'` по-прежнему даёт [AppMotion].
export 'motion.dart';

/// Чем набирается интерфейс (задача 7.4).
///
/// Фоллбек у всех вариантов один — Montserrat: в Poppins нет кириллицы, а свой
/// шрифт может быть латинским. Русские буквы в таком случае берутся из
/// фоллбека, и текст остаётся текстом, а не квадратами.
@immutable
class AppFont {
  const AppFont({required this.family, required this.fallback});

  /// Poppins — как было до появления настройки.
  const AppFont.poppins()
      : family = 'Poppins',
        fallback = const <String>['Montserrat'];

  /// Системный шрифт платформы: `fontFamily` не задаём, Flutter берёт свой.
  const AppFont.system()
      : family = null,
        fallback = const <String>['Montserrat'];

  /// Шрифт пользователя, зарегистрированный под [kCustomFontFamily].
  const AppFont.custom()
      : family = kCustomFontFamily,
        fallback = const <String>['Montserrat'];

  /// `null` — семейство не навязывается (системный шрифт).
  final String? family;
  final List<String> fallback;

  static AppFont forPreference(FontPreference preference) {
    switch (preference) {
      case FontPreference.poppins:
        return const AppFont.poppins();
      case FontPreference.system:
        return const AppFont.system();
      case FontPreference.custom:
        return const AppFont.custom();
    }
  }
}

/// Сборка темы Material 3 / Material 3 Expressive.
///
/// Тема строится вокруг готового [ColorScheme] (сгенерированного из seed-цвета
/// или из обложки трека), а не из seed внутри виджета — так плеер может менять
/// палитру «на лету» под текущий трек.
class AppTheme {
  const AppTheme._();

  /// Шрифт интерфейса. Ставится из настроек (`SettingsController`), потому что
  /// тему собирает провайдер без `ref` на шрифт — так же, как флаг движений.
  /// `MopsApp` пересобирает тему, когда выбор меняется.
  static AppFont font = const AppFont.poppins();

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
    // Перекрываем все роли поверхности, а не только нижние уровни: диалоги,
    // палитра команд и поля поиска берут `surfaceContainerHigh` и
    // `surfaceContainerHighest`; без них на чёрном фоне оставались серые
    // прямоугольники.
    return scheme.copyWith(
      surface: Colors.black,
      surfaceDim: Colors.black,
      surfaceBright: Colors.black,
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: Colors.black,
      surfaceContainer: Colors.black,
      surfaceContainerHigh: Colors.black,
      surfaceContainerHighest: Colors.black,
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
        ExpressiveShape(superellipse: expressive),
      ],
    );
  }

  static BorderRadius _radius(double r) => BorderRadius.circular(r);

  /// Типографика. Expressive-шкала — крупные заголовки и плотный основной текст.
  static TextTheme _textTheme(ColorScheme scheme) {
    // Основной шрифт выбирается в настройках. По умолчанию — Poppins, как в
    // ArchiveTune: кириллицы в нём нет (0 из 64 букв), поэтому русские буквы
    // берутся из фоллбека — Montserrat, ближайшего по стилю геометрического
    // шрифта с полной кириллицей. Так латиница выглядит как в оригинале, а
    // русский текст — не «чужим» системным шрифтом.
    //
    // Фоллбек остаётся и для системного шрифта, и для своего: шрифт
    // пользователя может быть латинским, и тогда без фоллбека русский текст
    // превратился бы в квадраты. Предупреждение об этом показывает экран
    // настроек (см. `CustomFonts`), а не молчание интерфейса.
    final AppFont font = AppTheme.font;
    TextTheme base = Typography.material2021().black;
    base = base.apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    );
    if (font.family != null) {
      base = base.apply(
        fontFamily: font.family,
        fontFamilyFallback: font.fallback,
      );
    } else {
      base = base.apply(fontFamilyFallback: font.fallback);
    }

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
