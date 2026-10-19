import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/scrobbling/listenbrainz.dart';
import '../../core/scrobbling/scrobbler.dart';

/// Экран ListenBrainz: токен, состояние подключения и переключатель отправки.
class ListenBrainzScreen extends ConsumerStatefulWidget {
  const ListenBrainzScreen({super.key});

  @override
  ConsumerState<ListenBrainzScreen> createState() =>
      _ListenBrainzScreenState();
}

class _ListenBrainzScreenState extends ConsumerState<ListenBrainzScreen> {
  final TextEditingController _token = TextEditingController();

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ScrobbleState state = ref.watch(scrobblingProvider);
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('ListenBrainz')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: <Widget>[
          Text(
            'ListenBrainz — открытая площадка статистики. Достаточно вставить '
            'токен из профиля: трек уходит туда по тому же правилу, что и в '
            'Last.fm — половина песни или четыре минуты.',
            style: text.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          if (state.error != null) ...<Widget>[
            const SizedBox(height: 16),
            _ErrorCard(message: state.error!),
          ],
          const SizedBox(height: 16),
          if (state.listenBrainzConnected)
            _ConnectedView(state: state)
          else
            _ConnectView(token: _token, state: state),
        ],
      ),
    );
  }
}

/// Подключённый аккаунт: переключатель и отключение.
class _ConnectedView extends ConsumerWidget {
  const _ConnectedView({required this.state});

  final ScrobbleState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ScrobblerController controller =
        ref.read(scrobblingProvider.notifier);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Card(
          child: ListTile(
            leading: Icon(Icons.account_circle, color: scheme.primary),
            title: Text(
              state.listenBrainzUsername,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: const Text('Аккаунт подключён'),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: SwitchListTile(
            value: state.listenBrainzEnabled,
            onChanged: controller.setListenBrainzEnabled,
            title: const Text('Отправлять прослушивания'),
            subtitle: const Text('Треки попадают в статистику ListenBrainz'),
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => _confirmSignOut(context, controller),
            icon: Icon(Icons.logout, color: scheme.error),
            label: Text('Отключить', style: TextStyle(color: scheme.error)),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmSignOut(
    BuildContext context,
    ScrobblerController controller,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Отключить ListenBrainz?'),
        content: const Text(
          'Прослушивания перестанут отправляться, пока вы не подключитесь снова.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Отключить'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await controller.signOutListenBrainz();
  }
}

/// Ввод токена и подключение.
class _ConnectView extends ConsumerStatefulWidget {
  const _ConnectView({required this.token, required this.state});

  final TextEditingController token;
  final ScrobbleState state;

  @override
  ConsumerState<_ConnectView> createState() => _ConnectViewState();
}

class _ConnectViewState extends ConsumerState<_ConnectView> {
  @override
  Widget build(BuildContext context) {
    final ScrobbleState state = widget.state;
    final bool busy = state.busy;
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Токен пользователя',
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Скопируйте «User token» со страницы профиля ListenBrainz и '
              'вставьте сюда. Токен сохраняется локально.',
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: widget.token,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'User token'),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: <Widget>[
                TextButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse(kListenBrainzProfilePage),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Получить токен'),
                ),
                FilledButton.icon(
                  onPressed: busy ? null : _connect,
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link),
                  label: Text(busy ? 'Проверяем…' : 'Подключить'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _connect() async {
    final bool ok = await ref
        .read(scrobblingProvider.notifier)
        .connectListenBrainz(widget.token.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? 'ListenBrainz подключён'
            : ref.read(scrobblingProvider).error ?? 'Не удалось подключиться'),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          message,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: scheme.onErrorContainer),
        ),
      ),
    );
  }
}
