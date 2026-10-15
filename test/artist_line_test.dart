import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Имя исполнителя — ссылка внутри текста. Нажатие по ней не должно заодно
/// срабатывать как нажатие по контейнеру под ней (карточке, строке списка):
/// иначе вместо страницы исполнителя открывалась бы страница элемента.
void main() {
  testWidgets('ссылка в тексте перехватывает нажатие у контейнера',
      (WidgetTester tester) async {
    int link = 0;
    int container = 0;
    final TapGestureRecognizer recognizer = TapGestureRecognizer()
      ..onTap = () => link++;
    addTearDown(recognizer.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: InkWell(
            onTap: () => container++,
            child: Text.rich(
              TextSpan(children: <InlineSpan>[
                const TextSpan(text: 'текст '),
                TextSpan(text: 'исполнитель', recognizer: recognizer),
                const TextSpan(text: ' хвост'),
              ]),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    await tester.tap(find.textContaining('исполнитель'));
    await tester.pump();

    expect(link, 1, reason: 'ссылка должна сработать');
    expect(container, 0,
        reason: 'нажатие по ссылке не должно открывать контейнер');
  });
}
