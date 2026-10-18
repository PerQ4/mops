import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mops/widgets/horizontal_list.dart';
import 'package:mops/widgets/media_card.dart';

/// Карточки лент: обложка запускает, подпись открывает, а сама лента листается
/// колесом мыши. Вертикальное колесо над лентой при этом листает страницу —
/// лента его не перехватывает (см. комментарий в `horizontal_list.dart`).
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

  // Лента всегда лежит внутри вертикальной страницы, поэтому проверяем её
  // поведение именно там: важно, чтобы обычное (вертикальное) колесо не
  // «застревало» на ленте, а листало страницу.
  Widget pageWithList(ScrollController pageController) => MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: pageController,
            children: <Widget>[
              // Отступ сверху такой, чтобы лента сразу попала в видимую
              // область: ленивый `ListView` не строит детей за кадром.
              const SizedBox(height: 200),
              Center(
                child: HorizontalList(
                  height: 100,
                  separator: 8,
                  itemCount: 20,
                  itemBuilder: (BuildContext context, int index) =>
                      SizedBox(width: 120, child: Text('карточка $index')),
                ),
              ),
              const SizedBox(height: 600),
            ],
          ),
        ),
      );

  ScrollableState listScrollable(WidgetTester tester) =>
      tester.state<ScrollableState>(find.descendant(
        of: find.byType(HorizontalList),
        matching: find.byType(Scrollable),
      ));

  testWidgets('лента прокручивается колесом мыши', (WidgetTester tester) async {
    final ScrollController pageController = ScrollController();
    addTearDown(pageController.dispose);
    await tester.pumpWidget(pageWithList(pageController));
    await tester.pump();

    final ScrollableState scrollable = listScrollable(tester);
    expect(scrollable.position.pixels, 0);

    // Горизонтальное колесо (наклонное или сдвиг тачпадом вбок) приходит уже
    // горизонтальным и листает ленту само — перехватывать его не нужно.
    final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
    final Offset center = tester.getCenter(find.byType(HorizontalList));
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(200, 0)));
    await tester.pump();

    expect(scrollable.position.pixels, greaterThan(0),
        reason: 'колесо должно прокручивать ленту');
    expect(pageController.position.pixels, 0,
        reason: 'горизонтальное колесо не должно двигать страницу');
  });

  testWidgets('вертикальное колесо над лентой листает страницу, а не ленту',
      (WidgetTester tester) async {
    final ScrollController pageController = ScrollController();
    addTearDown(pageController.dispose);
    await tester.pumpWidget(pageWithList(pageController));
    await tester.pump();

    final ScrollableState scrollable = listScrollable(tester);

    // Раньше лента превращала вертикальное колесо в горизонтальную прокрутку
    // и гасила событие, из-за чего страница под ней не листалась. Теперь
    // колесо проходит насквозь — это и есть ожидаемое поведение.
    final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
    final Offset center = tester.getCenter(find.byType(HorizontalList));
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 200)));
    await tester.pump();

    expect(pageController.position.pixels, greaterThan(0),
        reason: 'вертикальное колесо должно листать страницу');
    expect(scrollable.position.pixels, 0,
        reason: 'лента не должна перехватывать вертикальное колесо');
  });
}
