import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/shell.dart';
import '../explore/explore_screen.dart';
import '../home/home_screen.dart';
import '../library/library_screen.dart';
import '../search/search_screen.dart';

/// Ключ вложенного навигатора области содержимого.
///
/// Подэкраны (альбом, плейлист, исполнитель, настройки) открываются внутри
/// него, а не поверх всей оболочки: тогда плавающий док остаётся видимым.
/// Ключ глобальный, потому что маршруты открываются ещё и из виджетов,
/// лежащих вне этого навигатора — например, из островка плеера.
final GlobalKey<NavigatorState> contentNavigatorKey =
    GlobalKey<NavigatorState>();

/// Область содержимого со своим стеком маршрутов.
///
/// Первый маршрут держит верхнеуровневые разделы как [IndexedStack] — так их
/// состояние (прокрутка, вкладки) сохраняется при переключении, как и раньше.
/// Всё, что открывается поверх, — подэкраны внутри того же навигатора.
class ContentNavigator extends StatelessWidget {
  const ContentNavigator({super.key});

  @override
  Widget build(BuildContext context) {
    // NavigatorPopHandler связывает системную кнопку «назад» (Android, жесты)
    // с вложенным навигатором. Без него back уходил бы в корневой навигатор,
    // не находил там маршрута и закрывал приложение вместо подэкрана.
    return NavigatorPopHandler<Object?>(
      onPopWithResult: (Object? _) =>
          contentNavigatorKey.currentState?.maybePop(),
      child: Navigator(
        key: contentNavigatorKey,
        onGenerateRoute: (RouteSettings settings) => MaterialPageRoute<void>(
          settings: settings,
          builder: (BuildContext context) => const _ContentRoot(),
        ),
      ),
    );
  }
}

/// Верхнеуровневые разделы: переключаются индексом, без пересоздания.
class _ContentRoot extends ConsumerWidget {
  const _ContentRoot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int index = ref.watch(shellIndexProvider);

    return IndexedStack(
      index: index,
      children: const <Widget>[
        HomeScreen(),
        ExploreScreen(),
        SearchScreen(),
        LibraryScreen(),
      ],
    );
  }
}

/// Переключает раздел верхнего уровня и убирает подэкраны.
///
/// Без сброса стека после перехода, например, в «Поиск» пользователь видел бы
/// поверх него ранее открытый альбом: раздел менялся бы «под» чужим экраном.
void selectShellDestination(WidgetRef ref, int index) {
  ref.read(shellIndexProvider.notifier).select(index);
  contentNavigatorKey.currentState?.popUntil(
    (Route<dynamic> route) => route.isFirst,
  );
}
