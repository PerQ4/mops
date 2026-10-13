// Проверка логики обхода блокировок: какие домены подменяются и как
// конфигурация переживает сохранение. Сеть не используется.
import 'package:flutter_test/flutter_test.dart';
import 'package:mops/core/net/anti_dpi.dart';
import 'package:mops/core/net/fronting.dart';

void main() {
  group('подмена хоста — выбор доменов', () {
    const FrontingConfig on = FrontingConfig(enabled: true);

    test('подменяются домены YouTube и медиахостов', () {
      for (final String host in <String>[
        'youtube.com',
        'music.youtube.com',
        'www.youtube.com',
        'i.ytimg.com',
        'yt3.ggpht.com',
        'rr1---sn-4g5e6nez.googlevideo.com',
        'redirector.googlevideo.com',
        'lh3.googleusercontent.com',
      ]) {
        expect(on.shouldFront(host), isTrue, reason: 'не подменяется: $host');
      }
    });

    test('чужие домены не подменяются', () {
      // Сертификат проверяется по имени фронта, поэтому подмена чужого домена
      // не только бесполезна, но и сломала бы проверку сертификата.
      for (final String host in <String>[
        'example.com',
        'github.com',
        'youtube.com.evil.example',
        'notyoutube.com',
      ]) {
        expect(on.shouldFront(host), isFalse, reason: 'подменяется лишнее: $host');
      }
    });

    test('сам узел подмены не подменяется', () {
      expect(on.shouldFront(FrontingConfig.defaultFrontHost), isFalse);
    });

    test('при выключенной подмене ничего не меняется', () {
      const FrontingConfig off = FrontingConfig();
      expect(off.shouldFront('music.youtube.com'), isFalse);
    });

    test('пустой узел подмены отключает механизм', () {
      const FrontingConfig broken =
          FrontingConfig(enabled: true, frontHost: '');
      expect(broken.shouldFront('music.youtube.com'), isFalse);
    });
  });

  group('конфигурация обхода', () {
    test('по умолчанию обход выключен', () {
      const AntiDpiConfig config = AntiDpiConfig();
      expect(config.isEnabled, isFalse);
      expect(config.isEnabled, isFalse);
    });

    test('подмена хоста включается отдельно от прокси', () {
      const AntiDpiConfig config =
          AntiDpiConfig(fronting: FrontingConfig(enabled: true));
      expect(config.isEnabled, isTrue);
      expect(config.usesProxy, isFalse);
    });

    test('прокси без адреса не считается включённым', () {
      const AntiDpiConfig config = AntiDpiConfig(
        proxyKind: ProxyKind.socks5,
        proxyHost: '',
      );
      expect(config.usesProxy, isFalse);
      expect(config.isEnabled, isFalse);
    });

    test('SOCKS5 требует локального узла, HTTP — нет', () {
      const AntiDpiConfig socks = AntiDpiConfig(
        proxyKind: ProxyKind.socks5,
        proxyHost: '127.0.0.1',
        proxyPort: 1080,
      );
      const AntiDpiConfig http = AntiDpiConfig(
        proxyKind: ProxyKind.http,
        proxyHost: '127.0.0.1',
        proxyPort: 8080,
      );
      // dart:io умеет HTTP-прокси сам, а SOCKS5 — нет.
      expect(socks.needsRelay, isTrue);
      expect(http.needsRelay, isFalse);
    });

    test('настройки сохраняются и читаются без потерь', () {
      const AntiDpiConfig source = AntiDpiConfig(
        fronting: FrontingConfig(enabled: true, frontHost: 'www.google.com'),
        fragmentation: FragmentationLevel.medium,
        proxyKind: ProxyKind.socks5,
        proxyHost: '127.0.0.1',
        proxyPort: 1080,
        proxyUsername: 'user',
        proxyPassword: 'secret',
      );

      final AntiDpiConfig restored = AntiDpiConfig.fromJson(source.toJson());

      expect(restored.fronting.enabled, isTrue);
      expect(restored.fronting.frontHost, 'www.google.com');
      expect(restored.proxyKind, ProxyKind.socks5);
      expect(restored.proxyHost, '127.0.0.1');
      expect(restored.proxyPort, 1080);
      expect(restored.proxyUsername, 'user');
      expect(restored.proxyPassword, 'secret');
      expect(restored.fragmentation, FragmentationLevel.medium);
    });

    test('битый JSON не роняет приложение', () {
      final AntiDpiConfig restored = AntiDpiConfig.fromJson(
        <String, dynamic>{'proxyKind': 'неизвестный', 'proxyPort': 'не число'},
      );
      expect(restored.proxyKind, ProxyKind.none);
      expect(restored.fronting.frontHost, FrontingConfig.defaultFrontHost);
    });
  });
}
