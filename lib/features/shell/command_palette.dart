import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart' as m3e;

import '../../core/theme/motion.dart';
import '../../data/models/models.dart';
import '../../data/sources/catalog_source.dart';
import '../../state/catalog_providers.dart';
import '../../state/player_controller.dart';
import '../common/navigation.dart';
import 'content_navigator.dart';

/// Открыта ли палитра команд.
///
/// Флаг читают глобальные горячие клавиши (`app_shortcuts.dart`): пока палитра
/// на экране, пробел и стрелки должны работать в ней, а не управлять плеером.
/// Это [ValueNotifier], а не провайдер: состояние чисто интерфейсное и живёт
/// ровно столько, сколько открыт маршрут палитры.
final ValueNotifier<bool> commandPaletteOpen = ValueNotifier<bool>(false);

/// Сколько результатов показываем разом.
///
/// Больше в панель не влезет, а листать её всё равно неудобно: уточнить запрос
/// быстрее, чем прокручивать десятки строк.
const int _maxResults = 30;

/// Открывает палитру команд поверх всего интерфейса.
///
/// Палитра кладётся в **корневой** навигатор: так она перекрывает и
/// полноэкранный плеер, и подэкраны оболочки. Закрывается по Esc, по тапу мимо
/// панели (`barrierDismissible`) и после выбора результата.
Future<void> showCommandPalette(BuildContext context) async {
  if (commandPaletteOpen.value) return;
  final NavigatorState? navigator = rootNavigatorKey.currentState;
  if (navigator == null) return;

  // Цвет затемнения берём ролью темы, а не «чёрным»: в светлой теме скрим
  // тоже должен быть согласован с палитрой.
  final ColorScheme scheme = Theme.of(context).colorScheme;
  commandPaletteOpen.value = true;
  try {
    await navigator.push<void>(
      _CommandPaletteRoute(barrierColor: scheme.scrim.withValues(alpha: 0.55)),
    );
  } finally {
    // Маршрут мог не построиться — снимаем флаг здесь, а не только в dispose,
    // иначе клавиши «залипли» бы выключенными до перезапуска.
    commandPaletteOpen.value = false;
  }
}

/// Маршрут палитры: полупрозрачный, с затемнением фона.
///
/// `barrierDismissible` даёт закрытие по тапу мимо и штатное закрытие по Esc
/// (см. комментарий в `navigation.dart`), а `opaque: false` — видеть интерфейс
/// под панелью, чтобы поиск читался как всплывающий поверх, а не как новый экран.
class _CommandPaletteRoute extends PageRouteBuilder<void> {
  _CommandPaletteRoute({required Color barrierColor})
    : super(
        opaque: false,
        barrierDismissible: true,
        barrierLabel: 'Закрыть поиск',
        barrierColor: barrierColor,
        transitionDuration: AppMotion.overlayEnter.duration,
        reverseTransitionDuration:
            AppMotion.overlayEnter.reverseDuration ??
                AppMotion.overlayEnter.duration,
        pageBuilder: (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) => const _CommandPalette(),
        transitionsBuilder:
            (
              BuildContext context,
              Animation<double> animation,
              Animation<double> secondaryAnimation,
              Widget child,
            ) {
              // Панель «всплывает» сверху — как поиск на рабочем столе.
              return AppMotion.overlayEnter.routeTransition(
                animation: animation,
                begin: const Offset(0, -0.04),
                child: child,
              );
            },
      );
}

/// Сама палитра: поле поиска сверху и список найденного.
///
/// Ищем существующим провайдером `searchResultsProvider` — он уже учитывает
/// настройку «искать онлайн или только в библиотеке», кэширует выдачу и отдаёт
/// секции с `BrowseItem` (трек, альбом, исполнитель, плейлист).
class _CommandPalette extends ConsumerStatefulWidget {
  const _CommandPalette();

  @override
  ConsumerState<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends ConsumerState<_CommandPalette> {
  final TextEditingController _controller = TextEditingController();

  /// Прокрутка списка: при новом запросе возвращаемся к началу выдачи.
  final ScrollController _scroll = ScrollController();

  /// Ключи строк по индексу — по ним список доводится до выделения.
  final Map<int, GlobalKey> _itemKeys = <int, GlobalKey>{};

  /// Задержка перед запросом, чтобы не бить по сети на каждую букву —
  /// как в `search_screen.dart`.
  Timer? _debounce;

  /// Запрос, который реально уходит в поиск (после задержки).
  String _query = '';

  /// Выбранная стрелками строка.
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    commandPaletteOpen.value = true;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    commandPaletteOpen.value = false;
    super.dispose();
  }

