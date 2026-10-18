import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/player_controller.dart';

/// Открывает диалог «Детали потока» — параметры играющего потока.
///
/// Данные берём из `PlaybackState`: их наполняет движок из `media_kit`
/// (`track-list`, `audio-params`, `audio-bitrate`). Чего движок не отдаёт
/// (контейнер), показываем как «нет данных», а не выдумываем.
Future<void> showMediaInfoDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => const _MediaInfoDialog(),
  );
}

class _MediaInfoDialog extends ConsumerWidget {
  const _MediaInfoDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Следим только за сведениями о потоке: они меняются редко. Запись из
    // значений сравнивается по содержимому, поэтому тики позиции (несколько
    // раз в секунду) диалог не перестраивают.
    final (
      String? codec,
      String? container,
      int? bitrate,
      int? sampleRate,
      int? channels,
    ) = ref.watch(
      playerControllerProvider.select(
        (PlayerUiState s) => (
          s.playback.audioCodec,
          s.playback.container,
          s.playback.bitrate,
          s.playback.sampleRate,
          s.playback.channels,
        ),
      ),
    );

    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final bool known =
        codec != null || bitrate != null || sampleRate != null || channels != null;

    return AlertDialog(
      title: const Text('Детали потока'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (!known)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'Параметры ещё не разобраны — включите трек и откройте '
                    'диалог снова.',
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              _MediaInfoRow(label: 'Кодек', value: codec),
              _MediaInfoRow(label: 'Контейнер', value: container),
              _MediaInfoRow(label: 'Битрейт', value: _formatBitrate(bitrate)),
              _MediaInfoRow(
                label: 'Частота дискретизации',
                value: sampleRate == null ? null : '$sampleRate Гц',
              ),
              _MediaInfoRow(
                label: 'Каналы',
                value: channels?.toString(),
              ),
              const SizedBox(height: 12),
              Text(
                // media_kit в Dart контейнер не отдаёт — пишем это прямо, чтобы
                // «нет данных» не выглядело как сбой приложения.
                'Контейнер media_kit не сообщает, поэтому он всегда «нет '
                'данных». Остальные параметры — реальные, от движка.',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}

/// Битрейт в бит/с → «147 кбит/с». `null` — значение неизвестно.
String? _formatBitrate(int? bitsPerSecond) {
  if (bitsPerSecond == null || bitsPerSecond <= 0) return null;
  if (bitsPerSecond < 1000) return '$bitsPerSecond бит/с';
  final double kbps = bitsPerSecond / 1000;
  final String value =
      kbps >= 100 ? kbps.round().toString() : kbps.toStringAsFixed(1);
  return '$value кбит/с';
}

/// Строка «подпись — значение»; вместо отсутствующего значения — «нет данных».
class _MediaInfoRow extends StatelessWidget {
  const _MediaInfoRow({required this.label, required this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool missing = value == null || value!.isEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              missing ? 'нет данных' : value!,
              style: text.bodyMedium?.copyWith(
                color: missing ? scheme.onSurfaceVariant : scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
