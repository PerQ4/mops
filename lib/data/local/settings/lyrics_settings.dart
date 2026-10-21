/// Откуда брать текст песни.
///
/// Как в ArchiveTune, источников несколько: сервисы с синхронизацией (TTML и
/// LRC), вкладка «Текст» YouTube Music и субтитры видео. Выбранный источник
/// авторитетен: если в нём пусто, приложение не подменяет результат текстом
/// YouTube. Режим «Авто» перебирает реальные базы, а тексты YouTube берёт
/// только в самом конце — когда ни одна база не ответила.
enum LyricsSource {
  auto('Авто', 'Перебор баз по порядку; тексты YouTube — в последнюю очередь'),
  music('Текст YouTube Music', 'Вкладка «Текст» — без времён'),
  subtitles('Субтитры видео', 'Дорожка видео — со временем строк'),
  betterLyrics('BetterLyrics', 'Apple Music (TTML) — пословная синхронизация'),
  youlyPlus('YouLy+', 'Зеркала Lyricify — TTML или LRC'),
  lrclib('LRCLIB', 'Открытая база — текст с временами'),
  kugou('KuGou', 'Внешняя база — текст с временами'),
  unison('Unison', 'Внешняя база — текст с временами'),
  musixmatch('Paxsenix', 'Apple Music и Musixmatch — нужен ключ в настройках');

  const LyricsSource(this.label, this.description);

  final String label;
  final String description;

  static LyricsSource fromName(String? name) => LyricsSource.values.firstWhere(
    (LyricsSource v) => v.name == name,
    orElse: () => LyricsSource.auto,
  );
}

/// Режим отображения текста песни (задача 3.1).
///
/// Классический — прежний вид: строки одного размера, активная выделена
/// насыщенностью. V2 усиливает контраст: активная строка крупнее, соседние
/// мельче и прозрачнее. Enhanced добавляет отдельную панель активной строки —
/// на широком экране список и текущая строка стоят рядом.
enum LyricsMode {
  classic(
    'Классический',
    'Строки одного размера, активная выделена насыщенностью',
  ),
  v2('V2', 'Крупная активная строка, соседние мельче и прозрачнее'),
  enhanced(
    'Enhanced',
    'Активная строка на отдельной панели, список рядом — на широком экране',
  );

  const LyricsMode(this.label, this.description);

  final String label;
  final String description;

  static LyricsMode fromName(String? name) => LyricsMode.values.firstWhere(
    (LyricsMode v) => v.name == name,
    orElse: () => LyricsMode.classic,
  );
}

/// Стиль анимации текста песни (задача 3.2).
///
/// Один стиль отвечает и за появление активной строки, и за подсветку слов.
/// Длительности и кривые берутся из словаря движений (`AppMotion`), поэтому
/// «Отключить анимации» делает любой из стилей мгновенным.
enum LyricsAnimationStyle {
  none('Нет', 'Строка и слова появляются сразу, без движения'),
  fade('Плавное', 'Мягкое проявление строки и подсветки — как было'),
  spring('Пружинное', 'Появление с отдачей, слово подскакивает заметнее'),
  scale('Масштаб', 'Строка и слово вырастают из меньшего размера');

  const LyricsAnimationStyle(this.label, this.description);

  final String label;
  final String description;

  static LyricsAnimationStyle fromName(String? name) =>
      LyricsAnimationStyle.values.firstWhere(
        (LyricsAnimationStyle v) => v.name == name,
        orElse: () => LyricsAnimationStyle.fade,
      );
}

/// Какие каталоги Paxsenix спрашивать.
///
/// Как `paxsenixProviders` в ArchiveTune: ключ у Paxsenix один, а каталоги за
/// ним разные — Apple Music, Spotify и Musixmatch. Включаются по отдельности:
/// не всем нужен каждый, а лишний каталог — это лишний запрос и лишние
/// варианты в списке найденного.
class PaxsenixOptions {
  const PaxsenixOptions({
    this.appleMusic = true,
    this.spotify = true,
    this.musixmatch = true,
  });

