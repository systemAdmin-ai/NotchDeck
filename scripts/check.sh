#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="Build/${APP_NAME:-NotchDeck}.app"
BIN="$APP/Contents/MacOS/NotchDeck"
python3 scripts/check_bundle.py "$APP"
"$BIN" --test-profiles
"$BIN" --test-r39
"$BIN" --test-key-routing
"$BIN" --test-halo
"$BIN" --test-hud-lifecycle
codesign --verify --deep --strict "$APP"
