import 'dart:async';
import 'dart:io';

import 'fronting.dart';
import 'local_proxy.dart';

/// ---------------------------------------------------------------------------
/// Пошаговая диагностика соединения
/// ---------------------------------------------------------------------------
///
/// Повторяет проверки из `tool/diagnose.dart`, но вызывается из интерфейса:
/// пользователь видит, на каком звене обрывается доступ, и не запускает
/// скрипты. Каждое звено проверяется отдельно — DNS, API напрямую, API с
/// подменой хоста, медиахост и локальный прокси.
///
/// Диагностика намеренно не трогает глобальный обход приложения: проверки
/// используют собственные клиенты, поэтому уже настроенное соединение не
/// ломается во время отчёта.
///
/// Разбор потока (получение ссылки и скачивание первых байтов) здесь не
/// делается: он требует конкретного видео и подменял бы глобальный
/// `HttpOverrides`, из-за чего во время проверки могло бы сорваться
/// воспроизведение. Это звено проверяет сам плеер.

/// Состояние одного шага.
enum DiagnosticStatus {
  /// Проверка прошла и звено работает.
  ok,

  /// Проверка прошла и звено не работает.
  failed,

  /// Проверить не удалось (таймаут, неожиданная ошибка) либо проверка
  /// неприменима — например, прокси просто не найден.
  unknown,
}

/// Один шаг отчёта.
class DiagnosticStep {
  const DiagnosticStep({
    required this.title,
    required this.status,
    required this.detail,
  });

  final String title;
  final DiagnosticStatus status;

  /// Подробность для человека. У DNS — по строке на имя.
  final String detail;
}

/// Итог диагностики для показа в настройках.
class DiagnosticReport {
  const DiagnosticReport({
    required this.ok,
    required this.summary,
    required this.steps,
    this.advice = const <String>[],
  });

  /// Заработает ли приложение в текущих условиях — с учётом обхода.
  final bool ok;

  final String summary;
  final List<DiagnosticStep> steps;

  /// Что сделать, чтобы заработало.
  final List<String> advice;
}

abstract final class ConnectionDiagnostics {
  /// Хост InnerTube: по нему видно, доступны ли данные.
  static const String apiHost = 'music.youtube.com';

  /// Представитель медиахостов: если он недоступен, звук не пойдёт.
  static const String mediaHost = 'redirector.googlevideo.com';

  /// Хосты, разрешение которых проверяем. `www.google.com` — это узел подмены,
  /// `youtube.com` — запасной ориентир.
  static const List<String> dnsHosts = <String>[
    apiHost,
    'www.google.com',
    'youtube.com',
  ];

  /// Больше этого ждать нельзя: пользователь смотрит на кнопку, а не в лог.
  static const Duration _dnsTimeout = Duration(seconds: 5);
  static const Duration _apiTimeout = Duration(seconds: 12);
  static const Duration _mediaTimeout = Duration(seconds: 10);
  static const Duration _proxyTimeout = Duration(seconds: 5);

  /// Прогоняет все проверки и собирает отчёт. Не бросает исключений.
  static Future<DiagnosticReport> run() async {
    final ({DiagnosticStep step, bool googleResolved}) dns = await _checkDns();
    // API-проверки идут по очереди: каждая на время подменяет глобальный
    // `HttpOverrides`, и параллельный запуск перепутал бы цепочку обхода.
    final DiagnosticStep apiDirect = await _checkApi(fronting: false);
    final DiagnosticStep apiFronted = await _checkApi(fronting: true);
    final DiagnosticStep media = await _checkMedia();
    final ({DiagnosticStep step, LocalProxy? proxy}) proxy = await _checkProxy();

    final List<DiagnosticStep> steps = <DiagnosticStep>[
      dns.step,
      apiDirect,
      apiFronted,
      media,
      proxy.step,
    ];

    return _summarize(
      steps: steps,
      apiDirect: apiDirect,
      apiFronted: apiFronted,
      media: media,
      proxy: proxy.proxy,
      googleResolved: dns.googleResolved,
    );
  }

