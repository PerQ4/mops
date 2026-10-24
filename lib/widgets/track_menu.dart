import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme/layout.dart';
import '../core/theme/motion.dart';
import '../data/local/blocked_artists.dart';
import '../data/models/models.dart';
import '../features/common/navigation.dart';
import '../features/library/playlist_edit.dart';
import '../features/player/sleep_timer.dart';
import '../features/playlist/song_replacement_dialog.dart';
import '../state/auth_controller.dart';
import '../state/library_providers.dart';
import '../state/player_controller.dart';
import '../state/providers.dart';
import 'artwork.dart';
import 'async_views.dart';

/// Действия контекстного меню трека.
///
/// Список один на всё приложение: меню вызывается из списков, очереди и
/// плеера, и копии действий в каждом экране гарантированно разошлись бы
/// (где-то переход к исполнителю есть, где-то нет).
enum _TrackAction {
  findReplacement,
  openArtist,
  blockArtist,
  chooseArtist,
  openAlbum,
  removeFromQueue,
  playNext,
  enqueue,
  download,
  removeDownload,
  radio,
  clip,
  copyLink,
  openInYouTubeMusic,
  addToPlaylist,
  mediaInfo,
  sleepTimer,
  like,
}

/// Ширина меню. Умолчание Material 3 (280) тесно для длинных подписей:
/// «Заблокировать исполнителя» и «Открыть в YouTube Music» в него не влезают.
const BoxConstraints _menuConstraints = BoxConstraints(
  minWidth: 200,
  maxWidth: 320,
);

/// Контекстное меню трека.
///
/// Один лист на всё приложение. Действия вызываются из списков, очереди и
/// плеера; держать их копии в каждом экране — значит гарантированно получить
/// расхождения (где-то переход к исполнителю есть, где-то нет).
///
/// На десктопе меню открывается у курсора (`showMenu`): шторка снизу — это
/// мобильный паттерн, в широком окне она выезжает далеко от нажатия. На
/// телефоне и в узком окне остаётся шторка: там она ближе к пальцу и не
/// спорит с системными жестами.
///
/// [rootNavigator] ставит полноэкранный плеер: он сам открыт в корневом
/// навигаторе, и меню из него должно лежать там же, поверх плеера. Переходы
/// к исполнителю и альбому при этом сначала сворачивают плеер — см. [AppRoutes].
///
/// [position] — точка нажатия в глобальных координатах (правый клик по строке).
/// Кнопка «…» передаёт свои координаты, остальные вызывающие — ничего, и меню
/// привязывается к низу их виджета (см. [_TrackMenu.anchor]).
Future<void> showTrackMenu(
  BuildContext context,
  Track track, {
  bool rootNavigator = false,
  VoidCallback? onMediaInfo,
  VoidCallback? onSleepTimer,
  Future<void> Function(Track replacement)? replaceInPlaylist,
  Offset? position,
}) {
  final _TrackMenu menu = _TrackMenu(
    track: track,
    hostContext: context,
    // Контейнер, а не `ref`: всплывающее меню живёт отдельным маршрутом и
    // widget-ссылки на него не имеет, а действиям нужны те же провайдеры.
    container: ProviderScope.containerOf(context, listen: false),
    onMediaInfo: onMediaInfo,
    onSleepTimer: onSleepTimer,
    replaceInPlaylist: replaceInPlaylist,
  );

  if (!context.isCompactLayout) {
    return menu.showPopup(
      context,
      rootNavigator: rootNavigator,
      position: position,
    );
  }

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useRootNavigator: rootNavigator,
    // Меню выше стандартных 9/16 экрана (обложка + действия), поэтому
    // разрешаем занять больше и добавляем прокрутку — на низком окне
    // последние пункты иначе были бы обрезаны.
    isScrollControlled: true,
    // Лист появляется и уходит тем же переходом, что и элементы интерфейса:
    // появление — 400 мс с торможением, закрытие — 200 мс на разгон.
    sheetAnimationStyle: AppMotion.elementMoveEnter.style,
    builder: (BuildContext sheetContext) => _TrackMenuSheet(menu: menu),
  );
}

