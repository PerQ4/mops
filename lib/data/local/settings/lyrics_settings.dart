import 'json_read.dart';

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

/// Выравнивание строк текста песни.
///
/// По левому краю — как было всегда: строки растут от одной вертикали, и глаз
/// не перескакивает. По центру — как в караоке на телефоне: активная строка
/// стоит посередине, соседние под ней.
enum LyricsTextAlign {
  left('По левому краю', 'Строки начинаются от одной вертикали — как было'),
  center('По центру', 'Строки стоят по центру колонки, как в караоке');

  const LyricsTextAlign(this.label, this.description);

  final String label;
  final String description;

  static LyricsTextAlign fromName(String? name) =>
      LyricsTextAlign.values.firstWhere(
        (LyricsTextAlign v) => v.name == name,
        orElse: () => LyricsTextAlign.left,
      );
}

/// Ширина колонки текста песни.
///
/// На десктопе окно широкое, и текст во всю ширину читается как полоса: строка
/// длиннее ~80 знаков теряет начало, пока глаз доходит до конца. Поэтому по
/// умолчанию колонка ограничена, а «во всю ширину» остаётся выбором.
enum LyricsColumnWidth {
  narrow('Узко', 'Около 400 точек — короткая строка, удобно читать'),
  normal('Обычно', 'Около 560 точек — как было'),
  full('Во всю ширину', 'Текст занимает всё окно');

  const LyricsColumnWidth(this.label, this.description);

  final String label;
  final String description;

  /// Предельная ширина колонки; `null` — без ограничения.
  double? get maxWidth => switch (this) {
    LyricsColumnWidth.narrow => 400,
    LyricsColumnWidth.normal => 560,
    LyricsColumnWidth.full => null,
  };