  /// Собирает вывод: что работает и что делать дальше.
  static DiagnosticReport _summarize({
    required List<DiagnosticStep> steps,
    required DiagnosticStep apiDirect,
    required DiagnosticStep apiFronted,
    required DiagnosticStep media,
    required LocalProxy? proxy,
    required bool googleResolved,
  }) {
    final bool directOk = apiDirect.status == DiagnosticStatus.ok;
    final bool frontedOk = apiFronted.status == DiagnosticStatus.ok;
    final bool mediaOk = media.status == DiagnosticStatus.ok;
    final bool mediaFailed = media.status == DiagnosticStatus.failed;
    final List<String> advice = <String>[];

    // Провайдер блокирует медиасерверы отдельно: у них собственный backend,
    // и подмена хоста их не обходит. Поэтому звук решается только прокси.
    const String mediaReason = 'Провайдер блокирует медиасерверы отдельно, '
        'и подмена хоста их не обходит: у них собственный сервер.';

    late final bool ok;
    late final String summary;

    if (directOk && mediaOk) {
      ok = true;
      summary = 'Всё доступно напрямую, обход не нужен';
    } else if (frontedOk && mediaOk) {
      ok = true;
      summary = 'Подмена хоста обходит блокировку, звук тоже пойдёт';
      if (!directOk) {
        advice.add(
          'Прямой доступ к YouTube Music закрыт — оставьте подмену хоста '
          'включённой.',
        );
      }
    } else if (mediaFailed && (directOk || frontedOk)) {
      ok = false;
      summary = 'Данные доступны, но звук заблокирован';
      if (!directOk && frontedOk) {
        advice.add(
          'Данные открываются только с подменой хоста — оставьте её включённой.',
        );
      }
      advice.add(mediaReason);
      advice.add(_proxyAdvice(proxy));
    } else if (directOk || frontedOk) {
      // Данные открываются, а медиахост проверить не удалось — не выдаём
      // это за «звук не работает».
      ok = false;
      summary = 'Данные доступны, но доступность звука проверить не удалось';
      advice.add(
        'Повторите проверку. Если звук не играет — включите прокси в разделе '
        '«Прокси».',
      );
    } else if (proxy != null) {
      // Прокси найден именно потому, что через него открывается медиахост.
      ok = true;
      summary = 'Прямой доступ закрыт, но найден рабочий прокси — включите его';
      advice.add(
        'Прокси ${proxy.label} открывает медиахост. Включите его в разделе '
        '«Прокси», и приложение заработает целиком.',
      );
    } else if (apiDirect.status == DiagnosticStatus.unknown &&
        apiFronted.status == DiagnosticStatus.unknown) {
      ok = false;
      summary = 'Не удалось проверить соединение';
      advice.add(
        'Проверка не получила ответа ни напрямую, ни с подменой. Проверьте '
        'подключение к сети и попробуйте ещё раз.',
      );
    } else if (!googleResolved) {
      ok = false;
      summary = 'Нет доступа в интернет или не работает DNS';
      advice.add(
        'Ни одно из проверенных имён не разрешается. Проверьте подключение '
        'к сети.',
      );
    } else {
      ok = false;
      summary = 'YouTube Music недоступен. Нужен прокси или VPN';
      advice.add(_proxyAdvice(proxy));
    }

    return DiagnosticReport(
      ok: ok,
      summary: summary,
      steps: steps,
      advice: advice,
    );
  }

  static String _proxyAdvice(LocalProxy? proxy) {
    if (proxy != null) {
      return 'Найден прокси ${proxy.label} — включите его в разделе «Прокси», '
          'и звук заработает.';
    }
    return 'Включите прокси в разделе «Прокси» либо системный обход '
        '(zapret / GoodbyeDPI / VPN) — тогда звук заработает.';
  }

  /// Шаг 1. Разрешаются ли имена.
  static Future<({DiagnosticStep step, bool googleResolved})>
      _checkDns() async {
    final List<_Resolution> results =
        await Future.wait(<Future<_Resolution>>[
      for (final String host in dnsHosts) _resolve(host),
    ]);

    int resolved = 0;
    int unresolved = 0;
    int unknown = 0;
    bool googleResolved = false;
    final List<String> details = <String>[];

    for (final _Resolution result in results) {
      if (result.timedOut) {
        unknown++;
        details.add('${result.host} — не удалось проверить (таймаут)');
        continue;
      }
      if (result.ipv4 == null && !result.hasIpv6) {
        unresolved++;
        details.add('${result.host} — не разрешается');
        continue;
      }
      resolved++;
      if (result.host == 'www.google.com') googleResolved = true;
      details.add(
        '${result.host} — ${result.ipv4 ?? "нет IPv4"}'
        '${result.hasIpv6 ? ", IPv6 есть" : ""}',
      );
    }

    final DiagnosticStatus status;
    if (unknown == results.length) {
      status = DiagnosticStatus.unknown;
    } else if (unresolved == results.length) {
      status = DiagnosticStatus.failed;
    } else if (resolved == results.length) {
      status = DiagnosticStatus.ok;
    } else {
      // Часть имён не разрешается — это результат, но не сбой проверки.
      status = DiagnosticStatus.unknown;
    }

    return (
      step: DiagnosticStep(
        title: 'DNS',
        status: status,
        detail: details.join('\n'),
      ),
      googleResolved: googleResolved,
    );
  }

