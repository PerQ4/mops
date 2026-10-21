import 'package:flutter/material.dart';

import '../../core/theme/layout.dart';

/// Страница медиа: альбом, исполнитель, плейлист.
///
/// На узком и среднем окне — одна колонка: шапка сверху, содержимое под ней,
/// как в ArchiveTune. На широком окне шапка перестаёт быть огромным блоком во
/// всю высоту: обложка с действиями уходит в колонку слева, а список треков
/// встаёт справа и виден сразу, без прокрутки под шапку.
///
/// Зачем общий виджет: содержимое у трёх страниц разное, а правило раскладки
/// одно. Держать его копией в каждом экране — значит гарантированно получить
/// расхождение при следующей правке.
class MediaPage extends StatelessWidget {
  const MediaPage({
    super.key,
    required this.title,
    required this.heroBuilder,
    required this.slivers,
    this.actions = const <Widget>[],
  });

  /// Заголовок в шапке страницы.
  final String title;

  /// Действия шапки (у плейлиста — «…»).
  final List<Widget> actions;

  /// Шапка страницы. [wide] — рисовать её колонкой слева, а не во всю ширину.
  final Widget Function(BuildContext context, bool wide) heroBuilder;

  /// Содержимое под шапкой: заголовок секции, список треков, ленты.
  ///
  /// На широком окне эти слюды уходят в правую колонку и прокручиваются
  /// отдельно от шапки — поэтому треки не прячутся за ней.
  final List<Widget> slivers;

  @override
  Widget build(BuildContext context) {
    // Широкое окно определяется окном, а не шириной области содержимого:
    // раскладка страницы должна переключаться там же, где и раскладка
    // оболочки, иначе панель библиотеки и страница разъедутся по порогам.
    final bool wide = context.isExpandedLayout;

    if (!wide) {
      return CustomScrollView(
        slivers: <Widget>[
          _appBar(),
          SliverToBoxAdapter(child: heroBuilder(context, false)),
          ...slivers,
          _footer(),
        ],
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double heroWidth =
            AppLayout.heroColumnWidth(constraints.maxWidth);
        return CustomScrollView(
          slivers: <Widget>[
            _appBar(),
            SliverFillRemaining(
              // Ребёнок — не один список, а ряд из двух: `hasScrollBody: true`
              // даёт ему ровно высоту под шапкой, и обе колонки скроллятся
              // сами, не растягивая страницу.
              hasScrollBody: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SizedBox(
                    width: heroWidth,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(
                        AppLayout.gutter,
                        AppLayout.gutter,
                        AppLayout.gutter,
                        // Запас под плавающий островок: он лежит поверх
                        // содержимого и на широком окне тоже.
                        AppLayout.floatingDockClearance,
                      ),
                      child: heroBuilder(context, true),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: CustomScrollView(
                      slivers: <Widget>[
                        ...slivers,
                        _footer(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// Шапка одинакова в обеих раскладках: на широком окне она просто
  /// растягивается над двумя колонками.
  Widget _appBar() {
    return SliverAppBar(
      pinned: true,
      expandedHeight: AppLayout.appBarHeight,
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: actions.isEmpty ? null : actions,
    );
  }

  /// Отступ снизу: последние строки не уходят под плавающий островок.
  Widget _footer() {
    return const SliverToBoxAdapter(
      child: SizedBox(height: AppLayout.floatingDockClearance),
    );
  }
}