/// Снимок состояния, из которого собирается список действий.
///
/// Собирается и из `ref.watch` (шторка показывает живые подписи: прогресс
/// загрузки, лайк), и из контейнера (всплывающее меню открывается один раз),
/// поэтому производные поля считаются здесь — иначе две ветки могли бы
/// разойтись в мелочах вроде «убирать из очереди» у играющего трека.
class _MenuState {
  _MenuState({
    required this.track,
    required this.signedIn,
    required this.liked,
    required this.currentId,
    required this.currentIndex,
    required this.queue,
    required this.unavailable,
    required this.download,
    required this.downloaded,
    required this.blockedArtists,
    required this.sleepTimer,
  }) {
    isCurrent = currentId != null && currentId == track.id;
    // Есть ли трек в очереди вообще: для играющего это всегда так, но пункт
    // убираем только когда убирать действительно есть что.
    queueIndex = queue.indexWhere((Track t) => t.id == track.id);
    inQueue = queueIndex >= 0;

    // Перейти можно только туда, где есть id. Если YouTube его не отдал,
    // пункт не показываем вовсе — «мёртвая» кнопка путает сильнее, чем её
    // отсутствие.
    navigableArtists = track.artists
        .where((ArtistRef a) => a.isNavigable)
        .toList(growable: false);
    artist = navigableArtists.isEmpty ? null : navigableArtists.first;
    album = (track.album?.isNavigable ?? false) ? track.album : null;
    singleBlocked = navigableArtists.length == 1 &&
        blockedArtists
            .any((BlockedArtist b) => b.id == navigableArtists.first.id);
  }

  final Track track;
  final bool signedIn;
  final bool liked;
  final String? currentId;
  final int currentIndex;
  final List<Track> queue;
  final bool unavailable;
  final DownloadTask? download;
  final bool downloaded;
  final List<BlockedArtist> blockedArtists;

  /// Текущий таймер сна: подпись пункта меню показывает, идёт он или нет.
  final int sleepTimer;

  late final bool isCurrent;
  late final int queueIndex;
  late final bool inQueue;
  late final List<ArtistRef> navigableArtists;
  late final ArtistRef? artist;
  late final AlbumRef? album;
  late final bool singleBlocked;
}

/// Элемент списка действий: либо пункт, либо разделитель группы.
sealed class _MenuEntry {
  const _MenuEntry();
}

final class _MenuDivider extends _MenuEntry {
  const _MenuDivider();
}

final class _MenuActionEntry extends _MenuEntry {
  const _MenuActionEntry({
    required this.action,
    required this.icon,
    required this.title,
    this.subtitle,
    this.subtitleIsError = false,
    this.enabled = true,
  });

  final _TrackAction action;
  final IconData icon;
  final String title;

  /// Пояснение под пунктом: причина ошибки загрузки или что даёт действие.
  final String? subtitle;
  final bool subtitleIsError;

  /// Ложное значение — пункт виден, но недоступен (нет входа, идёт загрузка).
  final bool enabled;
}

/// Логика меню трека, общая для шторки и всплывающего меню.
class _TrackMenu {
  _TrackMenu({
    required this.track,
    required this.hostContext,
    required this.container,
    this.onMediaInfo,
    this.onSleepTimer,
    this.replaceInPlaylist,
  });

  final Track track;

  /// Контекст, из которого меню открыли. Нужен, чтобы навигацию выполнять
  /// после закрытия меню: контекст самого меню к этому моменту уже
  /// недействителен.
  final BuildContext hostContext;

  final ProviderContainer container;

  /// Показ параметров играющего потока. Задаёт только плеер: у трека из списка
  /// никакого потока ещё нет, и пункт там был бы враньём.
  final VoidCallback? onMediaInfo;

  /// Таймер сна: состояние и выбор живут в контроллере плеера, а меню лишь
  /// открывает их. Задаёт только плеер — в строке списка таймер не к месту.
  final VoidCallback? onSleepTimer;

