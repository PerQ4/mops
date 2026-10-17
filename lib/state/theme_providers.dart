import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../data/local/app_settings.dart';
import '../core/theme/seed_colors.dart';
import '../data/models/models.dart';
import '../widgets/artwork.dart';
import 'player_controller.dart';
import 'providers.dart';

/// Готовая пара схем для светлой и тёмной темы.
@immutable
class AppSchemes {
  const AppSchemes({required this.light, required this.dark});

  final ColorScheme light;
  final ColorScheme dark;
}

/// Кэш палитр, построенных из обложек.
///
/// Генерация схемы — небыстрая операция (квантование цветов), а треки
/// повторяются, поэтому результат запоминается по URL обложки.
final Map<String, AppSchemes> _artworkSchemeCache = <String, AppSchemes>{};

/// Палитра из выбранного пользователем акцентного цвета.
final Provider<AppSchemes> seedSchemesProvider = Provider<AppSchemes>((ref) {
  // Следим только за полями палитры: `watch` всего объекта пересобирал бы
  // обе схемы на любое изменение настроек — например, на каждое движение
  // ползунка громкости, — а вслед за ними перестраивалось бы всё приложение
  // (тема лежит в `MaterialApp`).
  final (Color seed, bool expressive, PaletteStylePreference style) = ref.watch(
    settingsControllerProvider.select(
      (AppSettings s) => (
        kSeedColors[s.safeSeedIndex].color,
        s.useMaterialExpressive,
        s.paletteStyle,
      ),
    ),
  );

  return AppSchemes(
    light: AppTheme.schemeFromSeed(
      seed: seed,
      brightness: Brightness.light,
      expressive: expressive,
      style: style,
    ),
    dark: AppTheme.schemeFromSeed(
      seed: seed,
      brightness: Brightness.dark,
      expressive: expressive,
      style: style,
    ),
  );
});

/// Палитра, построенная из обложки текущего трека.
///
/// Возвращает `null`, если источник палитры отключён, трек не играет
/// или из обложки не удалось собрать цвета.
final FutureProvider<AppSchemes?> artworkSchemesProvider =
    FutureProvider<AppSchemes?>((ref) async {
  // Как и у палитры из акцента: только нужные поля, иначе схема из обложки
  // пересчитывалась бы на каждое изменение любой настройки.
  final (ColorSource source, bool expressive, PaletteStylePreference style) =
      ref.watch(
    settingsControllerProvider.select(
      (AppSettings s) => (
        s.colorSource,
        s.useMaterialExpressive,
        s.paletteStyle,
      ),
    ),
  );
  if (source != ColorSource.artwork) return null;

  final Track? track = ref.watch(currentTrackProvider);
  final String? url = track?.thumbnails.sized(512) ?? track?.artwork;
  if (url == null || url.isEmpty) return null;

  final AppSchemes? cached = _artworkSchemeCache[url];
  if (cached != null) return cached;

  try {
    final ImageProvider provider = artworkProvider(url);
    // Параллельно строим обе схемы — так переключение темы не ждёт сеть.
    final List<ColorScheme> schemes = await Future.wait<ColorScheme>(<Future<ColorScheme>>[
      AppTheme.schemeFromArtwork(
        provider: provider,
        brightness: Brightness.light,
        expressive: expressive,
        style: style,
      ),
      AppTheme.schemeFromArtwork(
        provider: provider,
        brightness: Brightness.dark,
        expressive: expressive,
        style: style,
      ),
    ]);

    final AppSchemes result = AppSchemes(light: schemes[0], dark: schemes[1]);
    _artworkSchemeCache[url] = result;
    // Кэш не должен расти бесконечно.
    if (_artworkSchemeCache.length > 60) {
      _artworkSchemeCache.remove(_artworkSchemeCache.keys.first);
    }
    return result;
  } on Exception {
    // Не удалось разобрать обложку — тихо откатываемся на акцентный цвет.
    return null;
  }
});

/// Итоговая пара схем: обложка, если доступна, иначе акцентный цвет.
final Provider<AppSchemes> effectiveSchemesProvider = Provider<AppSchemes>((ref) {
  final AppSchemes fallback = ref.watch(seedSchemesProvider);
  final AsyncValue<AppSchemes?> fromArtwork = ref.watch(artworkSchemesProvider);

  return fromArtwork.value ?? fallback;
});

/// Собранная [ThemeData] для светлой и тёмной темы.
final Provider<({ThemeData light, ThemeData dark})> themeDataProvider =
    Provider<({ThemeData light, ThemeData dark})>((ref) {
  final AppSchemes schemes = ref.watch(effectiveSchemesProvider);
  final bool expressive =
      ref.watch(settingsControllerProvider.select((s) => s.useMaterialExpressive));
  final bool pureBlack =
      ref.watch(settingsControllerProvider.select((s) => s.pureBlack));

  return (
    light: AppTheme.build(scheme: schemes.light, expressive: expressive),
    dark: AppTheme.build(
      scheme: pureBlack ? AppTheme.pureBlack(schemes.dark) : schemes.dark,
      expressive: expressive,
    ),
  );
});
