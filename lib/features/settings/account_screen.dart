import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/oauth_device_flow.dart';
import '../../core/auth/inapp_login.dart';
import '../../core/auth/webview_login.dart';
import '../../core/auth/token_store.dart';
import '../../state/auth_controller.dart';
import '../../state/providers.dart';
import '../../state/shell.dart';

/// Вход в аккаунт YouTube Music.
///
/// Google не выдаёт сторонним приложениям общие ключи, поэтому поддерживаются
/// два пути: собственный OAuth-клиент (аккуратный, с автообновлением токена)
/// и cookie браузера (быстрый, но токен живёт ограниченно).
class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  final TextEditingController _clientId = TextEditingController();
  final TextEditingController _clientSecret = TextEditingController();
  final TextEditingController _cookies = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Подставляем ранее сохранённые значения, чтобы не вводить заново.
    final settings = ref.read(settingsControllerProvider);
    _clientId.text = settings.oauthClientId;
    _clientSecret.text = settings.oauthClientSecret;
  }

  @override
  void dispose() {
    _clientId.dispose();
    _clientSecret.dispose();
    _cookies.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AuthState auth = ref.watch(authControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Аккаунт')),
      body: auth.isSignedIn
          ? _SignedInView(auth: auth)
          : _SignedOutView(
              clientId: _clientId,
              clientSecret: _clientSecret,
              cookies: _cookies,
            ),
    );
  }
}

/// Профиль и выход.
class _SignedInView extends ConsumerWidget {
  const _SignedInView({required this.auth});

