# Полная сборка libmpv для Windows.
#
# Пакет media_kit_libs_windows_audio скачивает архив libmpv сам, но в нём
# урезанный FFmpeg — только overlay и equalizer. Без astats визуализатор
# уровня мёртв, а af-metadata по отсутствующей метке роняет libmpv. Скрипт
# переписывает ссылку в CMakeLists пакета на полную сборку, чтобы локальная
# сборка и конвейер брали один и тот же файл с одной и той же суммой.
#
# Запускать после flutter pub get и до flutter build windows.
# Повторный запуск ничего не портит: ссылка просто ставится на место.

$ErrorActionPreference = 'Stop'

# Версия, размер и сумма архива. Меняются вместе: CMake сверяет MD5 и
# перекачивает файл, если он не совпал.
$LibMpv = 'mpv-dev-x86_64-20261018-git-01e2533f31.7z'
$LibMpvUrl = "https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20261018/$LibMpv"
$LibMpvMd5 = '5ca2e48b297f05367eb355ab1e068284'

$roots = @($env:PUB_CACHE, "$env:LOCALAPPDATA\Pub\Cache", "$env:USERPROFILE\AppData\Local\Pub\Cache") |
    Where-Object { $_ } | Select-Object -Unique

$found = @()
foreach ($root in $roots) {
    $found += Get-ChildItem -Path "$root\hosted\pub.dev\media_kit_libs_windows_audio-*\windows\CMakeLists.txt" -ErrorAction SilentlyContinue
}

if ($found.Count -eq 0) {
    throw 'Не найден CMakeLists.txt пакета media_kit_libs_windows_audio. Сначала выполните flutter pub get.'
}

foreach ($file in $found) {
    $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
    $text = $text -replace 'set\(LIBMPV "[^"]+"\)', "set(LIBMPV `"$LibMpv`")"
    $text = $text -replace 'set\(LIBMPV_URL "[^"]+"\)', "set(LIBMPV_URL `"$LibMpvUrl`")"
    $text = $text -replace 'set\(LIBMPV_MD5 "[^"]+"\)', "set(LIBMPV_MD5 `"$LibMpvMd5`")"

    # Если формат CMakeLists в пакете изменится, подмена не сработает молча —
    # тогда лучше упасть здесь, чем собрать сборку без визуализатора.
    if ($text -notmatch 'shinchiro/mpv-winbuild-cmake') {
        throw "Не удалось подменить ссылку в $($file.FullName): изменился формат CMakeLists пакета."
    }

    # Без BOM: CMake читает CMakeLists как ASCII, и BOM ломает первую строку.
    [System.IO.File]::WriteAllText($file.FullName, $text, (New-Object System.Text.UTF8Encoding($false)))

    Write-Host "libmpv (полная сборка): $($file.FullName)"
    Select-String -Path $file.FullName -Pattern 'set\(LIBMPV' | ForEach-Object { "  $($_.Line.Trim())" }
}