  /// Подмена записи в плейлисте, из которого открыли меню. Задаёт экран
  /// плейлиста: только он знает, можно ли править список. Без колбэка замена
  /// всё равно происходит в очереди.
  final Future<void> Function(Track replacement)? replaceInPlaylist;

  /// Меню на месте — у курсора или у виджета, который его открыл.
  Future<void> showPopup(
    BuildContext context, {
    required bool rootNavigator,
    Offset? position,
  }) async {
    final _MenuState state = readState();
    final _TrackAction? action = await showMenu<_TrackAction>(
      context: context,
      useRootNavigator: rootNavigator,
      position: _menuPosition(
        context,
        position ?? anchor,
        rootNavigator: rootNavigator,
      ),
      constraints: _menuConstraints,
      items: <PopupMenuEntry<_TrackAction>>[
        for (final _MenuEntry entry in entries(state))
          if (entry is _MenuDivider)
            const PopupMenuDivider()
          else
            _popupItem(
              entry as _MenuActionEntry,
              Theme.of(context).colorScheme,
            ),
      ],
    );
    if (action == null || !hostContext.mounted) return;
    await run(action, ScaffoldMessenger.of(hostContext));
  }

  /// Точка привязки, когда нажатие её не передало.
  ///
  /// Кнопки «…» в чужих виджетах (панель плеера, очередь, загрузки) своего
  /// `RenderBox` наружу не отдают, поэтому берём низ центра виджета, из
  /// которого меню открыли: у панели плеера и островка это как раз строка с
  /// действиями. Точка нажатия важнее — она приходит из строки трека.
  Offset get anchor {
    final RenderObject? box = hostContext.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      return box.localToGlobal(Offset(box.size.width / 2, box.size.height));
    }
    final Size size = MediaQuery.sizeOf(hostContext);
    return Offset(size.width / 2, size.height / 2);
  }

  /// Состояние на момент вызова: всплывающее меню собирается один раз, а
  /// подписи должны совпадать с тем, что видит пользователь сейчас.
  _MenuState readState() {
    final PlayerUiState player = container.read(playerControllerProvider);
    final DownloadsState downloads = container.read(downloadsControllerProvider);
    return _MenuState(
      track: track,
      signedIn: container.read(authControllerProvider).isSignedIn,
      liked: container.read(likedIdsProvider).contains(track.id),
      currentId: player.current?.id,
      currentIndex: player.index,
      queue: player.queue,
      unavailable: player.unavailableIds.contains(track.id),
      download: downloads.taskFor(track.id),
      downloaded: downloads.isDownloaded(track.id),
      blockedArtists: container.read(blockedArtistsProvider),
      sleepTimer: player.sleepTimer,
    );
  }

  /// Пункты в порядке показа. Один и тот же список рисуют обе поверхности.
  List<_MenuEntry> entries(_MenuState state) {
    final DownloadTask? download = state.download;
    return <_MenuEntry>[
      // Пункт только у действительно недоступного трека: для рабочего он был
      // бы предложением искать замену исправной песне.
      if (state.unavailable) ...<_MenuEntry>[
        const _MenuActionEntry(
          action: _TrackAction.findReplacement,
          icon: Icons.find_replace,
          title: 'Найти замену',
        ),
        const _MenuDivider(),
      ],
      if (state.artist != null)
        const _MenuActionEntry(
          action: _TrackAction.openArtist,
          icon: Icons.person_outline,
          title: 'Перейти к исполнителю',
        ),
      // Блокировка — только когда исполнителя можно опознать по id:
      // блокировать «по имени» нельзя, имена у YouTube не уникальны.
      if (state.navigableArtists.length == 1)
        _MenuActionEntry(
          action: _TrackAction.blockArtist,
          icon: state.singleBlocked
              ? Icons.person_add_alt_1_outlined
              : Icons.person_off_outlined,
          title: state.singleBlocked
              ? 'Разблокировать исполнителя'
              : 'Заблокировать исполнителя',
        )
      else if (state.navigableArtists.length > 1)
        // У трека с несколькими авторами непонятно, кого именно прятать,
        // поэтому спрашиваем: молча выбрать первого значило бы спрятать не
        // того.
        const _MenuActionEntry(
          action: _TrackAction.chooseArtist,
          icon: Icons.person_off_outlined,
          title: 'Заблокировать исполнителя',
        ),
      if (state.album != null)
        const _MenuActionEntry(
          action: _TrackAction.openAlbum,
          icon: Icons.album_outlined,
          title: 'Перейти к альбому',
        ),
      if (state.artist != null || state.album != null) const _MenuDivider(),
      // Для играющего трека «играть следующим» и «в очередь» бессмысленны:
      // он уже звучит. Вместо них — убрать из очереди.
      if (state.isCurrent && state.inQueue)
        const _MenuActionEntry(
          action: _TrackAction.removeFromQueue,
          icon: Icons.remove_circle_outline,
          title: 'Убрать из очереди',
        )
      else ...<_MenuEntry>[
        const _MenuActionEntry(
          action: _TrackAction.playNext,
          icon: Icons.queue_play_next,
          title: 'Играть следующим',
        ),
        const _MenuActionEntry(
          action: _TrackAction.enqueue,
          icon: Icons.playlist_add,
          title: 'В очередь',
        ),
      ],
      // Загрузка рядом с очередью: это действие над самим треком, а не над
      // тем, где он играет. Прогресс показывается и в островке — им управляет
      // контроллер плеера по тому же состоянию.
      if (download != null && !download.failed)
        _MenuActionEntry(
          action: _TrackAction.download,
          icon: Icons.downloading,
          title: 'Скачивается ${(download.progress * 100).round()}%',
          subtitle: 'Подождите — файл допишется сам',
          enabled: false,
        )
      else if (state.downloaded)
        const _MenuActionEntry(
          action: _TrackAction.removeDownload,
          icon: Icons.download_done,
          title: 'Удалить загрузку',
          subtitle: 'Трек останется в списках, но играть будет из сети',
        )
      else
        _MenuActionEntry(
          action: _TrackAction.download,
          icon: Icons.download_outlined,
          title: download?.failed == true ? 'Повторить скачивание' : 'Скачать',
          subtitle: download?.failed == true
              ? download!.error
              : 'Слушать без интернета',
          subtitleIsError: download?.failed == true,
        ),
      // Радио доступно у любого трека — и у играющего, и у того, что просто
      // лежит в списке: YouTube Music строит рекомендации по любому видео.
      const _MenuActionEntry(
        action: _TrackAction.radio,
        icon: Icons.radio,
        title: 'Начать радио',
      ),
      // Клип есть только у самого видео: у обычной песни YouTube отдал бы
      // звуковую дорожку, и пункт был бы обманом.
      if (track.isVideo)
        const _MenuActionEntry(
          action: _TrackAction.clip,
          icon: Icons.play_circle_outline,
          title: 'Смотреть клип',
        ),
      // Ссылка — тот же id: на YouTube Music он открывает именно этот трек.
      // Скопировать и открыть — два разных намерения (отправить другу и
      // послушать самому), поэтому пункта два.
      const _MenuActionEntry(
        action: _TrackAction.copyLink,
        icon: Icons.link,
        title: 'Копировать ссылку',
      ),
      const _MenuActionEntry(
        action: _TrackAction.openInYouTubeMusic,
        icon: Icons.open_in_new,
        title: 'Открыть в YouTube Music',
      ),
      _MenuActionEntry(
        action: _TrackAction.addToPlaylist,
        icon: Icons.playlist_add,
        title: 'Добавить в плейлист',
        // Без входа YouTube не примет правку плейлиста — как и лайк.
        enabled: state.signedIn,
      ),
      // Параметры потока — только там, где поток уже играет: пункт приходит
      // из плеера вместе с колбэком.
      if (onMediaInfo != null)
        const _MenuActionEntry(
          action: _TrackAction.mediaInfo,
          icon: Icons.info_outline,
          title: 'Детали потока',
        ),
      // Таймер сна — тоже только в плеере: состояние пишем в подписи, чтобы
      // включённый отсчёт читался без наведения на кнопку.
      if (onSleepTimer != null)
        _MenuActionEntry(
          action: _TrackAction.sleepTimer,
          icon: state.sleepTimer == 0
              ? Icons.bedtime_outlined
              : Icons.bedtime,
          title: state.sleepTimer == 0
              ? 'Таймер сна'
              // Подпись состояния — строчными: строка идёт после двоеточия,
              // а `sleepTimerLabel` рассчитан и на отдельную строку настроек.
              : 'Таймер сна: '
                  '${sleepTimerLabel(state.sleepTimer).toLowerCase()}',
        ),
      _MenuActionEntry(
        action: _TrackAction.like,
        icon: state.liked ? Icons.favorite : Icons.favorite_border,
        title: state.liked ? 'Убрать из «Мне нравится»' : 'Мне нравится',
        // Без входа действие недоступно — как и кнопка лайка в плеере.
        enabled: state.signedIn,
      ),
    ];
  }

  /// Закрывает шторку и выполняет действие.
  ///
  /// Мессенджер берём до `Navigator.pop`: после закрытия листа его контекст
  /// уже снят, а сообщение нужно показать на экране хоста.
  void runFromSheet(BuildContext sheetContext, _TrackAction action) {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(hostContext);
    Navigator.pop(sheetContext);
    unawaited(run(action, messenger));
  }

  /// Выполняет выбранное действие. Данные читаются заново: меню могло
  /// провисеть открытым, пока очередь или загрузка успели измениться.
  Future<void> run(
    _TrackAction action,
    ScaffoldMessengerState messenger,
  ) async {
    final _MenuState state = readState();
    switch (action) {
      case _TrackAction.findReplacement:
        await _replaceTrack(messenger);
      case _TrackAction.openArtist:
        // Переход делает [AppRoutes]: из полноэкранного плеера он сначала
        // сворачивает его, иначе страница осталась бы под плеером.
        unawaited(AppRoutes.artistFromMenu(hostContext, state.artist!.id!));
      case _TrackAction.openAlbum:
        unawaited(AppRoutes.albumFromMenu(hostContext, state.album!.id!));
      case _TrackAction.blockArtist:
        await _applyArtistBlock(
          state.navigableArtists.first,
          state.singleBlocked,
          messenger,
        );
      case _TrackAction.chooseArtist:
        await _askAndToggle(
          state.navigableArtists,
          state.blockedArtists,
          messenger,
        );
      case _TrackAction.removeFromQueue:
        // У играющего берём его настоящий индекс: при дублях `indexWhere`
        // вернул бы первое вхождение, а не то, что звучит сейчас.
        container.read(playerControllerProvider.notifier).removeFromQueue(
              state.currentIndex >= 0 ? state.currentIndex : state.queueIndex,
            );
      case _TrackAction.playNext:
        container.read(playerControllerProvider.notifier).playNext(track);
      case _TrackAction.enqueue:
        container.read(playerControllerProvider.notifier).enqueue(track);
      case _TrackAction.download:
        await _download(messenger);
      case _TrackAction.removeDownload:
        await _removeDownload(messenger);
      case _TrackAction.radio:
        container.read(playerControllerProvider.notifier).startRadio(track);
      case _TrackAction.clip:
        // Клип, как и плеер, живёт в корневом навигаторе — иначе при открытии
        // из полноэкранного плеера он остался бы под его экраном.
        AppRoutes.clip(hostContext, track);
      case _TrackAction.copyLink:
        await _copyLink(messenger);
      case _TrackAction.openInYouTubeMusic:
        await _openInYouTubeMusic(messenger);
      case _TrackAction.addToPlaylist:
        // Диалог показываем уже после закрытия меню: два модальных слоя друг
        // над другом на одном контексте конфликтуют.
        showAddToPlaylistDialog(hostContext, track);
      case _TrackAction.mediaInfo:
        onMediaInfo?.call();
      case _TrackAction.sleepTimer:
        onSleepTimer?.call();
      case _TrackAction.like:
        await _toggleLike(messenger);
    }
  }

  /// Ставит трек в загрузку и сообщает о результате.
  Future<void> _download(ScaffoldMessengerState messenger) async {
    final DownloadsController controller =
        container.read(downloadsControllerProvider.notifier);
    final String? error = await controller.download(track);
    if (!hostContext.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          error == null
              ? '«${track.title}» скачан и доступен без интернета'
              : 'Не удалось скачать: $error',
        ),
      ),
    );
  }

  /// Удаляет скачанный файл трека.
  Future<void> _removeDownload(ScaffoldMessengerState messenger) async {
    final DownloadsController controller =
        container.read(downloadsControllerProvider.notifier);
    final String? error = await controller.remove(track.id);
    if (!hostContext.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          error == null
              ? 'Загрузка «${track.title}» удалена'
              : 'Не удалось удалить загрузку: $error',
        ),
      ),
    );
  }

  /// Ссылка на трек в YouTube Music: id трека — это и есть videoId.
  Uri get _watchUri =>
      Uri.parse('https://music.youtube.com/watch?v=${track.id}');

  /// Кладёт ссылку в буфер обмена и подтверждает это.
  ///
  /// Меню закрываем сразу: держать его открытым, пока пользователь идёт
  /// вставлять ссылку, незачем.
  Future<void> _copyLink(ScaffoldMessengerState messenger) async {
    try {
      await Clipboard.setData(ClipboardData(text: _watchUri.toString()));
      messenger.showSnackBar(
        const SnackBar(content: Text('Ссылка скопирована')),
      );
    } on Object {
      // Буфер обмена — системный ресурс: если платформа отказала, молчать
      // нельзя, иначе пользователь вставит что-то другое и не поймёт почему.
      messenger.showSnackBar(
        const SnackBar(content: Text('Не удалось скопировать ссылку.')),
      );
    }
  }

  /// Открывает трек в браузере системы.
  ///
  /// `externalApplication` — именно внешний браузер, а не встроенный WebView:
  /// цель пункта — послушать трек на YouTube Music, где играет полноценный
  /// веб-плеер, а не наш.
  Future<void> _openInYouTubeMusic(ScaffoldMessengerState messenger) async {
    bool ok = false;
    try {
      ok = await launchUrl(_watchUri, mode: LaunchMode.externalApplication);
    } on Object {
      ok = false;
    }
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Не удалось открыть браузер.')),
      );
    }
  }

  /// Открывает выбор замены и применяет его.
  Future<void> _replaceTrack(ScaffoldMessengerState messenger) async {
    final PlayerController player =
        container.read(playerControllerProvider.notifier);
    final Future<void> Function(Track)? replaceInPlaylist =
        this.replaceInPlaylist;

    final Track? replacement =
        await showSongReplacementDialog(hostContext, track);
    if (replacement == null) return;
    if (!hostContext.mounted) return;

    try {
      // Сначала плейлист: если сервер откажет, очередь останется прежней.
      if (replaceInPlaylist != null) {
        await replaceInPlaylist(replacement);
      }
      await player.replaceTrack(track, replacement);
      messenger.showSnackBar(
        SnackBar(
          content: Text('«${track.title}» заменён на «${replacement.title}»'),
        ),
      );
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Не удалось заменить трек: ${describeError(error)}'),
        ),
      );
    }
  }

  /// Спрашивает, кого из соавторов трека заблокировать.
  Future<void> _askAndToggle(
    List<ArtistRef> artists,
    List<BlockedArtist> blocked,
    ScaffoldMessengerState messenger,
  ) async {
    bool isBlocked(ArtistRef artist) =>
        blocked.any((BlockedArtist item) => item.id == artist.id);

    final ArtistRef? chosen = await showDialog<ArtistRef>(
      context: hostContext,
      builder: (BuildContext dialogContext) => SimpleDialog(
        title: const Text('Заблокировать исполнителя'),
        children: <Widget>[
          for (final ArtistRef artist in artists)
            ListTile(
              leading: Icon(
                isBlocked(artist) ? Icons.lock_outline : Icons.person_outline,
              ),
              title: Text(artist.name),
              subtitle: isBlocked(artist)
                  ? const Text('Уже заблокирован — нажмите, чтобы снять')
                  : null,
              onTap: () => Navigator.pop(dialogContext, artist),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    await _applyArtistBlock(chosen, isBlocked(chosen), messenger);
  }

  /// Блокирует или разблокирует исполнителя трека.
  Future<void> _applyArtistBlock(
    ArtistRef artist,
    bool blocked,
    ScaffoldMessengerState messenger,
  ) async {
    final String id = artist.id ?? '';
    if (id.isEmpty) return;
    final BlockedArtists notifier =
        container.read(blockedArtistsProvider.notifier);
    try {
      if (blocked) {
        await notifier.unblock(id);
      } else {
        await notifier.block(id: id, name: artist.name);
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            blocked
                ? 'Блокировка снята: ${artist.name}'
                : 'Исполнитель заблокирован: ${artist.name}',
          ),
        ),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Не удалось изменить блокировку.')),
      );
    }
  }

  Future<void> _toggleLike(ScaffoldMessengerState messenger) async {
    final bool wasLiked = container.read(likedIdsProvider).contains(track.id);
    try {
      await container.read(likedIdsProvider.notifier).toggle(track.id);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            wasLiked
                ? 'Убрано из «Мне нравится»'
                : 'Добавлено в «Мне нравится»',
          ),
        ),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Не удалось поставить лайк. Проверьте вход в аккаунт.'),
        ),
      );
    }
  }
}

