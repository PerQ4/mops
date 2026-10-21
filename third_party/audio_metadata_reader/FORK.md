# Форк `audio_metadata_reader` 1.8.1

Взят из [ClementBeal/audio_metadata_reader](https://github.com/ClementBeal/audio_metadata_reader),
лицензия MIT — см. `LICENSE` рядом.

**Зачем форк.** Пакет ронял чтение файла целиком в трёх местах, которые нам
важны: у старых русских rip'ов теги в cp1251, а у самодельных — грязные поля.

1. `id3v1.dart` декодировал текст строгим `utf8.decode` → cp1251 бросал
   `FormatException`, и файл терял и теги, и длительность.
2. `vorbis_comment.dart` читал числа через `int.parse` → значение вида `12/12`
   в `TRACKTOTAL` роняло FLAC/OGG целиком.
3. `id3v2.dart` и `vorbis_comment.dart` декодировали UTF-8 строго → один битый
   байт ронял весь файл.

**Что изменено.** Один новый файл — `lib/src/utils/tag_text.dart`:
`decodeTagText` (UTF-8 → cp1251 → latin1 с заменой невалидных байт) и
`parseTagInt` (первое число из строки). Этим заменены вызовы в `id3v1.dart`,
`id3v2.dart`, `vorbis_comment.dart` и `mp4.dart`. Больше ничего не менялось.

**При обновлении пакета** эти правки нужно перенести заново: сначала проверить,
не починили ли их наверху, иначе заменить файл и вызовы по списку выше.