  static LyricsColumnWidth fromName(String? name) =>
      LyricsColumnWidth.values.firstWhere(
        (LyricsColumnWidth v) => v.name == name,
        orElse: () => LyricsColumnWidth.normal,
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
/// `null` — значения нет или тип не тот, поэтому список пуст.
List<LyricsSource> _parseSourceNames(List<String>? names) {
  if (names == null) return const <LyricsSource>[];
  final List<LyricsSource> parsed = <LyricsSource>[];
  for (final String name in names) {
    final LyricsSource? source = LyricsSource.values
        .cast<LyricsSource?>()
        .firstWhere((LyricsSource? v) => v?.name == name, orElse: () => null);
    if (source != null && !parsed.contains(source)) parsed.add(source);
  }
  return parsed;
}

/// Разбирает сохранённый порядок источников; при мусоре — порядок по умолчанию.
List<LyricsSource> _parseLyricsOrder(List<String>? names) {
  final List<LyricsSource> parsed = _parseSourceNames(names);
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
    // Ноль — «как в выбранном виде» (см. [effectiveActiveLineScale]): так
    // смена вида сразу даёт его привычный вид, а не значение, подобранное для
    // другого вида.
    this.lyricsActiveLineScale = 0.0,
    this.lyricsInactiveOpacity = 1.0,
    this.lyricsTextAlign = LyricsTextAlign.left,
    this.lyricsColumnWidth = LyricsColumnWidth.normal,
    this.lyricsAutoScroll = true,
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

  /// Во сколько раз активная строка крупнее базовой.
  ///
  /// Раскладку это не меняет: строка рисуется базовым кеглем, а увеличение
  /// даёт `Transform.scale`, поэтому подсветка не двигает список. Ноль —
  /// «как в выбранном виде» (см. [effectiveActiveLineScale]), иначе 1.0–1.6.
  final double lyricsActiveLineScale;

  /// Множитель прозрачности неактивных строк (1 — как в выбранном виде).
  final double lyricsInactiveOpacity;

  /// Выравнивание строк текста.
  final LyricsTextAlign lyricsTextAlign;

  /// Ширина колонки текста.
  final LyricsColumnWidth lyricsColumnWidth;

  /// Следует ли список за поющейся строкой сам.
  final bool lyricsAutoScroll;

  /// Крупность активной строки, которая задана самим видом.
  static const double classicActiveScale = 1.0;
  static const double v2ActiveScale = 1.3;
  static const double enhancedActiveScale = 1.14;

  /// Крупность активной строки с учётом настройки.
  double get effectiveActiveLineScale =>
      hasCustomActiveLineScale ? lyricsActiveLineScale : modeActiveLineScale;

  /// Крупность активной строки, которую задаёт сам вид.
  double get modeActiveLineScale => switch (lyricsMode) {
    LyricsMode.classic => classicActiveScale,
    LyricsMode.v2 => v2ActiveScale,
    LyricsMode.enhanced => enhancedActiveScale,
  };

  /// Задана ли крупность активной строки вручную, а не видом.
  bool get hasCustomActiveLineScale => lyricsActiveLineScale > 0;

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
    double? lyricsActiveLineScale,
    double? lyricsInactiveOpacity,
    LyricsTextAlign? lyricsTextAlign,
    LyricsColumnWidth? lyricsColumnWidth,
    bool? lyricsAutoScroll,
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
      lyricsActiveLineScale:
          lyricsActiveLineScale ?? this.lyricsActiveLineScale,
      lyricsInactiveOpacity: lyricsInactiveOpacity ?? this.lyricsInactiveOpacity,
      lyricsTextAlign: lyricsTextAlign ?? this.lyricsTextAlign,
      lyricsColumnWidth: lyricsColumnWidth ?? this.lyricsColumnWidth,
      lyricsAutoScroll: lyricsAutoScroll ?? this.lyricsAutoScroll,
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
    'lyricsActiveLineScale': lyricsActiveLineScale,
    'lyricsInactiveOpacity': lyricsInactiveOpacity,
    'lyricsTextAlign': lyricsTextAlign.name,
    'lyricsColumnWidth': lyricsColumnWidth.name,
    'lyricsAutoScroll': lyricsAutoScroll,
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
      lyricsSource: readEnumByName(
        json['lyricsSource'],
        LyricsSource.values,
        LyricsSource.auto,
      ),
      showLyricsInPlayer: readBool(json['showLyricsInPlayer'], true),
      lyricsTextScale: readDouble(json['lyricsTextScale'], 1.0),
      lyricsLineSpacing: readDouble(json['lyricsLineSpacing'], 1.35),
      lyricsLineBlur: readBool(json['lyricsLineBlur'], true),
      lyricsMode: readEnumByName(
        json['lyricsMode'],
        LyricsMode.values,
        LyricsMode.classic,
      ),
      lyricsAnimationStyle: readEnumByName(
        json['lyricsAnimationStyle'],
        LyricsAnimationStyle.values,
        LyricsAnimationStyle.fade,
      ),
      lyricsActiveLineScale: readDouble(json['lyricsActiveLineScale'], 0.0),
      lyricsInactiveOpacity: readDouble(json['lyricsInactiveOpacity'], 1.0),
      lyricsTextAlign: readEnumByName(
        json['lyricsTextAlign'],
        LyricsTextAlign.values,
        LyricsTextAlign.left,
      ),
      lyricsColumnWidth: readEnumByName(
        json['lyricsColumnWidth'],
        LyricsColumnWidth.values,
        LyricsColumnWidth.normal,
      ),
      lyricsAutoScroll: readBool(json['lyricsAutoScroll'], true),
      lyricsProviderOrder: _parseLyricsOrder(
        readStringList(json['lyricsProviderOrder']),
      ),
      lyricsDisabledProviders: _parseSourceNames(
        readStringList(json['lyricsDisabledProviders']),
      ),
      paxsenixAppleMusic: readBool(json['paxsenixAppleMusic'], true),
      paxsenixSpotify: readBool(json['paxsenixSpotify'], true),
      paxsenixMusixmatch: readBool(json['paxsenixMusixmatch'], true),
      romanizeJapanese: readBool(json['romanizeJapanese'], true),
      romanizeKorean: readBool(json['romanizeKorean'], true),
      romanizeChinese: readBool(json['romanizeChinese'], true),
      romanizeHindi: readBool(json['romanizeHindi'], true),
      romanizeOther: readBool(json['romanizeOther'], true),
    );
  }
}
