#!/bin/sh
# Renders and measures the app's bear and heart menu bar rows. Compiles the app's sources read-only and
# reads the bundled bear assets (copied next to the temporary binary, where Bundle.main looks).
set -e
cd "$(dirname "$0")"
APP=../../src/Tokenly
BUILD="${TMPDIR:-/tmp}/tokenly-gauge-rows"
mkdir -p "$BUILD"
rm -rf "$BUILD/BearGauge" && cp -R "$APP/Resources/BearGauge" "$BUILD/"
swiftc -O -parse-as-library "$APP"/Models/*.swift "$APP"/Providers/*.swift "$APP/ExternalProviderStore.swift" \
    "$APP/ProviderDisplaySettings.swift" "$APP/UsageStore.swift" "$APP/KeychainAdminKeyStore.swift" \
    ../Shared/HeartGaugeView.swift "$APP/Views/BearGaugeView.swift" "$APP/Views/MenuBarGaugeRow.swift" \
    GaugeRowsApp.swift -o "$BUILD/render"
"$BUILD/render" "$(pwd)"
