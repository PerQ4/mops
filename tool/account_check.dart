// Проверяет ответ account/account_menu с реальной сессией.
//
// Запуск: dart run tool/account_check.dart
import 'dart:convert';
import 'dart:io';

import 'package:mops/core/innertube/innertube_client.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/bypass.dart';

const String _sessionPath =
    '/home/perqa/.local/share/com.mops.mops/session.json';

Future<void> main() async {
  await BypassManager.instance.apply(const AntiDpiConfig());

  final String cookieString = (jsonDecode(
    File(_sessionPath).readAsStringSync(),
  ) as Map<String, dynamic>)['cookieString'] as String;
  final CookieAuth auth = CookieAuth(cookieString);

  final InnerTubeClient client = InnerTubeClient(
    auth: auth,
    locale: 'ru',
    region: 'RU',
  );

  final Map<String, dynamic> res = await client.post(
    'account/account_menu',
    body: <String, dynamic>{},
    authenticated: true,
  );

  stdout.writeln('== верхний уровень ответа ==');
  stdout.writeln('  ключи: ${res.keys.join(", ")}');

  final dynamic actions = res['actions'];
  stdout.writeln('\n== actions ==');
  if (actions is List) {
    for (final dynamic action in actions) {
      if (action is Map) {
        stdout.writeln('  ключи действия: ${action.keys.join(", ")}');
        final dynamic popup = (action['openPopupAction'] as Map?)?['popup'];
        if (popup is Map) {
          stdout.writeln('  popup: ${popup.keys.join(", ")}');
          final dynamic menu = popup['multiPageMenuRenderer'];
          if (menu is Map) {
            stdout.writeln('  multiPageMenu: ${menu.keys.join(", ")}');
            final dynamic header = menu['header'];
            if (header is Map) {
              stdout.writeln('  header: ${header.keys.join(", ")}');
            }
          }
        }
      }
    }
  } else {
    stdout.writeln('  actions: ${actions.runtimeType}');
  }

  // Дамп первого уровня для разбора.
  stdout.writeln('\n== полный ответ (первые 1500 символов) ==');
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(res).substring(
        0,
        1500,
      ));

  client.dispose();
  await BypassManager.instance.dispose();
  exit(0);
}
