#!/usr/bin/env bash
set -e

BUILD_DIR="build"
CONFIG="${1:-Release}"   # pass Debug as first arg if needed

echo "→ Configuring (${CONFIG})..."
cmake -S . -B "${BUILD_DIR}" \
      -DCMAKE_BUILD_TYPE="${CONFIG}" \
      -G "$([ "$(uname)" = "Darwin" ] && echo "Xcode" || echo "Unix Makefiles")"

echo "→ Building..."
cmake --build "${BUILD_DIR}" --config "${CONFIG}" --parallel

# ── Install (macOS) ─────────────────────────────────────────────────────────
if [ "$(uname)" = "Darwin" ]; then
    VST3_SRC=$(find "${BUILD_DIR}" -name "SuperNovaPad.vst3" -type d | head -1)
    AU_SRC=$(find "${BUILD_DIR}"   -name "SuperNovaPad.component" -type d | head -1)

    if [ -n "$VST3_SRC" ]; then
        echo "→ Installing VST3 to ~/Library/Audio/Plug-Ins/VST3/"
        mkdir -p ~/Library/Audio/Plug-Ins/VST3
        cp -r "$VST3_SRC" ~/Library/Audio/Plug-Ins/VST3/
    fi

    if [ -n "$AU_SRC" ]; then
        echo "→ Installing AU to ~/Library/Audio/Plug-Ins/Components/"
        mkdir -p ~/Library/Audio/Plug-Ins/Components
        cp -r "$AU_SRC" ~/Library/Audio/Plug-Ins/Components/
    fi

    echo "✓ Done. Restart your DAW to see the plugin."
fi

# ── Install (Linux) ──────────────────────────────────────────────────────────
if [ "$(uname)" = "Linux" ]; then
    VST3_SRC=$(find "${BUILD_DIR}" -name "SuperNovaPad.vst3" -type d | head -1)
    if [ -n "$VST3_SRC" ]; then
        echo "→ Installing VST3 to ~/.vst3/"
        mkdir -p ~/.vst3
        cp -r "$VST3_SRC" ~/.vst3/
        echo "✓ Done. Restart your DAW."
    fi
fi

# ── Windows hint ────────────────────────────────────────────────────────────
if echo "$OS" | grep -qi "windows"; then
    echo "On Windows: copy the .vst3 bundle from ${BUILD_DIR}/ to"
    echo "  C:\\Program Files\\Common Files\\VST3\\"
fi
