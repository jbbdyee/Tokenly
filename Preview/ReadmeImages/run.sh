#!/bin/sh
# README menu bar images rendered by the app's own code (not screen captures). Output: ../../Doc/images.
set -e
cd "$(dirname "$0")"
APP=../../src/Tokenly
BUILD="${TMPDIR:-/tmp}/tokenly-readme-images"
mkdir -p "$BUILD"
rm -rf "$BUILD/BearGauge" && cp -R "$APP/Resources/BearGauge" "$BUILD/"
# MenuBarPresentation lives in TokenlyApp.swift (which has @main); copy it without the app entry point.
sed '/^@main/,/^}/d' "$APP/TokenlyApp.swift" > "$BUILD/AppLabels.swift"
swiftc -O -parse-as-library "$APP"/Models/*.swift "$APP"/Providers/*.swift "$APP/ExternalProviderStore.swift" \
    "$APP/ProviderDisplaySettings.swift" "$APP/UsageStore.swift" "$APP/KeychainAdminKeyStore.swift" \
    "$APP/Views/BearGaugeView.swift" "$APP/Views/MenuBarGaugeRow.swift" "$APP/Views/MenuBarNumericRow.swift" \
    "$BUILD/AppLabels.swift" render.swift -o "$BUILD/render"
"$BUILD/render" "$(cd ../../Doc/images && pwd)"
