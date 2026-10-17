import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/utils/format.dart';
import '../data/models/models.dart';
import '../features/common/navigation.dart';

/// Подпись исполнителей, где каждое имя — ссылка на страницу.
///
/// Артист написан во многих местах: строка трека, очередь, панель плеера,
/// полный экран, подпись карточки. Раньше ссылкой он был только в строке
/// трека, а в остальных местах оставался простым текстом — то есть нажать
/// на него было нельзя. Здесь сборка подписи живёт в одном месте, поэтому
/// ведёт себя одинаково везде.
///
/// Исполнители без идентификатора (гостевые ответы) остаются обычным текстом:
/// вести некуда, и притворяться ссылкой нельзя.
///
/// Навигабельное имя помечается цветом акцента и подчёркиванием, а над строкой
/// появляется курсор-указатель: иначе ссылку не отличить от обычного текста, и
/// нажатие выглядит как «кнопка не работает».
class ArtistLine extends StatefulWidget {
  const ArtistLine({
    super.key,
    required this.artists,
    this.style,
    this.maxLines = 1,
    this.fallback = 'Неизвестный исполнитель',
    this.suffix,
    this.overflow = TextOverflow.ellipsis,
    this.textAlign,
    this.onArtistTap,
  });

  final List<ArtistRef> artists;
  final TextStyle? style;
  final int maxLines;

  /// Что показать, если исполнителей нет вовсе.
  final String fallback;

  /// Хвост подписи: длительность, альбом, отметка качества. Дописывается
  /// через « • », как `joinByBullet` в оригинале.
  final List<String>? suffix;

  final TextOverflow overflow;

  /// Свой обработчик нажатия на имя.
  ///
  /// Нужен полному плееру: перед переходом к исполнителю он должен СВЕРНУТЬСЯ,
  /// иначе страница открывается под плеером, а плеер остаётся на экране.
  final void Function(ArtistRef artist)? onArtistTap;

  /// Выравнивание строки. В «герое» страницы подпись идёт по центру
  /// (`TextAlign.Center` в `MediaDetailHero.kt`), поэтому выравнивание
  /// вынесено параметром, а не задано жёстко.
  final TextAlign? textAlign;

  @override
  State<ArtistLine> createState() => _ArtistLineState();
}

class _ArtistLineState extends State<ArtistLine> {
  /// Распознаватели нажатий. Их нужно освобождать вручную: `TextSpan` не
  /// владеет ими, а утечка распознавателя — это утечка всего дерева жестов.
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final TapGestureRecognizer recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  /// Распознаватель ссылки №[index].
  ///
  /// Распознаватели переиспользуются между сборками, а не создаются заново.
  /// Причина: панель плеера и полный экран перестраиваются на каждом тике
  /// позиции (несколько раз в секунду). Если при этом освобождать
  /// распознаватель, нажатие, начатое до перестройки, обрывается: палец
  /// опущен, распознаватель уже уничтожен — и тап не срабатывает. Поэтому
  /// меняем только `onTap`, а сам объект живёт до смены набора исполнителей.
  TapGestureRecognizer _recognizerAt(int index) {
    while (_recognizers.length <= index) {
      _recognizers.add(TapGestureRecognizer());
    }
    return _recognizers[index];
  }

  /// Освобождает распознаватели, оставшиеся от прошлого набора ссылок
  /// (ссылок стало меньше) — иначе они копились бы и утекали.
  void _trimRecognizers(int keep) {
    while (_recognizers.length > keep) {
      _recognizers.removeLast().dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Ссылка намеренно НЕ отличается от остального текста: ни цветом, ни
    // подчёркиванием. Так исполнитель выглядит одинаково во всех местах —
    // в карточке, в строке трека и в плеере, — а о кликабельности говорит
    // только курсор. Раньше имя подсвечивалось акцентом, и подписи карточек
    // выделялись на фоне остального интерфейса.
    final List<InlineSpan> spans = <InlineSpan>[];
    int linkCount = 0;
    if (widget.artists.isEmpty) {
      spans.add(TextSpan(text: widget.fallback));
    } else {
      for (int i = 0; i < widget.artists.length; i++) {
        if (i > 0) spans.add(const TextSpan(text: ', '));
        final ArtistRef artist = widget.artists[i];
        final String name = cleanArtistName(artist.name);
        if (artist.isNavigable) {
          final TapGestureRecognizer recognizer = _recognizerAt(linkCount++);
          recognizer.onTap = () => widget.onArtistTap != null
              ? widget.onArtistTap!(artist)
              : AppRoutes.artist(context, artist.id!);
          spans.add(TextSpan(text: name, recognizer: recognizer));
        } else {
          spans.add(TextSpan(text: name));
        }
      }
    }
    _trimRecognizers(linkCount);

    for (final String tail in widget.suffix ?? const <String>[]) {
      if (tail.trim().isEmpty) continue;
      spans.add(TextSpan(text: ' • $tail'));
    }

    final Widget text = Text.rich(
      TextSpan(children: spans),
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      textAlign: widget.textAlign,
      style: widget.style,
    );

    // Указатель-курсор: `TextSpan.mouseCursor` обычный `Text` не показывает,
    // поэтому задаём его областью вокруг строки — и только когда в ней правда
    // есть ссылка, иначе курсор обманывал бы так же, как и вид текста.
    if (linkCount == 0) return text;
    return MouseRegion(cursor: SystemMouseCursors.click, child: text);
  }
}
