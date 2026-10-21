import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/inapp_login.dart';
import '../../core/theme/motion.dart';
import '../../core/webview/webview_environment.dart';
import '../../data/models/models.dart';
import '../../state/player_controller.dart';
import '../../widgets/app_progress.dart';
import '../shell/title_bar_visibility.dart';
import 'clip_embed.dart';

/// Просмотр клипа трека во встроенном браузере.
///
/// Наш плеер — это libmpv в сборке «только звук»
/// (`media_kit_libs_windows_audio`), видео в нём нет. Поэтому клип показываем
/// встроенным браузером (WebView2 в Windows, WKWebView в macOS) — тем же
/// механизмом, что и вход в аккаунт (см. `inAppLoginAvailable`).
///
/// Страницу клипа открываем с заголовком `Referer` (см. [clipReferer]): без
/// него YouTube отвечает «Ошибка 153». Часть клипов владелец всё равно
/// запрещает встраивать — тогда страница загружается, но играть нечему.
/// Поэтому переход во внешний браузер доступен всегда, а отказ плеера мы
/// распознаём и показываем вместо пустого окна понятное сообщение.
class ClipScreen extends ConsumerStatefulWidget {
  const ClipScreen({required this.track, super.key});

  final Track track;

  @override
  ConsumerState<ClipScreen> createState() => _ClipScreenState();
}

class _ClipScreenState extends ConsumerState<ClipScreen> {
  /// Канал своей шапки окна (см. `lib/features/shell/window_title_bar.dart` и
  /// `windows/runner/flutter_window.cpp`). Flutter не умеет управлять окном
  /// сам, а полноэкранному клипу нужно его развернуть — для этого берём уже
  /// существующий `toggleMaximize`, а не заводим новый нативный вызов.
  static const MethodChannel _windowChannel = MethodChannel('mops/window');

  /// Есть ли на этой системе встроенный браузер: на Linux его нет, там
  /// показываем запасной вариант с переходом во внешний браузер.
  late final bool _supported = inAppLoginAvailable;

  /// Идёт загрузка страницы клипа — поверх WebView держим индикатор.
  bool _loading = true;

  /// Документ клипа не загрузился — предлагаем открыть во внешнем браузере.
  bool _failed = false;

  /// Плеер отказался играть клип (запрет встраивания и подобное) — вместо
  /// страницы YouTube показываем своё объяснение.
  bool _embedRefused = false;

  /// Домен, с которого сейчас открыт клип. Начинаем с обычного `youtube.com`,
  /// при отказе один раз пробуем `youtube-nocookie.com`.
  ClipEmbedHost _host = ClipEmbedHost.youTube;

  /// Вторую попытку (nocookie) уже сделали — больше не повторяем.
  bool _retriedNoCookie = false;

  /// Проверяем отказ плеера не только сразу после загрузки, но и с небольшой
  /// задержкой: страница-отказ собирается скриптом уже после `onLoadStop`.
  Timer? _probeTimer;

  /// Проверка страницы уже идёт: вторую не запускаем, иначе две проверки
  /// решали бы судьбу клипа наперегонки (одна ещё видит старую страницу,
  /// вторая — уже новую).
  bool _probeInFlight = false;

  /// Ссылка на встроенный браузер: нужна, чтобы сменить адрес клипа при
  /// повторной попытке (уже созданный WebView новый `initialUrlRequest` не
  /// читает).
  InAppWebViewController? _webController;

  /// Полноэкранный режим: шапка скрыта, окно развёрнуто.
  bool _fullscreen = false;

  /// Окно развернули именно мы. Выходя из полноэкранного режима, возвращаем
  /// прежний размер, а не оставляем окно развёрнутым.
  bool _maximizedByFullscreen = false;

  /// Звук нашего плеера был активен до открытия клипа. Если да — после
  /// закрытия вернём воспроизведение; если трек стоял на паузе, не трогаем.
  bool _pausedByUs = false;

  /// Трек, который звучал (или догружался) в момент открытия клипа. Сверяем
  /// его при закрытии: за время просмотра очередь могла уйти вперёд (радио,
  /// горячие клавиши), и возобновлять звук уже чужого трека нельзя.
  String? _openedTrackId;

  /// Текущий трек плеера — обновляет подписка, чтобы в `dispose` не
  /// обращаться к `ref` (виджет к тому моменту уже снимается).
  String? _currentTrackId;

  /// Играет ли наш плеер сейчас. Нужно в `dispose`: если звук уже вернулся
  /// сам, повторный `play()` не нужен.
  bool _playerPlaying = false;

  /// Резолв ссылки шёл в момент открытия клипа: тогда `pause()` не помешает
  /// `load(autoplay: true)` заиграть, и трек нужно погасить, когда он
  /// действительно начнёт звучать (см. `_onPlayerChanged`).
  bool _pauseWhenLoaded = false;

