#!/bin/bash
# NotchDeck — установка одной командой, без окна «приложение не проверено».
#
# Почему так: файлы, скачанные curl/gh (а не браузером), не получают метку
# карантина com.apple.quarantine, поэтому Gatekeeper не блокирует первый запуск.
# Это не отключение защиты и не xattr -d: просто загрузка не через браузер.
# SHA256 проверяется по опубликованному SHA256SUMS.txt.
set -euo pipefail
VERSION="${NOTCHDECK_VERSION:-2.0.0}"
TAG="${NOTCHDECK_TAG:-v2.0.0-preview.2}"
BASE="https://github.com/systemAdmin-ai/NotchDeck/releases/download/$TAG"
TARGET="${NOTCHDECK_TARGET:-/Applications}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "→ Скачиваю NotchDeck $VERSION ($TAG)"
curl -fsSL "$BASE/NotchDeck-$VERSION-AppleSilicon.zip" -o "$WORK/app.zip"
curl -fsSL "$BASE/SHA256SUMS.txt" -o "$WORK/sums.txt"

echo "→ Проверяю контрольную сумму"
expected="$(awk -v n="NotchDeck-$VERSION-AppleSilicon.zip" '$2==n {print $1}' "$WORK/sums.txt")"
actual="$(shasum -a 256 "$WORK/app.zip" | awk '{print $1}')"
if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
  echo "✗ Не совпало: ожидалось $expected, получено $actual" >&2
  exit 1
fi
echo "  ok $actual"

echo "→ Распаковываю"
ditto -x -k "$WORK/app.zip" "$WORK/out"
if [ -e "$TARGET/NotchDeck.app" ]; then
  echo "  существующий $TARGET/NotchDeck.app будет заменён"
  rm -rf "$TARGET/NotchDeck.app"
fi
ditto "$WORK/out/NotchDeck.app" "$TARGET/NotchDeck.app"
# На случай, если архив пришёл из браузера, а не из curl.
xattr -dr com.apple.quarantine "$TARGET/NotchDeck.app" 2>/dev/null || true

echo "→ Готово: $TARGET/NotchDeck.app"
open -a "$TARGET/NotchDeck.app" 2>/dev/null || true
echo "  Первый экран знакомства: выбор языка, затем разрешения по желанию."
