import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mops/core/updates/app_version.dart';
import 'package:mops/core/updates/update_check.dart';
import 'package:mops/features/settings/updates_screen.dart';
import 'package:mops/state/providers.dart';

/// Подставной ответ GitHub Releases: сеть в тестах не нужна, а разбор ответа
/// и сравнение версий — единственное, что здесь может сломаться.
String _releasesJson(List<Map<String, dynamic>> releases) =>
    jsonEncode(releases);

Map<String, dynamic> _release({
  required String tag,
  String? name,
  String body = 'Список изменений',
  bool prerelease = false,
  bool draft = false,
  String? publishedAt = '2026-10-01T10:00:00Z',
}) =>
    <String, dynamic>{
      'tag_name': tag,
      'name': name ?? tag,
      'body': body,
      'html_url': 'https://github.com/PerQ4/mops/releases/tag/$tag',
      'prerelease': prerelease,
      'draft': draft,
      'published_at': publishedAt,
    };

UpdateChecker _checker({
  required String body,
  String current = 'v0.2.12',
  int status = 200,
}) {
  final MockClient client = MockClient((http.Request request) async {
    expect(request.url.toString(), kReleasesApiUrl);
    // Кодировка задана явно: в теле есть кириллица, а `http.Response` без
    // `charset` кодирует строку в latin1 и падает на ней.
    return http.Response(
      body,
      status,
      headers: const <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );
  });
  return UpdateChecker(
    client: client,
    currentVersion: current,
    timeout: const Duration(seconds: 1),
  );
}

