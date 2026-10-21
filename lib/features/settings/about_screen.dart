import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/layout.dart';
import '../../core/theme/motion.dart';
import '../../core/updates/app_version.dart';
import 'settings_components.dart';

/// Адрес проекта: один и тот же в шапке и в строке «Репозиторий».
const String _repositoryUrl = 'https://github.com/PerQ4/mops';

/// «О приложении»: версия, ссылки, лицензии и проекты, на которых построен mOps.
///
/// Отдельный экран, а не разросшаяся строка настроек: список проектов и
/// лицензии — это справочная информация, к настройкам поведения не относящаяся.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  /// Версия ищется один раз: чтение `pubspec.yaml` синхронное, а в `build`
  /// оно повторялось бы на каждую перерисовку.
  late final String? _version = resolveAppVersion();

  Future<void> _open(String url) async {
    final bool opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Не удалось открыть $url')));
    }
  }

  /// Лицензии открываются тем же переходом, что и подэкраны приложения:
  /// стандартный `MaterialPageRoute` принёс бы свою анимацию мимо словаря.
  void _openLicenses() {
    final MotionTransition motion = AppMotion.pageEnter;
    Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        transitionDuration: motion.duration,
        reverseTransitionDuration: motion.reverseDuration ?? motion.duration,
        pageBuilder:
            (
              BuildContext context,
              Animation<double> animation,
              Animation<double> secondaryAnimation,
            ) => LicensePage(
              applicationName: 'mOps',
              applicationVersion: _version,
              applicationLegalese:
                  'Неофициальный клиент YouTube Music. '
                  'Не связан с Google LLC и YouTube.',
            ),
        transitionsBuilder:
            (
              BuildContext context,
              Animation<double> animation,
              Animation<double> secondaryAnimation,
              Widget child,
            ) => motion.routeTransition(
              animation: animation,
              begin: const Offset(0, 0.02),
              child: child,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('О приложении')),
      body: ContentWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
          children: <Widget>[
            _Header(version: _version),
            const SizedBox(height: 24),

            SettingsGroup(
              title: 'Ссылки',
              accent: scheme.primary,
              children: <Widget>[
                SettingsRow(
                  icon: Icons.code,
                  title: 'Репозиторий',
                  subtitle: _repositoryUrl,
                  subtitleMaxLines: null,
                  onTap: () => _open(_repositoryUrl),
                ),
                SettingsRow(
                  icon: Icons.bug_report_outlined,
                  title: 'Сообщить о проблеме',
                  subtitle: 'Ошибки и предложения — в issues на GitHub',
                  onTap: () => _open('$_repositoryUrl/issues'),
                ),
              ],
            ),
            const SizedBox(height: 24),

            SettingsGroup(
              title: 'Лицензии',
              accent: scheme.tertiary,
              children: <Widget>[
                SettingsRow(
                  icon: Icons.description_outlined,
                  title: 'Лицензии открытого кода',
                  subtitle:
                      'Flutter, пакеты и проекты, на которых работает mOps',
                  onTap: _openLicenses,
                ),
              ],
            ),
            const SizedBox(height: 24),

            SettingsGroup(
              title: 'Проекты',
              accent: scheme.secondary,
              children: const <Widget>[
                _ProjectRow(
                  icon: Icons.phone_android,
                  name: 'ArchiveTune',
                  purpose:
                      'Эталон интерфейса, настроек и логики текстов; '
                      'из него взята схема движения.',
                ),
                _ProjectRow(
                  icon: Icons.play_circle_outline,
                  name: 'media_kit / libmpv',
                  purpose: 'Воспроизведение звука через mpv.',
                ),
                _ProjectRow(
                  icon: Icons.video_library_outlined,
                  name: 'youtube_explode_dart',
                  purpose: 'Доступ к YouTube: поиск, метаданные и аудиопотоки.',
                ),
                _ProjectRow(
                  icon: Icons.lyrics_outlined,
                  name: 'BetterLyrics',
                  purpose:
                      'Тексты Apple Music (TTML) с пословной синхронизацией.',
                ),
                _ProjectRow(
                  icon: Icons.auto_awesome_outlined,
                  name: 'YouLy+ / Lyricify',
                  purpose: 'Зеркала Lyricify: тексты в TTML и LRC.',
                ),
                _ProjectRow(
                  icon: Icons.public,
                  name: 'LRCLIB',
                  purpose: 'Открытая база синхронизированных текстов.',
                ),
                _ProjectRow(
                  icon: Icons.cloud_outlined,
                  name: 'KuGou',
                  purpose: 'Внешняя база текстов с временами строк.',
                ),
                _ProjectRow(
                  icon: Icons.hub_outlined,
                  name: 'Unison',
                  purpose: 'Поиск текстов по метаданным трека и id видео.',
                ),
                _ProjectRow(
                  icon: Icons.vpn_key_outlined,
                  name: 'Paxsenix',
                  purpose: 'Доступ к Apple Music и Musixmatch по ключу.',
                ),
                _ProjectRow(
                  icon: Icons.animation,
                  name: 'material_3_expressive',
                  purpose:
                      'Схема движения и выразительные формы '
                      'Material 3 Expressive.',
                ),
              ],
            ),
            const SizedBox(height: 24),

            Text(
              'mOps — неофициальное приложение. Оно не связано с Google LLC '
              'и YouTube; используйте его в рамках условий сервиса. Все '
              'названия проектов принадлежат их авторам.',
              style: text.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.version});

  final String? version;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Column(
      children: <Widget>[
        Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Icon(
            Icons.graphic_eq,
            size: 44,
            color: scheme.onPrimaryContainer,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'mOps',
          style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        // Версии нет — так и говорим: лучше честная строка, чем число,
        // которое разошлось с тегом сборки.
        SelectableText(
          version == null ? 'Версия не передана сборкой' : 'Версия $version',
          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Text(
          'Кросс-платформенный клиент YouTube Music на Flutter\n'
          'Material 3 Expressive',
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.icon,
    required this.name,
    required this.purpose,
  });

  final IconData icon;
  final String name;
  final String purpose;

  @override
  Widget build(BuildContext context) {
    return SettingsRow(
      icon: icon,
      title: name,
      subtitle: purpose,
      subtitleMaxLines: null,
    );
  }
}

/// Версия приложения из единственного честного источника — см.
/// `resolveAppVersion()` в `core/updates/app_version.dart`. Разбор живёт там,
/// потому что его читает ещё и проверка обновлений.
