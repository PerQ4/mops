import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/inapp_login.dart';
import '../../data/models/models.dart';
import '../../state/player_controller.dart';

/// Просмотр клипа трека во встроенном браузере.
///
/// Наш плеер — это libmpv в сборке «только звук»
/// (`media_kit_libs_windows_audio`), видео в нём нет. Поэтому клип показываем
/// встроенным браузером (WebView2 в Windows, WKWebView в macOS) — тем же
/// механизмом, что и вход в аккаунт (см. `inAppLoginAvailable`).
class ClipScreen extends ConsumerStatefulWidget {
  const ClipScreen({required this.track, super.key});

  final Track track;

  @override
  ConsumerState<ClipScreen> createState() => _ClipScreenState();
}

class _ClipScreenState extends ConsumerState<ClipScreen> {
  /// Есть ли на этой системе встроенный браузер: на Linux его нет, там
  /// показываем запасной вариант с переходом во внешний браузер.
  late final bool _supported = inAppLoginAvailable;

  /// Идёт загрузка страницы клипа — поверх WebView держим индикатор.
  bool _loading = true;

  /// Документ клипа не загрузился — предлагаем открыть во внешнем браузере.
  bool _failed = false;

  /// Был ли звук нашего плеера активен до открытия клипа. Если да — после
  /// закрытия вернём воспроизведение; если трек стоял на паузе, не трогаем.
  bool _wasPlaying = false;

  /// Ссылка на контроллер плеера: держим её, чтобы дёргать паузу/возврат
  /// без обращения к `ref` в `dispose` (там виджет уже снимается).
  PlayerController? _controller;

  /// Ссылка на клип во встроенном браузере. `rel=0` убирает чужие видео
  /// в конце, `autoplay=1` запускает клип сразу.
  String get _embedUrl =>
      'https://www.youtube.com/embed/${widget.track.id}?autoplay=1&rel=0';

  /// Ссылка для внешнего браузера — обычная страница просмотра, а не embed.
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
    _wasPlaying = player.playback.isPlaying || player.playback.isLoading;
    if (_wasPlaying) unawaited(_controller!.pause());
  }

  @override
  void dispose() {
    // Возвращаем звук как было: играло — продолжаем, стояло — не трогаем.
    // `play()` возвращает Future, но здесь ждать нечего: маршрут уже снят.
    if (_wasPlaying) unawaited(_controller?.play());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Клип — «тёмная комната»: чёрный фон не спорит с видео и интерфейсом.
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _ClipHeader(
              track: widget.track,
              onClose: () => Navigator.maybePop(context),
            ),
            Expanded(child: _content()),
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
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(_embedUrl)),
          onLoadStart: (InAppWebViewController controller, WebUri? url) {
            if (!mounted) return;
            setState(() => _loading = true);
          },
          onLoadStop: (InAppWebViewController controller, WebUri? url) {
            if (!mounted) return;
            setState(() => _loading = false);
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
        if (_loading) const Center(child: CircularProgressIndicator()),
      ],
    );
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

/// Шапка: кнопка закрытия и название клипа.
class _ClipHeader extends StatelessWidget {
  const _ClipHeader({required this.track, required this.onClose});

  final Track track;
  final VoidCallback onClose;

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
        ],
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
