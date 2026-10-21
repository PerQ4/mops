import '../../../core/audio/audio_equalizer.dart';
import 'json_read.dart';

/// Качество аудио. YouTube отдаёт свободным клиентам только part-качество
/// (до ~160 kbps Opus / 128 kbps AAC), поэтому «Максимум» — это лучший
/// доступный поток, а не 256 kbps.
enum AudioQuality {
  /// Минимум трафика: ~48–70 kbps.
  low('Экономия трафика', 70),

  /// Компромисс: ~128 kbps.
  medium('Среднее', 128),

  /// Лучший доступный поток (обычно ~160 kbps Opus).
  high('Максимум', 256);

  const AudioQuality(this.label, this.targetKbps);

  final String label;
  final int targetKbps;

  static AudioQuality fromName(String? name) => AudioQuality.values.firstWhere(
    (AudioQuality q) => q.name == name,
    orElse: () => AudioQuality.high,
  );
}

/// Откуда брать ссылку на поток.
///
/// YouTube выдаёт поток разным клиентам по-разному: одним он требует
/// PO-токен, другим — вход. Профили ниже проверены на живых запросах
/// и не требуют ни того, ни другого.
enum StreamSource {
  /// Сначала visionOS, затем Android VR и iOS.
  auto('Автоматически', 'Сначала visionOS, затем Android VR и iOS'),

  /// Клиент очков Apple Vision Pro — отдаёт поток целиком.
  visionOs('visionOS', 'Отдаёт поток целиком — самый надёжный'),

  /// Клиент очков Oculus.
  androidVr('Android VR', 'Клиент очков — самый устойчивый'),

  /// Клиент iPhone.
  ios('iOS', 'Клиент iPhone — запасной вариант'),

  /// Клиент библиотеки по умолчанию.
  library('Клиент библиотеки', 'YouTube всё чаще требует для него PO-токен');

  const StreamSource(this.label, this.description);

  final String label;
  final String description;

  static StreamSource fromName(String? name) => StreamSource.values.firstWhere(
    (StreamSource c) => c.name == name,
    orElse: () => StreamSource.auto,
  );
}

/// Разбирает сохранённые полосы эквалайзера.
///
/// Набор неверной длины или с мусором откатывается к плоскому: применить
/// «половину» настроек хуже, чем вернуть эквалайзер к нулю.
List<double> _parseEqualizerBands(List<String>? parts) {
  if (parts == null || parts.isEmpty) return kEqualizerFlatBands;
  if (parts.length != kEqualizerBandCount) return kEqualizerFlatBands;
  final List<double> bands = <double>[];
  for (final String part in parts) {
    final double? value = double.tryParse(part);
    if (value == null) return kEqualizerFlatBands;
    bands.add(value.clamp(-kEqualizerMaxGainDb, kEqualizerMaxGainDb));
  }
  return bands;
}

/// Воспроизведение: качество и источник потока, очередь, эквалайзер и
/// обработка звука.
class PlaybackSettings {
  const PlaybackSettings({
    this.audioQuality = AudioQuality.high,
    this.streamClient = StreamSource.auto,
    this.autoPlayNext = true,
    this.restoreQueue = true,
    // Предзагрузка следующего трека стоит копейки (один запрос за ссылкой),
    // а переключение начинает звучать заметно раньше, поэтому включена.
    this.preloadNextTrack = true,
    this.lastVolume = 1.0,
    this.lastSpeed = 1.0,
    // Эквалайзер выключен и «плоский»: частоты не тронуты, а цепочка фильтров
    // не строится. Пресет хранится отдельно от полос, чтобы интерфейс мог
    // показать, какой набор выбран, даже когда пользователь подправил полосы.
    this.equalizerEnabled = false,
    this.equalizerBands = kEqualizerFlatBands,
    this.equalizerPresetId = 'flat',
    // Оба «улучшателя» по умолчанию выключены: это вмешательство в звук, а не
    // настройка по умолчанию.
    this.skipSilence = false,
    this.audioNormalization = false,
    this.pauseOnDeviceMute = true,
  });

  final AudioQuality audioQuality;

  /// Клиент YouTube, у которого запрашивается ссылка на поток.
  final StreamSource streamClient;

  final bool autoPlayNext;

  /// Восстанавливать очередь и позицию прошлой сессии при запуске.
  ///
  /// По умолчанию включено: вернуться к тому, что играло, — ожидаемое
  /// поведение. Восстановление идёт без автозапуска: очередь на месте, но звук
  /// пойдёт только после нажатия «играть».
  final bool restoreQueue;