  /// Ссылка на контроллер плеера: держим её, чтобы дёргать паузу/возврат
  /// без обращения к `ref` в `dispose` (там виджет уже снимается).
  PlayerController? _controller;

  /// Ссылка на клип во встроенном браузере. Заголовки запроса — см.
  /// `clip_embed.dart`: без `Referer` YouTube отвечает «Ошибка 153».
  URLRequest _embedRequest() => URLRequest(
        url: WebUri(clipEmbedUrl(widget.track.id, _host)),
        headers: clipEmbedHeaders(),
      );

  /// Ссылка для внешнего браузера — обычная страница просмотра, а не embed:
  /// только она обходит запрет на встраивание.
  Uri get _watchUrl =>
      Uri.parse('https://www.youtube.com/watch?v=${widget.track.id}');

  @override
  void initState() {
    super.initState();
    // Клип звучит сам, поэтому наш плеер ставим на паузу — иначе звук шёл бы
    // дважды. Запоминаем прежнее состояние, чтобы вернуть его при закрытии.
    // Считаем «активным» и загрузку/буферизацию: если трек ещё разгонялся,
    // без паузы он зазвучал бы поверх клипа.
    _controller = ref.read(playerControllerProvider.notifier);
    final PlayerUiState player = ref.read(playerControllerProvider);
    _openedTrackId = player.current?.id;
    _currentTrackId = player.current?.id;
    _playerPlaying = player.playback.isPlaying;
    // `isLoading` включает и резолв ссылки, и загрузку в режиме обхода: трек
    // ещё не звучит, но уже «в пути» — считать его активным нужно, чтобы
    // вернуть воспроизведение при закрытии.
    _pausedByUs = player.playback.isPlaying || player.isLoading;
    _pauseWhenLoaded = player.resolving || player.downloading;
    if (_pausedByUs) unawaited(_controller!.pause());
  }

  /// Следит за плеером, пока клип открыт.
  ///
  /// Нужен для двух вещей: заметить смену трека (см. [dispose]) и погасить
  /// звук, если трек, поставленный на паузу во время резолва, всё же заиграл
  /// после загрузки.
  void _onPlayerChanged(PlayerUiState? previous, PlayerUiState next) {
    _currentTrackId = next.current?.id;
    _playerPlaying = next.playback.isPlaying;
    if (_pauseWhenLoaded &&
        next.current?.id == _openedTrackId &&
        next.playback.isPlaying) {
      _pauseWhenLoaded = false;
      unawaited(_controller!.pause());
    }
  }

