#!/bin/sh
# Option B (name set into the lower outline, larger bear, ears ×1.05) vs. the app's current bear.
# Compiles the app's sources read-only plus the SceneKit bear model; never writes into the app.
set -e
cd "$(dirname "$0")"
APP=../../src/Tokenly
BUILD="${TMPDIR:-/tmp}/tokenly-bear-name-outline"
mkdir -p "$BUILD"
rm -rf "$BUILD/BearGauge" && cp -R "$APP/Resources/BearGauge" "$BUILD/"
swiftc -O -parse-as-library "$APP"/Models/*.swift "$APP"/Providers/*.swift "$APP/ExternalProviderStore.swift" \
    "$APP/ProviderDisplaySettings.swift" "$APP/UsageStore.swift" "$APP/KeychainAdminKeyStore.swift" \
    ../Shared/HeartGaugeView.swift "$APP/Views/BearGaugeView.swift" \
    HeartMesh.swift Render3D.swift BearModel.swift BearNameOutline.swift -o "$BUILD/render"
"$BUILD/render" "$(pwd)"
