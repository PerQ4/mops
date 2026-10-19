import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/scrobbling/scrobbler.dart';

/// Страница регистрации приложения Last.fm — отсюда берут API key и secret.
const String _createAppUrl = 'https://www.last.fm/api/account/create';

/// Экран Last.fm: ключи приложения, вход по токену и состояние подключения.
class LastFmScreen extends ConsumerStatefulWidget {
  const LastFmScreen({super.key});

  @override
  ConsumerState<LastFmScreen> createState() => _LastFmScreenState();
}

class _LastFmScreenState extends ConsumerState<LastFmScreen> {
  final TextEditingController _apiKey = TextEditingController();
  final TextEditingController _apiSecret = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Поля подставляем из сохранённых значений, чтобы не вводить заново.
    final ScrobblerController controller =
        ref.read(scrobblingProvider.notifier);
    _apiKey.text = controller.lastFmApiKey;
    _apiSecret.text = controller.lastFmApiSecret;
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _apiSecret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ScrobbleState state = ref.watch(scrobblingProvider);
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Last.fm')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: <Widget>[
          Text(
            'Last.fm ведёт статистику прослушиваний. Трек отмечается '
            'в профиле, как только наберётся половина песни или четыре '
            'минуты — что наступит раньше.',
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
          if (state.lastFmConnected)
            _ConnectedView(state: state)
          else
            _LoginView(
              apiKey: _apiKey,
              apiSecret: _apiSecret,
              state: state,
            ),
        ],
      ),
    );
  }
}

/// Подключённый аккаунт: переключатели и выход.
class _ConnectedView extends ConsumerWidget {
  const _ConnectedView({required this.state});

  final ScrobbleState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ScrobblerController controller =
        ref.read(scrobblingProvider.notifier);
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Card(
          child: ListTile(
            leading: Icon(Icons.account_circle, color: scheme.primary),
            title: Text(
              state.lastFmUsername,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: const Text('Аккаунт подключён'),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: <Widget>[
              SwitchListTile(
                value: state.lastFmEnabled,
                onChanged: controller.setLastFmEnabled,
                title: const Text('Отправлять прослушивания'),
                subtitle: const Text(
                  'Треки попадают в статистику профиля Last.fm',
                ),
              ),
              const Divider(height: 1),
              SwitchListTile(
                value: state.lastFmNowPlaying,
                onChanged: controller.setLastFmNowPlaying,
                title: const Text('Показывать «сейчас играет»'),
                subtitle: const Text('Строка о текущем треке в профиле'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => _confirmSignOut(context, controller),
            icon: Icon(Icons.logout, color: scheme.error),
            label: Text('Выйти', style: TextStyle(color: scheme.error)),
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
        title: const Text('Отключить Last.fm?'),
        content: const Text(
          'Прослушивания перестанут отправляться, пока вы не войдёте снова.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await controller.signOutLastFm();
  }
}

/// Вход: ключи приложения, затем подтверждение токена в браузере.
class _LoginView extends ConsumerStatefulWidget {
  const _LoginView({
    required this.apiKey,
    required this.apiSecret,
    required this.state,
  });

  final TextEditingController apiKey;
  final TextEditingController apiSecret;
  final ScrobbleState state;

  @override
  ConsumerState<_LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends ConsumerState<_LoginView> {
  @override
  Widget build(BuildContext context) {
    final ScrobblerController controller =
        ref.read(scrobblingProvider.notifier);
    final ScrobbleState state = widget.state;
    final bool busy = state.busy;
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Ключи приложения',
                  style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  'Зарегистрируйте приложение на last.fm и скопируйте его '
                  'API key и shared secret. Ключи хранятся локально.',
                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: widget.apiKey,
                  decoration: const InputDecoration(labelText: 'API key'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: widget.apiSecret,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Shared secret'),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: <Widget>[
                    TextButton.icon(
                      onPressed: () => launchUrl(
                        Uri.parse(_createAppUrl),
                        mode: LaunchMode.externalApplication,
                      ),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Получить ключи'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: busy ? null : () => _save(controller),
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Сохранить ключи'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Вход в аккаунт',
                  style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  state.lastFmConfigured
                      ? 'Нажмите «Войти» — откроется страница Last.fm. '
                          'Подтвердите доступ и вернитесь сюда.'
                      : 'Сначала сохраните ключи приложения — без них вход '
                          'невозможен.',
                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                if (state.lastFmAuthToken == null)
                  FilledButton.icon(
                    onPressed:
                        busy || !state.lastFmConfigured ? null : _startAuth,
                    icon: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login),
                    label: Text(busy ? 'Ждём…' : 'Войти в Last.fm'),
                  )
                else
                  _ConfirmStep(
                    authUrl: state.lastFmAuthUrl,
                    busy: busy,
                    onConfirm: _completeAuth,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _save(ScrobblerController controller) async {
    await controller.saveLastFmCredentials(
      apiKey: widget.apiKey.text,
      apiSecret: widget.apiSecret.text,
    );
    if (!mounted) return;
    final String? error = ref.read(scrobblingProvider).error;
    _snack(error ?? 'Ключи сохранены');
  }

  Future<void> _startAuth() async {
    final String? url =
        await ref.read(scrobblingProvider.notifier).startLastFmAuth();
    if (!mounted || url == null) return;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } on Object catch (error) {
      if (!mounted) return;
      _snack('Не удалось открыть браузер: $error');
    }
  }

  Future<void> _completeAuth() async {
    final bool ok =
        await ref.read(scrobblingProvider.notifier).completeLastFmAuth();
    if (!mounted) return;
    _snack(ok
        ? 'Last.fm подключён'
        : ref.read(scrobblingProvider).error ?? 'Не удалось войти');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Второй шаг входа: ссылка и кнопка «я подтвердил».
class _ConfirmStep extends StatelessWidget {
  const _ConfirmStep({
    required this.authUrl,
    required this.busy,
    required this.onConfirm,
  });

  final String? authUrl;
  final bool busy;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Подтвердите вход на странице Last.fm, затем нажмите кнопку ниже.',
          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: <Widget>[
            if (authUrl != null)
              OutlinedButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse(authUrl!),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_browser),
                label: const Text('Открыть страницу'),
              ),
            FilledButton.icon(
              onPressed: busy ? null : onConfirm,
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
              label: Text(busy ? 'Проверяем…' : 'Я подтвердил вход'),
            ),
          ],
        ),
      ],
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
