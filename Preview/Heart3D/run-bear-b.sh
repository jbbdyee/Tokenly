#!/bin/sh
# Exports option-B bear assets (21pt frame, ears ×1.05) to ./assets-b. Reuses the app's HeartGaugeView.swift read-only.
set -e
cd "$(dirname "$0")"
BUILD="${TMPDIR:-/tmp}/tokenly-bear-b-export"
mkdir -p "$BUILD"
swiftc -O -parse-as-library ../Shared/HeartGaugeView.swift \
    HeartMesh.swift Render3D.swift BearModel.swift BearExportB.swift -o "$BUILD/export"
"$BUILD/export" "$(pwd)"
