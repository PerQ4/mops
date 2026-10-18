import '../../data/models/models.dart';

/// Приводит секции главной к порядку и подписям из спецификации ArchiveTune.
///
/// Зачем: YouTube Music отдаёт секции в разном порядке и под своими
/// названиями («Рекомендуем», «В тренде», «Новые клипы»). Спецификация же
/// задаёт свой порядок (чипы, «Быстрый выбор», «Слушать снова», «Ваши
/// плейлисты», «Давно не слушали», «Похоже на»). Никаких новых данных здесь не
/// появляется: функция только сортирует уже полученные секции и переименовывает
/// те, чей смысл однозначно читается по заголовку. Незнакомые секции остаются
/// как есть.
List<BrowseSection> curateHomeSections(List<BrowseSection> sections) {
  final List<({int index, BrowseSection section, String label, int rank})>
      ranked = <({int index, BrowseSection section, String label, int rank})>[];

  for (int i = 0; i < sections.length; i++) {
    final BrowseSection section = sections[i];
    final String label = _archiveLabel(section.title);
    ranked.add((
      index: i,
      section: section,
      label: label,
      rank: _rankOf(label),
    ));
  }

  // Сортируем по рангу; внутри одного ранга сохраняем исходный порядок —
  // иначе секции «дёргались» бы при каждом обновлении.
  ranked.sort((
    ({int index, BrowseSection section, String label, int rank}) a,
    ({int index, BrowseSection section, String label, int rank}) b,
  ) {
    final int byRank = a.rank.compareTo(b.rank);
    return byRank != 0 ? byRank : a.index.compareTo(b.index);
  });

  return <BrowseSection>[
    for (final ({int index, BrowseSection section, String label, int rank}) e
        in ranked)
      _renamed(e.section, e.label),
  ];
}

/// Верхние блоки главной, которые показываются отдельно от общей ленты.
///
/// «Слушать снова» и «Быстрый выбор» вынимаются из ленты: иначе один и тот же
/// раздел стоял бы дважды — отдельным блоком и обычной секцией.
class HomeTopBlocks {
  const HomeTopBlocks({
    this.listenAgain,
    this.quickPicks,
    this.sections = const <BrowseSection>[],
  });

  /// Полка недавнего прослушивания. `null` — YouTube её не вернул.
  final BrowseSection? listenAgain;

  /// «Быстрый выбор» — плитки быстрого запуска. `null` — данных нет.
  final BrowseSection? quickPicks;

  /// Остальные секции, уже приведённые к порядку ArchiveTune.
  final List<BrowseSection> sections;
}

/// Делит секции главной на верхние блоки и общую ленту.
///
/// Локальной истории прослушиваний в проекте нет (задача 8.1 не сделана),
/// поэтому «Слушать снова» берётся из секции YouTube с тем же смыслом —
/// выдуманных данных здесь не появляется. Заголовок полки не переименовываем:
/// он остаётся таким, каким его отдал YouTube.
HomeTopBlocks splitHomeTop(List<BrowseSection> sections) {
  BrowseSection? listenAgain;
  BrowseSection? quickPicks;
  final List<BrowseSection> rest = <BrowseSection>[];
  for (final BrowseSection section in sections) {
    if (section.items.isNotEmpty) {
      if (listenAgain == null && _isListenAgain(section.title)) {
        listenAgain = section;
        continue;
      }
      if (quickPicks == null && _isQuickPicks(section.title)) {
        quickPicks = section;
        continue;
      }
    }
    rest.add(section);
  }

  // Если после выноса в ленте не осталось ни одной непустой секции, отдельные
  // блоки показывать нельзя: `SectionListView` при пустом списке секций рисует
  // заглушку «не найдено» и шапку пропускает. Тогда оставляем всё как есть.
  final bool restHasContent =
      rest.any((BrowseSection section) => section.items.isNotEmpty);
  if ((listenAgain != null || quickPicks != null) && !restHasContent) {
    return HomeTopBlocks(sections: curateHomeSections(sections));
  }

  return HomeTopBlocks(
    listenAgain: listenAgain,
    quickPicks: quickPicks,
    sections: curateHomeSections(rest),
  );
}

/// Признаки полки недавнего прослушивания в заголовке секции YouTube.
///
/// Набор уже был в проекте (он разбирал такие секции как «Быстрый выбор»);
/// здесь он отделён, потому что полка недавнего и быстрый выбор — разные блоки.
const List<String> _listenAgainMarkers = <String>[
  'слушать снова',
  'listen again',
  'продолж',
  'continue',
  'недавн',
  'recent',
  'истори',
  'history',
];

