import '../../data/models/models.dart';

/// Приводит секции главной к порядку и подписям из спецификации ArchiveTune.
///
/// Зачем: YouTube Music отдаёт секции в разном порядке и под своими
/// названиями («Рекомендуем», «В тренде», «Новые клипы»). Спецификация же
/// задаёт свой порядок (чипы, «Быстрый выбор», «Продолжайте слушать», «Ваши
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
/// чтобы заголовки секций совпадали с nightly-сборкой дословно.
const List<(String label, List<String> markers)> _knownLabels =
    <(String, List<String>)>[
  (
    // ArchiveTune: `<string name="quick_picks">Быстрый выбор</string>`.
    'Быстрый выбор',
    <String>[
      'слушать снова',
      'listen again',
      'рекоменду',
      'recommended',
      'quick pick',
      'микс дня',
      'my mix',
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
    // ArchiveTune: `<string name="keep_listening">Продолжайте слушать</string>`.
    'Продолжайте слушать',
    <String>['продолж', 'continue', 'недавн', 'recent', 'истори', 'history'],
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
/// быстрый выбор, «продолжайте слушать», плейлисты аккаунта, «давно не
/// слушали», «похоже на», затем прочие секции YouTube Music. Незнакомые
/// уходят в конец, сохраняя относительный порядок.
int _rankOf(String label) {
  switch (label) {
    case 'Быстрый выбор':
      return 0;
    case 'Продолжайте слушать':
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
