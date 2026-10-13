#!/usr/bin/env bash
# Запуск приложения во время разработки.
#
#   bash run.sh          — обычный запуск с горячей перезагрузкой
#   bash run.sh release  — запуск собранной релизной версии
#
# Flutter лежит вне PATH, поэтому скрипт сам его подставляет.
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-$HOME/flutter/bin/flutter}"
BINARY="$PROJECT/build/linux/x64/release/bundle/mops"

if [ "${1:-}" = "release" ]; then
  if [ ! -x "$BINARY" ]; then
    echo "Релиза ещё нет — собираю…"
    (cd "$PROJECT" && "$FLUTTER_BIN" build linux --release)
  fi
  exec "$BINARY"
fi

if [ ! -x "$FLUTTER_BIN" ]; then
  echo "Flutter не найден: $FLUTTER_BIN" >&2
  echo "Укажите путь: FLUTTER_BIN=/путь/к/flutter bash run.sh" >&2
  exit 1
fi

cd "$PROJECT"
exec "$FLUTTER_BIN" run -d linux