/// Признаки «Быстрого выбора» — плиток быстрого запуска.
const List<String> _quickPicksMarkers = <String>[
  'быстрый выбор',
  'quick pick',
  'микс дня',
  'my mix',
];

bool _isListenAgain(String title) => _hasMarker(title, _listenAgainMarkers);
bool _isQuickPicks(String title) => _hasMarker(title, _quickPicksMarkers);

bool _hasMarker(String title, List<String> markers) {
  final String lower = title.toLowerCase();
  for (final String marker in markers) {
    if (lower.contains(marker)) return true;
  }
  return false;
}

/// Копия секции с новым заголовком, если он поменялся.
///
/// [BrowseSection] неизменяемый, поэтому создаём новую с теми же данными.
BrowseSection _renamed(BrowseSection section, String label) {
  if (label == section.title) return section;
  return BrowseSection(
    title: label,
    subtitle: section.subtitle,
    items: section.items,
    browseId: section.browseId,
    params: section.params,
  );
}

/// Подписи ArchiveTune и признаки, по которым узнаётся секция YouTube Music.
///
/// Порядок проверки важен: «Новые клипы» должно проверяться раньше
/// «Новых релизов», иначе подстрока «нов» уведёт его не туда.
/// Подписи взяты из `res/values-ru/strings.xml` ветки main ArchiveTune
/// (`quick_picks`, `keep_listening`, `forgotten_favorites`, `similar_to`),
/// чтобы заголовки секций совпадали с nightly-сборкой дословно. Исключение —
/// «Слушать снова»: так полку недавнего называет YouTube Music, у ArchiveTune
/// ей соответствует `keep_listening`.
const List<(String label, List<String> markers)> _knownLabels =
    <(String, List<String>)>[
  (
    // Полка недавнего прослушивания. ArchiveTune зовёт её
    // `keep_listening` («Продолжайте слушать»), YouTube — «Слушать снова»;
    // оба названия относятся к одному блоку.
    'Слушать снова',
    <String>[
      'слушать снова',
      'listen again',
      'продолж',
      'continue',
      'недавн',
      'recent',
      'истори',
      'history',
    ],
  ),
  (
    // ArchiveTune: `<string name="quick_picks">Быстрый выбор</string>`.
    'Быстрый выбор',
    <String>[
      'быстрый выбор',
      'quick pick',
      'микс дня',
      'my mix',
      'рекоменду',
      'recommended',
    ],
  ),
  (
    'Новые клипы',
    <String>['клип', 'video', 'видео'],
  ),
  (
    'Новые релизы',
    <String>['релиз', 'release', 'нов', 'new'],
  ),
  (
    'Хиты и чарты',
    <String>[
      'тренд',
      'trending',
      'чарт',
      'chart',
      'хит',
      'hit',
      'популярн',
      'popular',
    ],
  ),
  (
    // ArchiveTune: `<string name="forgotten_favorites">Давно не слушали</string>`.
    'Давно не слушали',
    <String>['забыт', 'forgotten'],
  ),
  (
    // ArchiveTune: `<string name="similar_to">Похоже на</string>`.
    'Похоже на',
    <String>[
      'похож',
      'similar',
      'related',
      'исполнител',
      'artist',
      'артист',
    ],
  ),
  (
    'Плейлисты для вас',
    <String>[
      'плейлист',
      'playlist',
      'подборк',
      'mix',
      'микс',
      'настроен',
      'mood',
    ],
  ),
];

/// Подбирает подпись ArchiveTune или возвращает исходный заголовок.
String _archiveLabel(String title) {
  final String lower = title.toLowerCase();
  for (final (String label, List<String> markers) in _knownLabels) {
    for (final String marker in markers) {
      if (lower.contains(marker)) return label;
    }
  }
  return title;
}

/// Порядок секций — как в `HomeContent` (HomeScreen.kt:350-635):
/// «быстрый выбор», полка недавнего, плейлисты аккаунта, «давно не
/// слушали», «похоже на», затем прочие секции YouTube Music. Незнакомые
/// уходят в конец, сохраняя относительный порядок.
int _rankOf(String label) {
  switch (label) {
    case 'Слушать снова':
      return 0;
    case 'Быстрый выбор':
      return 1;
    case 'Плейлисты для вас':
      return 2;
    case 'Давно не слушали':
      return 3;
    case 'Похоже на':
      return 4;
    case 'Новые релизы':
      return 5;
    case 'Хиты и чарты':
      return 6;
    case 'Новые клипы':
      return 7;
  }
  return 100;
}
