#!/bin/bash
# Builds the Release app and build/EasyReader-<version>.dmg (used by .github/workflows/build.yml).
# Usage: scripts/build-release.sh [version]   (default: git describe of the last v* tag)
# Signing comes from Config/Signing.xcconfig (+ SigningIdentity.xcconfig, which CI writes too).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --always --dirty)}"
ARCHIVE=build/EasyReader.xcarchive
STAGING=build/dmg
DMG="build/EasyReader-$VERSION.dmg"
APP="$STAGING/EasyReader.app"

pretty() { if command -v xcbeautify > /dev/null; then xcbeautify; else cat; fi; }

rm -rf "$ARCHIVE" "$STAGING" "$DMG"
xcodebuild archive -project EasyReader.xcodeproj -scheme EasyReader -configuration Release -archivePath "$ARCHIVE" \
    ONLY_ACTIVE_ARCH=NO | pretty

# "mac-application" = Organizer's "Copy App" (keeps our signature; "developer-id" would need an Apple account)
plutil -convert xml1 -o build/ExportOptions.plist - <<< '{"method": "mac-application"}'
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$STAGING" -exportOptionsPlist build/ExportOptions.plist | pretty
cp LICENSE README.md "$STAGING"
[[ ! -f CHANGELOG.md ]] || cp CHANGELOG.md "$STAGING"
hdiutil create -quiet -srcdir "$STAGING" -volname EasyReader "$DMG"

codesign --verify --strict "$APP"
codesign -dr - "$APP" 2>&1 | grep designated
echo "Built $DMG"