  /// Apple Music — TTML с временем каждого слова (караоке).
  final bool appleMusic;

  /// Spotify — обычный текст или LRC.
  final bool spotify;

  /// Musixmatch — текст с временами строк.
  final bool musixmatch;

  /// Хоть один каталог включён: если ни одного, спрашивать нечего.
  bool get any => appleMusic || spotify || musixmatch;

  @override
  bool operator ==(Object other) =>
      other is PaxsenixOptions &&
      other.appleMusic == appleMusic &&
      other.spotify == spotify &&
      other.musixmatch == musixmatch;

  @override
  int get hashCode => Object.hash(appleMusic, spotify, musixmatch);
}

/// Порядок источников текста по умолчанию — как `DefaultLyricsProviderOrder`
/// в ArchiveTune. Первый в списке — приоритетный.
/// Порядок подобран по тому, что реально отвечает и что даёт подробнее
/// разметку. Хосты отброшенных источников недоступны из этой сети: они лишь
/// держали поиск открытым до таймаута, ничего не принося, поэтому из проекта
/// они удалены целиком.
const List<LyricsSource> kDefaultLyricsOrder = <LyricsSource>[
  LyricsSource.youlyPlus,
  LyricsSource.betterLyrics,
  LyricsSource.musixmatch,
  LyricsSource.kugou,
  LyricsSource.lrclib,
  LyricsSource.unison,
];

/// Разбирает список имён источников, отбрасывая неизвестные.
///
/// Имена, которых больше нет в [LyricsSource] (например, удалённые источники),
/// молча пропускаются: у пользователя в сохранённых настройках они могут
/// остаться, и это не должно ни ронять разбор, ни терять остальные.
List<LyricsSource> _parseSourceNames(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <LyricsSource>[];
  final List<LyricsSource> parsed = <LyricsSource>[];
  for (final String name in raw.split(',')) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) continue;
    final LyricsSource? source = LyricsSource.values
        .cast<LyricsSource?>()
        .firstWhere(
          (LyricsSource? v) => v?.name == trimmed,
          orElse: () => null,
        );
    if (source != null && !parsed.contains(source)) parsed.add(source);
  }
  return parsed;
}

/// Разбирает сохранённый порядок источников; при мусоре — порядок по умолчанию.
List<LyricsSource> _parseLyricsOrder(String? raw) {
  final List<LyricsSource> parsed = _parseSourceNames(raw);
  return parsed.isEmpty ? kDefaultLyricsOrder : parsed;
}

/// Тексты песен: источник, вид, анимация, романизация и каталоги Paxsenix.
class LyricsSettings {
  const LyricsSettings({
    this.lyricsSource = LyricsSource.auto,
    this.showLyricsInPlayer = true,
    this.lyricsTextScale = 1.0,
    this.lyricsLineSpacing = 1.35,
    this.lyricsLineBlur = true,
    this.lyricsMode = LyricsMode.classic,
    this.lyricsAnimationStyle = LyricsAnimationStyle.fade,
    this.lyricsProviderOrder = kDefaultLyricsOrder,
    // Источники, выключенные пользователем (как `providerPreferenceKeys`
    // в ArchiveTune). Храним именно выключенные: новый источник по умолчанию
    // включён, а не пропадает из поиска.
    this.lyricsDisabledProviders = const <LyricsSource>[],
    // Под-провайдеры Paxsenix (как `paxsenixProviders` в ArchiveTune).
    this.paxsenixAppleMusic = true,
    this.paxsenixSpotify = true,
    this.paxsenixMusixmatch = true,
    // Романизация: пять отдельных переключателей как `LyricsRomanize*Key`
    // в ArchiveTune. Язык по тексту определяется сам, выбирать его не нужно.
    this.romanizeJapanese = true,
    this.romanizeKorean = true,
    this.romanizeChinese = true,
    this.romanizeHindi = true,
    this.romanizeOther = true,
  });

  /// Откуда брать текст песни.
  final LyricsSource lyricsSource;

