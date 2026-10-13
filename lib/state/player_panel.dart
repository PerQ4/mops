import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Что показано в выезжающей панели справа.
enum PlayerPanelMode {
  none,
  queue,
  lyrics,
}

/// Управляет выезжающей панелью.
///
/// Панель накрывает содержимое, а не отнимает у него ширину: иначе при её
/// открытии вся раскладка перестраивалась бы и элементы «дёргались».
class PlayerPanelController extends Notifier<PlayerPanelMode> {
  @override
  PlayerPanelMode build() => PlayerPanelMode.none;

  /// Открыть панель или закрыть, если она уже открыта в этом режиме.
  void toggle(PlayerPanelMode mode) {
    state = state == mode ? PlayerPanelMode.none : mode;
  }

  void close() => state = PlayerPanelMode.none;
}

final NotifierProvider<PlayerPanelController, PlayerPanelMode>
    playerPanelProvider =
    NotifierProvider<PlayerPanelController, PlayerPanelMode>(
  PlayerPanelController.new,
);
