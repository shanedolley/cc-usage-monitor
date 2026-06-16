#!/usr/bin/env bash
# Builds a Release CCUsageMonitor.app, signs it with a stable identity, installs it to
# /Applications, and launches it.
#
# Why a named identity, not ad-hoc: macOS ties a Keychain "Always Allow" grant to the app's
# code signature. An ad-hoc signature has no stable identity, so the grant is invalidated on
# every rebuild and the app re-prompts for access to the Claude Code credential each time.
# Signing with one self-signed certificate gives a stable identity, so the read and write
# grants persist across launches and rebuilds. install.md covers the one-time cert setup.
#
# Override the identity with: SIGN_IDENTITY="My Cert Name" ./scripts/build-release.sh
set -euo pipefail

cd "$(dirname "$0")/.."

DERIVED="build/derived"
SIGN_IDENTITY="${SIGN_IDENTITY:-CC Usage Monitor Dev}"
APP_DEST="${APP_DEST:-/Applications/CCUsageMonitor.app}"

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

# Pick the signing identity: the named self-signed cert if it exists, else ad-hoc with a warning.
if security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY"; then
    SIGN_ARG="$SIGN_IDENTITY"
    echo "Signing with identity: $SIGN_IDENTITY"
else
    SIGN_ARG="-"
    echo "WARNING: code-signing identity '$SIGN_IDENTITY' not found; falling back to ad-hoc."
    echo "         The app will re-prompt for Keychain access on every rebuild."
    echo "         Create the cert once (Keychain Access > Certificate Assistant > Create a"
    echo "         Certificate, type: Code Signing) and name it '$SIGN_IDENTITY'. See install.md."
fi

# Quit any running copy so the bundle at the destination can be replaced.
osascript -e 'quit app "CCUsageMonitor"' 2>/dev/null || true

echo "Installing to $APP_DEST..."
DEST_DIR="$(dirname "$APP_DEST")"
if [ ! -w "$DEST_DIR" ]; then
    echo "ERROR: $DEST_DIR is not writable. Re-run with a writable APP_DEST, e.g.:"
    echo "       APP_DEST=\"\$HOME/Applications/CCUsageMonitor.app\" ./scripts/build-release.sh"
    exit 1
fi
rm -rf "$APP_DEST"
cp -R "$BUILT" "$APP_DEST"

echo "Signing..."
codesign --force --sign "$SIGN_ARG" "$APP_DEST"
xattr -cr "$APP_DEST"   # clear any quarantine attributes so the first launch is not blocked

echo "Launching..."
open "$APP_DEST"

echo "Done: $APP_DEST"
