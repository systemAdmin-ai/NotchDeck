#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="Build/${APP_NAME:-NotchDeck}.app"
DIST=Dist
STAGE=Build/DMG
[ -d "$APP" ] || ./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
./scripts/check.sh
mkdir -p "$DIST" "$STAGE"
# Package the app bundle only. UserDefaults, home directories and logs are never copied.
rm -rf "$STAGE/NotchDeck.app"
ditto "$APP" "$STAGE/NotchDeck.app"
ln -sfn /Applications "$STAGE/Applications"
cp docs/GETTING_STARTED.md "$STAGE/Getting Started.txt"
cp docs/GETTING_STARTED.ru.md "$STAGE/Начало работы.txt"
cp LICENSE "$STAGE/LICENSE.txt"
hdiutil create -volname "NotchDeck $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/NotchDeck-$VERSION-AppleSilicon.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/NotchDeck-$VERSION-AppleSilicon.zip"
cp "$DIST/NotchDeck-$VERSION-AppleSilicon.dmg" "$DIST/NotchDeck.dmg"
cp "$DIST/NotchDeck-$VERSION-AppleSilicon.zip" "$DIST/NotchDeck.zip"
(cd "$DIST" && shasum -a 256 "NotchDeck-$VERSION-AppleSilicon.dmg" "NotchDeck-$VERSION-AppleSilicon.zip" NotchDeck.dmg NotchDeck.zip > SHA256SUMS.txt)
echo "Packages: $DIST"
