import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mops/widgets/horizontal_list.dart';
import 'package:mops/widgets/media_card.dart';

/// Карточки лент: обложка запускает, подпись открывает страницу, а сама
/// лента прокручивается колесом мыши.
void main() {
  testWidgets('обложка запускает, подпись открывает', (WidgetTester tester) async {
    int plays = 0;
    int opens = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: MediaCard(
            title: 'Название',
            subtitle: 'Исполнитель',
            width: 128,
            showPlay: true,
            onPlay: () => plays++,
            onTap: () => opens++,
          ),
        ),
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('Название'));
    expect(opens, 1, reason: 'подпись должна открывать страницу');
    expect(plays, 0);

    await tester.tap(find.text('Исполнитель'));
    expect(opens, 2);

    // Кнопка play на обложке — тоже запуск.
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    expect(plays, 1, reason: 'кнопка на обложке должна запускать');
    expect(opens, 2);
  });

  testWidgets('лента прокручивается колесом мыши', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: HorizontalList(
            height: 100,
            separator: 8,
            itemCount: 20,
            itemBuilder: (BuildContext context, int index) =>
                SizedBox(width: 120, child: Text('карточка $index')),
          ),
        ),
      ),
    ));
    await tester.pump();

    final Finder list = find.byType(ListView);
    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.descendant(of: list, matching: find.byType(Scrollable)),
    );
    expect(scrollable.position.pixels, 0);

    // Вертикальное колесо над лентой должно двигать её по горизонтали.
    final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
    final Offset center = tester.getCenter(list);
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(
      pointer.scroll(const Offset(0, 200)),
    );
    await tester.pump();

    expect(scrollable.position.pixels, greaterThan(0),
        reason: 'колесо должно прокручивать ленту');
  });
}
