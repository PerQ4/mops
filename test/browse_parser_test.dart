// Разбор ответов InnerTube. Сеть не используется: строки собраны вручную
// по реальной разметке YouTube Music.
//
// Эти тесты страхуют от тонкой ошибки: обход ответов «разворачивает» список
// на последнем шаге, поэтому `traverse` вместо списка возвращает один элемент.
// Из-за этого молча терялись исполнители, альбом и длительность.
import 'package:flutter_test/flutter_test.dart';
import 'package:mops/core/innertube/renderer.dart';
import 'package:mops/data/models/models.dart';
import 'package:mops/data/sources/browse_parser.dart';

Map<String, dynamic> run(String text, {String? browseId}) => <String, dynamic>{
      'text': text,
      if (browseId != null)
        'navigationEndpoint': <String, dynamic>{
          'browseEndpoint': <String, dynamic>{'browseId': browseId},
        },
    };

Map<String, dynamic> column(List<Map<String, dynamic>> runs) => <String, dynamic>{
      'musicResponsiveListItemFlexColumnRenderer': <String, dynamic>{
        'text': <String, dynamic>{'runs': runs},
      },
    };

/// Строка трека в том виде, в каком её отдаёт поиск.
Map<String, dynamic> trackRow() => <String, dynamic>{
      'flexColumns': <Map<String, dynamic>>[
        column(<Map<String, dynamic>>[run('Creep')]),
        column(<Map<String, dynamic>>[
          run('Radiohead', browseId: 'UCr_iyUANcn9OX_yy9piYoLw'),
          run(' • '),
          run('Pablo Honey', browseId: 'MPREb_abc'),
          run(' • '),
          run('3:59'),
        ]),
      ],
      'playlistItemData': <String, dynamic>{'videoId': '9RfVp-GhKfs'},
      'thumbnail': <String, dynamic>{
        'thumbnails': <Map<String, dynamic>>[
          <String, dynamic>{'url': 'https://example.test/a.jpg', 'width': 60},
        ],
      },
    };

/// Строка исполнителя: используется в фильтре «Исполнители».
Map<String, dynamic> artistRow() => <String, dynamic>{
      'flexColumns': <Map<String, dynamic>>[
        column(<Map<String, dynamic>>[run('Radiohead')]),
        column(<Map<String, dynamic>>[run('Исполнитель')]),
      ],
      'navigationEndpoint': <String, dynamic>{
        'browseEndpoint': <String, dynamic>{
          'browseId': 'UCr_iyUANcn9OX_yy9piYoLw',
          'browseEndpointContextSupportedConfigs': <String, dynamic>{
            'browseEndpointContextMusicConfig': <String, dynamic>{
              'pageType': 'MUSIC_PAGE_TYPE_ARTIST',
            },
          },
        },
      },
    };

