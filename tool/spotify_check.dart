// Инструмент для проверки: печать в консоль здесь уместна.
// ignore_for_file: avoid_print

// Проверка механики Spotify: секрет, время сервера, код TOTP.
import 'dart:io';
import 'package:mops/data/sources/spotify_client.dart';

Future<void> main() async {
  final SpotifyClient client = SpotifyClient();
  // Проверяем, что секрет и время сервера читаются, а код считается.
  print('секрет и время читаются: '
      '${await client.debugTotp() ?? "не удалось"}');
  // Токен без cookie не выдадут — проверяем подготовительные шаги.
  try {
    await client.authorize('');
    print('токен получен (неожиданно)');
  } on SpotifyException catch (e) {
    print('шаги пройдены, ожидаемая остановка: ${e.message}');
  }
  client.dispose();
  exit(0);
}
