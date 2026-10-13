import 'package:flutter/material.dart';

/// Seed-цвета для Material 3 Expressive.
///
/// Expressive-палитра любит насыщенные, «сочные» источники — из них
/// `ColorScheme.fromSeed` строит более контрастные роли.
@immutable
class SeedColor {
  const SeedColor(this.name, this.color);

  final String name;
  final Color color;
}

/// Набор предустановленных палитр. Первый элемент — значение по умолчанию.
const List<SeedColor> kSeedColors = <SeedColor>[
  SeedColor('Индиго', Color(0xFF4F46E5)),
  SeedColor('Фиолетовый', Color(0xFF8B5CF6)),
  SeedColor('Розовый', Color(0xFFEC4899)),
  SeedColor('Красный', Color(0xFFEF4444)),
  SeedColor('Оранжевый', Color(0xFFF97316)),
  SeedColor('Янтарный', Color(0xFFF59E0B)),
  SeedColor('Лаймовый', Color(0xFF84CC16)),
  SeedColor('Зелёный', Color(0xFF22C55E)),
  SeedColor('Бирюзовый', Color(0xFF14B8A6)),
  SeedColor('Голубой', Color(0xFF06B6D4)),
  SeedColor('Синий', Color(0xFF3B82F6)),
  SeedColor('Серый', Color(0xFF64748B)),
];

/// Режим выбора темы.
enum ThemeModePreference {
  system('Как в системе'),
  light('Светлая'),
  dark('Тёмная');

  const ThemeModePreference(this.label);

  final String label;

  ThemeMode get themeMode => switch (this) {
        ThemeModePreference.system => ThemeMode.system,
        ThemeModePreference.light => ThemeMode.light,
        ThemeModePreference.dark => ThemeMode.dark,
      };

  static ThemeModePreference fromName(String? name) {
    return ThemeModePreference.values.firstWhere(
      (ThemeModePreference m) => m.name == name,
      orElse: () => ThemeModePreference.system,
    );
  }
}

/// Откуда брать палитру.
enum ColorSource {
  seed('Акцентный цвет'),
  artwork('Из обложки трека');

  const ColorSource(this.label);

  final String label;

  static ColorSource fromName(String? name) => ColorSource.values.firstWhere(
        (ColorSource s) => s.name == name,
        orElse: () => ColorSource.seed,
      );
}