  /// Предзагружать следующий трек: получить ссылку заранее, чтобы
  /// переключение не ждало сетевого запроса (задача 2.4).
  ///
  /// Скачанный трек и треки на диске не предзагружаются: у них нет сети,
  /// которую можно сэкономить. При перемешивании следующий трек неизвестен,
  /// и предзагрузка тоже не запускается.
  final bool preloadNextTrack;

  final double lastVolume;
  final double lastSpeed;

  /// Включён ли эквалайзер. Отдельный флаг: «плоский, но включённый» — это
  /// рабочее состояние (пользователь двигает полосы от нуля), и выключать
  /// эквалайзер только потому, что все полосы пока в нуле, нельзя.
  final bool equalizerEnabled;

  /// Усиления полос эквалайзера в дБ (ровно [kEqualizerBandCount] значений).
  final List<double> equalizerBands;

  /// Имя выбранного пресета — только для интерфейса.
  final String equalizerPresetId;

  /// Убирать паузы из потока при воспроизведении.
  final bool skipSilence;

  /// Выравнивать громкость между тихими и громкими местами.
  final bool audioNormalization;

  /// Ставить воспроизведение на паузу, когда пропадает устройство вывода,
  /// в которое шёл звук (выдернули наушники, отвалился Bluetooth).
  ///
  /// По умолчанию включено: играть «в тишину» — худший из вариантов.
  final bool pauseOnDeviceMute;

  PlaybackSettings copyWith({
    AudioQuality? audioQuality,
    StreamSource? streamClient,
    bool? autoPlayNext,
    bool? restoreQueue,
    bool? preloadNextTrack,
    double? lastVolume,
    double? lastSpeed,
    bool? equalizerEnabled,
    List<double>? equalizerBands,
    String? equalizerPresetId,
    bool? skipSilence,
    bool? audioNormalization,
    bool? pauseOnDeviceMute,
  }) {
    return PlaybackSettings(
      audioQuality: audioQuality ?? this.audioQuality,
      streamClient: streamClient ?? this.streamClient,
      autoPlayNext: autoPlayNext ?? this.autoPlayNext,
      restoreQueue: restoreQueue ?? this.restoreQueue,
      preloadNextTrack: preloadNextTrack ?? this.preloadNextTrack,
      lastVolume: lastVolume ?? this.lastVolume,
      lastSpeed: lastSpeed ?? this.lastSpeed,
      equalizerEnabled: equalizerEnabled ?? this.equalizerEnabled,
      equalizerBands: equalizerBands ?? this.equalizerBands,
      equalizerPresetId: equalizerPresetId ?? this.equalizerPresetId,
      skipSilence: skipSilence ?? this.skipSilence,
      audioNormalization: audioNormalization ?? this.audioNormalization,
      pauseOnDeviceMute: pauseOnDeviceMute ?? this.pauseOnDeviceMute,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'audioQuality': audioQuality.name,
    'streamClient': streamClient.name,
    'autoPlayNext': autoPlayNext,
    'restoreQueue': restoreQueue,
    'preloadNextTrack': preloadNextTrack,
    'lastVolume': lastVolume,
    'lastSpeed': lastSpeed,
    'equalizerEnabled': equalizerEnabled,
    'equalizerBands': equalizerBands.join(','),
    'equalizerPresetId': equalizerPresetId,
    'skipSilence': skipSilence,
    'audioNormalization': audioNormalization,
    'pauseOnDeviceMute': pauseOnDeviceMute,
  };

  factory PlaybackSettings.fromJson(Map<String, dynamic> json) {
    return PlaybackSettings(
      audioQuality: readEnumByName(
        json['audioQuality'],
        AudioQuality.values,
        AudioQuality.high,
      ),
      streamClient: readEnumByName(
        json['streamClient'],
        StreamSource.values,
        StreamSource.auto,
      ),
      autoPlayNext: readBool(json['autoPlayNext'], true),
      restoreQueue: readBool(json['restoreQueue'], true),
      preloadNextTrack: readBool(json['preloadNextTrack'], true),
      lastVolume: readDouble(json['lastVolume'], 1.0),
      lastSpeed: readDouble(json['lastSpeed'], 1.0),
      equalizerEnabled: readBool(json['equalizerEnabled'], false),
      equalizerBands: _parseEqualizerBands(
        readStringList(json['equalizerBands']),
      ),
      equalizerPresetId: readString(json['equalizerPresetId'], 'flat'),
      skipSilence: readBool(json['skipSilence'], false),
      audioNormalization: readBool(json['audioNormalization'], false),
      pauseOnDeviceMute: readBool(json['pauseOnDeviceMute'], true),
    );
  }
}
