#!/usr/bin/env bash
# Builds a launchable, ad-hoc-signed Release CCUsageMonitor.app into ./build.
#
# Ad-hoc signing (codesign -s -) needs no Apple Developer account, which suits a single-user,
# this-Mac app. Gatekeeper still quarantines a copied or downloaded build; install.md covers that.
set -euo pipefail

cd "$(dirname "$0")/.."

DERIVED="build/derived"
APP_OUT="build/CCUsageMonitor.app"

echo "Generating the Xcode project..."
xcodegen generate

echo "Building Release..."
xcodebuild -project CCUsageMonitor.xcodeproj \
    -scheme CCUsageMonitor \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    build CODE_SIGNING_ALLOWED=NO

BUILT="$DERIVED/Build/Products/Release/CCUsageMonitor.app"

echo "Copying to $APP_OUT and ad-hoc signing..."
rm -rf "$APP_OUT"
cp -R "$BUILT" "$APP_OUT"
codesign --force --sign - "$APP_OUT"
xattr -cr "$APP_OUT"   # clear any quarantine attributes so the first launch is not blocked

echo "Done: $APP_OUT"
echo "Launch with: open '$APP_OUT'"
