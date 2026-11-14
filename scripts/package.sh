#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=0.1.0
APP=Build/NotchDeck.app
DIST=Dist
STAGE=Build/DMG
[ -d "$APP" ] || ./build.sh
./scripts/check.sh
mkdir -p "$DIST" "$STAGE"
# Package the app bundle only. UserDefaults, home directories and logs are never copied.
rm -rf "$STAGE/NotchDeck.app"
ditto "$APP" "$STAGE/NotchDeck.app"
ln -sfn /Applications "$STAGE/Applications"
cp docs/GETTING_STARTED.md "$STAGE/Начало работы.txt"
cp LICENSE "$STAGE/LICENSE.txt"
hdiutil create -volname "NotchDeck $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/NotchDeck-$VERSION-AppleSilicon.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/NotchDeck-$VERSION-AppleSilicon.zip"
(cd "$DIST" && shasum -a 256 *.dmg *.zip > SHA256SUMS.txt)
echo "Packages: $DIST"