  final bool showLyricsInPlayer;

  /// Множитель размера текста песни (0.8–1.4). Позволяет крупнее показывать
  /// слова, не меняя системный масштаб всего интерфейса.
  final double lyricsTextScale;

  /// Межстрочный интервал текста песни (как `LyricsLineSpacingKey`).
  final double lyricsLineSpacing;

  /// Размывать неактивные строки текста (как `LyricsLineBlurKey`).
  final bool lyricsLineBlur;

  /// Режим отображения текста: классический, V2 или Enhanced (задача 3.1).
  final LyricsMode lyricsMode;

  /// Стиль появления строки и подсветки слов (задача 3.2).
  final LyricsAnimationStyle lyricsAnimationStyle;

  /// Порядок источников текста в режиме «Авто» — как `LyricsProviderOrderKey`
  /// в ArchiveTune. Первый источник в списке — приоритетный.
  final List<LyricsSource> lyricsProviderOrder;

  /// Источники текста, выключенные пользователем. Выключенный источник не
  /// спрашивается вовсе — ни в «Авто», ни в списке найденного.
  final List<LyricsSource> lyricsDisabledProviders;

  /// Каталоги Paxsenix: Apple Music.
  final bool paxsenixAppleMusic;

  /// Каталоги Paxsenix: Spotify.
  final bool paxsenixSpotify;

  /// Каталоги Paxsenix: Musixmatch.
  final bool paxsenixMusixmatch;

  /// Романизация японского текста (кана, `々`, `〆`).
  final bool romanizeJapanese;

  /// Романизация корейского текста (слоги хангыля).
  final bool romanizeKorean;

  /// Романизация китайского текста (иероглифы без каны и хангыля).
  final bool romanizeChinese;

  /// Романизация текста на хинди (деванагари).
  final bool romanizeHindi;

  /// Романизация остальных нелатинских письменностей (тайский, арабский,
  /// кириллица, греческий и другие).
  final bool romanizeOther;

  /// Включён ли источник текста.
  ///
  /// «Авто» — не источник, а режим перебора: выключать его нечем, поэтому в
  /// списке источников он не участвует и всегда считается включённым.
  bool isSourceEnabled(LyricsSource source) =>
      source != LyricsSource.auto && !lyricsDisabledProviders.contains(source);

  /// Источники, которые можно включать и выключать, — всё, кроме «Авто».
  static List<LyricsSource> get toggleableSources => LyricsSource.values
      .where((LyricsSource s) => s != LyricsSource.auto)
      .toList(growable: false);

  /// Каталоги Paxsenix одним значением — так источник получает их одним
  /// параметром, а не тремя.
  PaxsenixOptions get paxsenixOptions => PaxsenixOptions(
    appleMusic: paxsenixAppleMusic,
    spotify: paxsenixSpotify,
    musixmatch: paxsenixMusixmatch,
  );

