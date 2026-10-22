import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mops/core/audio/audio_engine.dart';
import 'package:mops/core/theme/ui_scaler.dart';
import 'package:mops/data/local/app_settings.dart';
import 'package:mops/data/models/models.dart';
import 'package:mops/features/player/lyrics_view.dart';
import 'package:mops/state/catalog_providers.dart';
import 'package:mops/state/lyrics_edits.dart';
import 'package:mops/state/player_controller.dart';
import 'package:mops/state/providers.dart';
import 'package:mops/state/theme_providers.dart';

/// Кегль, с которым список меряет строки в этих тестах.
const double _baseSize = 22;

LyricsLook _look(
  LyricsMode mode, {
  double? activeScale,
  double inactiveOpacity = 1,
  double lineSpacing = 1.35,
  LyricsTextAlign align = LyricsTextAlign.left,
}) {
  return LyricsLook(
    mode: mode,
    animation: LyricsAnimationStyle.fade,
    blurEnabled: true,
    lineSpacing: lineSpacing,
    activeScale: activeScale ?? _settingsFor(mode).effectiveActiveLineScale,
    inactiveOpacity: inactiveOpacity,
    align: align,
  );
}

LyricsSettings _settingsFor(LyricsMode mode) =>
    LyricsSettings(lyricsMode: mode);

LyricsLineLayout _layout(
  LyricsLook look, {
  required int distance,
  bool active = false,
  double step = 1,
}) {
  return look.layoutFor(
    baseSize: _baseSize,
    distance: distance,
    step: step,
    active: active,
    manual: false,
    visible: true,
  );
}

