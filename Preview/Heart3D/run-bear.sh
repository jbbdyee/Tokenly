#!/bin/sh
# Renders the glass jelly bear: exports runtime assets to ./assets and writes the comparison sheets here.
# Reuses the app's HeartGaugeView.swift read-only (shared studio helpers live in Render3D.swift).
set -e
cd "$(dirname "$0")"
BUILD="${TMPDIR:-/tmp}/tokenly-bear-3d"
mkdir -p "$BUILD"
swiftc -O -parse-as-library ../Shared/HeartGaugeView.swift \
    HeartMesh.swift Render3D.swift BearModel.swift BearGauge.swift BearMain.swift -o "$BUILD/render"
"$BUILD/render" "$(pwd)"
