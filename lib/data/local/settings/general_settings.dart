/// Где искать треки.
///
/// В ArchiveTune поиск можно ограничить своей библиотекой — так быстрее
/// находить уже знакомое и не уходить в бесконечную выдачу YouTube.
enum SearchSource {
  online('Онлайн', 'Искать по всему YouTube Music'),
  libraryOnly('Только библиотека', 'Искать среди лайкнутых и сохранённых');

  const SearchSource(this.label, this.description);

  final String label;
  final String description;

  static SearchSource fromName(String? name) => SearchSource.values.firstWhere(
    (SearchSource v) => v.name == name,
    orElse: () => SearchSource.online,
  );
}

/// Длина топов и чартов.
///
/// Как `TopSize` в ArchiveTune (`ContentSettings.kt`), только не строкой, а
/// набором: серверу длину не передать, поэтому каталог обрезает уже разобранные
/// полки. Значение по умолчанию — 50, как в оригинале.
enum TopSize {
  ten('10', 10),
  twenty('20', 20),
  fifty('50', 50),
  hundred('100', 100);

  const TopSize(this.label, this.value);

  final String label;

  /// Сколько элементов оставлять в полке топа.
  final int value;

  static TopSize fromName(String? name) => TopSize.values.firstWhere(
    (TopSize v) => v.name == name,
    orElse: () => TopSize.fifty,
  );
}

/// Прочее: локальные файлы, поиск и выдача каталога, регион и статистика.
///
/// Здесь лежит то, что не относится ни к оформлению, ни к звуку, ни к сети.
class GeneralSettings {
  const GeneralSettings({
    // Папка с локальной музыкой. Пусто — раздел «Локальные файлы» просит
    // указать путь и ничего не сканирует.
    this.localMediaFolder = '',
    this.searchSource = SearchSource.online,
    // Что прятать в выдаче каталога и поиска, как `HideExplicitKey` и
    // `HideVideoKey` в ArchiveTune. По умолчанию ничего не прячем.
    this.hideExplicit = false,
    this.hideVideo = false,
    // Длина топов и чартов (как `TopSize`).
    this.topSize = TopSize.fifty,
    this.streamingRegion = 'RU',
    this.streamingLanguage = 'ru',
    // Статистика прослушиваний — только на этом компьютере. Включена по
    // умолчанию: без неё экран статистики всегда пуст, а данные никуда не
    // уходят. Выключение останавливает запись, не стирая уже собранное.
    this.listeningStatsEnabled = true,
  });

  /// Папка с локальными аудиофайлами (задача 8.3). Путь вводится текстом —
  /// системного диалога выбора папки в приложении нет.
  final String localMediaFolder;

  /// Где искать: по всему YouTube Music или только по своей библиотеке.
  final SearchSource searchSource;

  /// Прятать explicit-треки (мат) в выдаче каталога и поиска.
  final bool hideExplicit;

  /// Прятать клипы (видео) в выдаче каталога и поиска.
  final bool hideVideo;

  /// Сколько элементов оставлять в топах и чартах.
  final TopSize topSize;

  final String streamingRegion;
  final String streamingLanguage;

  /// Считать ли прослушивания на этом компьютере (задача 8.1).
  ///
  /// Запись локальная: ни треки, ни время никуда не отправляются. Выключение
  /// прекращает новые записи, а стереть уже собранное можно на экране
  /// статистики — отдельной кнопкой, а не снятием галочки.
  final bool listeningStatsEnabled;

  GeneralSettings copyWith({
    String? localMediaFolder,
    SearchSource? searchSource,
    bool? hideExplicit,
    bool? hideVideo,
    TopSize? topSize,
    String? streamingRegion,
    String? streamingLanguage,
    bool? listeningStatsEnabled,
  }) {
    return GeneralSettings(
      localMediaFolder: localMediaFolder ?? this.localMediaFolder,
      searchSource: searchSource ?? this.searchSource,
      hideExplicit: hideExplicit ?? this.hideExplicit,
      hideVideo: hideVideo ?? this.hideVideo,
      topSize: topSize ?? this.topSize,
      streamingRegion: streamingRegion ?? this.streamingRegion,
      streamingLanguage: streamingLanguage ?? this.streamingLanguage,
      listeningStatsEnabled:
          listeningStatsEnabled ?? this.listeningStatsEnabled,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'localMediaFolder': localMediaFolder,
    'searchSource': searchSource.name,
    'hideExplicit': hideExplicit,
    'hideVideo': hideVideo,
    'topSize': topSize.name,
    'streamingRegion': streamingRegion,
    'streamingLanguage': streamingLanguage,
    'listeningStatsEnabled': listeningStatsEnabled,
  };

  factory GeneralSettings.fromJson(Map<String, dynamic> json) {
    return GeneralSettings(
      localMediaFolder: json['localMediaFolder'] as String? ?? '',
      searchSource: SearchSource.fromName(json['searchSource'] as String?),
      hideExplicit: json['hideExplicit'] as bool? ?? false,
      hideVideo: json['hideVideo'] as bool? ?? false,
      topSize: TopSize.fromName(json['topSize'] as String?),
      streamingRegion: json['streamingRegion'] as String? ?? 'RU',
      streamingLanguage: json['streamingLanguage'] as String? ?? 'ru',
      listeningStatsEnabled: json['listeningStatsEnabled'] as bool? ?? true,
    );
  }
}
