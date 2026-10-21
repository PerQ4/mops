import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/audio_equalizer.dart';
import '../../data/local/app_settings.dart';
import '../../state/providers.dart';

/// Готовый набор полос эквалайзера.
///
/// Полосы заданы в тех же 10 частотах, что и слайдеры
/// ([kEqualizerBandFrequencies]); значения — в дБ и укладываются в
/// [kEqualizerMaxGainDb]. Наборы приблизительные, как у бытовых эквалайзеров:
/// точной «правильной» кривой не существует, важно, что эффект слышен.
class EqualizerPreset {
  const EqualizerPreset(this.id, this.label, this.bands);

  final String id;
  final String label;
  final List<double> bands;
}

const List<EqualizerPreset> kEqualizerPresets = <EqualizerPreset>[
  EqualizerPreset('flat', 'Плоский', kEqualizerFlatBands),
  EqualizerPreset('bass', 'Бас', <double>[7, 6, 5, 3, 1, 0, 0, 0, 0, 0]),
  EqualizerPreset('vocal', 'Вокал', <double>[-3, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
  EqualizerPreset('rock', 'Рок', <double>[5, 4, 2, 0, -1, 0, 2, 4, 5, 5]),
  EqualizerPreset('pop', 'Поп', <double>[-1, 0, 2, 4, 4, 2, 0, -1, -1, -2]),
  EqualizerPreset('jazz', 'Джаз', <double>[3, 2, 1, 2, -1, -1, 0, 1, 2, 3]),
  EqualizerPreset('classical', 'Классика',
      <double>[4, 3, 2, 0, -1, -1, 0, 2, 3, 4]),
  EqualizerPreset('electronic', 'Электроника',
      <double>[5, 4, 1, 0, -2, 0, 1, 2, 5, 6]),
];

/// Пресет по имени; неизвестное имя — плоский.
EqualizerPreset equalizerPresetById(String id) => kEqualizerPresets.firstWhere(
      (EqualizerPreset p) => p.id == id,
      orElse: () => kEqualizerPresets.first,
    );

/// Подпись строки настроек: выключен, выбранный пресет или «Свой».
String equalizerSummary(AppSettings settings) {
  if (!settings.equalizerEnabled) return 'Выключен';
  final EqualizerPreset preset = equalizerPresetById(settings.equalizerPresetId);
  // Пресет мог быть выбран, а полосы после этого подправлены — тогда честнее
  // сказать «свой», чем показывать имя набора, которому значения не отвечают.
  if (preset.id != 'flat' && _sameBands(preset.bands, settings.equalizerBands)) {
    return preset.label;
  }
  return settings.equalizerBands.every((double g) => g == 0)
      ? 'Плоский'
      : 'Свой';
}

bool _sameBands(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if ((a[i] - b[i]).abs() > 0.05) return false;
  }
  return true;
}

/// Открывает диалог эквалайзера.
///
/// Точка входа одна: и из настроек, и (при желании) из меню трека. Значения
/// применяются к движку сразу, а на диск пишутся тем же настроечным
/// контроллером, поэтому пресет переживает перезапуск.
Future<void> showEqualizerDialog(BuildContext context, WidgetRef ref) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => const _EqualizerDialog(),
  );
}

class _EqualizerDialog extends ConsumerStatefulWidget {
  const _EqualizerDialog();

  @override
  ConsumerState<_EqualizerDialog> createState() => _EqualizerDialogState();
}

class _EqualizerDialogState extends ConsumerState<_EqualizerDialog> {
  late bool _enabled;
  late List<double> _bands;
  late String _presetId;

  /// Значения полос для графика АЧХ.
  ///
  /// Отдельный notifier, а не `setState`: кривая подписана на него через
  /// `CustomPainter(repaint:)`, поэтому перетаскивание слайдера перерисовывает
  /// только painter, а не весь диалог с десятью слайдерами и пресетами.
  late final ValueNotifier<List<double>> _curve;

  /// Отложенное применение к движку: слайдер шлёт значения десятками в
  /// секунду, и пересобирать цепочку `af` на каждый тик незачем.
  Timer? _applyTimer;

