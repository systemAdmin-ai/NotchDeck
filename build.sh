#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/Build/ModuleCache}"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"

APP="Build/${APP_NAME:-NotchDeck}.app"
BIN="$APP/Contents/MacOS/NotchDeck"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NotchDeck</string>
  <key>CFBundleDisplayName</key><string>NotchDeck</string>
  <key>CFBundleExecutable</key><string>NotchDeck</string>
  <key>CFBundleIdentifier</key><string>com.notchdeck.app</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0.0</string>
  <key>CFBundleVersion</key><string>200</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>NotchDeck показывает, что играет, и переключает треки.</string>
  <key>NSMicrophoneUsageDescription</key><string>Микрофон включается только кнопкой микрофона для записи экрана с вашим голосом.</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

# An isolated bundle identity lets the local Preview run with its own preferences.
if [ -n "${BUNDLE_ID:-}" ]; then
  [[ "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || exit 2
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
fi
if [ -n "${APP_NAME:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP/Contents/Info.plist"
fi

swiftc -target arm64-apple-macos26.0 -swift-version 5 -O -o "$BIN" \
  Sources/Metrics.swift Sources/SystemControl.swift Sources/Store.swift \
  Sources/NowPlaying.swift Sources/Tools.swift Sources/Procs.swift Sources/Keys.swift \
  Sources/ToolPanels.swift Sources/ProcPanel.swift \
  Sources/Profiles.swift Sources/ProfileChecks.swift Sources/Onboarding.swift Sources/ScreenRecording.swift Sources/PowerEvents.swift Sources/Connections.swift Sources/Notes.swift Sources/Checks.swift Sources/Preferences.swift Sources/SystemMedia.swift Sources/HUDMotion.swift Sources/NotchHUD.swift Sources/Cleanup.swift Sources/Views.swift Sources/Panel.swift Sources/main.swift \
  -framework AppKit -framework CoreAudio -framework IOKit \
  -framework AVFoundation -framework SystemConfiguration -framework ImageIO -framework ServiceManagement -framework CoreGraphics 2>&1 | tail -40

# System-wide media metadata helper, BSD-3-Clause.
MRA_SRC="Vendor/mediaremote-adapter"
FW="$APP/Contents/Resources/mediaremote/MediaRemoteAdapter.framework"
mkdir -p "$FW/Versions/A/Resources"
clang -arch arm64 -mmacosx-version-min=26.0 -dynamiclib -O2 -fobjc-arc -fvisibility=default \
  -I"$MRA_SRC/include" -I"$MRA_SRC/src" \
  "$MRA_SRC"/src/adapter/*.m "$MRA_SRC/src/private/MediaRemote.m" "$MRA_SRC"/src/utility/*.m \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
  -o "$FW/Versions/A/MediaRemoteAdapter" 2> Build/media-warnings.log
ln -sfn A "$FW/Versions/Current"
ln -sfn Versions/Current/MediaRemoteAdapter "$FW/MediaRemoteAdapter"
ln -sfn Versions/Current/Resources "$FW/Resources"
cat > "$FW/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
<key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>45</string>
</dict></plist>
PLIST
cp "$MRA_SRC/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/mediaremote/"
cp "$MRA_SRC/LICENSE" "$APP/Contents/Resources/mediaremote/LICENSE-mediaremote-adapter.txt"
codesign --force --sign - --timestamp=none "$FW"

cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "${SIGN_IDENTITY:--}" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
echo "BUILD OK: $BIN"
ls -lh "$BIN" | awk '{print "binary size: "$5}'
