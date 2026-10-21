import 'dart:io';

import 'package:meta/meta.dart';

/// Единственный источник текущей версии приложения.
///
/// Сначала — значение сборки (`MOPS_VERSION`): CI берёт его из тега (`v*`), и
/// только оно есть в релизе, потому что `pubspec.yaml` в поставку не попадает.
/// Без define версия читается из `pubspec.yaml` рядом с рабочим каталогом — это
/// отладочный запуск из репозитория; так версия на экране совпадает с файлом,
/// а не с отдельной константой, которую забывают обновить к тегу.
///
/// Функция живёт здесь, а не на экране «О приложении», потому что её читают
/// двое: сам экран и проверка обновлений. Второй разбор версии разошёлся бы с
/// первым — ровно в тот момент, когда расхождение заметнее всего.
const String kDefinedVersion = String.fromEnvironment('MOPS_VERSION');

String? resolveAppVersion() {
  if (kDefinedVersion.isNotEmpty) return kDefinedVersion;

  try {
    Directory dir = Directory.current;
    for (int depth = 0; depth < 6; depth++) {
      final File file = File(
        '${dir.path}${Platform.pathSeparator}pubspec.yaml',
      );
      if (file.existsSync()) {
        for (final String line in file.readAsLinesSync()) {
          if (!line.startsWith('version:')) continue;
          final String value = line.substring('version:'.length).trim();
          return value.isEmpty ? null : value;
        }
        return null;
      }
      final Directory parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  } on FileSystemException {
    return null;
  }
  return null;
}

/// Разобранная версия: числа и, если есть, предварительная метка.
///
/// Сравнивать строки нельзя: «v0.2.10» лексикографически больше «v0.2.9», а
/// «v0.10.0» — меньше «v0.9.0». Тег релиза приходит с `v`, `pubspec` — с
/// номером сборки после `+`, поэтому разбор терпит оба вида.
@immutable
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, [this.prerelease = '']);

  final int major;
  final int minor;
  final int patch;

  /// Метка предварительной версии без ведущего дефиса (`home.1`, `beta`).
  /// Пустая строка — стабильная версия.
  final String prerelease;

  bool get isPrerelease => prerelease.isNotEmpty;

  /// Разбирает `v1.2.3`, `1.2.3+4`, `v0.2.12-home.1`; мусор даёт `null`.
  static AppVersion? tryParse(String? raw) {
    if (raw == null) return null;
    String text = raw.trim();
    if (text.isEmpty) return null;
    if (text[0] == 'v' || text[0] == 'V') text = text.substring(1);

    // Номер сборки (`+1`) к сравнению версий отношения не имеет.
    final int plus = text.indexOf('+');
    if (plus >= 0) text = text.substring(0, plus);

    String core = text;
    String prerelease = '';
    final int dash = text.indexOf('-');
    if (dash >= 0) {
      core = text.substring(0, dash);
      prerelease = text.substring(dash + 1);
    }

    final List<String> parts = core.split('.');
    if (parts.isEmpty || parts.length > 3) return null;

    final List<int> numbers = <int>[];
    for (final String part in parts) {
      final int? value = int.tryParse(part);
      if (value == null || value < 0) return null;
      numbers.add(value);
    }
    while (numbers.length < 3) {
      numbers.add(0);
    }
    return AppVersion(numbers[0], numbers[1], numbers[2], prerelease);
  }

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    return _comparePrerelease(prerelease, other.prerelease);
  }

  /// Правила SemVer: стабильная версия новее своей предварительной, а метки
  /// сравниваются по частям — числовые как числа, текстовые как строки.
  static int _comparePrerelease(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return 1;
    if (b.isEmpty) return -1;

    final List<String> left = a.split('.');
    final List<String> right = b.split('.');
    final int length = left.length < right.length ? left.length : right.length;
    for (int i = 0; i < length; i++) {
      final int? leftNumber = int.tryParse(left[i]);
      final int? rightNumber = int.tryParse(right[i]);
      if (leftNumber != null && rightNumber != null) {
        if (leftNumber != rightNumber) {
          return leftNumber.compareTo(rightNumber);
        }
      } else if (leftNumber != null) {
        // Числовая часть всегда младше текстовой.
        return -1;
      } else if (rightNumber != null) {
        return 1;
      } else {
        final int byText = left[i].compareTo(right[i]);
        if (byText != 0) return byText;
      }
    }
    return left.length.compareTo(right.length);
  }

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, prerelease);

  @override
  String toString() =>
      prerelease.isEmpty ? '$major.$minor.$patch' : '$major.$minor.$patch-$prerelease';
}