  @override
  void initState() {
    super.initState();
    final AppSettings settings = ref.read(settingsControllerProvider);
    _enabled = settings.equalizerEnabled;
    _bands = List<double>.of(settings.equalizerBands);
    _presetId = settings.equalizerPresetId;
    _curve = ValueNotifier<List<double>>(List<double>.unmodifiable(_bands));
  }

  @override
  void dispose() {
    _applyTimer?.cancel();
    _curve.dispose();
    super.dispose();
  }

  /// Отдаёт графику снимок полос: сам `_bands` дальше ещё меняется.
  void _publishCurve() {
    _curve.value = List<double>.unmodifiable(_bands);
  }

  /// Применяет текущее состояние к движку (звучит сразу).
  void _applyToEngine() {
    unawaited(
      ref
          .read(audioEngineProvider)
          .setEqualizer(_enabled ? _bands : const <double>[]),
    );
  }

  /// Применяет с задержкой — во время перетаскивания слайдера.
  void _scheduleEngineApply() {
    _applyTimer?.cancel();
    _applyTimer = Timer(const Duration(milliseconds: 120), _applyToEngine);
  }

  /// Записывает настройки на диск (и через контроллер — в движок).
  void _persist() {
    unawaited(
      ref.read(settingsControllerProvider.notifier).setEqualizer(
            enabled: _enabled,
            bands: _bands,
            presetId: _presetId,
          ),
    );
  }

  void _setEnabled(bool value) {
    setState(() => _enabled = value);
    _applyToEngine();
    _persist();
  }

  void _pickPreset(EqualizerPreset preset) {
    setState(() {
      _presetId = preset.id;
      _bands = List<double>.of(preset.bands);
      if (preset.id != 'flat') _enabled = true;
    });
    _publishCurve();
    _applyToEngine();
    _persist();
  }

  void _reset() {
    _applyTimer?.cancel();
    setState(() {
      _bands = List<double>.of(kEqualizerFlatBands);
      _presetId = 'flat';
    });
    _publishCurve();
    _applyToEngine();
    _persist();
  }

  void _changeBand(int index, double gain) {
    setState(() {
      _bands[index] = gain;
      // Ручная правка ломает соответствие пресету — дальше это «свой» набор.
      _presetId = 'custom';
    });
    _publishCurve();
    _scheduleEngineApply();
  }

