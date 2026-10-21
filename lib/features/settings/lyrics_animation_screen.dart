import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/layout.dart';
import '../../data/local/app_settings.dart';
import '../../state/providers.dart';
import '../player/lyrics_view.dart';
import 'settings_components.dart';

/// Настройка анимации текста песни (задача 3.2).
///
/// Отдельный экран, а не диалог: у каждого стиля есть описание и предпросмотр,
/// а в диалог это не помещается. Стиль выбирается один на появление строки и
/// подсветку слов, поэтому подписывать его дважды не нужно.
class LyricsAnimationScreen extends ConsumerStatefulWidget {
  const LyricsAnimationScreen({super.key});

  @override
  ConsumerState<LyricsAnimationScreen> createState() =>
      _LyricsAnimationScreenState();
}

class _LyricsAnimationScreenState
    extends ConsumerState<LyricsAnimationScreen> {
  /// Счётчик запусков предпросмотра: по нему анимация перезапускается, даже
  /// если выбран тот же стиль.
  int _previewSeq = 0;

  void _replay() => setState(() => _previewSeq++);

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = ref.watch(settingsControllerProvider);
    final SettingsController controller =
        ref.read(settingsControllerProvider.notifier);
    final LyricsAnimationStyle style = settings.lyricsAnimationStyle;
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Анимация текста')),
      body: ContentWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            SettingsDims.screenHorizontalPadding,
            16,
            SettingsDims.screenHorizontalPadding,
            SettingsDims.screenBottomPadding,
          ),
          children: <Widget>[
            _AnimationPreview(
              style: style,
              seq: _previewSeq,
              onReplay: _replay,
            ),
            const SizedBox(height: SettingsDims.sectionSpacing),
            SettingsGroup(
              title: 'Стиль',
              accent: scheme.secondary,
              children: <Widget>[
                RadioGroup<LyricsAnimationStyle>(
                  groupValue: style,
                  onChanged: (LyricsAnimationStyle? value) {
                    if (value == null) return;
                    controller.setLyricsAnimationStyle(value);
                    setState(() => _previewSeq++);
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (final LyricsAnimationStyle item
                          in LyricsAnimationStyle.values)
                        RadioListTile<LyricsAnimationStyle>(
                          value: item,
                          title: Text(item.label),
                          subtitle: Text(
                            item.description,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: SettingsDims.sectionSpacing),
            SettingsGroup(
              title: 'Доступность',
              accent: scheme.tertiary,
              children: <Widget>[
                // Дублирует переключатель из «Внешнего вида» намеренно: здесь
                // видно, почему выбранный стиль ничего не делает.
                SettingsSwitchRow(
                  icon: Icons.animation,
                  title: 'Отключить анимации',
                  subtitle: settings.disableAnimations
                      ? 'Включено: любой стиль срабатывает мгновенно'
                      : 'Выключено: стиль применяется к строкам и словам',
                  value: settings.disableAnimations,
                  onChanged: controller.setDisableAnimations,
                ),
                if (settings.disableAnimations)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: Text(
                      'Стиль сохраняется, но движение отключено во всём '
                      'приложении — подсветка слов и смена строк происходят '
                      'без перехода.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Предпросмотр стиля: строка появляется по выбранному профилю, выделенное
/// слово «пропевается» теми же множителями подскока и свечения.
///
/// Анимация одноразовая и заканчивается сама: никакого `repeat`, иначе
/// `pumpAndSettle` в тестах не дождался бы покоя.
class _AnimationPreview extends StatelessWidget {
  const _AnimationPreview({
    required this.style,
    required this.seq,
    required this.onReplay,
  });

  final LyricsAnimationStyle style;
  final int seq;
  final VoidCallback onReplay;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final LyricsAnimationProfile profile = LyricsAnimationProfile.of(style);
    final bool instant = profile.enter.duration == Duration.zero;
    final TextStyle lineStyle = theme.textTheme.headlineSmall!.copyWith(
      fontWeight: FontWeight.w800,
      color: scheme.onSurface,
    );
    final TextStyle wordStyle = theme.textTheme.titleMedium!.copyWith(
      fontWeight: FontWeight.w700,
      color: scheme.onSurfaceVariant,
    );

    // Ключ включает и стиль, и счётчик: выбор строки и кнопка «ещё раз»
    // перезапускают предпросмотр с начала.
    final Key previewKey = ValueKey<String>('$style-$seq');

    Widget linePreview(double t) {
      final double clamped = t.clamp(0.0, 1.0);
      final double scale = profile.fromScale + (1 - profile.fromScale) * t;
      return Opacity(
        opacity: clamped,
        child: Transform.scale(
          scale: scale,
          alignment: Alignment.centerLeft,
          child: Text('Слова плывут в такт аккордам', style: lineStyle),
        ),
      );
    }

    Widget wordPreview(double t) {
      final double sin = math.sin(t.clamp(0.0, 1.0) * math.pi);
      final double scale = 1 + 0.015 * profile.wordBounce * sin;
      final double glow = profile.wordGlow * 0.45 * t.clamp(0.0, 1.0);
      return Transform.scale(
        scale: scale,
        alignment: Alignment.centerLeft,
        child: Text(
          'аккордам',
          style: wordStyle.copyWith(
            color: Color.lerp(
              scheme.onSurfaceVariant,
              scheme.onSurface,
              t.clamp(0.0, 1.0),
            ),
            shadows: glow > 0
                ? <Shadow>[
                    Shadow(
                      color: scheme.primary.withValues(alpha: glow),
                      blurRadius: math.max(1, 12 * profile.wordGlow),
                    ),
                  ]
                : null,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(SettingsDims.groupCardCornerRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.play_circle_outline,
                  size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                'Предпросмотр',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: onReplay,
                icon: const Icon(Icons.replay, size: 18),
                label: const Text('Ещё раз'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (instant)
            linePreview(1)
          else
            TweenAnimationBuilder<double>(
              key: previewKey,
              tween: Tween<double>(begin: 0, end: 1),
              duration: profile.enter.duration,
              curve: profile.enter.curve,
              builder: (BuildContext context, double t, Widget? _) =>
                  linePreview(t),
            ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Text(
                'Караоке: ',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (instant)
                wordPreview(1)
              else
                TweenAnimationBuilder<double>(
                  key: ValueKey<String>('word-$style-$seq'),
                  tween: Tween<double>(begin: 0, end: 1),
                  duration: profile.enter.duration,
                  curve: profile.enter.curve,
                  builder: (BuildContext context, double t, Widget? _) =>
                      wordPreview(t),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
