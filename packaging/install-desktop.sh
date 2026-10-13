#!/usr/bin/env bash
# Устанавливает ярлык mOps в меню приложений (GNOME, KDE и прочие).
#
# Запуск: bash packaging/install-desktop.sh
#
# Что делает:
#   1. собирает релизную версию, если её ещё нет;
#   2. кладёт иконку в нужные размеры;
#   3. создаёт .desktop-файл, указывающий на собранный бинарник;
#   4. обновляет базу ярлыков, если есть чем.
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-$HOME/flutter/bin/flutter}"
BINARY="$PROJECT/build/linux/x64/release/bundle/mops"

APP_ID="mops"
APP_NAME="mOps"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

echo "== 1/4 Сборка =="
if [ -x "$BINARY" ]; then
  echo "  уже собрано: $BINARY"
else
  if [ ! -x "$FLUTTER_BIN" ]; then
    echo "  Flutter не найден: $FLUTTER_BIN" >&2
    echo "  Укажите путь: FLUTTER_BIN=/путь/к/flutter bash packaging/install-desktop.sh" >&2
    exit 1
  fi
  echo "  собираю (это может занять минуту)…"
  (cd "$PROJECT" && # --no-tree-shake-icons: иконки лежат в enum и кортежах, и штатное
  # «вырезание» неиспользуемых иконок удаляет их из шрифта — в запущенном
  # приложении они показывались бы пустыми квадратами.
  "$FLUTTER_BIN" build linux --release --no-tree-shake-icons)
fi

echo
echo "== 2/4 Иконка =="
SOURCE_ICON="$PROJECT/packaging/mops.png"
if [ ! -f "$SOURCE_ICON" ]; then
  echo "  нет файла $SOURCE_ICON" >&2
  exit 1
fi

for size in 128 256 512; do
  target_dir="$DATA_HOME/icons/hicolor/${size}x${size}/apps"
  mkdir -p "$target_dir"

  if command -v magick >/dev/null 2>&1; then
    magick "$SOURCE_ICON" -resize "${size}x${size}" "$target_dir/$APP_ID.png"
  else
    # Без ImageMagick кладём один размер — GNOME его отмасштабирует сам.
    cp "$SOURCE_ICON" "$target_dir/$APP_ID.png"
  fi
  echo "  $target_dir/$APP_ID.png"
done

echo
echo "== 3/4 Ярлык =="
APPS_DIR="$DATA_HOME/applications"
mkdir -p "$APPS_DIR"
DESKTOP_FILE="$APPS_DIR/$APP_ID.desktop"

cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=$APP_NAME
GenericName=Плеер YouTube Music
Comment=Кросс-платформенный плеер YouTube Music с Material 3 Expressive
Exec=$BINARY
Icon=$APP_ID
Terminal=false
Categories=AudioVideo;Player;
Keywords=music;youtube;музыка;плеер;ytmusic;
StartupNotify=true
StartupWMClass=com.mops.mops
EOF

chmod +x "$DESKTOP_FILE"
echo "  $DESKTOP_FILE"

echo
echo "== 4/4 Обновление базы ярлыков =="
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APPS_DIR" 2>/dev/null || true
  echo "  база обновлена"
else
  echo "  update-desktop-database нет — обычно и не нужен"
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$DATA_HOME/icons/hicolor" 2>/dev/null || true
fi

echo
echo "Готово. Приложение «$APP_NAME» появилось в меню приложений."
echo "Если его не видно сразу — поищите по имени в обзоре приложений."
echo
echo "Запуск из терминала: $BINARY"