  void _commitBand() {
    _applyTimer?.cancel();
    _applyToEngine();
    _persist();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // Отказ фильтра (сборка libmpv без него) показываем прямо в диалоге, а не
    // молчим: включать эквалайзер без эффекта нельзя незаметно.
    final Listenable issue = ref.read(audioEngineProvider).audioEffectIssue;

    return AlertDialog(
      title: const Text('Эквалайзер'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Включить эквалайзер'),
                value: _enabled,
                onChanged: _setEnabled,
              ),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: <Widget>[
                  for (final EqualizerPreset preset in kEqualizerPresets)
                    ChoiceChip(
                      label: Text(preset.label),
                      selected: _presetId == preset.id,
                      onSelected: (_) => _pickPreset(preset),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              _EqualizerCurve(bands: _curve, enabled: _enabled),
              for (int i = 0; i < kEqualizerBandCount; i++)
                _BandSlider(
                  frequency: kEqualizerBandFrequencies[i],
                  gain: _bands[i],
                  enabled: _enabled,
                  onChanged: (double value) => _changeBand(i, value),
                  onChangeEnd: (_) => _commitBand(),
                ),
              ListenableBuilder(
                listenable: issue,
                builder: (BuildContext context, Widget? _) {
                  final String? reason =
                      ref.read(audioEngineProvider).audioEffectIssue.value;
                  if (reason == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Фильтр не применён: $reason',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: _reset, child: const Text('Сбросить')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Готово'),
        ),
      ],
    );
  }
}

/// Одна полоса: подпись частоты, слайдер и текущее усиление в дБ.
class _BandSlider extends StatelessWidget {
  const _BandSlider({
    required this.frequency,
    required this.gain,
    required this.enabled,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final double frequency;
  final double gain;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final String value =
        gain == 0 ? '0' : '${gain > 0 ? '+' : ''}${gain.toStringAsFixed(1)}';
    return Row(
      children: <Widget>[
        SizedBox(
          width: 64,
          child: Text(
            equalizerBandLabel(frequency),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: Slider(
            value: gain.clamp(-kEqualizerMaxGainDb, kEqualizerMaxGainDb),
            min: -kEqualizerMaxGainDb,
            max: kEqualizerMaxGainDb,
            divisions: (kEqualizerMaxGainDb * 4).round(),
            label: value,
            onChanged: enabled ? onChanged : null,
            onChangeEnd: onChangeEnd,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// График АЧХ по тем же десяти полосам, что и слайдеры.
///
/// Подписан на [bands] как на `repaint`: при перетаскивании слайдера
/// перерисовывается только painter, а `RepaintBoundary` не даёт этой
/// перерисовке задеть остальное содержимое диалога.
class _EqualizerCurve extends StatelessWidget {
  const _EqualizerCurve({required this.bands, required this.enabled});

  /// Текущие усиления полос, дБ.
  final ValueListenable<List<double>> bands;

  /// Выключенный эквалайзер рисует кривую приглушённой: слайдеры в это время
  /// тоже недоступны, и яркая кривая обещала бы звук, которого нет.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return RepaintBoundary(
      child: SizedBox(
        height: 148,
        width: double.infinity,
        child: CustomPaint(
          painter: _EqualizerCurvePainter(
            bands: bands,
            enabled: enabled,
            curveColor: scheme.primary,
            gridColor: scheme.outline,
            labelColor: scheme.onSurfaceVariant,
            labelStyle:
                (theme.textTheme.labelSmall ?? const TextStyle())
                    .copyWith(fontSize: 9),
            textDirection: Directionality.of(context),
          ),
        ),
      ),
    );
  }
}

class _EqualizerCurvePainter extends CustomPainter {
  _EqualizerCurvePainter({
    required this.bands,
    required this.enabled,
    required this.curveColor,
    required this.gridColor,
    required this.labelColor,
    required this.labelStyle,
    required this.textDirection,
  }) : super(repaint: bands);

  final ValueListenable<List<double>> bands;
  final bool enabled;
  final Color curveColor;
  final Color gridColor;
  final Color labelColor;
  final TextStyle labelStyle;
  final TextDirection textDirection;

  /// Поля вокруг области графика: слева — подписи дБ, снизу — частоты.
  static const double _left = 28;

  /// Справа поле шире обычного: подпись «16 кГц» должна поместиться по центру
  /// последней полосы, иначе её пришлось бы сдвинуть на соседнюю.
  static const double _right = 20;

  static const double _top = 6;
  static const double _bottom = 16;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect plot = Rect.fromLTRB(
      _left,
      _top,
      size.width - _right,
      size.height - _bottom,
    );
    final List<double> gains = bands.value;
    if (plot.width <= 0 || plot.height <= 0 || gains.isEmpty) return;

    final int count = gains.length;
    final double stepX = count > 1 ? plot.width / (count - 1) : 0;

    // Сетка: горизонтали по ±12, ±6 и 0 дБ, вертикали по полосам. Ноль
    // заметнее остальных — по нему видно, где усиления нет.
    for (final double db in <double>[
      kEqualizerMaxGainDb,
      kEqualizerMaxGainDb / 2,
      0,
      -kEqualizerMaxGainDb / 2,
      -kEqualizerMaxGainDb,
    ]) {
      final double y = _yFor(db, plot);
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        Paint()
          ..color = gridColor.withValues(alpha: db == 0 ? 0.55 : 0.28)
          ..strokeWidth = 1,
      );
    }
    final Paint vertical = Paint()
      ..color = gridColor.withValues(alpha: 0.18)
      ..strokeWidth = 1;
    for (int i = 0; i < count; i++) {
      final double x = plot.left + stepX * i;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), vertical);
    }

    // Точки кривой — по центрам полос, как у слайдеров ниже.
    final List<Offset> points = <Offset>[
      for (int i = 0; i < count; i++)
        Offset(
          plot.left + stepX * i,
          _yFor(
            gains[i].clamp(-kEqualizerMaxGainDb, kEqualizerMaxGainDb),
            plot,
          ),
        ),
    ];

    // Сглаживание — кубики через середины между соседними точками: кривая
    // проходит ровно по значениям полос и не «выстреливает» между ними.
    final Path line = Path()..moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      final Offset previous = points[i - 1];
      final Offset point = points[i];
      final double midX = (previous.dx + point.dx) / 2;
      line.cubicTo(midX, previous.dy, midX, point.dy, point.dx, point.dy);
    }

    final double curveAlpha = enabled ? 1 : 0.4;
    // Заливка под кривой — та же primary с малой альфой: показывает знак
    // усиления, не споря с линией.
    final Path fill = Path.from(line)
      ..lineTo(points.last.dx, plot.bottom)
      ..lineTo(points.first.dx, plot.bottom)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..style = PaintingStyle.fill
        ..color = curveColor.withValues(alpha: enabled ? 0.14 : 0.06),
    );

    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..color = curveColor.withValues(alpha: curveAlpha);
    canvas.drawPath(line, stroke);

    final Paint dot = Paint()..color = curveColor.withValues(alpha: curveAlpha);
    for (final Offset point in points) {
      canvas.drawCircle(point, 2.5, dot);
    }

    _paintDbLabels(canvas, plot);
    _paintFrequencyLabels(canvas, size, plot, stepX, count);
  }

  /// Y усиления [db] в области [plot]: +12 дБ сверху, −12 снизу.
  static double _yFor(double db, Rect plot) {
    return plot.top +
        (kEqualizerMaxGainDb - db) / (2 * kEqualizerMaxGainDb) * plot.height;
  }

  void _paintDbLabels(Canvas canvas, Rect plot) {
    for (final double db in <double>[
      kEqualizerMaxGainDb,
      0,
      -kEqualizerMaxGainDb,
    ]) {
      final double width = plot.left - 4;
      final TextPainter painter = _textPainter(
        db == 0 ? '0' : '${db > 0 ? '+' : '−'}${db.abs().round()}',
        TextAlign.right,
      )..layout(minWidth: width, maxWidth: width);
      painter.paint(canvas, Offset(0, _yFor(db, plot) - painter.height / 2));
      painter.dispose();
    }
  }

  void _paintFrequencyLabels(
    Canvas canvas,
    Size size,
    Rect plot,
    double stepX,
    int count,
  ) {
    for (int i = 0; i < count; i++) {
      if (i >= kEqualizerBandFrequencies.length) break;
      final TextPainter painter = _textPainter(
        equalizerBandLabel(kEqualizerBandFrequencies[i]),
        TextAlign.center,
      )..layout();
      // Крайние подписи прижимаем к краю, чтобы «31 Гц» и «16 кГц» не
      // вылезали за график.
      final double x = (plot.left + stepX * i - painter.width / 2)
          .clamp(0.0, size.width - painter.width);
      painter.paint(canvas, Offset(x, plot.bottom + 2));
      painter.dispose();
    }
  }

  TextPainter _textPainter(String text, TextAlign align) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: labelStyle.copyWith(color: labelColor),
      ),
      textDirection: textDirection,
      textAlign: align,
      maxLines: 1,
    );
  }

  @override
  bool shouldRepaint(_EqualizerCurvePainter old) =>
      // Значения полос приходят через `repaint`-notifier, поэтому здесь их
      // сравнивать не нужно: painter уже перерисован уведомлением.
      old.bands != bands ||
      old.enabled != enabled ||
      old.curveColor != curveColor ||
      old.gridColor != gridColor ||
      old.labelColor != labelColor ||
      old.labelStyle != labelStyle ||
      old.textDirection != textDirection;
}