  @override
  void dispose() {
    _probeTimer?.cancel();
    // Возвращаем звук как было: играло — продолжаем, стояло — не трогаем.
    // `play()` возвращает Future, но здесь ждать нечего: маршрут уже снят.
    // Трек сверяем: если за время клипа очередь ушла вперёд, его звук не наш.
    if (_pausedByUs && _currentTrackId == _openedTrackId && !_playerPlaying) {
      unawaited(_controller?.play());
    }
    // Полноэкранный режим снимаем и при закрытии экрана, а не только по
    // кнопке: иначе окно осталось бы развёрнутым, а панели — скрытыми.
    if (_fullscreen) _restoreWindow();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // `listen`, а не `watch`: экран не должен перестраиваться на каждый тик
    // плеера, но обязан знать о смене трека и возврате звука.
    ref.listen<PlayerUiState>(playerControllerProvider, _onPlayerChanged);

    return Scaffold(
      // Клип — «тёмная комната»: чёрный фон не спорит с видео и интерфейсом.
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: <Widget>[
            Column(
              children: <Widget>[
                if (!_fullscreen)
                  _ClipHeader(
                    track: widget.track,
                    onClose: () => Navigator.maybePop(context),
                    onOpenExternal: _openExternal,
                    onToggleFullscreen: _toggleFullscreen,
                  ),
                Expanded(child: _content()),
              ],
            ),
            // В полноэкранном режиме шапки нет, поэтому выход и закрытие
            // держим поверх видео полупрозрачными кнопками.
            if (_fullscreen)
              Positioned(
                top: 8,
                right: 8,
                child: _FullscreenOverlay(
                  onOpenExternal: _openExternal,
                  onExit: _toggleFullscreen,
                  onClose: () => Navigator.maybePop(context),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Основная часть: клип, запасной вариант или сообщение об ошибке.
  Widget _content() {
    if (!_supported) {
      return _ClipFallback(
        message: 'На этой системе встроенный браузер недоступен, '
            'поэтому клип можно посмотреть только во внешнем браузере.',
        onOpenExternal: _openExternal,
      );
    }
    if (_failed) {
      return _ClipFallback(
        message: 'Не удалось загрузить клип во встроенном браузере.',
        onOpenExternal: _openExternal,
      );
    }
    if (_embedRefused) {
      return _ClipFallback(
        message: 'YouTube не отдал этот клип встроенному плееру — обычно это '
            'значит, что владелец запретил встраивание. Его можно посмотреть '
            'в браузере.',
        onOpenExternal: _openExternal,
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        InAppWebView(
          // Окружение WebView2 из каталога приложения: рядом с exe писать
          // нельзя, если приложение установлено в `Program Files`.
          webViewEnvironment: mopsWebViewEnvironment,
          initialUrlRequest: _embedRequest(),
          onWebViewCreated: (InAppWebViewController controller) {
            _webController = controller;
          },
          onLoadStart: (InAppWebViewController controller, WebUri? url) {
            // Старая проверка относится к прошлой странице: её отменяем,
            // иначе она сработала бы уже на новом адресе.
            _probeTimer?.cancel();
            if (!mounted) return;
            setState(() => _loading = true);
          },
          onLoadStop: (InAppWebViewController controller, WebUri? url) {
            if (!mounted) return;
            setState(() => _loading = false);
            _scheduleProbe();
          },
          onReceivedError: (
            InAppWebViewController controller,
            WebResourceRequest request,
            WebResourceError error,
          ) {
            // Ошибки подресурсов (реклама, аналитика) не важны: реагируем
            // только на сбой самого документа клипа.
            if (!mounted || !(request.isForMainFrame ?? false)) return;
            setState(() {
              _loading = false;
              _failed = true;
            });
          },
        ),
        if (_loading) const Center(child: AppProgress()),
      ],
    );
  }

  /// Ставит проверку страницы: сразу и ещё раз с задержкой.
  ///
  /// Второй раз нужен потому, что страницу-отказ собирает скрипт плеера уже
  /// после `onLoadStop` — по одному лишь первому замеру отказ можно пропустить.
  void _scheduleProbe() {
    unawaited(_probePage());
    _probeTimer?.cancel();
    _probeTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_probePage());
    });
  }

  /// Спрашивает страницу, отказался ли плеер играть клип.
  ///
  /// Проверку не выдумываем нативными вызовами: читаем заголовок и текст
  /// страницы через `evaluateJavascript` и сверяем с известными текстами
  /// отказа (см. `clip_embed.dart`).
  Future<void> _probePage() async {
    if (!mounted || _embedRefused || _failed || _probeInFlight) return;
    final InAppWebViewController? controller = _webController;
    if (controller == null) return;
    _probeInFlight = true;
    try {
      final Object? result;
      try {
        result = await controller.evaluateJavascript(source: clipProbeScript);
      } on Object {
        // Прочитать страницу не вышло — не объявляем отказ наугад: пусть
        // страница останется как есть, кнопка внешнего браузера доступна.
        return;
      }
      if (!mounted) return;
      final ClipPageProbe probe = clipParseProbe(result);
      if (!clipLooksRefused(probe.title, probe.text)) return;
      await _onEmbedRefused();
    } finally {
      _probeInFlight = false;
    }
  }

  /// Плеер отказал: сначала пробуем запасной адрес, потом показываем сообщение.
  Future<void> _onEmbedRefused() async {
    if (!mounted || _embedRefused) return;
    if (!_retriedNoCookie) {
      // Причина отказа — в заголовке запроса, и он уже отправлен. Второй
      // адрес пробуем потому, что общий профиль WebView хранит вход в
      // аккаунт: nocookie не отправляет его cookie до начала
      // воспроизведения, а с ним YouTube может отказывать иначе.
      _retriedNoCookie = true;
      _host = ClipEmbedHost.youTubeNoCookie;
      _probeTimer?.cancel();
      final InAppWebViewController? controller = _webController;
      if (controller != null) {
        setState(() => _loading = true);
        try {
          await controller.loadUrl(urlRequest: _embedRequest());
          return;
        } on Object {
          // Адрес не сменился — дальше остаётся только внешний браузер.
        }
        if (!mounted) return;
      }
    }
    setState(() {
      _loading = false;
      _embedRefused = true;
    });
  }

  /// Включает/выключает полноэкранный режим.
  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
    if (_fullscreen) {
      unawaited(_enterFullscreen());
    } else {
      _restoreWindow();
    }
  }

  /// Разворачивает окно и убирает системные панели.
  Future<void> _enterFullscreen() async {
    // Свою шапку окна гасим сразу, не дожидаясь нативного разворота: она
    // нарисована выше навигатора (см. `app.dart`), и из дерева экрана её не
    // видно — единственный способ убрать её в полном экране.
    titleBarVisible.value = false;
    // На десктопе системных панелей нет и вызов ничего не делает; на
    // мобильных он убирает строку состояния и навигации.
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)
          .catchError((Object _) {}),
    );
    try {
      final bool maximized =
          await _windowChannel.invokeMethod<bool>('isMaximized') ?? false;
      // Разворачиваем, только если окно ещё не развёрнуто: иначе выход
      // вернул бы его в размер, которого пользователь не выбирал.
      if (!maximized && mounted && _fullscreen) {
        await _windowChannel.invokeMethod<void>('toggleMaximize');
        _maximizedByFullscreen = true;
      }
    } on Object {
      // Канал есть только на Windows — на других системах разворачивать
      // нечего, размером окна управляет оконная система.
    }
  }

  /// Возвращает системные панели и прежний размер окна.
  void _restoreWindow() {
    // Шапку окна возвращаем здесь же: так она восстанавливается и при выходе
    // из полного экрана, и при закрытии экрана прямо в нём (см. `dispose`).
    titleBarVisible.value = true;
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)
          .catchError((Object _) {}),
    );
    if (_maximizedByFullscreen) {
      _maximizedByFullscreen = false;
      _windowChannel
          .invokeMethod<void>('toggleMaximize')
          .catchError((Object _) {});
    }
  }

  /// Открывает клип во внешнем браузере системы.
  Future<void> _openExternal() async {
    bool ok = false;
    try {
      ok = await launchUrl(_watchUrl, mode: LaunchMode.externalApplication);
    } on Object {
      ok = false;
    }
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть браузер.')),
      );
    }
  }
}