void main() {
  group('разбор версии', () {
    test('терпит v, номер сборки и метку предварительной версии', () {
      expect(AppVersion.tryParse('v1.2.3'), const AppVersion(1, 2, 3));
      expect(AppVersion.tryParse('0.2.12+1'), const AppVersion(0, 2, 12));
      expect(
        AppVersion.tryParse('v0.2.0-home.1'),
        const AppVersion(0, 2, 0, 'home.1'),
      );
      expect(AppVersion.tryParse('1.0'), const AppVersion(1, 0, 0));
      expect(AppVersion.tryParse(''), isNull);
      expect(AppVersion.tryParse('ночной'), isNull);
      expect(AppVersion.tryParse(null), isNull);
    });

    test('сравнивает числа как числа, а не как строки', () {
      expect(
        AppVersion.tryParse('v0.10.0')!.compareTo(AppVersion.tryParse('0.9.9')!),
        greaterThan(0),
      );
      expect(
        AppVersion.tryParse('v0.2.12')!.compareTo(AppVersion.tryParse('0.2.12+1')!),
        0,
      );
    });

    test('стабильная версия новее своей предварительной', () {
      expect(
        AppVersion.tryParse('v1.0.0')!.compareTo(AppVersion.tryParse('v1.0.0-beta')!),
        greaterThan(0),
      );
      expect(
        AppVersion.tryParse('v1.0.0-beta.2')!
            .compareTo(AppVersion.tryParse('v1.0.0-beta.10')!),
        lessThan(0),
      );
    });
  });

  group('разбор ответа API', () {
    test('берёт только релизы с тегом и пропускает черновики', () {
      final List<ReleaseInfo> releases = parseReleases(
        jsonDecode(_releasesJson(<Map<String, dynamic>>[
          _release(tag: 'v0.3.0'),
          _release(tag: 'v0.4.0', draft: true),
          <String, dynamic>{'name': 'без тега'},
        ])),
      );
      expect(releases, hasLength(1));
      expect(releases.single.tagName, 'v0.3.0');
      expect(releases.single.notes, 'Список изменений');
    });

    test('мусор вместо списка не роняет разбор', () {
      expect(parseReleases(null), isEmpty);
      expect(parseReleases(<String, dynamic>{}), isEmpty);
    });
  });

  group('проверка обновлений', () {
    test('находит более новый релиз', () async {
      final UpdateCheck? check = await _checker(
        body: _releasesJson(<Map<String, dynamic>>[
          _release(tag: 'v0.3.0', body: 'Добавлены обновления'),
        ]),
      ).check();

      expect(check, isNotNull);
      expect(check!.updateAvailable, isTrue);
      expect(check.latest!.tagName, 'v0.3.0');
      expect(check.latest!.notes, 'Добавлены обновления');
    });

    test('та же версия — обновления нет', () async {
      final UpdateCheck? check = await _checker(
        body: _releasesJson(<Map<String, dynamic>>[_release(tag: 'v0.2.12')]),
      ).check();

      expect(check!.updateAvailable, isFalse);
      expect(check.latest!.tagName, 'v0.2.12');
    });

    test('среди нескольких релизов выбирает самый новый', () async {
      final UpdateCheck? check = await _checker(
        body: _releasesJson(<Map<String, dynamic>>[
          _release(tag: 'v0.3.0'),
          _release(tag: 'v0.10.0'),
          _release(tag: 'v0.9.0'),
        ]),
      ).check();

      expect(check!.latest!.tagName, 'v0.10.0');
    });

    test('бета не предлагается стабильной сборке', () async {
      final UpdateCheck? check = await _checker(
        body: _releasesJson(<Map<String, dynamic>>[
          _release(tag: 'v0.2.13', prerelease: true),
        ]),
      ).check();

      expect(check!.updateAvailable, isFalse);
    });

    test('бета предлагается бетe', () async {
      final UpdateCheck? check = await _checker(
        current: 'v0.2.12-home.1',
        body: _releasesJson(<Map<String, dynamic>>[
          _release(tag: 'v0.2.13-home.1', prerelease: true),
        ]),
      ).check();

      expect(check!.updateAvailable, isTrue);
    });

    test('ошибка сервера и обрыв связи — тихое «ничего»', () async {
      expect(
        await _checker(body: 'нет', status: 500).check(),
        isNull,
      );

      final UpdateChecker broken = UpdateChecker(
        client: MockClient((http.Request request) async {
          throw const SocketExceptionStub();
        }),
        currentVersion: 'v0.2.12',
      );
      expect(await broken.check(), isNull);
    });

    test('без известной текущей версии сравнивать не с чем', () async {
      expect(
        await _checker(
          current: '',
          body: _releasesJson(<Map<String, dynamic>>[_release(tag: 'v0.3.0')]),
        ).check(),
        isNull,
      );
    });
  });

  group('экран обновлений', () {
    Future<void> pumpScreen(WidgetTester tester, UpdateCheck? result) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            updateCheckProvider.overrideWith(
              (Ref ref) async => result,
            ),
          ],
          child: const MaterialApp(home: UpdatesScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('показывает версию, кнопку и лог изменений',
        (WidgetTester tester) async {
      await pumpScreen(
        tester,
        UpdateCheck(
          currentVersion: 'v0.2.12',
          latest: ReleaseInfo(
            tagName: 'v0.3.0',
            title: 'mOps 0.3.0',
            notes: 'Добавлены обновления и свой шрифт',
            pageUrl: 'https://github.com/PerQ4/mops/releases/tag/v0.3.0',
            prerelease: false,
            publishedAt: DateTime.utc(2026, 10, 1),
          ),
          updateAvailable: true,
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Доступна версия v0.3.0'), findsOneWidget);
      expect(find.text('Скачать'), findsOneWidget);
      expect(find.text('Добавлены обновления и свой шрифт'), findsOneWidget);
    });

    testWidgets('без сети — одна спокойная строка, а не ошибка',
        (WidgetTester tester) async {
      await pumpScreen(tester, null);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Не удалось проверить обновления'), findsOneWidget);
      expect(find.text('Скачать'), findsNothing);
    });
  });
}

/// Замена `SocketException`: `dart:io` в тесте не нужен, достаточно любого
/// исключения, которое проверка обязана проглотить.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
