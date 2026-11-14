#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=Build/NotchDeck.app/Contents/MacOS/NotchDeck
"$BIN" --test-r39
"$BIN" --test-key-routing
"$BIN" --test-hud-lifecycle
codesign --verify --deep --strict Build/NotchDeck.app