/// Шапка: закрытие, название клипа, переход во внешний браузер и полный экран.
class _ClipHeader extends StatelessWidget {
  const _ClipHeader({
    required this.track,
    required this.onClose,
    required this.onOpenExternal,
    required this.onToggleFullscreen,
  });

  final Track track;
  final VoidCallback onClose;
  final Future<void> Function() onOpenExternal;
  final VoidCallback onToggleFullscreen;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: 'Закрыть',
            icon: const Icon(Icons.close_rounded, color: Colors.white),
            onPressed: onClose,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  track.artistLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),
          // Кнопка есть всегда: часть клипов YouTube не отдаёт для встраивания,
          // и страница внутри выглядит загруженной, хотя играть там нечего.
          IconButton(
            tooltip: 'Открыть во внешнем браузере',
            icon: const Icon(Icons.open_in_new, color: Colors.white),
            onPressed: () => onOpenExternal(),
          ),
          IconButton(
            tooltip: 'Во весь экран',
            icon: const Icon(Icons.fullscreen, color: Colors.white),
            onPressed: onToggleFullscreen,
          ),
        ],
      ),
    );
  }
}

/// Кнопки поверх видео в полноэкранном режиме: во внешний браузер, выход из
/// полного экрана и закрытие клипа.
class _FullscreenOverlay extends StatelessWidget {
  const _FullscreenOverlay({
    required this.onOpenExternal,
    required this.onExit,
    required this.onClose,
  });

  final Future<void> Function() onOpenExternal;
  final VoidCallback onExit;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _OverlayButton(
          icon: Icons.open_in_new,
          tooltip: 'Открыть во внешнем браузере',
          onTap: () => onOpenExternal(),
        ),
        const SizedBox(width: 8),
        _OverlayButton(
          icon: Icons.fullscreen_exit,
          tooltip: 'Выйти из полноэкранного режима',
          onTap: onExit,
        ),
        const SizedBox(width: 8),
        _OverlayButton(
          icon: Icons.close_rounded,
          tooltip: 'Закрыть',
          onTap: onClose,
        ),
      ],
    );
  }
}

/// Полупрозрачная кнопка поверх видео: глиф видно всегда, фон проявляется
/// при наведении — иначе над видео висели бы тяжёлые плашки.
class _OverlayButton extends StatefulWidget {
  const _OverlayButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_OverlayButton> createState() => _OverlayButtonState();
}

class _OverlayButtonState extends State<_OverlayButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: AppMotion.quickChange.duration,
            curve: AppMotion.quickChange.curve,
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: _hover ? 0.65 : 0.3),
            ),
            child: Icon(widget.icon, size: 22, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// Запасной вариант: понятное объяснение и переход во внешний браузер.
class _ClipFallback extends StatelessWidget {
  const _ClipFallback({required this.message, required this.onOpenExternal});

  final String message;
  final Future<void> Function() onOpenExternal;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.videocam_off_outlined,
              size: 56,
              color: Colors.white54,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: text.bodyLarge?.copyWith(color: Colors.white70),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onOpenExternal,
              icon: const Icon(Icons.open_in_new),
              label: const Text('Открыть в браузере'),
            ),
          ],
        ),
      ),
    );
  }
}
