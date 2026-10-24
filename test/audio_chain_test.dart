// Разбор цепочки `af`, которой владеет движок.
//
// Визуализатор отдаёт владельцу один фильтр `lavfi` с графом, а mpv возвращает
// его с экранированными запятыми (`%750%…`). Если разобрать такую строку по
// запятым, граф развалится, и при следующей пересборке mpv получит битую
// цепочку — вместе с эквалайзером. Эти тесты фиксируют, что разбор и сборка
// сохраняют граф целиком.
import 'package:flutter_test/flutter_test.dart';
import 'package:mops/core/audio/mpv_audio_chain.dart';

/// Строка ровно в том виде, в каком её отдаёт libmpv после установки графа:
/// длину литерала mpv считает сам. Здесь строим её так же — от длины графа.
final String _escapedGraph = '@mopsvis:lavfi=graph=%${_graph.length}%$_graph';

const String _graph =
    'asplit=9[s0][s1][s2][s3][s4][s5][s6][s7][s8];'
    '[s1]bandpass=f=60:width_type=o:width=1,pan=mono|c0=0.5*c0+0.5*c1[b1];'
    '[s2]bandpass=f=120:width_type=o:width=1,pan=mono|c0=0.5*c0+0.5*c1[b2];'
    '[s3]bandpass=f=240:width_type=o:width=1,pan=mono|c0=0.5*c0+0.5*c1[b3];'
    '[s4]bandpass=f=500:width_type=o:width=1,pan=mono|c0=0.5*c0+0.5*c1[b4];'
    '[s5]bandpass=f=1000:width_type=o:width=1,pan=mono|c0=0.5*c0+0.5*c1[b5];'
    '[s6]bandpass=f=2000:width_type=o:width=1,pan=mono|c0=0.5*c0+0.5*c1[b6];'
    '[s7]bandpass=f=4000:width_type=o:width=1,pan=mono|c0=0.5*c0+0.5*c1[b7];'
    '[s8]bandpass=f=8000:width_type=o:width=1,pan=mono|c0=0.5*c0+0.5*c1[b8];'
    '[s0][b1][b2][b3][b4][b5][b6][b7][b8]amerge=inputs=9,'
    'astats=metadata=1:measure_perchannel=RMS_level:measure_overall=none,'
    'pan=stereo|c0=c0|c1=c1';

/// Запись эквалайзера в том же экранированном виде, в каком её вернул mpv:
/// параметры `Nb=` тоже содержат запятые-разделители и точку.
const String _equalizer =
    '@mopseq:superequalizer=1b=%4%1.20:2b=%4%1.00:3b=%4%1.00';

/// Чужой фильтр media_kit — его владелец обязан сохранить на месте.
const String _tempo = 'scaletempo:scale=1.00000000';

void main() {
  test('граф lavfi с экранированными запятыми остаётся одним фильтром', () {
    final String chain = '$_tempo,$_equalizer,$_escapedGraph';
    final List<String> segments = MpvAudioChain.splitChain(chain);

    expect(segments, hasLength(3));
    expect(segments[0], _tempo);
    expect(segments[1], _equalizer);
    expect(segments[2], _escapedGraph);
    // Главное свойство: обратная сборка не меняет ни байта. Иначе следующая
    // пересборка `af` отправила бы mpv испорченный граф.
    expect(segments.join(','), chain);
  });

  test('метки эквалайзера и визуализатора видны в собранной цепочке', () {
    final String chain = '$_tempo,$_equalizer,$_escapedGraph';

    expect(MpvAudioChain.containsLabel(chain, 'mopseq'), isTrue);
    expect(MpvAudioChain.containsLabel(chain, 'mopsvis'), isTrue);
    expect(MpvAudioChain.containsLabel(chain, 'mopsgain'), isFalse);

    // Своё владелец отличает по префиксу, чужое (`scaletempo`) не трогает.
    final List<String> own = MpvAudioChain.splitChain(chain)
        .where(MpvAudioChain.isOwned)
        .toList();
    expect(own, hasLength(2));
    expect(own.every((String s) => s.startsWith('@mops')), isTrue);
  });

  test('запятые внутри параметров не режут обычные фильтры', () {
    // У `pan` и `volume` параметры без запятых, но с двоеточиями: их разбор
    // не должен зависеть от экранирования.
    final List<String> segments = MpvAudioChain.splitChain(
      '@mopsgain:volume=volume=-3.00dB,@mopsvis:astats=metadata=1',
    );
    expect(segments, <String>[
      '@mopsgain:volume=volume=-3.00dB',
      '@mopsvis:astats=metadata=1',
    ]);
  });
}
