import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme/layout.dart';
import '../data/models/models.dart';
import '../features/common/navigation.dart';
import '../features/library/playlist_edit.dart';
import '../state/auth_controller.dart';
import '../state/library_providers.dart';
import '../state/player_controller.dart';
import 'artwork.dart';

/// Контекстное меню трека: обложка, подписи и действия над треком.
///
/// Один лист на всё приложение. Действия вызываются из списков, очереди и
/// плеера; держать их копии в каждом экране — значит гарантированно получить
/// расхождения (где-то переход к исполнителю есть, где-то нет).
///
/// [rootNavigator] нужен полноэкранному плееру: он открыт в корневом
/// навигаторе, и переход во вложенном навигаторе остался бы у него «под»
/// экраном. Из островка и из списков переход идёт во вложенный навигатор —
/// так плавающий док остаётся видимым (см. [AppRoutes]).
Future<void> showTrackMenu(
  BuildContext context,
  Track track, {
  bool rootNavigator = false,
  VoidCallback? onMediaInfo,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    // Меню выше стандартных 9/16 экрана (обложка + действия), поэтому
    // разрешаем занять больше и добавляем прокрутку — на низком окне
    // последние пункты иначе были бы обрезаны.
    isScrollControlled: true,
    builder: (BuildContext sheetContext) => _TrackMenuSheet(
      track: track,
      hostContext: context,
      rootNavigator: rootNavigator,
      onMediaInfo: onMediaInfo,
    ),
  );
}

class _TrackMenuSheet extends ConsumerWidget {
  const _TrackMenuSheet({
    required this.track,
    required this.hostContext,
    required this.rootNavigator,
    this.onMediaInfo,
  });

  final Track track;

  /// Контекст, из которого меню открыли. Нужен, чтобы навигацию выполнять
  /// после закрытия листа: контекст листа к этому моменту уже недействителен.
  final BuildContext hostContext;

  final bool rootNavigator;

  /// Показ параметров играющего потока. Задаёт только плеер: у трека из списка
  /// никакого потока ещё нет, и пункт там был бы враньём.
  final VoidCallback? onMediaInfo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
    final bool isCurrent = currentId != null && currentId == track.id;
    // Есть ли трек в очереди вообще: для играющего это всегда так, но пункт
    // убираем только когда убирать действительно есть что.
    final int queueIndex = queue.indexWhere((Track t) => t.id == track.id);
    final bool inQueue = queueIndex >= 0;

