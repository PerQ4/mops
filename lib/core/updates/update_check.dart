import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'app_version.dart';

/// Координаты проекта — те же, что в строке «Репозиторий» на экране «О
/// приложении». Отдельного поля в настройках нет: адрес один и он не меняется.
const String kUpdatesOwner = 'PerQ4';
const String kUpdatesRepo = 'mops';

/// Список релизов по GitHub API. Именно `/releases`, а не `/releases/latest`:
/// последний отдаёт только стабильный релиз, а приложение живёт и на
/// предварительных сборках (`v0.2.0-home.1`).
const String kReleasesApiUrl =
    'https://api.github.com/repos/$kUpdatesOwner/$kUpdatesRepo/releases';

/// Страница релизов для кнопки «Скачать» и для ручной проверки.
const String kReleasesPageUrl =
    'https://github.com/$kUpdatesOwner/$kUpdatesRepo/releases';

/// Один релиз из ответа API — только то, что показывается пользователю.
@immutable
class ReleaseInfo {
  const ReleaseInfo({
    required this.tagName,
    required this.title,
    required this.notes,
    required this.pageUrl,
    required this.prerelease,
    this.publishedAt,
  });

  final String tagName;
  final String title;

  /// Тело релиза — тот самый список изменений, который пишется в заметках.
  final String notes;

  /// Страница релиза в браузере.
  final String pageUrl;

  final bool prerelease;
  final DateTime? publishedAt;

  AppVersion? get version => AppVersion.tryParse(tagName);

  /// Разбирает элемент ответа API, отбрасывая всё, что не похоже на релиз.
  static ReleaseInfo? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final dynamic tag = raw['tag_name'];
    if (tag is! String || tag.trim().isEmpty) return null;

    final dynamic url = raw['html_url'];
    final dynamic name = raw['name'];
    final dynamic body = raw['body'];
    final dynamic published = raw['published_at'];

    return ReleaseInfo(
      tagName: tag.trim(),
      title: name is String && name.trim().isNotEmpty ? name.trim() : tag.trim(),
      notes: body is String ? body.trim() : '',
      pageUrl: url is String && url.trim().isNotEmpty
          ? url.trim()
          : '$kReleasesPageUrl/tag/${tag.trim()}',
      prerelease: raw['prerelease'] == true,
      publishedAt: published is String ? DateTime.tryParse(published) : null,
    );
  }
}

/// Результат проверки: что установлено и что предлагают.
@immutable
class UpdateCheck {
  const UpdateCheck({
    required this.currentVersion,
    required this.latest,
    required this.updateAvailable,
  });

  /// Текущая версия в том виде, в каком её дала сборка (`v0.2.12`, `0.2.12+1`).
  final String currentVersion;

  /// Самый новый подходящий релиз; `null` — релизов нет вовсе.
  final ReleaseInfo? latest;

  /// Новее ли [latest], чем установленная версия.
  final bool updateAvailable;
}

/// Проверка обновлений по GitHub Releases.
///
/// Сеть может не ответить по сотне причин (нет интернета, блокировка, лимит
/// запросов GitHub), и ни одна из них не повод для ошибки на весь экран:
/// проверка возвращает `null`, а интерфейс просто молчит. Поэтому исключения
/// здесь не выходят наружу.
class UpdateChecker {
  UpdateChecker({
    http.Client? client,
    Uri? endpoint,
    String? currentVersion,
    this.timeout = const Duration(seconds: 8),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _endpoint = endpoint ?? Uri.parse(kReleasesApiUrl),
        _currentVersion = currentVersion ?? resolveAppVersion();

  final http.Client _client;
  final bool _ownsClient;
  final Uri _endpoint;

  /// `null` — версию определить не удалось (запуск без `pubspec` и без define):
  /// сравнивать не с чем, и проверка честно молчит.
  final String? _currentVersion;

  /// Предел ожидания. Дольше держать пользователя в «Проверяем…» незачем:
  /// это фоновая проверка, а не действие, которого он ждёт.
  final Duration timeout;

  Future<UpdateCheck?> check() async {
    final String? current = _currentVersion;
    final AppVersion? installed = AppVersion.tryParse(current);
    if (current == null || installed == null) return null;

    try {
      final http.Response response = await _client.get(
        _endpoint,
        headers: const <String, String>{
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'mOps',
        },
      ).timeout(timeout);
      if (response.statusCode != 200) return null;

      final List<ReleaseInfo> releases = parseReleases(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );

      ReleaseInfo? latest;
      for (final ReleaseInfo release in releases) {
        final AppVersion? version = release.version;
        if (version == null) continue;
        // Предварительная сборка не обновление для стабильной версии: иначе
        // пользователю предлагали бы бету как обычный релиз.
        if (release.prerelease && !installed.isPrerelease) continue;
        if (latest == null || version.compareTo(latest.version!) > 0) {
          latest = release;
        }
      }

      final bool available =
          latest != null && latest.version!.compareTo(installed) > 0;
      return UpdateCheck(
        currentVersion: current,
        latest: latest,
        updateAvailable: available,
      );
    } on Object {
      // Нет сети, таймаут, кривой JSON — тихо «ничего», см. комментарий класса.
      return null;
    }
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

/// Разбирает ответ `/releases` в список релизов.
///
/// Вынесено отдельно от запроса: разбор — единственная часть, которую стоит
/// проверять тестом на подставном ответе.
List<ReleaseInfo> parseReleases(Object? decoded) {
  if (decoded is! List<dynamic>) return const <ReleaseInfo>[];
  final List<ReleaseInfo> releases = <ReleaseInfo>[];
  for (final dynamic item in decoded) {
    if (item is Map<String, dynamic> && item['draft'] == true) continue;
    final ReleaseInfo? release = ReleaseInfo.fromJson(item);
    if (release != null) releases.add(release);
  }
  return releases;
}
