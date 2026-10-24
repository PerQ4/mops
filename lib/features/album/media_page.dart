import 'package:flutter/material.dart';

import '../../core/theme/layout.dart';
import 'media_wide.dart';

/// Страница медиа: альбом, исполнитель, плейлист.
///
/// На узком и среднем окне — одна колонка: шапка сверху, содержимое под ней,
/// как в ArchiveTune. На широком окне страница тоже одноколоночная, но шапка
/// превращается в баннер на всю ширину, а список идёт под ним отдельной
/// центрированной колонкой. Одной прокруткой: две независимые полосы и
/// разделитель на всю высоту читались как две панели, а не как одна страница.
///
/// Зачем общий виджет: содержимое у трёх страниц разное, а правило раскладки
/// одно. Держать его копией в каждом экране — значит гарантированно получить
/// расхождение при следующей правке.
class MediaPage extends StatelessWidget {
  const MediaPage({
    super.key,
    required this.title,
    required this.heroBuilder,
    required this.sliverBuilder,
    this.actions = const <Widget>[],
    this.description,
  });

  /// Заголовок в шапке страницы. На широком окне не показывается: там имя
  /// страницы уже есть в баннере, и дубль в шапке только спорил с ним.
  final String title;

  /// Действия шапки (у плейлиста — «…»).
  final List<Widget> actions;

  /// Шапка страницы. [wide] — рисовать баннером на всю ширину.
  final Widget Function(BuildContext context, bool wide) heroBuilder;

  /// Содержимое под шапкой: заголовки секций, список треков, ленты.
  ///
  /// Строится вместе с признаком [wide]: на широком окне список — таблица с
  /// подписанными колонками, на узком — прежние строки с обложкой.
  final List<Widget> Function(BuildContext context, bool wide) sliverBuilder;

  /// Описание под баннером. Показывается только на широком окне: на узком
  /// оно живёт внутри шапки и в отдельном блоке не нуждается.
  final String? description;

  @override
  Widget build(BuildContext context) {
    // Широкое окно определяется окном, а не шириной области содержимого:
    // раскладка страницы должна переключаться там же, где и раскладка
    // оболочки, иначе панель библиотеки и страница разъедутся по порогам.
    final bool wide = context.isExpandedLayout;

    if (!wide) {
      return CustomScrollView(
        slivers: <Widget>[
          _appBar(context, wide: false),
          SliverToBoxAdapter(child: heroBuilder(context, false)),
          ...sliverBuilder(context, false),
          _footer(),
        ],
      );
    }

    final String? text = description?.trim();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double inset = mediaContentInset(constraints.maxWidth);
        return CustomScrollView(
          slivers: <Widget>[
            _appBar(context, wide: true),
            SliverToBoxAdapter(child: heroBuilder(context, true)),
            if (text != null && text.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: inset),
                  child: MediaDescription(text: text),
                ),
              ),
            // Небольшой зазор после баннера: его градиент заканчивается
            // цветом поверхности, и список не должен липнуть к краю.
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            for (final Widget sliver in sliverBuilder(context, true))
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                sliver: sliver,
              ),
            _footer(),
          ],
        );
      },
    );
  }

  /// Шапка страницы. На широком окне — только «назад» и действия: заголовок
  /// уже в баннере.
  Widget _appBar(BuildContext context, {required bool wide}) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SliverAppBar(
      pinned: true,
      expandedHeight: AppLayout.appBarHeight,
      title: wide
          ? null
          : Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: actions.isEmpty ? null : actions,
      // На широком окне шапка прозрачна по цвету и не видна на фоне страницы;
      // тонкая линия отделяет её от уезжающего под неё баннера и списка.
      shape: wide
          ? Border(
              bottom: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.18),
              ),
            )
          : null,
    );
  }

  /// Отступ снизу: последние строки не уходят под плавающий островок.
  Widget _footer() {
    return const SliverToBoxAdapter(
      child: SizedBox(height: AppLayout.floatingDockClearance),
    );
  }
}