  /// Шаг 2–3. Доступен ли InnerTube напрямую и через узел подмены.
  static Future<DiagnosticStep> _checkApi({required bool fronting}) async {
    final String title = fronting ? 'API с подменой хоста' : 'API напрямую';
    try {
      final bool reachable = await ConnectivityCheck.dataReachable(
        fronting: fronting,
      ).timeout(_apiTimeout);

      if (reachable) {
        return DiagnosticStep(
          title: title,
          status: DiagnosticStatus.ok,
          detail: fronting
              ? 'InnerTube отвечает через узел подмены'
              : 'InnerTube отвечает без обхода',
        );
      }
      return DiagnosticStep(
        title: title,
        status: DiagnosticStatus.failed,
        detail: fronting
            ? 'узел подмены не открывает API'
            : 'прямой запрос к API не удался',
      );
    } on TimeoutException {
      return DiagnosticStep(
        title: title,
        status: DiagnosticStatus.unknown,
        detail: 'не удалось проверить: превышено время ожидания',
      );
    } on Object catch (error) {
      return DiagnosticStep(
        title: title,
        status: DiagnosticStatus.unknown,
        detail: 'не удалось проверить: ${error.runtimeType}',
      );
    }
  }

  /// Шаг 4. Проходит ли TLS-рукопожатие к медиахосту напрямую.
  static Future<DiagnosticStep> _checkMedia() async {
    const String title = 'Медиахост (звук)';
    try {
      final bool reachable =
          await ConnectivityCheck.mediaReachable().timeout(_mediaTimeout);
      return DiagnosticStep(
        title: title,
        status: reachable ? DiagnosticStatus.ok : DiagnosticStatus.failed,
        detail: reachable
            ? '$mediaHost открывается напрямую'
            : '$mediaHost недоступен — звук не пойдёт',
      );
    } on TimeoutException {
      return const DiagnosticStep(
        title: title,
        status: DiagnosticStatus.unknown,
        detail: 'не удалось проверить: превышено время ожидания',
      );
    } on Object catch (error) {
      return DiagnosticStep(
        title: title,
        status: DiagnosticStatus.unknown,
        detail: 'не удалось проверить: ${error.runtimeType}',
      );
    }
  }

  /// Шаг 5. Есть ли на машине прокси, открывающий медиахост.
  static Future<({DiagnosticStep step, LocalProxy? proxy})>
      _checkProxy() async {
    const String title = 'Локальный прокси';
    try {
      final LocalProxy? proxy =
          await LocalProxyDetector.find().timeout(_proxyTimeout);

      if (proxy == null) {
        // Отсутствие прокси — не сбой: он может быть и не нужен.
        return (
          step: const DiagnosticStep(
            title: title,
            status: DiagnosticStatus.unknown,
            detail: 'не найден среди известных портов — можно указать вручную',
          ),
          proxy: null,
        );
      }

      return (
        step: DiagnosticStep(
          title: title,
          status: DiagnosticStatus.ok,
          detail: '${proxy.kind.label} ${proxy.label}'
              '${proxy.note == null ? "" : " · ${proxy.note}"} — '
              'открывает медиахост',
        ),
        proxy: proxy,
      );
    } on TimeoutException {
      return (
        step: const DiagnosticStep(
          title: title,
          status: DiagnosticStatus.unknown,
          detail: 'не удалось проверить: превышено время ожидания',
        ),
        proxy: null,
      );
    } on Object catch (error) {
      return (
        step: DiagnosticStep(
          title: title,
          status: DiagnosticStatus.unknown,
          detail: 'не удалось проверить: ${error.runtimeType}',
        ),
        proxy: null,
      );
    }
  }

  /// Разрешает имя, укладываясь в таймаут. Не бросает.
  static Future<_Resolution> _resolve(String host) async {
    try {
      return await _lookup(host).timeout(_dnsTimeout);
    } on TimeoutException {
      return _Resolution(host: host, timedOut: true);
    } on Object {
      // Имя не разрешается — это тоже ответ.
      return _Resolution(host: host);
    }
  }

  static Future<_Resolution> _lookup(String host) async {
    String? ipv4;
    try {
      final List<InternetAddress> v4 =
          await InternetAddress.lookup(host, type: InternetAddressType.IPv4);
      if (v4.isNotEmpty) ipv4 = v4.first.address;
    } on Object {
      // Имя может разрешаться только в IPv6 — тогда сработает проверка ниже.
    }

    bool hasIpv6 = false;
    try {
      hasIpv6 = (await InternetAddress.lookup(
        host,
        type: InternetAddressType.IPv6,
      ))
          .isNotEmpty;
    } on Object {
      // Нет AAAA-записи — не беда: для соединения достаточно IPv4.
    }

    return _Resolution(host: host, ipv4: ipv4, hasIpv6: hasIpv6);
  }
}

/// Результат разрешения одного имени.
class _Resolution {
  const _Resolution({
    required this.host,
    this.ipv4,
    this.hasIpv6 = false,
    this.timedOut = false,
  });

  final String host;
  final String? ipv4;
  final bool hasIpv6;
  final bool timedOut;
}
