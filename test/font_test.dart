import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mops/core/theme/app_theme.dart';
import 'package:mops/core/theme/custom_font.dart';

/// Проверка шрифтов: кириллица не должна исчезать ни в одном варианте, а
/// «свой» шрифт должен честно сообщать, есть ли в нём русские буквы.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Корень пакета: `flutter test` запускается из каталога проекта.
  String packageFile(String relative) {
    Directory dir = Directory.current;
    for (int i = 0; i < 8; i++) {
      final String marker = '${dir.path}${Platform.pathSeparator}pubspec.yaml';
      if (File(marker).existsSync()) {
        return '${dir.path}${Platform.pathSeparator}$relative';
      }
      final Directory parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return relative;
  }

  group('шрифт темы', () {
    tearDown(() => AppTheme.font = const AppFont.poppins());

    TextTheme textThemeOf(AppFont font) {
      AppTheme.font = font;
      return AppTheme.build(
        scheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ).textTheme;
    }

    test('Poppins — как было', () {
      final TextTheme text = textThemeOf(const AppFont.poppins());
      expect(text.bodyMedium?.fontFamily, 'Poppins');
      expect(text.bodyMedium?.fontFamilyFallback, contains('Montserrat'));
    });

    test('системный не навязывает семейство, но кириллицу подстрахует',
        () {
      final TextTheme text = textThemeOf(const AppFont.system());
      expect(text.bodyMedium?.fontFamily, isNot('Poppins'));
      expect(text.bodyMedium?.fontFamilyFallback, contains('Montserrat'));
    });

    test('свой шрифт идёт с фоллбеком Montserrat', () {
      final TextTheme text = textThemeOf(const AppFont.custom());
      expect(text.bodyMedium?.fontFamily, kCustomFontFamily);
      expect(text.bodyMedium?.fontFamilyFallback, contains('Montserrat'));
    });
  });

  group('файл шрифта', () {
    test('Poppins без кириллицы — предупреждение честное', () async {
      final CustomFontStatus status = await CustomFonts.load(
        packageFile('assets/fonts/Poppins-400.ttf'),
      );
      expect(status.error, isNull);
      expect(status.hasCyrillic, isFalse);
      expect(status.fileName, 'Poppins-400.ttf');
    });

    test('в Montserrat кириллица есть', () async {
      final CustomFontStatus status = await CustomFonts.load(
        packageFile('assets/fonts/Montserrat-400.ttf'),
      );
      expect(status.error, isNull);
      expect(status.hasCyrillic, isTrue);
    });

    test('отсутствующий файл не применяется', () async {
      final CustomFontStatus status = await CustomFonts.load(
        packageFile('assets/fonts/Нет-такого-шрифта.ttf'),
      );
      expect(status.loaded, isFalse);
      expect(status.error, contains('не найден'));
    });

    test('пустой путь — понятная причина, а не исключение', () async {
      final CustomFontStatus status = await CustomFonts.load('   ');
      expect(status.loaded, isFalse);
      expect(status.error, isNotNull);
    });
  });
}
