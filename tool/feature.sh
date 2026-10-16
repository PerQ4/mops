#!/usr/bin/env bash
#
# Управление фичами: отдельная ветка и отдельная ПАПКА на каждую.
#
# Зачем. Агенты правят код параллельно, и в одной папке они мешают друг другу:
# нельзя ни собрать, ни влить одну фичу, не задев другую, а сборка ломается,
# пока кто-то на середине правки. Рабочее дерево git (`git worktree`) даёт
# каждой фиче свою папку при общем репозитории.
#
#   tool/feature.sh start home-redesign   создать ветку и папку рядом
#   tool/feature.sh list                  что сейчас в работе
#   tool/feature.sh merge home-redesign   влить в dev с проверкой
#   tool/feature.sh drop home-redesign    убрать папку и ветку
#   tool/feature.sh build 0.2.0-home.1    тег-предрелиз: конвейер соберёт
#                                         все три платформы и сделает prerelease
#   tool/feature.sh clean-tags            удалить старые предрелизы
#
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${MOPS_BASE_BRANCH:-dev}"
FLUTTER="${FLUTTER_BIN:-flutter}"

die() { echo "ошибка: $*" >&2; exit 1; }

# Папка фичи — рядом с проектом, с суффиксом имени: mOps-home-redesign.
feature_dir() { echo "$(dirname "$PROJECT")/$(basename "$PROJECT")-$1"; }
feature_branch() { echo "feat/$1"; }

cmd_start() {
  local name="${1:-}"
  [ -n "$name" ] || die "укажите имя фичи: tool/feature.sh start home-redesign"
  local dir; dir="$(feature_dir "$name")"
  local branch; branch="$(feature_branch "$name")"
  [ -e "$dir" ] && die "папка уже есть: $dir"

  git -C "$PROJECT" fetch origin "$BASE"
  git -C "$PROJECT" worktree add -b "$branch" "$dir" "origin/$BASE"
  echo "готово: $dir (ветка $branch от origin/$BASE)"
  echo "flutter pub get там нужен один раз: cd \"$dir\" && $FLUTTER pub get --offline"
}

cmd_list() {
  git -C "$PROJECT" worktree list
  echo
  echo "ветки фич:"
  git -C "$PROJECT" branch --list 'feat/*' | sed 's/^/  /' || true
}

cmd_merge() {
  local name="${1:-}"
  [ -n "$name" ] || die "укажите имя фичи"
  local branch; branch="$(feature_branch "$name")"
  git -C "$PROJECT" rev-parse --verify "$branch" >/dev/null 2>&1 ||
    die "нет ветки $branch"

  cd "$PROJECT"
  git checkout "$BASE"
  git pull --ff-only origin "$BASE" || true
  # --no-ff: в истории видно, что это была отдельная фича, и её легко откатить.
  git merge --no-ff "$branch" -m "Влить $branch"

  echo "== проверка =="
  $FLUTTER analyze --no-pub
  $FLUTTER test --no-pub
  echo "готово. Залейте: git push origin $BASE"
}

cmd_drop() {
  local name="${1:-}"
  [ -n "$name" ] || die "укажите имя фичи"
  local dir; dir="$(feature_dir "$name")"
  local branch; branch="$(feature_branch "$name")"
  git -C "$PROJECT" worktree remove --force "$dir" 2>/dev/null || true
  git -C "$PROJECT" branch -D "$branch" 2>/dev/null || true
  echo "убрано: $dir и ветка $branch"
}

# Тег вида v0.2.0-home.1: конвейер запускается на любой тег `v*`, собирает все
# три платформы и публикует предрелиз. Так каждую фичу можно поставить и
# проверить, не выдавая её за релиз.
cmd_build() {
  local version="${1:-}"
  [ -n "$version" ] || die "укажите версию: tool/feature.sh build 0.2.0-home.1"
  cd "$PROJECT"
  git tag -a "v$version" -m "Предрелиз $version"
  git push origin "v$version"
  echo "тег v$version отправлен — сборка пойдёт сама (Actions → Сборки)"
}

# Предрелизы копятся быстро: на каждую фичу по тегу. Чистим те, что старше
# последних десяти, — они уже проверены и влиты.
cmd_clean_tags() {
  cd "$PROJECT"
  local keep=10
  local prereleases
  prereleases="$(git tag --list 'v*-*' --sort=-creatordate)"
  local count; count="$(echo "$prereleases" | grep -c . || true)"
  if [ "$count" -le "$keep" ]; then
    echo "предрелизов $count — чистить нечего"
    return
  fi
  echo "$prereleases" | tail -n "+$((keep + 1))" | while read -r tag; do
    [ -n "$tag" ] || continue
    git push origin ":refs/tags/$tag" || true
    git tag -d "$tag" || true
    echo "удалён $tag"
  done
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  list) cmd_list ;;
  merge) shift; cmd_merge "$@" ;;
  drop) shift; cmd_drop "$@" ;;
  build) shift; cmd_build "$@" ;;
  clean-tags) cmd_clean_tags ;;
  *)
    sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
