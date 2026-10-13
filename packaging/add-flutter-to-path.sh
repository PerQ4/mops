#!/usr/bin/env bash
# Добавляет Flutter и Dart в PATH для всех новых терминалов.
#
#   bash packaging/add-flutter-to-path.sh
#
# Скрипт дописывает одну строку в конфиг вашей оболочки. Ничего не
# перезаписывает: сначала проверяет, не добавлено ли уже.
set -euo pipefail

FLUTTER_HOME="${FLUTTER_HOME:-$HOME/flutter}"
LINE="export PATH=\"$FLUTTER_HOME/bin:\$PATH\""
FISH_LINE="fish_add_path $FLUTTER_HOME/bin"

if [ ! -x "$FLUTTER_HOME/bin/flutter" ]; then
  echo "Flutter не найден в $FLUTTER_HOME" >&2
  echo "Укажите путь: FLUTTER_HOME=/путь/к/flutter bash packaging/add-flutter-to-path.sh" >&2
  exit 1
fi

added=0

add_to_file() {
  local file="$1"
  local line="$2"
  [ -e "$file" ] || return 0
  if grep -qF "$FLUTTER_HOME/bin" "$file" 2>/dev/null; then
    echo "  уже есть в $file"
    return 0
  fi
  printf '\n# Flutter SDK (добавлено скриптом mOps)\n%s\n' "$line" >> "$file"
  echo "  добавлено в $file"
  added=1
}

# fish хранит настройки отдельно и своим синтаксисом.
add_to_file "$HOME/.config/fish/config.fish" "$FISH_LINE"
add_to_file "$HOME/.bashrc" "$LINE"
add_to_file "$HOME/.zshrc" "$LINE"

echo
if [ "$added" -eq 1 ]; then
  echo "Откройте новый терминал — команда flutter станет доступна."
else
  echo "Ничего менять не пришлось."
fi
echo "Проверить: flutter --version"
