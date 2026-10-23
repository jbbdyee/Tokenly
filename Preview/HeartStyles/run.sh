#!/bin/sh
# Renders the A/B/C heart style sheets into this folder. Reuses the app's HeartGaugeView.swift read-only.
set -e
cd "$(dirname "$0")"
BUILD="${TMPDIR:-/tmp}/tokenly-heart-styles"
mkdir -p "$BUILD"
swiftc -parse-as-library ../Shared/HeartGaugeView.swift ../Shared/LegacyMenuBarHeart.swift render.swift -o "$BUILD/render"
"$BUILD/render" "$(pwd)"
