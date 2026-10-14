import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/inapp_login.dart';
import '../../core/auth/webview_login.dart';
import '../../data/sources/spotify_client.dart';
import '../../data/sources/spotify_importer.dart';
import '../../state/catalog_providers.dart';

/// Перенос библиотеки из Spotify.
///
/// Вход выполняется во встроенном браузере — той же панелью, что и вход в
/// аккаунт Google. Так ключи Spotify не нужны вовсе: после входа у Spotify
/// забирается cookie сессии, по ней берётся токен, и уже им читаются
/// плейлисты.
class SpotifyImportScreen extends ConsumerStatefulWidget {
  const SpotifyImportScreen({super.key});

  @override
  ConsumerState<SpotifyImportScreen> createState() =>
      _SpotifyImportScreenState();
}

class _SpotifyImportScreenState extends ConsumerState<SpotifyImportScreen> {
  final SpotifyClient _client = SpotifyClient();

  bool _busy = false;
  String? _error;
  String? _status;
  List<SpotifyPlaylist>? _playlists;
  final Set<String> _selected = <String>{};

  @override
  void dispose() {
    _client.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Открываем вход в Spotify…';
    });

    try {
      // Панель входа есть либо в Linux (WebKitGTK), либо во встроенном
      // браузере системы (WebView2 в Windows, WKWebView в macOS).
      final String cookies = inAppLoginAvailable
          ? (await openInAppLogin(
                context,
                url: SpotifyClient.loginUrl,
                cookieHost: 'https://open.spotify.com',
                isDone: (String value) => _cookieValue(value, 'sp_dc') != null,
              ) ??
              '')
          : await WebviewLogin.openLogin(url: SpotifyClient.loginUrl);
      final String? spDc = _cookieValue(cookies, 'sp_dc');
      if (spDc == null) {
        throw const SpotifyException(
          'Вход не выполнен: Spotify не выдал cookie сессии.',
        );
      }

      setState(() => _status = 'Получаем доступ…');
      await _client.authorize(spDc);

      setState(() => _status = 'Читаем плейлисты…');
      final List<SpotifyPlaylist> playlists = await _client.playlists();
      if (!mounted) return;
      setState(() {
        _playlists = playlists;
        _busy = false;
        _status = playlists.isEmpty
            ? 'Плейлистов не нашлось — возможно, их нет в аккаунте.'
            : null;
      });
    } on WebviewLoginException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
          _error = error.message;
        });
      }
    } on SpotifyException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
          _error = error.message;
        });
      }
    }
  }

  Future<void> _import() async {
    final List<SpotifyPlaylist>? all = _playlists;
    if (all == null) return;
    final List<SpotifyPlaylist> chosen =
        all.where((SpotifyPlaylist p) => _selected.contains(p.id)).toList();
    if (chosen.isEmpty) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    final List<String> report = <String>[];
    try {
      for (final SpotifyPlaylist playlist in chosen) {
        final ImportResult result = await SpotifyImporter(
          spotify: _client,
          catalog: ref.read(catalogSourceProvider),
          library: ref.read(librarySourceProvider),
        ).importPlaylist(
          playlist,
          onProgress: (int done, int total) {
            if (mounted) {
              setState(() => _status = '${playlist.name}: $done из $total');
            }
          },
        );

        report.add(result.error != null
            ? '«${result.name}»: ${result.error}'
            : '«${result.name}»: перенесено ${result.matched}'
                '${result.missed.isEmpty ? "" : ", не найдено ${result.missed.length}"}');
      }

      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = report.join('\n');
        _selected.clear();
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Перенос прерван: $error';
        });
      }
    }
  }

  static String? _cookieValue(String cookies, String name) {
    for (final String part in cookies.split(';')) {
      final String trimmed = part.trim();
      final int eq = trimmed.indexOf('=');
      if (eq <= 0) continue;
      if (trimmed.substring(0, eq) == name) {
        return trimmed.substring(eq + 1);
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<SpotifyPlaylist>? playlists = _playlists;

    return Scaffold(
      appBar: AppBar(title: const Text('Перенос из Spotify')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
        children: <Widget>[
          Text(
            'Переносит плейлисты из Spotify в YouTube Music: треки ищутся по '
            'исполнителю и названию, а найденные складываются в новый плейлист '
            'с тем же названием. Ключи Spotify не нужны — вход выполняется '
            'во встроенном браузере.',
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),

          if (playlists == null)
            FilledButton.icon(
              onPressed: _busy ? null : _login,
              icon: const Icon(Icons.login),
              label: Text(_busy ? 'Ждём…' : 'Войти в Spotify'),
            )
          else ...<Widget>[
            Row(
              children: <Widget>[
                Text('Плейлисты', style: text.titleMedium),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() {
                    if (_selected.length == playlists.length) {
                      _selected.clear();
                    } else {
                      _selected
                        ..clear()
                        ..addAll(playlists.map((SpotifyPlaylist p) => p.id));
                    }
                  }),
                  child: Text(
                    _selected.length == playlists.length
                        ? 'Снять все'
                        : 'Выбрать все',
                  ),
                ),
              ],
            ),
            for (final SpotifyPlaylist playlist in playlists)
              CheckboxListTile(
                value: _selected.contains(playlist.id),
                onChanged: _busy
                    ? null
                    : (bool? value) => setState(() {
                          if (value ?? false) {
                            _selected.add(playlist.id);
                          } else {
                            _selected.remove(playlist.id);
                          }
                        }),
                title: Text(playlist.name),
                subtitle: Text('${playlist.trackCount} треков'),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy || _selected.isEmpty ? null : _import,
              icon: const Icon(Icons.download),
              label: Text(_busy
                  ? 'Переносим…'
                  : 'Перенести выбранные (${_selected.length})'),
            ),
          ],

          if (_status != null) ...<Widget>[
            const SizedBox(height: 20),
            Text(_status!, style: text.bodyMedium),
          ],
          if (_error != null) ...<Widget>[
            const SizedBox(height: 20),
            Text(
              _error!,
              style: text.bodyMedium?.copyWith(color: scheme.error),
            ),
          ],
        ],
      ),
    );
  }
}
