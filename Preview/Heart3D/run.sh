#!/bin/sh
# Renders the 3D heart study (SceneKit) into this folder. Reuses the app's HeartGaugeView.swift read-only.
set -e
cd "$(dirname "$0")"
BUILD="${TMPDIR:-/tmp}/tokenly-heart-3d"
mkdir -p "$BUILD"
swiftc -O -parse-as-library ../Shared/HeartGaugeView.swift ../Shared/LegacyMenuBarHeart.swift \
    HeartMesh.swift Render3D.swift Main.swift -o "$BUILD/render"
"$BUILD/render" "$(pwd)"
