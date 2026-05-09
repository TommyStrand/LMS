#!/usr/bin/env bash
# create_installer.sh — Build SuperNovaPad and package a macOS .pkg + .dmg
#
# Usage:
#   ./create_installer.sh              # build then package
#   ./create_installer.sh --skip-build # package from an existing build/ directory
#   ./create_installer.sh --dmg-only   # skip build, create DMG from existing .pkg
#
# Outputs:
#   dist/SuperNovaPad-1.0.0.pkg
#   dist/SuperNovaPad-1.0.0.dmg

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
NAME="SuperNovaPad"
VERSION="1.0.0"
COMPANY="TommyStrand"
BUILD_DIR="build"
DIST_DIR="dist"
STAGE_DIR="$(mktemp -d /tmp/omni_stage.XXXXXX)"
PKG_OUT="${DIST_DIR}/${NAME}-${VERSION}.pkg"
DMG_OUT="${DIST_DIR}/${NAME}-${VERSION}.dmg"
INSTALLER_RESOURCES="installer/Resources"

SKIP_BUILD=false
DMG_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=true ;;
        --dmg-only)   SKIP_BUILD=true; DMG_ONLY=true ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "  $*"; }
step() { echo; echo "▸ $*"; }
die()  { echo "✗ Error: $*" >&2; exit 1; }

require() {
    command -v "$1" &>/dev/null || die "'$1' not found. Install Xcode Command Line Tools: xcode-select --install"
}

require cmake
require pkgbuild
require productbuild
require hdiutil

[[ "$(uname)" == "Darwin" ]] || die "This script must run on macOS."

mkdir -p "${DIST_DIR}"

# ── Step 1: Build ─────────────────────────────────────────────────────────────
if ! $SKIP_BUILD; then
    step "Configuring with CMake (Release / Xcode generator)..."
    cmake -S . -B "${BUILD_DIR}" \
          -DCMAKE_BUILD_TYPE=Release \
          -G Xcode \
          -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"  # universal binary

    step "Building..."
    cmake --build "${BUILD_DIR}" --config Release --parallel
fi

# ── Step 2: Locate build artifacts ───────────────────────────────────────────
step "Locating build artifacts in ${BUILD_DIR}/..."

VST3_SRC=$(find "${BUILD_DIR}" -name "${NAME}.vst3"       -type d 2>/dev/null | head -1)
AU_SRC=$(  find "${BUILD_DIR}" -name "${NAME}.component"  -type d 2>/dev/null | head -1)
APP_SRC=$( find "${BUILD_DIR}" -name "${NAME}.app"        -type d 2>/dev/null | grep -v ".vst3\|.component" | head -1)

[[ -n "${VST3_SRC}" ]] && log "VST3:       ${VST3_SRC}" || log "VST3:       (not found, skipping)"
[[ -n "${AU_SRC}"   ]] && log "AU:         ${AU_SRC}"   || log "AU:         (not found, skipping)"
[[ -n "${APP_SRC}"  ]] && log "Standalone: ${APP_SRC}"  || log "Standalone: (not found, skipping)"

[[ -z "${VST3_SRC}" && -z "${AU_SRC}" && -z "${APP_SRC}" ]] && \
    die "No build artifacts found. Run without --skip-build or check ${BUILD_DIR}/"

if ! $DMG_ONLY; then

# ── Step 3: Stage components ──────────────────────────────────────────────────
step "Staging installation payloads..."

COMP_PKGS=()

# VST3 → /Library/Audio/Plug-Ins/VST3/
if [[ -n "${VST3_SRC}" ]]; then
    VST3_STAGE="${STAGE_DIR}/vst3/Library/Audio/Plug-Ins/VST3"
    mkdir -p "${VST3_STAGE}"
    cp -r "${VST3_SRC}" "${VST3_STAGE}/"
    log "Staged VST3"

    pkgbuild \
        --root "${STAGE_DIR}/vst3" \
        --identifier "com.${COMPANY,,}.${NAME,,}.vst3" \
        --version "${VERSION}" \
        --install-location "/" \
        "${DIST_DIR}/${NAME}-vst3.pkg"
    COMP_PKGS+=("${DIST_DIR}/${NAME}-vst3.pkg")
    log "Built VST3 component package"
fi

# AU → /Library/Audio/Plug-Ins/Components/
if [[ -n "${AU_SRC}" ]]; then
    AU_STAGE="${STAGE_DIR}/au/Library/Audio/Plug-Ins/Components"
    mkdir -p "${AU_STAGE}"
    cp -r "${AU_SRC}" "${AU_STAGE}/"
    log "Staged AU"

    pkgbuild \
        --root "${STAGE_DIR}/au" \
        --identifier "com.${COMPANY,,}.${NAME,,}.au" \
        --version "${VERSION}" \
        --install-location "/" \
        "${DIST_DIR}/${NAME}-au.pkg"
    COMP_PKGS+=("${DIST_DIR}/${NAME}-au.pkg")
    log "Built AU component package"
fi

# Standalone → /Applications/
if [[ -n "${APP_SRC}" ]]; then
    APP_STAGE="${STAGE_DIR}/app/Applications"
    mkdir -p "${APP_STAGE}"
    cp -r "${APP_SRC}" "${APP_STAGE}/"
    log "Staged Standalone app"

    pkgbuild \
        --root "${STAGE_DIR}/app" \
        --identifier "com.${COMPANY,,}.${NAME,,}.app" \
        --version "${VERSION}" \
        --install-location "/" \
        "${DIST_DIR}/${NAME}-standalone.pkg"
    COMP_PKGS+=("${DIST_DIR}/${NAME}-standalone.pkg")
    log "Built Standalone component package"
