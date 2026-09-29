#!/bin/bash
# Builds the Release configuration and installs the .app so it can be launched
# like any other Mac app, without Xcode.
#
#   ./Scripts/install-mac.sh              → ~/Desktop
#   ./Scripts/install-mac.sh /Applications → Launchpad and Spotlight too
#
# The app keeps its bundle identifier, so saved games and imported photos carry
# over between the Xcode build and this copy.

set -euo pipefail

DESTINATION="${1:-$HOME/Desktop}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# Release is signed with the team's certificate for the App Store. This copy is
# only for this Mac, so sign it ad hoc: no Apple account, nothing that expires.
# An ad-hoc signature cannot carry iCloud or Game Center — macOS refuses to
# launch an app that claims them without a profile — so this copy takes the
# plain sandbox entitlements and simply plays without sync.
echo "Building Release…"
xcodebuild -project JigsawPuzzle.xcodeproj -scheme JigsawPuzzle \
    -destination 'platform=macOS,arch=arm64' -configuration Release build \
    CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS=Config/JigsawPuzzle.entitlements -quiet

PRODUCTS_DIR="$(xcodebuild -project JigsawPuzzle.xcodeproj -scheme JigsawPuzzle \
    -destination 'platform=macOS,arch=arm64' -configuration Release \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')"

APP_NAME="$(xcodebuild -project JigsawPuzzle.xcodeproj -scheme JigsawPuzzle \
    -destination 'platform=macOS,arch=arm64' -configuration Release \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ FULL_PRODUCT_NAME/{print $2; exit}')"

SOURCE="$PRODUCTS_DIR/$APP_NAME"
TARGET="$DESTINATION/$APP_NAME"

[ -d "$SOURCE" ] || { echo "Build product not found at $SOURCE" >&2; exit 1; }

# Replacing a running bundle leaves the app in a broken state, so close it first.
if pgrep -f "$DESTINATION/$APP_NAME" >/dev/null 2>&1; then
    echo "Quitting the running copy…"
    pkill -f "$DESTINATION/$APP_NAME" || true
    sleep 1
fi

rm -rf "$TARGET"
cp -R "$SOURCE" "$TARGET"

echo "Installed: $TARGET"
echo "Size: $(du -sh "$TARGET" | cut -f1)"
