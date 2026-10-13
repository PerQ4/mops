// Проверка определения системного масштаба: реальные конфиги GNOME и KDE
// подменяются файлами во временном каталоге, поэтому тест не зависит
// от рабочего стола и графики.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mops/core/theme/ui_scaler.dart';
import 'package:mops/state/ui_scale.dart';

void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('mops-dpi-');
    // Подменяем окружение: HOME указывает на временный каталог,
    // остальные переменные отсутствуют.
    envReaderOverride = (String name) => name == 'HOME' ? home.path : null;
  });

  tearDown(() {
    envReaderOverride = null;
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  void writeConfig(String relativePath, String content) {
    final File file = File('${home.path}/$relativePath');
    file.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  test('по умолчанию масштаб не применяется', () {
    final DesktopScaleInfo info = detectDesktopScaleInfo();

    expect(info.scale, 1.0);
    expect(info.isDefault, isTrue);
  });

  test('читает дробный масштаб GNOME из monitors.xml', () {
    // Так GNOME хранит масштаб 125% — именно его GTK3 не передаёт Flutter.
    writeConfig('.config/monitors.xml', '''
<monitors version="2">
  <configuration>
    <logicalmonitor>
      <x>0</x><y>0</y>
      <scale>1.25</scale>
      <primary>yes</primary>
    </logicalmonitor>
    <logicalmonitor>
      <x>1920</x><y>0</y>
      <scale>1</scale>
    </logicalmonitor>
  </configuration>
</monitors>
''');

    final DesktopScaleInfo info = detectDesktopScaleInfo();

    expect(info.scale, 1.25);
    expect(info.source, contains('GNOME'));
    expect(info.isDefault, isFalse);
  });

  test('берёт масштаб основного монитора, а не первого в списке', () {
    writeConfig('.config/monitors.xml', '''
<monitors version="2">
  <configuration>
    <logicalmonitor>
      <x>0</x><y>0</y>
      <scale>1</scale>
    </logicalmonitor>
    <logicalmonitor>
      <x>1920</x><y>0</y>
      <scale>2</scale>
      <primary>yes</primary>
    </logicalmonitor>
  </configuration>
</monitors>
''');

    expect(detectDesktopScaleInfo().scale, 2.0);
  });

  test('читает ScaleFactor из kdeglobals', () {
    writeConfig('.config/kdeglobals', '''
[General]
ScaleFactor=1.5
[KDE]
AnimationDurationFactor=1
''');

    final DesktopScaleInfo info = detectDesktopScaleInfo();

    expect(info.scale, 1.5);
    expect(info.source, contains('KDE'));
  });

  test('переменная MOPS_UI_SCALE имеет наивысший приоритет', () {
    writeConfig('.config/monitors.xml', '''
<monitors version="2">
  <configuration>
    <logicalmonitor><scale>1.25</scale><primary>yes</primary></logicalmonitor>
  </configuration>
</monitors>
''');

    envReaderOverride = (String name) => switch (name) {
          'HOME' => home.path,
          'MOPS_UI_SCALE' => '1.75',
          _ => null,
        };

    final DesktopScaleInfo info = detectDesktopScaleInfo();

    expect(info.scale, 1.75);
    expect(info.source, contains('MOPS_UI_SCALE'));
  });

  test('переменные GDK перемножаются между собой', () {
    // GDK_SCALE=2 и GDK_DPI_SCALE=0.5 в сумме дают 1.0 — двойного роста нет.
    envReaderOverride = (String name) => switch (name) {
          'HOME' => home.path,
          'GDK_SCALE' => '2',
          'GDK_DPI_SCALE' => '0.5',
          _ => null,
        };

    expect(detectDesktopScaleInfo().scale, 1.0);
  });

  test('берётся максимум из источников, а не произведение', () {
    // GNOME просит 1.25, Qt-переменная говорит 1.5 — берём 1.5, не 1.875.
    writeConfig('.config/monitors.xml', '''
<monitors version="2">
  <configuration>
    <logicalmonitor><scale>1.25</scale><primary>yes</primary></logicalmonitor>
  </configuration>
</monitors>
''');

    envReaderOverride = (String name) => switch (name) {
          'HOME' => home.path,
          'QT_SCALE_FACTOR' => '1.5',
          _ => null,
        };

    expect(detectDesktopScaleInfo().scale, 1.5);
  });

  group('компенсация масштаба', () {
    test('система уже масштабирует (GNOME 125%, DPR 2.0) — не вмешиваемся', () {
      // Именно этот случай на целевой машине: Mutter отдаёт DPR 2 и сам
      // понижает масштаб до 1.25, поэтому интерфейс уже верный.
      expect(
        computeUiCompensation(
          const DesktopScaleInfo(scale: 1.25, source: 'test'),
          2.0,
        ),
        1.0,
      );
    });

    test('движок масштаб не получил (GNOME 125%, DPR 1.0) — увеличиваем', () {
      expect(
        computeUiCompensation(
          const DesktopScaleInfo(scale: 1.25, source: 'test'),
          1.0,
        ),
        closeTo(1.25, 0.001),
      );
    });

    test('GTK3 и дробный масштаб 150% при DPR 1.0', () {
      expect(
        computeUiCompensation(
          const DesktopScaleInfo(scale: 1.5, source: 'test'),
          1.0,
        ),
        closeTo(1.5, 0.001),
      );
    });

    test('целочисленный масштаб не требует изменений', () {
      expect(
        computeUiCompensation(
          const DesktopScaleInfo(scale: 2.0, source: 'test'),
          2.0,
        ),
        1.0,
      );
    });

    test('никогда не уменьшает интерфейс автоматически', () {
      // Даже если система просит меньше, чем отдаёт движок, уменьшать нельзя:
      // так работает понижение масштаба в Mutter.
      for (final double dpr in <double>[1.5, 2.0, 2.5, 3.0]) {
        final double k = computeUiCompensation(
          const DesktopScaleInfo(scale: 1.25, source: 'test'),
          dpr,
        );
        expect(k, 1.0, reason: 'DPR $dpr не должен приводить к уменьшению');
      }
    });

    test('без данных о системе масштаб не меняется', () {
      expect(computeUiCompensation(DesktopScaleInfo.none, 2.0), 1.0);
      expect(computeUiCompensation(DesktopScaleInfo.none, 1.0), 1.0);
    });

    test('нулевой DPR не приводит к делению на ноль', () {
      expect(
        computeUiCompensation(
          const DesktopScaleInfo(scale: 1.25, source: 'test'),
          0,
        ),
        1.0,
      );
    });
  });
}