  void _onTextChanged() {
    _debounce?.cancel();
    final String next = _controller.text.trim();
    // Очистку применяем сразу: пустой запрос нечего ждать.
    if (next.isEmpty) {
      if (_query.isNotEmpty) setState(() => _query = '');
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted || next == _query) return;
      setState(() {
        _query = next;
        // Новый запрос — выделение снова на первой строке.
        _selected = 0;
        // Строки будут другие, а ключи привязаны к индексам прежней выдачи.
        _itemKeys.clear();
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  void _close() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// Перемещает выделение с «закольцовыванием» по краям.
  void _move(int delta, int count) {
    if (count == 0) return;
    setState(() {
      _selected = (_selected + delta) % count;
      if (_selected < 0) _selected += count;
    });
    _revealSelection(_selected);
  }

  /// Доводит выделенную строку до края списка.
  ///
  /// Список не следит за выделением сам, поэтому без этого шага строка,
  /// ушедшая за край, оставалась невидимой и клавиатура «не работала».
  /// Прокручиваем после кадра: к этому моменту строка разложена, и её ключ
  /// действителен.
  void _revealSelection(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final BuildContext? itemContext = _itemKeys[index]?.currentContext;
      if (itemContext == null) return;
      final RenderObject? target = itemContext.findRenderObject();
      final RenderAbstractViewport? viewport = target == null
          ? null
          : RenderAbstractViewport.maybeOf(target);
      final ScrollableState? scrollable = Scrollable.maybeOf(itemContext);
      if (target == null || viewport == null || scrollable == null) return;

      final ScrollPosition position = scrollable.position;
      // `top` — смещение, при котором строка встанет к верхнему краю,
      // `bottom` — к нижнему. Строка целиком в кадре, если текущее смещение
      // лежит между ними; тогда двигать нечего, иначе стрелка «на месте»
      // прокручивала бы список на каждом нажатии.
      final double top = viewport.getOffsetToReveal(target, 0).offset;
      final double bottom = viewport.getOffsetToReveal(target, 1).offset;
      if (position.pixels <= top && position.pixels >= bottom) return;

      // Выравнивание выбираем по тому, где строка оказалась, а не по
      // направлению движения: при переходе через край (с последней на первую)
      // направление противоположно стороне, куда надо прокрутить.
      unawaited(
        Scrollable.ensureVisible(
          itemContext,
          duration: AppMotion.rowActions.duration,
          curve: AppMotion.rowActions.curve,
          alignment: position.pixels > top ? 0 : 1,
          alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        ),
      );
    });
  }

  /// Открывает выбранный результат: трек играет, остальное открывает страницу.
  void _activate(List<BrowseItem> items, int index) {
    if (items.isEmpty) return;
    final BrowseItem item = items[index.clamp(0, items.length - 1)];

    // Сначала закрываем палитру, потом переходим: иначе панель осталась бы
    // висеть поверх открытой страницы до конца анимации.
    _close();

    switch (item) {
      case TrackItem(:final Track track):
        // Очередью делаем все найденные треки — тогда «дальше» в плеере
        // логично продолжает выдачу, а не обрывается на одном треке.
        final List<Track> queue = items
            .whereType<TrackItem>()
            .map((TrackItem t) => t.track)
            .toList();
        unawaited(
          ref
              .read(playerControllerProvider.notifier)
              .playTrack(track, context: queue),
        );
      case AlbumItem(:final Album album):
        unawaited(AppRoutes.album(context, album.id));
      case ArtistItem(:final Artist artist):
        unawaited(AppRoutes.artist(context, artist.id));
      case PlaylistItem(:final Playlist playlist):
        unawaited(AppRoutes.playlist(context, playlist.id));
    }
  }

  /// Иконка и подпись результата — по типу элемента.
  (IconData, String) _appearance(BrowseItem item) {
    switch (item) {
      case TrackItem(:final Track track):
        return (Icons.music_note, track.artistLine);
      case AlbumItem(:final Album album):
        final String artist = album.artistLine;
        return (Icons.album, artist.isEmpty ? 'Альбом' : artist);
      case ArtistItem():
        return (Icons.person, 'Исполнитель');
      case PlaylistItem():
        return (Icons.queue_music, 'Плейлист');
    }
  }

  /// Разворачивает секции в один список, сохраняя порядок выдачи.
  List<BrowseItem> _flatten(List<BrowseSection> sections) {
    final List<BrowseItem> items = <BrowseItem>[];
    for (final BrowseSection section in sections) {
      for (final BrowseItem item in section.items) {
        items.add(item);
        if (items.length >= _maxResults) return items;
      }
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    final AsyncValue<List<BrowseSection>> results = _query.isEmpty
        ? const AsyncValue<List<BrowseSection>>.data(<BrowseSection>[])
        : ref.watch(
            searchResultsProvider(SearchQuery(_query, SearchFilter.all)),
          );

    final List<BrowseItem> items = _query.isEmpty
        ? const <BrowseItem>[]
        : _flatten(results.value ?? const <BrowseSection>[]);
    final int selected = items.isEmpty
        ? 0
        : _selected.clamp(0, items.length - 1);

    return CallbackShortcuts(
      // Стрелки и Esc перехватываем раньше `DefaultTextEditingShortcuts`:
      // наш `CallbackShortcuts` ближе к полю ввода, поэтому курсор в тексте
      // не поедет, а выделение пойдёт по строкам.
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _move(1, items.length),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _move(-1, items.length),
        const SingleActivator(LogicalKeyboardKey.escape): _close,
      },
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(
            top: 72,
            left: 24,
            right: 24,
            bottom: 24,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640, maxHeight: 480),
            child: Material(
              // Палитра — самостоятельная поверхность, приподнятая над фоном.
              color: scheme.surfaceContainerHigh,
              elevation: 6,
              clipBehavior: Clip.antiAlias,
              borderRadius: BorderRadius.circular(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                    child: m3e.M3ESearchBar(
                      controller: _controller,
                      autoFocus: true,
                      textInputAction: TextInputAction.search,
                      hintText: 'Поиск: треки, альбомы, исполнители…',
                      leading: const Icon(Icons.search),
                      showClearButton: true,
                      // Панель неподвижна: поле не должно расширяться на фокус
                      // и «дышать» отступами, как автономная строка поиска.
                      expandOnFocus: false,
                      margin: 0,
                      focusedMargin: 0,
                      backgroundColor: WidgetStatePropertyAll<Color>(
                        scheme.surfaceContainerHighest,
                      ),
                      // Тап внутри панели не должен снимать фокус с поля:
                      // иначе стрелки перестанут работать. Мимо панели тап
                      // закрывает маршрут через `barrierDismissible`.
                      onTapOutside: (PointerDownEvent event) {},
                      onSubmitted: (String _) => _activate(items, selected),
                      onEscape: _close,
                    ),
                  ),
                  Divider(height: 1, color: scheme.outlineVariant),
                  Flexible(child: _body(context, results, items, selected)),
                  _footer(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AsyncValue<List<BrowseSection>> results,
    List<BrowseItem> items,
    int selected,
  ) {
    if (_query.isEmpty) {
      return _hint(
        context,
        'Начните вводить название трека, альбома или исполнителя',
      );
    }
    if (results.isLoading && !results.hasValue) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }
    if (results.hasError && !results.hasValue) {
      return _hint(context, 'Не удалось выполнить поиск');
    }
    if (items.isEmpty) return _hint(context, 'Ничего не найдено');

    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 4),
      // Строк не больше [_maxResults], поэтому строим их разом: у каждой есть
      // ключ, и `ensureVisible` находит её, даже если она за краем. В ленивом
      // списке далёкая строка ещё не существует, и прокрутить к ней нечем.
      child: Column(
        children: <Widget>[
          for (int index = 0; index < items.length; index++)
            _resultRow(items, index, selected),
        ],
      ),
    );
  }

  /// Одна строка выдачи: иконка, название и подпись по типу элемента.
  Widget _resultRow(List<BrowseItem> items, int index, int selected) {
    final BrowseItem item = items[index];
    final (IconData icon, String subtitle) = _appearance(item);
    return m3e.M3EListItem(
      key: _itemKeys.putIfAbsent(index, () => GlobalKey()),
      headline: item.title,
      supportingText: subtitle,
      leading: Icon(icon),
      selected: index == selected,
      onTap: () => _activate(items, index),
    );
  }

  Widget _hint(BuildContext context, String text) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(Icons.search, size: 20, color: scheme.outline),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle? style = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: scheme.onSurfaceVariant);

    Widget key(String label) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: style),
    );

    Widget item(String keyboardKey, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        key(keyboardKey),
        const SizedBox(width: 6),
        Text(text, style: style),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
      child: Row(
        children: <Widget>[
          item('↑ ↓', 'выбрать'),
          const SizedBox(width: 18),
          item('Enter', 'открыть'),
          const SizedBox(width: 18),
          item('Esc', 'закрыть'),
        ],
      ),
    );
  }
}
