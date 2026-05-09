#!/usr/bin/env bash
# Build SuperNovaPad as a Mac Catalyst app and package it as a .pkg + .dmg
# installer. Run this on macOS with Xcode 15+ installed.
#
# Usage:
#   ./scripts/build-macos.sh                # unsigned local build
#   DEV_TEAM=ABCDE12345 ./scripts/build-macos.sh    # signed build
#
# Output (in ./build/):
#   SuperNovaPad.app             — the standalone app bundle
#   SuperNovaPad-1.0.pkg         — installer that drops the app into /Applications
#   SuperNovaPad-1.0.dmg         — drag-to-Applications disk image
#
# To install: double-click the .pkg, OR mount the .dmg and drag the app to
# /Applications. First launch on an unsigned build: right-click → Open
# (Gatekeeper one-time bypass).

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

PROJECT="OmnisphereSynth.xcodeproj"
SCHEME="SuperNovaPad"
CONFIG="Release"
APP_NAME="SuperNovaPad"
BUNDLE_ID="com.tommystrand.supernovapad"
VERSION="1.0"

BUILD_DIR="$ROOT/build"
DERIVED="$BUILD_DIR/DerivedData"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
PKG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.pkg"
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "error: this script must be run on macOS" >&2
    exit 1
fi

if ! command -v xcodebuild >/dev/null; then
    echo "error: Xcode command-line tools not found. Install Xcode from the App Store." >&2
    exit 1
fi

echo "==> cleaning $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$EXPORT_DIR"

# Pick signing strategy
SIGN_FLAGS=()
if [[ -n "${DEV_TEAM:-}" ]]; then
    echo "==> signing with team $DEV_TEAM"
    SIGN_FLAGS=(
        DEVELOPMENT_TEAM="$DEV_TEAM"
        CODE_SIGN_STYLE=Automatic
    )
else
    echo "==> unsigned local build (set DEV_TEAM=XXXX for signed builds)"
    SIGN_FLAGS=(
        CODE_SIGN_IDENTITY="-"
        CODE_SIGNING_REQUIRED=NO
        CODE_SIGNING_ALLOWED=NO
    )
fi

echo "==> archiving for Mac Catalyst"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$DERIVED" \
    -archivePath "$ARCHIVE" \
    SUPPORTS_MACCATALYST=YES \
    "${SIGN_FLAGS[@]}" \
    archive

# The Catalyst .app sits inside the xcarchive
SRC_APP="$ARCHIVE/Products/Applications/$APP_NAME.app"
if [[ ! -d "$SRC_APP" ]]; then
    echo "error: archive did not produce $SRC_APP" >&2
    ls -la "$ARCHIVE/Products/Applications/" || true
    exit 1
fi

cp -R "$SRC_APP" "$APP_PATH"
echo "==> app bundle: $APP_PATH"

echo "==> building .pkg installer"
# productbuild puts the app under /Applications when the user runs the .pkg
PRODUCT_SIGN_FLAGS=()
if [[ -n "${INSTALLER_SIGN_ID:-}" ]]; then
    PRODUCT_SIGN_FLAGS=(--sign "$INSTALLER_SIGN_ID")
fi
productbuild \
    --component "$APP_PATH" /Applications \
    --identifier "$BUNDLE_ID.installer" \
    --version "$VERSION" \
    "${PRODUCT_SIGN_FLAGS[@]}" \
    "$PKG_PATH"
echo "==> pkg: $PKG_PATH"

echo "==> building .dmg"
DMG_STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP_PATH" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "$APP_NAME $VERSION" \
    -srcfolder "$DMG_STAGE" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null
rm -rf "$DMG_STAGE"
echo "==> dmg: $DMG_PATH"

echo
echo "Done. Artifacts in $BUILD_DIR:"
ls -lh "$BUILD_DIR" | grep -E "\.app$|\.pkg$|\.dmg$" || ls -lh "$BUILD_DIR"

if [[ -z "${DEV_TEAM:-}" ]]; then
    cat <<EOF

NOTE: this is an unsigned build. Gatekeeper will block first launch.
First run instructions for end users:
  1. Mount the .dmg or run the .pkg
  2. Drag SuperNovaPad.app to /Applications (if .dmg)
  3. Right-click → Open (one-time Gatekeeper bypass)

For a signed + notarized build:
  DEV_TEAM=ABCDE12345 \\
  INSTALLER_SIGN_ID="Developer ID Installer: Your Name (ABCDE12345)" \\
  ./scripts/build-macos.sh
  # then run: xcrun notarytool submit "$PKG_PATH" --keychain-profile YourProfile --wait
EOF
fi
