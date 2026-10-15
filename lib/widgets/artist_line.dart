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
class ArtistLine extends StatefulWidget {
  const ArtistLine({
    super.key,
    required this.artists,
    this.style,
    this.maxLines = 1,
    this.fallback = 'Неизвестный исполнитель',
    this.suffix,
    this.overflow = TextOverflow.ellipsis,
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

  @override
  Widget build(BuildContext context) {
    // Набор исполнителей мог смениться — распознаватели пересобираем.
    _disposeRecognizers();

    final List<InlineSpan> spans = <InlineSpan>[];
    if (widget.artists.isEmpty) {
      spans.add(TextSpan(text: widget.fallback));
    } else {
      for (int i = 0; i < widget.artists.length; i++) {
        if (i > 0) spans.add(const TextSpan(text: ', '));
        final ArtistRef artist = widget.artists[i];
        final String name = cleanArtistName(artist.name);
        if (artist.isNavigable) {
          final TapGestureRecognizer recognizer = TapGestureRecognizer()
            ..onTap = () => AppRoutes.artist(context, artist.id!);
          _recognizers.add(recognizer);
          spans.add(TextSpan(text: name, recognizer: recognizer));
        } else {
          spans.add(TextSpan(text: name));
        }
      }
    }

    for (final String tail in widget.suffix ?? const <String>[]) {
      if (tail.trim().isEmpty) continue;
      spans.add(TextSpan(text: ' • $tail'));
    }

    return Text.rich(
      TextSpan(children: spans),
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      style: widget.style,
    );
  }
}