    // Перейти можно только туда, где есть id. Если YouTube его не отдал,
    // пункт не показываем вовсе — «мёртвая» кнопка путает сильнее, чем её
    // отсутствие.
    final ArtistRef? artist = _firstNavigableArtist();
    final AlbumRef? album = (track.album?.isNavigable ?? false)
        ? track.album
        : null;

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _MenuHeader(track: track),
            const Divider(height: 1),
            if (artist != null)
              _MenuAction(
                icon: Icons.person_outline,
                title: 'Перейти к исполнителю',
                onTap: () => _openArtist(context, artist),
              ),
            if (album != null)
              _MenuAction(
                icon: Icons.album_outlined,
                title: 'Перейти к альбому',
                onTap: () => _openAlbum(context, album),
              ),
            if (artist != null || album != null) const Divider(height: 1),
            // Для играющего трека «играть следующим» и «в очередь»
            // бессмысленны: он уже звучит. Вместо них — убрать из очереди.
            // Для остальных действия прежние.
            if (isCurrent && inQueue)
              _MenuAction(
                icon: Icons.remove_circle_outline,
                title: 'Убрать из очереди',
                onTap: () {
                  Navigator.pop(context);
                  // У играющего берём его настоящий индекс: при дублях
                  // `indexWhere` вернул бы первое вхождение, а не то, что
                  // звучит сейчас.
                  ref.read(playerControllerProvider.notifier).removeFromQueue(
                        currentIndex >= 0 ? currentIndex : queueIndex,
                      );
                },
              )
            else ...<Widget>[
              _MenuAction(
                icon: Icons.queue_play_next,
                title: 'Играть следующим',
                onTap: () {
                  Navigator.pop(context);
                  ref.read(playerControllerProvider.notifier).playNext(track);
                },
              ),
              _MenuAction(
                icon: Icons.playlist_add,
                title: 'В очередь',
                onTap: () {
                  Navigator.pop(context);
                  ref.read(playerControllerProvider.notifier).enqueue(track);
                },
              ),
            ],
            // Радио доступно у любого трека — и у играющего, и у того, что
            // просто лежит в списке: YouTube Music строит рекомендации по
            // любому видео.
            _MenuAction(
              icon: Icons.radio,
              title: 'Начать радио',
              onTap: () {
                Navigator.pop(context);
                ref.read(playerControllerProvider.notifier).startRadio(track);
              },
            ),
            // Клип есть только у самого видео: у обычной песни YouTube отдал
            // бы звуковую дорожку, и пункт был бы обманом.
            if (track.isVideo)
              _MenuAction(
                icon: Icons.play_circle_outline,
                title: 'Смотреть клип',
                onTap: () => _openClip(context),
              ),
            // Ссылка — тот же id: на YouTube Music он открывает именно этот
            // трек. Скопировать и открыть — два разных намерения (отправить
            // другу и послушать самому), поэтому пункта два.
            _MenuAction(
              icon: Icons.link,
              title: 'Копировать ссылку',
              onTap: () => _copyLink(context),
            ),
            _MenuAction(
              icon: Icons.open_in_new,
              title: 'Открыть в YouTube Music',
              onTap: () => _openInYouTubeMusic(context),
            ),
            _MenuAction(
              icon: Icons.playlist_add,
              title: 'Добавить в плейлист',
              // Без входа YouTube не примет правку плейлиста — как и лайк.
              onTap: signedIn ? () => _openAddToPlaylist(context) : null,
            ),
            // Параметры потока — только там, где поток уже играет: пункт
            // приходит из плеера вместе с колбэком.
            if (onMediaInfo != null)
              _MenuAction(
                icon: Icons.info_outline,
                title: 'Детали потока',
                onTap: () {
                  Navigator.pop(context);
                  onMediaInfo!();
                },
              ),
            _MenuAction(
              icon: liked ? Icons.favorite : Icons.favorite_border,
              title: liked ? 'Убрать из «Мне нравится»' : 'Мне нравится',
              // Без входа действие недоступно — как и кнопка лайка в плеере.
              onTap: signedIn ? () => _toggleLike(ref) : null,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _openArtist(BuildContext sheetContext, ArtistRef artist) {
    Navigator.pop(sheetContext);
    AppRoutes.artist(hostContext, artist.id!, root: rootNavigator);
  }

  void _openAlbum(BuildContext sheetContext, AlbumRef album) {
    Navigator.pop(sheetContext);
    AppRoutes.album(hostContext, album.id!, root: rootNavigator);
  }

  void _openClip(BuildContext sheetContext) {
    Navigator.pop(sheetContext);
    // Клип, как и плеер, живёт в корневом навигаторе — иначе при открытии из
    // полноэкранного плеера он остался бы под его экраном.
    AppRoutes.clip(hostContext, track);
  }

  /// Ссылка на трек в YouTube Music: id трека — это и есть videoId.
  Uri get _watchUri =>
      Uri.parse('https://music.youtube.com/watch?v=${track.id}');

  /// Кладёт ссылку в буфер обмена и подтверждает это.
  ///
  /// Лист закрываем сразу: держать его открытым, пока пользователь идёт
  /// вставлять ссылку, незачем. Сообщение показываем на контексте хоста —
  /// контекст листа к этому моменту уже снят.
  Future<void> _copyLink(BuildContext sheetContext) async {
    Navigator.pop(sheetContext);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(hostContext);
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
  Future<void> _openInYouTubeMusic(BuildContext sheetContext) async {
    Navigator.pop(sheetContext);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(hostContext);
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

  /// Закрывает меню и открывает выбор плейлиста для этого трека.
  ///
  /// Диалог показываем уже после закрытия листа: два модальных слоя друг над
  /// другом на одном контексте конфликтуют, а лист после нажатия всё равно
  /// должен уйти.
  void _openAddToPlaylist(BuildContext sheetContext) {
    Navigator.pop(sheetContext);
    showAddToPlaylistDialog(hostContext, track);
  }

  /// Первый исполнитель с id: у трека с несколькими авторами на страницу
  /// можно уйти только к одному, и YouTube кладёт основного первым.
  ArtistRef? _firstNavigableArtist() {
    for (final ArtistRef artist in track.artists) {
      if (artist.isNavigable) return artist;
    }
    return null;
  }

  Future<void> _toggleLike(WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(hostContext);
    final bool wasLiked = ref.read(likedIdsProvider).contains(track.id);
    try {
      await ref.read(likedIdsProvider.notifier).toggle(track.id);
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
  });

  final IconData icon;
  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      enabled: onTap != null,
      onTap: onTap,
    );
  }
}