  final AuthState auth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AuthController controller = ref.read(authControllerProvider.notifier);
    final AuthSession session = auth.session!;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: <Widget>[
                CircleAvatar(
                  radius: 32,
                  backgroundColor: scheme.secondaryContainer,
                  foregroundImage: (session.avatarUrl != null &&
                          session.avatarUrl!.isNotEmpty)
                      ? NetworkImage(session.avatarUrl!)
                      : null,
                  child: const Icon(Icons.person, size: 32),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        session.displayName ?? 'Аккаунт YouTube Music',
                        style: text.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        session.method.label,
                        style: text.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (auth.error != null) ...<Widget>[
          Card(
            color: scheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                auth.error!,
                style: text.bodyMedium
                    ?.copyWith(color: scheme.onErrorContainer),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        ListTile(
          leading: const Icon(Icons.refresh),
          title: const Text('Обновить сессию'),
          subtitle: const Text('Продлить доступ, если токен истёк'),
          onTap: auth.busy ? null : controller.refreshToken,
        ),
        ListTile(
          leading: Icon(Icons.logout, color: scheme.error),
          title: Text('Выйти', style: TextStyle(color: scheme.error)),
          onTap: () => _confirmSignOut(context, controller),
        ),
      ],
    );
  }

  Future<void> _confirmSignOut(
    BuildContext context,
    AuthController controller,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Выйти из аккаунта?'),
        content: const Text(
          'Личные плейлисты, лайки и подписки станут недоступны, '
          'пока вы не войдёте снова.',
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
    if (confirmed ?? false) await controller.signOut();
  }
}

/// Формы входа.
class _SignedOutView extends ConsumerWidget {
  const _SignedOutView({
    required this.clientId,
    required this.clientSecret,
    required this.cookies,
  });

  final TextEditingController clientId;
  final TextEditingController clientSecret;
  final TextEditingController cookies;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AuthState auth = ref.watch(authControllerProvider);
    final AuthController controller = ref.read(authControllerProvider.notifier);
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (auth.error != null) ...<Widget>[
          Card(
            color: scheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                auth.error!,
                style: text.bodyMedium
                    ?.copyWith(color: scheme.onErrorContainer),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],

        // ------------------------------------------- вход во встроенном браузере
        // Самый простой путь: поверх интерфейса открывается настоящая страница
        // входа Google, cookie забираются автоматически.
        const _WebviewLoginCard(),
        const SizedBox(height: 16),

        // Вход по cookie вручную. Нужен там, где встроенного браузера нет:
        // он построен на WebKitGTK и существует только на Linux, а на Windows
        // и macOS остаётся этот путь.
        const _CookieLoginCard(),
        const SizedBox(height: 16),

        // ------------------------------------------------------- OAuth device flow
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Вход через Google (OAuth)',
                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  'Безопасный способ: приложение не видит пароль, '
                  'а токен обновляется автоматически.',
                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                _OAuthInstructions(
                  clientId: clientId,
                  clientSecret: clientSecret,
                ),
                const SizedBox(height: 16),

                if (auth.pendingCode == null)
                  FilledButton.icon(
                    onPressed: auth.busy ? null : controller.startOAuthLogin,
                    icon: auth.busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login),
                    label: const Text('Получить код для входа'),
                  )
                else
                  _DeviceCodeBlock(
                    code: auth.pendingCode!,
                    waiting: auth.waitingForUser,
                    onConfirm: controller.completeOAuthLogin,
                    onCancel: controller.cancelOAuthLogin,
                  ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // ---------------------------------------------------------------- cookies
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Вход по cookie браузера',
                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  'Быстрый способ без Google Cloud. Откройте music.youtube.com, '
                  'войдите, затем скопируйте значение cookie с именем '
                  'SAPISID или __Secure-3PAPISID (можно вставить всю строку cookie).',
                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: cookies,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Cookie',
                    hintText: 'SAPISID=…; __Secure-3PAPISID=…',
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  onPressed: auth.busy
                      ? null
                      : () => controller.signInWithCookies(cookies.text),
                  icon: const Icon(Icons.cookie_outlined),
                  label: const Text('Войти по cookie'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Поля OAuth-клиента и краткая инструкция.
class _OAuthInstructions extends ConsumerWidget {
  const _OAuthInstructions({
    required this.clientId,
    required this.clientSecret,
  });

  final TextEditingController clientId;
  final TextEditingController clientSecret;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: Text(
            'Как получить client_id и client_secret',
            style: text.titleSmall?.copyWith(color: scheme.primary),
          ),
          children: <Widget>[
            Text(
              '1. Откройте console.cloud.google.com и создайте проект.\n'
              '2. Включите «YouTube Data API v3».\n'
              '3. В разделе «OAuth consent screen» добавьте себя как '
              'тестового пользователя.\n'
              '4. Создайте учётные данные → OAuth client ID → тип '
              '«TVs and Limited Input devices».\n'
              '5. Скопируйте client_id и client_secret сюда.\n\n'
              'Это бесплатно. Так же устроен вход в ytmusicapi и других '
              'неофициальных клиентах: Google не выдаёт общие ключи.',
              style: text.bodyMedium?.copyWith(height: 1.5),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: clientId,
          decoration: const InputDecoration(labelText: 'client_id'),
          onChanged: (String value) => ref
              .read(settingsControllerProvider.notifier)
              .setOAuthCredentials(
                clientId: value,
                clientSecret: settings.oauthClientSecret,
              ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: clientSecret,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'client_secret'),
          onChanged: (String value) => ref
              .read(settingsControllerProvider.notifier)
              .setOAuthCredentials(
                clientId: settings.oauthClientId,
                clientSecret: value,
              ),
        ),
        if (settings.oauthClientId.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Ключи сохранены локально',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

/// Код устройства: показываем код, ссылку и ожидание подтверждения.
class _DeviceCodeBlock extends StatelessWidget {
  const _DeviceCodeBlock({
    required this.code,
    required this.waiting,
    required this.onConfirm,
    required this.onCancel,
  });

  final DeviceCodeResponse code;
  final bool waiting;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Введите этот код на странице Google:',
          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: SelectableText(
                code.userCode,
                style: text.headlineSmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 3,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Скопировать код',
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: code.userCode));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Код скопирован')),
                  );
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(code.verificationUrlWithCode),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Открыть страницу входа'),
            ),
            FilledButton.icon(
              onPressed: waiting ? null : onConfirm,
              icon: waiting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
              label: Text(waiting ? 'Ожидание…' : 'Я подтвердил вход'),
            ),
            TextButton(onPressed: onCancel, child: const Text('Отмена')),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Ссылка без кода: ${code.verificationUrl}',
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}


/// Вход во встроенном браузере.
///
/// Показывается только там, где браузер доступен (сейчас это Linux).
/// Открывает поверх интерфейса страницу входа Google; как только вход
/// выполнен, панель закрывается сама, а cookie попадают в сессию приложения.
class _WebviewLoginCard extends ConsumerStatefulWidget {
  const _WebviewLoginCard();

  @override
  ConsumerState<_WebviewLoginCard> createState() => _WebviewLoginCardState();
}

/// Вход по cookie: вставить строку cookie из браузера.
class _CookieLoginCard extends ConsumerStatefulWidget {
  const _CookieLoginCard();

  @override
  ConsumerState<_CookieLoginCard> createState() => _CookieLoginCardState();
}

class _CookieLoginCardState extends ConsumerState<_CookieLoginCard> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    await ref
        .read(authControllerProvider.notifier)
        .signInWithCookies(_controller.text);
    if (!mounted) return;
    final String? error = ref.read(authControllerProvider).error;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Вход по cookie',
              style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Откройте music.youtube.com в браузере, скопируйте cookie '
              'аккаунта (нужен SAPISID) и вставьте сюда. Этот способ работает '
              'на любой системе.',
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              maxLines: 3,
              minLines: 2,
              decoration: const InputDecoration(
                hintText: 'SAPISID=…; SID=…; HSID=…',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _submit,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.key),
              label: Text(_busy ? 'Проверяем…' : 'Войти по cookie'),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: text.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Готов ли вход: нужен SAPISID и cookie домена YouTube (LOGIN_INFO).
///
/// Одного SAPISID мало: без cookie YouTube аккаунт считается гостем, и данные
/// не подтягиваются.
bool _hasYoutubeLogin(String cookies) {
  bool hasSapisid = false;
  bool hasYoutubeCookie = false;
  for (final String part in cookies.split(';')) {
    final String name = part.split('=').first.trim();
    if (name == 'SAPISID' || name == '__Secure-3PAPISID') hasSapisid = true;
    if (name == 'LOGIN_INFO' || name == 'VISITOR_INFO1_LIVE') {
      hasYoutubeCookie = true;
    }
  }
  return hasSapisid && hasYoutubeCookie;
}

class _WebviewLoginCardState extends ConsumerState<_WebviewLoginCard> {
  bool _available = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Панель входа есть либо в Linux (WebKitGTK), либо через встроенный
    // браузер системы (WebView2 в Windows, WKWebView в macOS).
    WebviewLogin.isAvailable().then((bool value) {
      if (mounted) {
        setState(() => _available = value || inAppLoginAvailable);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_available) return const SizedBox.shrink();

    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Вход во встроенном браузере',
              style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Откроется страница входа Google поверх приложения. Как только вы '
              'войдёте, она закроется сама, а приложение заберёт cookie — '
              'ничего копировать вручную не нужно.',
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _login,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.open_in_browser),
              label: Text(_busy ? 'Ждём вход…' : 'Войти в браузере'),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: text.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final String cookies = inAppLoginAvailable
          ? (await openInAppLogin(
                context,
                url: WebviewLogin.signInUrl,
                cookieHost: 'https://music.youtube.com',
                isDone: _hasYoutubeLogin,
              ) ??
              '')
          : await WebviewLogin.openLogin();
      if (cookies.isEmpty) {
        throw WebviewLoginException("Вход отменён.");
      }
      await ref
          .read(authControllerProvider.notifier)
          .signInWithCookies(cookies);
      if (!mounted) return;
      setState(() => _busy = false);

      // Показываем главную: после входа она перезагружается уже с данными
      // аккаунта, и это сразу видно.
      ref.read(shellIndexProvider.notifier).select(0);
      Navigator.of(context).popUntil((Route<dynamic> route) => route.isFirst);
    } on WebviewLoginException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Ошибка входа: $error';
      });
    }
  }
}
