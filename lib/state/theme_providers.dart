import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
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
final Provider<AppSchemes> seedSchemesProvider = Provider<AppSchemes>((Ref ref) {
  final settings = ref.watch(settingsControllerProvider);
  final Color seed = kSeedColors[settings.safeSeedIndex].color;
  final bool expressive = settings.useMaterialExpressive;

  return AppSchemes(
    light: AppTheme.schemeFromSeed(
      seed: seed,
      brightness: Brightness.light,
      expressive: expressive,
    ),
    dark: AppTheme.schemeFromSeed(
      seed: seed,
      brightness: Brightness.dark,
      expressive: expressive,
    ),
  );
});

/// Палитра, построенная из обложки текущего трека.
///
/// Возвращает `null`, если источник палитры отключён, трек не играет
/// или из обложки не удалось собрать цвета.
final FutureProvider<AppSchemes?> artworkSchemesProvider =
    FutureProvider<AppSchemes?>((Ref ref) async {
  final settings = ref.watch(settingsControllerProvider);
  if (settings.colorSource != ColorSource.artwork) return null;

  final Track? track = ref.watch(currentTrackProvider);
  final String? url = track?.thumbnails.sized(512) ?? track?.artwork;
  if (url == null || url.isEmpty) return null;

  final AppSchemes? cached = _artworkSchemeCache[url];
  if (cached != null) return cached;

  final bool expressive = settings.useMaterialExpressive;
  try {
    final ImageProvider provider = artworkProvider(url);
    // Параллельно строим обе схемы — так переключение темы не ждёт сеть.
    final List<ColorScheme> schemes = await Future.wait<ColorScheme>(<Future<ColorScheme>>[
      AppTheme.schemeFromArtwork(
        provider: provider,
        brightness: Brightness.light,
        expressive: expressive,
      ),
      AppTheme.schemeFromArtwork(
        provider: provider,
        brightness: Brightness.dark,
        expressive: expressive,
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
final Provider<AppSchemes> effectiveSchemesProvider = Provider<AppSchemes>((Ref ref) {
  final AppSchemes fallback = ref.watch(seedSchemesProvider);
  final AsyncValue<AppSchemes?> fromArtwork =
      ref.watch(artworkSchemesProvider);

  return fromArtwork.valueOrNull ?? fallback;
});

/// Собранная [ThemeData] для светлой и тёмной темы.
final Provider<({ThemeData light, ThemeData dark})> themeDataProvider =
    Provider<({ThemeData light, ThemeData dark})>((Ref ref) {
  final AppSchemes schemes = ref.watch(effectiveSchemesProvider);
  final bool expressive =
      ref.watch(settingsControllerProvider.select((s) => s.useMaterialExpressive));

  return (
    light: AppTheme.build(scheme: schemes.light, expressive: expressive),
    dark: AppTheme.build(scheme: schemes.dark, expressive: expressive),
  );
});
