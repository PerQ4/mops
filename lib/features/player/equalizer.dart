import 'dart:async';

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
  }

  @override
  void dispose() {
    _applyTimer?.cancel();
    super.dispose();
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
    _applyToEngine();
    _persist();
  }

  void _reset() {
    _applyTimer?.cancel();
    setState(() {
      _bands = List<double>.of(kEqualizerFlatBands);
      _presetId = 'flat';
    });
    _applyToEngine();
    _persist();
  }

  void _changeBand(int index, double gain) {
    setState(() {
      _bands[index] = gain;
      // Ручная правка ломает соответствие пресету — дальше это «свой» набор.
      _presetId = 'custom';
    });
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
