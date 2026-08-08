#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Sources/Soundtime/TimelineRenderer.swift"
RESOURCE_DIR="$ROOT/Sources/Soundtime/Resources"
BUILD_DIR="$ROOT/.build/metal"
METAL_SOURCE="$BUILD_DIR/TimelineShaders.metal"
AIR_OUTPUT="$BUILD_DIR/TimelineShaders.air"
LIBRARY_OUTPUT="$RESOURCE_DIR/TimelineShaders.metallib"

mkdir -p "$RESOURCE_DIR" "$BUILD_DIR"

awk '
    /private static let shaderSource = """/ { copying = 1; next }
    copying && /^    """$/ { exit }
    copying {
        sub(/^    /, "")
        print
    }
' "$SOURCE" > "$METAL_SOURCE"

if [[ ! -s "$METAL_SOURCE" ]]; then
    echo "Could not extract TimelineRenderer.shaderSource" >&2
    exit 1
fi

xcrun metal \
    -c \
    -std=metal3.1 \
    -mmacosx-version-min=14.0 \
    "$METAL_SOURCE" \
    -o "$AIR_OUTPUT"
xcrun metallib "$AIR_OUTPUT" -o "$LIBRARY_OUTPUT"
rm -f "$AIR_OUTPUT"

extract_shader() {
    local input="$1"
    awk '
        /private static let shaderSource = """/ { copying = 1; next }
        copying && /^    """$/ { exit }
        copying {
            sub(/^    /, "")
            print
        }
    ' "$input"
}

build_library() {
    local swift_source="$1"
    local resource_name="$2"
    local metal_source="$BUILD_DIR/$resource_name.metal"
    local air_output="$BUILD_DIR/$resource_name.air"
    local library_output="$RESOURCE_DIR/$resource_name.metallib"

    extract_shader "$swift_source" > "$metal_source"
    if [[ ! -s "$metal_source" ]]; then
        echo "Could not extract shader source from $swift_source" >&2
        exit 1
    fi

    xcrun metal \
        -c \
        -std=metal3.1 \
        -mmacosx-version-min=14.0 \
        "$metal_source" \
        -o "$air_output"
    xcrun metallib "$air_output" -o "$library_output"
    rm -f "$air_output"
    echo "Built $library_output"
}

build_library "$ROOT/Sources/Soundtime/FrameRateHistoryView.swift" "FrameRateHistoryShaders"
build_library "$ROOT/Sources/Soundtime/LoudnessMeterView.swift" "LoudnessMeterShaders"
build_library "$ROOT/Sources/Soundtime/TransportControlPanelView.swift" "TransportControlShaders"
build_library "$ROOT/Sources/Soundtime/TimelineNavigationScrollbarView.swift" "TimelineNavigationScrollbarShaders"
build_library "$ROOT/Sources/Soundtime/MixerPanelView.swift" "MixerMeterShaders"

echo "Built $LIBRARY_OUTPUT"
