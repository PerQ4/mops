import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/library_providers.dart';
import '../../state/player_controller.dart';
import 'command_palette.dart';
import 'content_navigator.dart';

/// Шаг перемотки стрелками. Отдельной настройки шага в приложении нет, поэтому
/// используем привычные 5 секунд — как в большинстве плееров.
const Duration _seekStep = Duration(seconds: 5);

/// Глобальные горячие клавиши десктопа.
///
/// Слушаем клавиатуру напрямую (`HardwareKeyboard.addHandler`), а не через
/// `Shortcuts`: так событие приходит независимо от того, где сейчас фокус —
/// тем же способом сделан жест «назад» (`lib/widgets/back_gesture.dart`).
///
/// Важно понимать: такой обработчик **не** останавливает событие — Focus-система
/// получает его следом (см. `HardwareKeyboard._dispatchKeyMessage`). Поэтому
/// потенциально конфликтующие клавиши обрабатываются только тогда, когда фокус
/// не на элементе, который сам на них реагирует (поле ввода, кнопка, ползунок).
/// Иначе, например, пробел в поиске поставил бы паузу дважды.
class AppShortcuts extends ConsumerStatefulWidget {
  const AppShortcuts({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppShortcuts> createState() => _AppShortcutsState();
}

class _AppShortcutsState extends ConsumerState<AppShortcuts> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// Ищет среди предков текущего фокуса виджет, подходящий под [test].
  ///
  /// Читаем цепочку элементов напрямую: `Actions.maybeFind` во время обработки
  /// клавиши зарегистрировал бы зависимость наследования, чего вне `build`
  /// делать нельзя.
  bool _focusedBelow(bool Function(Widget widget) test) {
    final BuildContext? context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    bool found = false;
    context.visitAncestorElements((Element element) {
      if (test(element.widget)) {
        found = true;
        return false; // нашли ближайший — дальше не идём
      }
      return true;
    });
    return found;
  }

  /// Фокус в поле ввода: буквы и пробел должны набираться, а не управлять
  /// плеером. Ловит и экран поиска, и поле палитры, и любые диалоги.
  bool get _typingInTextField =>
      _focusedBelow((Widget widget) => widget is EditableText);

  /// Сфокусированный элемент сам обрабатывает «активацию» (пробел): кнопка,
  /// `ListTile`, переключатель. Проверяем по карте `Actions`.
  bool get _activationFocused => _focusedBelow((Widget widget) {
    if (widget is! Actions) return false;
    return widget.actions.containsKey(ActivateIntent) ||
        widget.actions.containsKey(ButtonActivateIntent);
  });

  /// Сфокусирован ползунок: стрелки должны менять его значение, а не
  /// перематывать трек.
  bool get _sliderFocused => _focusedBelow((Widget widget) => widget is Slider);

  void _openPalette() {
    if (commandPaletteOpen.value) return;
    unawaited(showCommandPalette(context));
  }

  /// Перемотка на [delta] от текущей позиции с ограничением по краям трека.
  void _seekBy(PlayerUiState state, Duration delta) {
    final Duration duration = state.playback.duration;
    Duration target = state.playback.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    unawaited(ref.read(playerControllerProvider.notifier).seek(target));
  }

  void _toggleLike(PlayerUiState state) {
    final Track? track = state.current;
    if (track == null) return;
    if (!ref.read(authControllerProvider).isSignedIn) return;
    unawaited(_like(track.id));
  }

  Future<void> _like(String videoId) async {
    try {
      await ref.read(likedIdsProvider.notifier).toggle(videoId);
    } on Object catch (error) {
      // Клавиша не должна «падать» из-за сети — просто сообщаем в лог.
      debugPrint('[Shortcuts] не удалось переключить лайк: $error');
    }
  }

  void _toggleMute(PlayerUiState state) {
    if (!state.hasTrack) return;
    // Повторяем кнопку «выключить звук» из плеера: 0 сменяется на 1.
    final double volume = state.playback.volume;
    unawaited(
      ref
          .read(playerControllerProvider.notifier)
          .setVolume(volume == 0 ? 1.0 : 0.0),
    );
  }

  /// Закрывает верхний маршрут корневого навигатора — полноэкранный плеер.
  ///
  /// Вложенный стек (альбом, настройки) не трогаем: Esc сворачивает именно
  /// плеер, как и просили. Двойного закрытия не будет: `Navigator.maybePop`
  /// проверяет, не изменился ли верхний маршрут, пока шёл `willPop`, и второй
  /// вызов (от системного `DismissIntent`) просто ничего не сделает.
  bool _closeFullscreenPlayer() {
    final NavigatorState? root = rootNavigatorKey.currentState;
    if (root == null || !root.canPop()) return false;
    unawaited(root.maybePop());
    return true;
  }

  bool _onKey(KeyEvent event) {
    // Повторы (удержание) игнорируем: перемотка остаётся пошаговой.
    if (event is! KeyDownEvent) return false;

    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final bool control = keyboard.isControlPressed || keyboard.isMetaPressed;
    final bool shift = keyboard.isShiftPressed;
    final bool alt = keyboard.isAltPressed;

    // Ctrl/Cmd + K — быстрый поиск. Работает даже из текстового поля: это
    // привычное сочетание, и ввод оно не ломает.
    if (event.logicalKey == LogicalKeyboardKey.keyK && control) {
      _openPalette();
      return true;
    }

    // Пока палитра открыта, клавиши принадлежат ей: там своё поле и стрелки.
    if (commandPaletteOpen.value) return false;

    // Поле ввода — не трогаем ничего: иначе пробел в поиске ставит паузу.
    if (_typingInTextField) return false;

    final PlayerController player = ref.read(playerControllerProvider.notifier);
    final PlayerUiState state = ref.read(playerControllerProvider);

    if (event.logicalKey == LogicalKeyboardKey.space) {
      if (control) return false;
      // Не мешаем сфокусированной кнопке: пробел — её штатная активация.
      if (_activationFocused) return false;
      unawaited(player.togglePlayPause());
      return true;
    }

    // Alt+← занят жестом «назад», Ctrl+← — перемещением по словам в тексте.
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (alt || control) return false;
      if (_sliderFocused) return false;
      if (shift) {
        unawaited(player.previous());
      } else {
        _seekBy(state, -_seekStep);
      }
      return true;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (alt || control) return false;
      if (_sliderFocused) return false;
      if (shift) {
        unawaited(player.next());
      } else {
        _seekBy(state, _seekStep);
      }
      return true;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyL) {
      if (control || alt || shift) return false;
      _toggleLike(state);
      return true;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyM) {
      if (control || alt || shift) return false;
      _toggleMute(state);
      return true;
    }

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      return _closeFullscreenPlayer();
    }

    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