/// Шторка меню — для телефона и узкого окна.
class _TrackMenuSheet extends ConsumerWidget {
  const _TrackMenuSheet({required this.menu});

  final _TrackMenu menu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track track = menu.track;
    final bool signedIn = ref.watch(
      authControllerProvider.select((AuthState s) => s.isSignedIn),
    );
    // Лайк — из общего источника правды (см. [likedIdsProvider]): меню,
    // строки треков и плеер всегда показывают одно и то же.
    final bool liked = ref.watch(
      likedIdsProvider.select((Set<String> ids) => ids.contains(track.id)),
    );

    // Состояние очереди берём через `select`: позиция воспроизведения
    // меняется несколько раз в секунду, и без этого лист перестраивался бы на
    // каждом тике. Нам нужны только текущий трек, его индекс и сама очередь —
    // по ним решаем, чем заменить «играть следующим» и «в очередь».
    final (String? currentId, int currentIndex, List<Track> queue) = ref.watch(
      playerControllerProvider.select(
        (PlayerUiState s) => (s.current?.id, s.index, s.queue),
      ),
    );
    // Недоступность — отдельным `select`: отметка меняется редко, и без него
    // список перестраивался бы на каждый тик позиции.
    final bool unavailable = ref.watch(
      playerControllerProvider.select(
        (PlayerUiState s) => s.unavailableIds.contains(track.id),
      ),
    );
    // Таймер сна — тоже отдельным `select`: подпись пункта живая, а позиция
    // воспроизведения меняется несколько раз в секунду.
    final int sleepTimer = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.sleepTimer),
    );

    // Загрузка трека: пункт меню и прогресс берутся из одного контроллера,
    // поэтому скачивание, начатое на экране «Загрузки», видно и здесь.
    final DownloadTask? download = ref.watch(
      downloadsControllerProvider.select(
        (DownloadsState s) => s.taskFor(track.id),
      ),
    );
    final bool downloaded = ref.watch(
      downloadsControllerProvider.select(
        (DownloadsState s) => s.isDownloaded(track.id),
      ),
    );

    // Блокировки — отдельным `watch`: список меняется редко, а меню должно
    // показывать актуальное действие (заблокировать или разблокировать).
    final List<BlockedArtist> blockedArtists =
        ref.watch(blockedArtistsProvider);

    final _MenuState state = _MenuState(
      track: track,
      signedIn: signedIn,
      liked: liked,
      currentId: currentId,
      currentIndex: currentIndex,
      queue: queue,
      unavailable: unavailable,
      download: download,
      downloaded: downloaded,
      blockedArtists: blockedArtists,
      sleepTimer: sleepTimer,
    );

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _MenuHeader(track: track),
            const Divider(height: 1),
            for (final _MenuEntry entry in menu.entries(state))
              _sheetEntry(context, entry),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Пункт шторки: та же запись, что и во всплывающем меню, но строкой.
  Widget _sheetEntry(BuildContext context, _MenuEntry entry) {
    if (entry is _MenuDivider) return const Divider(height: 1);
    final _MenuActionEntry action = entry as _MenuActionEntry;
    return _MenuAction(
      icon: action.icon,
      title: action.title,
      subtitle: action.subtitle,
      subtitleColor:
          action.subtitleIsError ? Theme.of(context).colorScheme.error : null,
      onTap: action.enabled
          ? () => menu.runFromSheet(context, action.action)
          : null,
    );
  }
}

