import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mops/features/shell/content_navigator.dart';
import 'package:mops/widgets/back_gesture.dart';

/// Жест «назад»: свайп двумя пальцами по тачпаду и Alt+← должны закрывать
/// верхний экран, а короткий свайп — нет.
void main() {
  Future<void> pumpTwoScreens(WidgetTester tester) async {
    // `BackGesture` ставим в `builder` — как в приложении: тогда он оборачивает
    // навигатор целиком, и события от новых экранов тоже доходят до него.
    await tester.pumpWidget(MaterialApp(
      navigatorKey: rootNavigatorKey,
      builder: (BuildContext context, Widget? child) =>
          BackGesture(child: child ?? const SizedBox.shrink()),
      home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (BuildContext _) =>
                        const Scaffold(body: Text('второй экран')),
                  ),
                ),
                child: const Text('первый экран'),
              ),
            ),
          ),
        ),
    ));
    await tester.tap(find.text('первый экран'));
    await tester.pumpAndSettle();
    expect(find.text('второй экран'), findsOneWidget);
  }

  testWidgets('свайп двумя пальцами возвращает назад',
      (WidgetTester tester) async {
    await pumpTwoScreens(tester);

    final TestGesture gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(const Offset(200, 300));
    await gesture.panZoomUpdate(
      const Offset(360, 300),
      pan: const Offset(160, 0),
    );
    await gesture.panZoomEnd();
    await tester.pumpAndSettle();

    expect(find.text('второй экран'), findsNothing,
        reason: 'свайп вправо должен закрыть верхний экран');
    expect(find.text('первый экран'), findsOneWidget);
  });

  testWidgets('короткий свайп ничего не закрывает',
      (WidgetTester tester) async {
    await pumpTwoScreens(tester);

    final TestGesture gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(const Offset(200, 300));
    await gesture.panZoomUpdate(
      const Offset(240, 300),
      pan: const Offset(40, 0),
    );
    await gesture.panZoomEnd();
    await tester.pumpAndSettle();

    expect(find.text('второй экран'), findsOneWidget,
        reason: 'сорок пикселей — это ещё не жест');
  });

  testWidgets('Alt+влево возвращает назад', (WidgetTester tester) async {
    await pumpTwoScreens(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();

    expect(find.text('второй экран'), findsNothing);
  });
}
