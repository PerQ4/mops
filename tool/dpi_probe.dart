// Проверка обхода SNI-блокировки на живом соединении.
//
// Запуск:
//   dart run tool/dpi_probe.dart                     — с системным DNS
//   dart run tool/dpi_probe.dart <ip>                — с заданным адресом
//
// Зачем адрес: на целевой сети системный DNS отдаёт только IPv6 через
// неработающий NAT64, поэтому имя не разрешается вовсе. Передав адрес,
// мы изолируем проверку фрагментации от проблемы с DNS.
import 'dart:async';
import 'dart:io';

import 'package:mops/core/net/anti_dpi.dart';

const String kHost = 'music.youtube.com';
const int kPort = 443;

/// TLS-рукопожатие поверх уже готового сокета.
Future<SecureSocket> handshake(Socket raw) {
  return SecureSocket.secure(
    raw,
    host: kHost,
    onBadCertificate: (X509Certificate _) => true,
  ).timeout(const Duration(seconds: 12));
}

Future<String> direct(String? ip) async {
  final Stopwatch watch = Stopwatch()..start();
  Socket? raw;
  SecureSocket? secure;
  try {
    raw = await Socket.connect(ip ?? kHost, kPort,
        timeout: const Duration(seconds: 10));
    secure = await handshake(raw);
    return 'OK за ${watch.elapsedMilliseconds} мс';
  } on Object catch (error) {
    return 'ПРОВАЛ за ${watch.elapsedMilliseconds} мс — ${_short(error)}';
  } finally {
    await _closeQuietly(secure, raw);
  }
}

Future<String> fragmented(
  String? ip,
  FragmentationLevel level,
  int delayMs,
) async {
  final FragmentingRelay relay = await FragmentingRelay.start(
    AntiDpiConfig(fragmentation: level, fragmentDelayMs: delayMs),
  );
  final Stopwatch watch = Stopwatch()..start();
  Socket? raw;
  SecureSocket? secure;
  try {
    raw = await Socket.connect(InternetAddress.loopbackIPv4, relay.port);
    raw.write('direct ${ip ?? kHost} $kPort\n');
    await raw.flush();
    secure = await handshake(raw);
    return 'OK за ${watch.elapsedMilliseconds} мс';
  } on Object catch (error) {
    return 'ПРОВАЛ за ${watch.elapsedMilliseconds} мс — ${_short(error)}';
  } finally {
    await _closeQuietly(secure, raw);
    await relay.close();
  }
}

Future<void> _closeQuietly(SecureSocket? secure, Socket? raw) async {
  try {
    await secure?.close();
  } on Object {
    // Соединение могло быть уже разрушено — это ожидаемо при блокировке.
  }
  try {
    raw?.destroy();
  } on Object {
    // Ничего не делаем.
  }
}

String _short(Object error) {
  final String text = error.toString().replaceAll('\n', ' ');
  return text.length > 100 ? '${text.substring(0, 100)}…' : text;
}

Future<void> main(List<String> args) async {
  final String? ip = args.isNotEmpty ? args.first : null;

  stdout.writeln('Хост: $kHost, адрес: ${ip ?? "системный DNS"}');
  stdout.writeln('TCP → TLS без фрагментации: ${await direct(ip)}\n');

  for (final FragmentationLevel level in <FragmentationLevel>[
    FragmentationLevel.soft,
    FragmentationLevel.medium,
    FragmentationLevel.aggressive,
  ]) {
    final String result = await fragmented(ip, level, 1);
    stdout.writeln('${level.label.padRight(28)} $result');
  }

  exit(0);
}