/// Пункт всплывающего меню.
///
/// Подпись обрезается, а не вылезает за меню: ширина поповера ограничена
/// [_menuConstraints], и длинная строка вроде «Заблокировать исполнителя»
/// иначе ломала бы раскладку.
PopupMenuItem<_TrackAction> _popupItem(
  _MenuActionEntry entry,
  ColorScheme scheme,
) {
  return PopupMenuItem<_TrackAction>(
    value: entry.action,
    enabled: entry.enabled,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(entry.icon, size: 20),
        const SizedBox(width: 12),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (entry.subtitle != null)
                Text(
                  entry.subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: entry.subtitleIsError
                        ? scheme.error
                        : scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Положение меню у точки нажатия.
///
/// `showMenu` ждёт координаты в системе наложения того навигатора, в котором
/// открывается меню, а нажатие приходит в глобальных. Без пересчёта меню
/// уезжало бы на ширину боковой панели — подэкраны живут во вложенном
/// навигаторе.
RelativeRect _menuPosition(
  BuildContext context,
  Offset globalPosition, {
  required bool rootNavigator,
}) {
  final RenderObject? overlay = Navigator.of(
    context,
    rootNavigator: rootNavigator,
  ).overlay?.context.findRenderObject();
  if (overlay is RenderBox && overlay.hasSize) {
    final Offset local = overlay.globalToLocal(globalPosition);
    return RelativeRect.fromLTRB(
      local.dx,
      local.dy,
      overlay.size.width - local.dx,
      overlay.size.height - local.dy,
    );
  }
  final Size size = MediaQuery.sizeOf(context);
  return RelativeRect.fromLTRB(
    globalPosition.dx,
    globalPosition.dy,
    size.width - globalPosition.dx,
    size.height - globalPosition.dy,
  );
}

/// Шапка меню: обложка и подписи — чтобы было понятно, к какому треку меню.
class _MenuHeader extends StatelessWidget {
  const _MenuHeader({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    const double size = AppLayout.trackArtwork;
    final int physical = (size * MediaQuery.devicePixelRatioOf(context))
        .round();
    final List<String> variants = track.artworkFallbacks(physical);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: <Widget>[
          Artwork(
            url: variants.isEmpty ? null : variants.first,
            fallbacks: variants.length > 1
                ? variants.sublist(1)
                : const <String>[],
            size: size,
            radius: BorderRadius.circular(AppLayout.trackArtworkRadius),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  track.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  track.artistLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Пункт меню: иконка и подпись. Оформление одно на все действия, чтобы
/// порядок и отступы не «плясали» от поверхности к поверхности.
class _MenuAction extends StatelessWidget {
  const _MenuAction({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.subtitleColor,
  });

  final IconData icon;
  final String title;

  /// Пояснение под пунктом: причина ошибки загрузки или что даёт действие.
  final String? subtitle;
  final Color? subtitleColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: subtitleColor),
            ),
      enabled: onTap != null,
      onTap: onTap,
    );
  }
}