  LyricsSettings copyWith({
    LyricsSource? lyricsSource,
    bool? showLyricsInPlayer,
    double? lyricsTextScale,
    double? lyricsLineSpacing,
    bool? lyricsLineBlur,
    LyricsMode? lyricsMode,
    LyricsAnimationStyle? lyricsAnimationStyle,
    List<LyricsSource>? lyricsProviderOrder,
    List<LyricsSource>? lyricsDisabledProviders,
    bool? paxsenixAppleMusic,
    bool? paxsenixSpotify,
    bool? paxsenixMusixmatch,
    bool? romanizeJapanese,
    bool? romanizeKorean,
    bool? romanizeChinese,
    bool? romanizeHindi,
    bool? romanizeOther,
  }) {
    return LyricsSettings(
      lyricsSource: lyricsSource ?? this.lyricsSource,
      showLyricsInPlayer: showLyricsInPlayer ?? this.showLyricsInPlayer,
      lyricsTextScale: lyricsTextScale ?? this.lyricsTextScale,
      lyricsLineSpacing: lyricsLineSpacing ?? this.lyricsLineSpacing,
      lyricsLineBlur: lyricsLineBlur ?? this.lyricsLineBlur,
      lyricsMode: lyricsMode ?? this.lyricsMode,
      lyricsAnimationStyle: lyricsAnimationStyle ?? this.lyricsAnimationStyle,
      lyricsProviderOrder: lyricsProviderOrder ?? this.lyricsProviderOrder,
      lyricsDisabledProviders:
          lyricsDisabledProviders ?? this.lyricsDisabledProviders,
      paxsenixAppleMusic: paxsenixAppleMusic ?? this.paxsenixAppleMusic,
      paxsenixSpotify: paxsenixSpotify ?? this.paxsenixSpotify,
      paxsenixMusixmatch: paxsenixMusixmatch ?? this.paxsenixMusixmatch,
      romanizeJapanese: romanizeJapanese ?? this.romanizeJapanese,
      romanizeKorean: romanizeKorean ?? this.romanizeKorean,
      romanizeChinese: romanizeChinese ?? this.romanizeChinese,
      romanizeHindi: romanizeHindi ?? this.romanizeHindi,
      romanizeOther: romanizeOther ?? this.romanizeOther,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'lyricsSource': lyricsSource.name,
    'showLyricsInPlayer': showLyricsInPlayer,
    'lyricsTextScale': lyricsTextScale,
    'lyricsLineSpacing': lyricsLineSpacing,
    'lyricsLineBlur': lyricsLineBlur,
    'lyricsMode': lyricsMode.name,
    'lyricsAnimationStyle': lyricsAnimationStyle.name,
    'lyricsProviderOrder': lyricsProviderOrder
        .map((LyricsSource s) => s.name)
        .join(','),
    'lyricsDisabledProviders': lyricsDisabledProviders
        .map((LyricsSource s) => s.name)
        .join(','),
    'paxsenixAppleMusic': paxsenixAppleMusic,
    'paxsenixSpotify': paxsenixSpotify,
    'paxsenixMusixmatch': paxsenixMusixmatch,
    'romanizeJapanese': romanizeJapanese,
    'romanizeKorean': romanizeKorean,
    'romanizeChinese': romanizeChinese,
    'romanizeHindi': romanizeHindi,
    'romanizeOther': romanizeOther,
  };

  factory LyricsSettings.fromJson(Map<String, dynamic> json) {
    return LyricsSettings(
      lyricsSource: LyricsSource.fromName(json['lyricsSource'] as String?),
      showLyricsInPlayer: json['showLyricsInPlayer'] as bool? ?? true,
      lyricsTextScale: (json['lyricsTextScale'] as num?)?.toDouble() ?? 1.0,
      lyricsLineSpacing:
          (json['lyricsLineSpacing'] as num?)?.toDouble() ?? 1.35,
      lyricsLineBlur: json['lyricsLineBlur'] as bool? ?? true,
      lyricsMode: LyricsMode.fromName(json['lyricsMode'] as String?),
      lyricsAnimationStyle: LyricsAnimationStyle.fromName(
        json['lyricsAnimationStyle'] as String?,
      ),
      lyricsProviderOrder: _parseLyricsOrder(
        json['lyricsProviderOrder'] as String?,
      ),
      lyricsDisabledProviders: _parseSourceNames(
        json['lyricsDisabledProviders'] as String?,
      ),
      paxsenixAppleMusic: json['paxsenixAppleMusic'] as bool? ?? true,
      paxsenixSpotify: json['paxsenixSpotify'] as bool? ?? true,
      paxsenixMusixmatch: json['paxsenixMusixmatch'] as bool? ?? true,
      romanizeJapanese: json['romanizeJapanese'] as bool? ?? true,
      romanizeKorean: json['romanizeKorean'] as bool? ?? true,
      romanizeChinese: json['romanizeChinese'] as bool? ?? true,
      romanizeHindi: json['romanizeHindi'] as bool? ?? true,
      romanizeOther: json['romanizeOther'] as bool? ?? true,
    );
  }
}