void main() {
  group('строка трека', () {
    test('разбираются название, исполнитель, альбом и длительность', () {
      final Track? track = BrowseParser.responsiveItem(trackRow());

      expect(track, isNotNull);
      expect(track!.id, '9RfVp-GhKfs');
      expect(track.title, 'Creep');
      expect(track.artists.map((ArtistRef a) => a.name), <String>['Radiohead']);
      expect(track.artists.first.id, 'UCr_iyUANcn9OX_yy9piYoLw');
      expect(track.album?.name, 'Pablo Honey');
      expect(track.duration, const Duration(minutes: 3, seconds: 59));
      expect(track.thumbnails, isNotEmpty);
    });

    test('служебные подписи не попадают в исполнителей', () {
      final Map<String, dynamic> row = trackRow();
      // YouTube иногда ставит на место исполнителя тип записи.
      row['flexColumns'] = <Map<String, dynamic>>[
        column(<Map<String, dynamic>>[run('Creep')]),
        column(<Map<String, dynamic>>[
          run('Композиция'),
          run(' • '),
          run('3:59'),
        ]),
      ];

      final Track? track = BrowseParser.responsiveItem(row);
      expect(track, isNotNull);
      expect(track!.artists, isEmpty);
      expect(track.duration, const Duration(minutes: 3, seconds: 59));
    });

    test('без ссылок альбом не становится вторым исполнителем', () {
      final Map<String, dynamic> row = trackRow();
      // У гостевых и урезанных ответов ссылок на страницы нет, и байлайн
      // приходит простым текстом. Исполнители в нём — только первый сегмент:
      // иначе альбом печатался в плеере как второй автор.
      row['flexColumns'] = <Map<String, dynamic>>[
        column(<Map<String, dynamic>>[run('Creep')]),
        column(<Map<String, dynamic>>[
          run('Radiohead'),
          run(' • '),
          run('Pablo Honey'),
          run(' • '),
          run('3:59'),
        ]),
      ];

      final Track? track = BrowseParser.responsiveItem(row);
      expect(track, isNotNull);
      expect(
        track!.artists.map((ArtistRef a) => a.name),
        <String>['Radiohead'],
      );
      expect(track.duration, const Duration(minutes: 3, seconds: 59));
    });
  });

  group('строка-не-трек', () {
    test('исполнитель определяется как артист', () {
      final BrowseItem? item = BrowseParser.responsiveAny(artistRow());

      expect(item, isA<ArtistItem>());
      final Artist artist = (item! as ArtistItem).artist;
      expect(artist.name, 'Radiohead');
      expect(artist.id, 'UCr_iyUANcn9OX_yy9piYoLw');
    });

    test('без ссылки на страницу элемент отбрасывается', () {
      final Map<String, dynamic> row = artistRow()..remove('navigationEndpoint');
      expect(BrowseParser.responsiveAny(row), isNull);
    });
  });

  group('секции', () {
    test('плоский поиск собирается в одну секцию «Результаты»', () {
      final Map<String, dynamic> response = <String, dynamic>{
        'contents': <String, dynamic>{
          'tabbedSearchResultsRenderer': <String, dynamic>{
            'tabs': <Map<String, dynamic>>[
              <String, dynamic>{
                'tabRenderer': <String, dynamic>{
                  'content': <String, dynamic>{
                    'sectionListRenderer': <String, dynamic>{
                      'contents': <Map<String, dynamic>>[
                        // Поиск отдаёт по секции на каждый элемент, без заголовков.
                        <String, dynamic>{
                          'itemSectionRenderer': <String, dynamic>{
                            'contents': <Map<String, dynamic>>[
                              <String, dynamic>{
                                'musicResponsiveListItemRenderer': trackRow(),
                              },
                            ],
                          },
                        },
                        <String, dynamic>{
                          'itemSectionRenderer': <String, dynamic>{
                            'contents': <Map<String, dynamic>>[
                              <String, dynamic>{
                                'musicResponsiveListItemRenderer': trackRow(),
                              },
                            ],
                          },
                        },
                      ],
                    },
                  },
                },
              },
            ],
          },
        },
      };

      final List<BrowseSection> sections =
          BrowseParser.sectionsFrom(response);

      expect(sections, hasLength(1));
      expect(sections.first.title, 'Результаты');
      expect(sections.first.items, hasLength(2));
      expect(sections.first.items.first, isA<TrackItem>());
    });

    test('полка с заголовком сохраняет своё название', () {
      final Map<String, dynamic> response = <String, dynamic>{
        'contents': <String, dynamic>{
          'sectionListRenderer': <String, dynamic>{
            'contents': <Map<String, dynamic>>[
              <String, dynamic>{
                'musicShelfRenderer': <String, dynamic>{
                  'title': <String, dynamic>{
                    'runs': <Map<String, dynamic>>[
                      <String, dynamic>{'text': 'Песни'},
                    ],
                  },
                  'contents': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'musicResponsiveListItemRenderer': trackRow(),
                    },
                  ],
                },
              },
            ],
          },
        },
      };

      final List<BrowseSection> sections =
          BrowseParser.sectionsFrom(response);

      expect(sections, hasLength(1));
      expect(sections.first.title, 'Песни');
      expect(sections.first.items, hasLength(1));
    });

    test('пустой ответ не приводит к падению', () {
      expect(BrowseParser.sectionsFrom(<String, dynamic>{}), isEmpty);
      expect(BrowseParser.homeSections(<String, dynamic>{}), isEmpty);
    });
  });

  group('вспомогательные функции', () {
    test('длительность разбирается из текста', () {
      expect(parseDurationText('3:59'), const Duration(minutes: 3, seconds: 59));
      expect(parseDurationText('1:02:33'),
          const Duration(hours: 1, minutes: 2, seconds: 33));
      expect(parseDurationText('Radiohead'), isNull);
      expect(parseDurationText(''), isNull);
    });

    test('текст собирается из runs и simpleText', () {
      expect(textOf(<String, dynamic>{'text': 'Привет'}), 'Привет');
      expect(textOf(<String, dynamic>{'simpleText': 'Привет'}), 'Привет');
      expect(
        textOf(<String, dynamic>{
          'runs': <Map<String, dynamic>>[
            <String, dynamic>{'text': 'А'},
            <String, dynamic>{'text': 'Б'},
          ],
        }),
        'АБ',
      );
    });
  });
}
