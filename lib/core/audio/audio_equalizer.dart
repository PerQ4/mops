/// Геометрия полос эквалайзера — общая для движка и интерфейса.
///
/// Десять полос взяты по центральным частотам, привычным для графического
/// эквалайзера (октавная сетка 31 Гц … 16 кГц). Интерфейс показывает именно их,
/// а движок раскладывает значения по сетке того фильтра, который есть в сборке
/// libmpv (см. `media_kit_engine.dart`).
library;

const int kEqualizerBandCount = 10;

/// Центральные частоты полос, Гц.
const List<double> kEqualizerBandFrequencies = <double>[
  31,
  62,
  125,
  250,
  500,
  1000,
  2000,
  4000,
  8000,
  16000,
];

/// Предел усиления одной полосы, дБ (в обе стороны). Больше — уже искажение,
/// а не «настройка звука».
const double kEqualizerMaxGainDb = 12;

/// Плоская настройка: все полосы по нулю. Это и есть «эквалайзер выключен».
const List<double> kEqualizerFlatBands = <double>[
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
];

/// Настроен ли эквалайзер: хоть одна полоса отличается от нуля заметно.
///
/// Порог в сотые доли дБ отсекает накопленный шум округления слайдера —
/// иначе включённый «плоский» эквалайзер строил бы пустую цепочку.
bool equalizerIsFlat(List<double> bands) =>
    bands.isEmpty || bands.every((double gain) => gain.abs() < 0.05);

/// Подпись полосы для интерфейса (`31`, `1 кГц`, …).
String equalizerBandLabel(double hz) {
  if (hz >= 1000) {
    final double k = hz / 1000;
    final String text =
        k == k.roundToDouble() ? k.round().toString() : k.toStringAsFixed(1);
    return '$text кГц';
  }
  return '${hz.round()} Гц';
}
