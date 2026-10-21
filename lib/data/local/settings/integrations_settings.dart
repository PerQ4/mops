import '../../sources/sponsorblock.dart';

/// Разбирает сохранённый набор категорий SponsorBlock.
///
/// `null` — ключа в файле нет (настройки с прошлой версии): берём набор по
/// умолчанию. Пустая строка — пользователь снял все галочки: это осознанный
/// выбор «ничего не пропускать», и подменять его умолчанием нельзя.
List<SponsorBlockCategory> _parseSponsorCategories(String? raw) {
  if (raw == null) return kDefaultSponsorBlockCategories;
  final List<SponsorBlockCategory> parsed = <SponsorBlockCategory>[];
  for (final String name in raw.split(',')) {
    final SponsorBlockCategory? category = SponsorBlockCategory.fromApiName(
      name.trim(),
    );
    if (category != null && !parsed.contains(category)) parsed.add(category);
  }
  return parsed;
}

/// Внешние сервисы: вход в аккаунт, Discord, SponsorBlock и ключ Paxsenix.
class IntegrationsSettings {
  const IntegrationsSettings({
    this.oauthClientId = '',
    this.oauthClientSecret = '',
    this.musixmatchApiKey = '',
    this.discordRichPresence = false,
    this.discordApplicationId = '',
    // SponsorBlock выключен по умолчанию: это вмешательство в воспроизведение
    // (перемотка через куски видео), и включать его нужно осознанно.
    this.sponsorBlockEnabled = false,
    this.sponsorBlockCategories = kDefaultSponsorBlockCategories,
  });

  final String oauthClientId;
  final String oauthClientSecret;

  /// Ключ Paxsenix — через него подключается Musixmatch (как в ArchiveTune).
  final String musixmatchApiKey;

  /// Отправлять текущий трек в Discord (Rich Presence).
  final bool discordRichPresence;

  /// Application ID приложения Discord. Без него presence не отправляется.
  final String discordApplicationId;

  /// Пропускать вставки, размеченные на SponsorBlock.
  ///
  /// Это перемотка через чужие метки: она короче трека, но и «неожиданная»,
  /// поэтому по умолчанию выключена.
  final bool sponsorBlockEnabled;

  /// Какие категории вставок пропускать. Пустой список — ничего.
  final List<SponsorBlockCategory> sponsorBlockCategories;

  IntegrationsSettings copyWith({
    String? oauthClientId,
    String? oauthClientSecret,
    String? musixmatchApiKey,
    bool? discordRichPresence,
    String? discordApplicationId,
    bool? sponsorBlockEnabled,
    List<SponsorBlockCategory>? sponsorBlockCategories,
  }) {
    return IntegrationsSettings(
      oauthClientId: oauthClientId ?? this.oauthClientId,
      oauthClientSecret: oauthClientSecret ?? this.oauthClientSecret,
      musixmatchApiKey: musixmatchApiKey ?? this.musixmatchApiKey,
      discordRichPresence: discordRichPresence ?? this.discordRichPresence,
      discordApplicationId: discordApplicationId ?? this.discordApplicationId,
      sponsorBlockEnabled: sponsorBlockEnabled ?? this.sponsorBlockEnabled,
      sponsorBlockCategories:
          sponsorBlockCategories ?? this.sponsorBlockCategories,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'oauthClientId': oauthClientId,
    'oauthClientSecret': oauthClientSecret,
    'musixmatchApiKey': musixmatchApiKey,
    'discordRichPresence': discordRichPresence,
    'discordApplicationId': discordApplicationId,
    'sponsorBlockEnabled': sponsorBlockEnabled,
    'sponsorBlockCategories': sponsorBlockCategories
        .map((SponsorBlockCategory c) => c.apiName)
        .join(','),
  };

  factory IntegrationsSettings.fromJson(Map<String, dynamic> json) {
    return IntegrationsSettings(
      oauthClientId: json['oauthClientId'] as String? ?? '',
      oauthClientSecret: json['oauthClientSecret'] as String? ?? '',
      musixmatchApiKey: json['musixmatchApiKey'] as String? ?? '',
      discordRichPresence: json['discordRichPresence'] as bool? ?? false,
      discordApplicationId: json['discordApplicationId'] as String? ?? '',
      sponsorBlockEnabled: json['sponsorBlockEnabled'] as bool? ?? false,
      // Отсутствующий ключ (`null`) — настройки с прошлой версии, набор по
      // умолчанию; пустая строка — пользователь снял все категории.
      sponsorBlockCategories: _parseSponsorCategories(
        json['sponsorBlockCategories'] as String?,
      ),
    );
  }
}