fi

# ── Step 4: Distribution package ─────────────────────────────────────────────
step "Assembling distribution package..."

# Build the <pkg-ref> + <choice> XML blocks from whatever we found
PKG_REFS=""
CHOICES=""
CHOICES_OUTLINE=""

for pkg in "${COMP_PKGS[@]}"; do
    base=$(basename "$pkg" .pkg)
    id_suffix="${base##*-}"   # vst3 | au | standalone
    full_id="com.${COMPANY,,}.${NAME,,}.${id_suffix}"
    title="$(tr '[:lower:]' '[:upper:]' <<< "${id_suffix:0:1}")${id_suffix:1}"
    [[ "$id_suffix" == "vst3" ]] && title="VST3 Plugin"
    [[ "$id_suffix" == "au"   ]] && title="Audio Unit (AU) Plugin"
    [[ "$id_suffix" == "standalone" ]] && title="Standalone Application"

    PKG_REFS+="    <pkg-ref id=\"${full_id}\" version=\"${VERSION}\">${base}.pkg</pkg-ref>\n"
    CHOICES+="    <choice id=\"${full_id}\" visible=\"true\" enabled=\"true\" selected=\"true\" title=\"${title}\"/>\n"
    CHOICES_OUTLINE+="        <line choice=\"${full_id}\"/>\n"
done

# Write distribution XML
DIST_XML="${DIST_DIR}/distribution.xml"
cat > "${DIST_XML}" <<DISTXML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>${NAME} ${VERSION}</title>
    <organization>com.${COMPANY,,}</organization>
    <domains enable_localSystem="true" enable_currentUserHome="false"/>
    <options customize="allow" require-scripts="false" rootVolumeOnly="false"/>
    <background file="background.png" alignment="bottomleft" scaling="none" mime-type="image/png"/>
    <welcome file="welcome.html" mime-type="text/html"/>
    <readme file="readme.html" mime-type="text/html"/>
    <license file="license.html" mime-type="text/html"/>
    <choices-outline>
$(echo -e "${CHOICES_OUTLINE}")    </choices-outline>
$(echo -e "${CHOICES}")
$(echo -e "${PKG_REFS}")
</installer-gui-script>
DISTXML

log "Wrote distribution.xml"

# Build final .pkg
RESOURCE_FLAGS=()
if [[ -d "${INSTALLER_RESOURCES}" ]]; then
    RESOURCE_FLAGS=(--resources "${INSTALLER_RESOURCES}")
    log "Using installer resources from ${INSTALLER_RESOURCES}/"
fi

productbuild \
    --distribution "${DIST_XML}" \
    --package-path "${DIST_DIR}" \
    "${RESOURCE_FLAGS[@]}" \
    "${PKG_OUT}"

# Remove component packages (they're embedded in the distribution pkg)
for pkg in "${COMP_PKGS[@]}"; do rm -f "$pkg"; done
rm -f "${DIST_XML}"

log "Created ${PKG_OUT}"

fi  # !DMG_ONLY

# ── Step 5: DMG ───────────────────────────────────────────────────────────────
step "Creating DMG..."

[[ -f "${PKG_OUT}" ]] || die "${PKG_OUT} not found. Run without --dmg-only first."

DMG_STAGE="$(mktemp -d /tmp/omni_dmg.XXXXXX)"
cp "${PKG_OUT}" "${DMG_STAGE}/"

# Copy optional extras if they exist
[[ -f "installer/Resources/readme.html" ]] && cp "installer/Resources/readme.html" "${DMG_STAGE}/Read Me.html"

# Create a writable DMG, then convert to compressed read-only
TMP_DMG="${DIST_DIR}/${NAME}-tmp.dmg"
hdiutil create \
    -volname "${NAME} ${VERSION}" \
    -srcfolder "${DMG_STAGE}" \
    -ov -format UDRW \
    "${TMP_DMG}"

# Set a window position/icon layout via AppleScript (best-effort, non-fatal)
MOUNT_PT=$(hdiutil attach "${TMP_DMG}" -readwrite -noverify -noautoopen | \
           awk '/\/Volumes\// { print $NF }')

if [[ -n "${MOUNT_PT}" ]]; then
    osascript <<APPLESCRIPT 2>/dev/null || true
tell application "Finder"
    tell disk "${NAME} ${VERSION}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 680, 380}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 72
        close
    end tell
end tell
APPLESCRIPT
    hdiutil detach "${MOUNT_PT}" -quiet
fi

hdiutil convert "${TMP_DMG}" -format UDZO -imagekey zlib-level=9 -o "${DMG_OUT}"
rm -f "${TMP_DMG}"
rm -rf "${DMG_STAGE}"

log "Created ${DMG_OUT}"

# ── Done ──────────────────────────────────────────────────────────────────────
step "Done!"
echo
echo "  Installer: ${PKG_OUT}"
echo "  DMG:       ${DMG_OUT}"
echo
echo "  To test locally (double-click or):"
echo "    open ${DMG_OUT}"
echo

rm -rf "${STAGE_DIR}"