void main() {
  group('раскладка строки', () {
    test('смена активной строки не меняет габарит ни в одном виде', () {
      for (final LyricsMode mode in LyricsMode.values) {
        final LyricsLook look = _look(mode);
        final LyricsLineLayout active = _layout(look, distance: 0, active: true);
        final LyricsLineLayout neighbour =
            _layout(look, distance: 1, step: 2);
        final LyricsLineLayout far = _layout(look, distance: 5, step: 2);

        for (final LyricsLineLayout other in <LyricsLineLayout>[neighbour, far]) {
          expect(other.fontSize, active.fontSize, reason: '$mode: кегль');
          expect(other.height, active.height, reason: '$mode: высота');
        }
        // Высота строки — ровно базовый кегль с межстрочным интервалом: по
        // ней стоят соседи, и активность в неё не входит.
        expect(active.height, _baseSize * 1.35);
      }
    });

    test('бывшая активная строка становится соседкой без сдвига', () {
      final LyricsLook look = _look(LyricsMode.v2);
      // Одна и та же строка до и после переезда подсветки: габарит тот же,
      // меняется только отрисовка.
      final LyricsLineLayout before = _layout(look, distance: 0, active: true);
      final LyricsLineLayout after = _layout(look, distance: 1);
      expect(after.height, before.height);
      expect(after.visualSize, lessThan(before.visualSize));
    });
  });

  group('настройки вида', () {
    test('по умолчанию крупность активной строки — как у вида', () {
      expect(_settingsFor(LyricsMode.classic).effectiveActiveLineScale, 1.0);
      expect(_settingsFor(LyricsMode.v2).effectiveActiveLineScale, 1.3);
      expect(_settingsFor(LyricsMode.enhanced).effectiveActiveLineScale, 1.14);
      // Явный выбор вида не перебивает настройку, а задаёт её умолчание.
      expect(
        _settingsFor(LyricsMode.v2)
            .copyWith(lyricsActiveLineScale: 1.0)
            .effectiveActiveLineScale,
        1.0,
      );
    });

    test('масштаб меняет отрисовку, но не раскладку', () {
      final LyricsLook normal = _look(LyricsMode.v2);
      final LyricsLook flat = _look(LyricsMode.v2, activeScale: 1.0);

      final LyricsLineLayout activeNormal =
          _layout(normal, distance: 0, active: true);
      final LyricsLineLayout activeFlat =
          _layout(flat, distance: 0, active: true);

      expect(activeNormal.height, activeFlat.height);
      expect(activeNormal.visualSize, closeTo(_baseSize * 1.3, 0.001));
      expect(activeFlat.visualSize, closeTo(_baseSize, 0.001));

      // Соседи от настройки не зависят: она про активную строку.
      expect(
        _layout(flat, distance: 1).visualSize,
        _layout(normal, distance: 1).visualSize,
      );
    });

    test('соседка на дробном шаге не крупнее активной строки', () {
      final LyricsLook flat = _look(LyricsMode.v2, activeScale: 1.0);
      // На широком экране видно больше строк, и первая соседка попадает
      // между ступенями таблицы.
      for (final int distance in <int>[1, 2, 3]) {
        expect(
          flat.sizeScale(distance, 4),
          lessThanOrEqualTo(flat.activeScale),
          reason: 'расстояние $distance',
        );
      }
    });

    test('классический вид не меняет кегль по расстоянию', () {
      final LyricsLook look = _look(LyricsMode.classic);
      expect(look.sizeScale(0, 1), 1.0);
      expect(look.sizeScale(1, 1), 1.0);
      expect(look.sizeScale(4, 1), 1.0);
      expect(look.restingScale, 0.95);
    });

    test('прозрачность неактивных строк — множитель к лестнице вида', () {
      final LyricsLook normal = _look(LyricsMode.v2);
      final LyricsLook dim = _look(LyricsMode.v2, inactiveOpacity: 0.5);

      expect(normal.alpha(0, 1, manual: false, active: true), 1.0);
      expect(normal.alpha(1, 1, manual: false, active: false), 0.42);
      expect(dim.alpha(1, 1, manual: false, active: false), closeTo(0.21, 1e-9));
      // Активная строка не гаснет никогда.
      expect(dim.alpha(0, 1, manual: false, active: true), 1.0);
    });

    test('выравнивание по центру не меняет габарит', () {
      final LyricsLook left = _look(LyricsMode.v2);
      final LyricsLook center = _look(LyricsMode.v2, align: LyricsTextAlign.center);
      expect(
        _layout(center, distance: 0, active: true).height,
        _layout(left, distance: 0, active: true).height,
      );
      expect(center.scaleAlignment, Alignment.center);
      expect(left.scaleAlignment, Alignment.centerLeft);
    });
  });

  group('настройки текста по умолчанию дают прежний вид', () {
    test('значения по умолчанию', () {
      const LyricsSettings lyrics = LyricsSettings();
      expect(lyrics.lyricsActiveLineScale, 0);
      expect(lyrics.hasCustomActiveLineScale, isFalse);
      expect(lyrics.lyricsInactiveOpacity, 1.0);
      expect(lyrics.lyricsTextAlign, LyricsTextAlign.left);
      expect(lyrics.lyricsColumnWidth, LyricsColumnWidth.normal);
      expect(lyrics.lyricsAutoScroll, isTrue);
    });

    test('сохранение и разбор настроек', () {
      final LyricsSettings custom = const LyricsSettings().copyWith(
        lyricsMode: LyricsMode.v2,
        lyricsActiveLineScale: 1.4,
        lyricsInactiveOpacity: 0.6,
        lyricsTextAlign: LyricsTextAlign.center,
        lyricsColumnWidth: LyricsColumnWidth.narrow,
        lyricsAutoScroll: false,
      );
      final LyricsSettings restored =
          LyricsSettings.fromJson(custom.toJson());
      expect(restored.toJson(), custom.toJson());
      expect(restored.effectiveActiveLineScale, 1.4);
      expect(restored.lyricsAutoScroll, isFalse);
    });
  });

  group('список строк', () {
    testWidgets('смена активной строки не двигает ни одну строку',
        (WidgetTester tester) async {
      // Список проверяем целиком: раскладка строки может быть постоянной, а
      // виджет всё равно пересчитает габарит — например, если кегль попадёт в
      // сам `Text`.
      tester.view.physicalSize = const Size(700, 320);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      const int lineCount = 10;
      final Lyrics lyrics = Lyrics(
        timed: <TimedLyric>[
          for (int i = 0; i < lineCount; i++)
            TimedLyric(
              time: Duration(seconds: i * 4),
              text: 'Строка $i',
            ),
        ],
      );
      final LyricsSearchState state = LyricsSearchState(
        candidates: <LyricsCandidate>[
          LyricsCandidate.from(
            source: LyricsSource.lrclib,
            lyrics: lyrics,
            score: 100,
          ),
        ],
      );
      // Увеличение активной строки и автопрокрутка — предмет проверки,
      // остальное по умолчанию. Автопрокрутка выключена: иначе список уезжает
      // сам, и сдвиг строк не отличить от перестройки раскладки.
      const AppSettings settings = AppSettings(
        lyrics: LyricsSettings(
          lyricsMode: LyricsMode.v2,
          lyricsAutoScroll: false,
          romanizeJapanese: false,
          romanizeKorean: false,
          romanizeChinese: false,
          romanizeHindi: false,
          romanizeOther: false,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            initialSettingsProvider.overrideWithValue(settings),
            desktopScaleProvider.overrideWithValue(DesktopScaleInfo.none),
            playerControllerProvider.overrideWith(
              () => _StubPlayer(
                const PlayerUiState(
                  playback: PlaybackState(
                    status: PlaybackStatus.playing,
                    position: Duration(seconds: 2),
                    duration: Duration(minutes: 3),
                  ),
                ),
              ),
            ),
            lyricsProvider.overrideWith(
              (Ref ref, LyricsRequest request) =>
                  Stream<LyricsSearchState>.value(state),
            ),
          ],
          child: const _Harness(child: LyricsView(videoId: 'vid00000000001')),
        ),
      );
      // Тикер текста идёт постоянно, поэтому `pumpAndSettle` здесь не годится:
      // кадры прокручиваем сами, давая переходам строк дойти до конца.
      Future<void> settle() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 800));
      }

      await settle();

      double contentExtent() =>
          tester.state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .maxScrollExtent;

      List<Size> lineSizes() => <Size>[
            for (int i = 0; i < lineCount; i++)
              tester.getSize(find.text('Строка $i')),
          ];

      // Визуальный множитель строки — её единственный `Transform`.
      double lineScale(int index) => tester
          .widget<Transform>(
            find
                .ancestor(
                  of: find.text('Строка $index'),
                  matching: find.byType(Transform),
                )
                .first,
          )
          .transform
          .getMaxScaleOnAxis();

      final double extentBefore = contentExtent();
      final List<Size> sizesBefore = lineSizes();
      final List<double> scalesBefore = <double>[
        for (int i = 0; i < lineCount; i++) lineScale(i),
      ];
      final int activeBefore = scalesBefore.indexOf(
        scalesBefore.reduce((double a, double b) => a > b ? a : b),
      );
      expect(scalesBefore[activeBefore], closeTo(1.3, 1e-6));

      // Та же песня, сдвиг текста на 16 секунд: активной становится другая
      // строка, остальное на экране не меняется.
      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(LyricsView)),
      );
      container.read(lyricsOffsetProvider.notifier).nudge(
            'vid00000000001',
            -16000,
          );
      await settle();

      expect(contentExtent(), closeTo(extentBefore, 0.01));
      expect(lineSizes(), sizesBefore);

      final List<double> scalesAfter = <double>[
        for (int i = 0; i < lineCount; i++) lineScale(i),
      ];
      final int activeAfter = scalesAfter.indexOf(
        scalesAfter.reduce((double a, double b) => a > b ? a : b),
      );
      expect(activeAfter, isNot(activeBefore));
      expect(scalesAfter[activeAfter], closeTo(1.3, 1e-6));
      expect(scalesAfter[activeBefore], lessThan(1.3));
    });
  });
}

/// Игрок без движка и таймеров: тексту нужна только позиция.
class _StubPlayer extends PlayerController {
  _StubPlayer(this._preset);

  final PlayerUiState _preset;

  @override
  PlayerUiState build() => _preset;
}

/// Обёртка как в приложении: тема и локали.
class _Harness extends ConsumerWidget {
  const _Harness({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ({ThemeData light, ThemeData dark}) themes =
        ref.watch(themeDataProvider);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: themes.light,
      darkTheme: themes.dark,
      themeMode: ThemeMode.dark,
      home: child,
    );
  }
}
