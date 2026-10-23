#!/bin/sh
# Bear outline strength study. Compiles the app's sources read-only and reads the bundled bear assets
# (copied next to the temporary binary, which is where Bundle.main looks for a command-line tool).
set -e
cd "$(dirname "$0")"
APP=../../src/Tokenly
BUILD="${TMPDIR:-/tmp}/tokenly-bear-outline"
mkdir -p "$BUILD"
rm -rf "$BUILD/BearGauge" && cp -R "$APP/Resources/BearGauge" "$BUILD/"
swiftc -O -parse-as-library "$APP"/Models/*.swift "$APP"/Providers/*.swift "$APP/ExternalProviderStore.swift" \
    "$APP/ProviderDisplaySettings.swift" "$APP/UsageStore.swift" "$APP/KeychainAdminKeyStore.swift" \
    ../Shared/HeartGaugeView.swift "$APP/Views/BearGaugeView.swift" BearOutline.swift -o "$BUILD/render"
"$BUILD/render" "$(pwd)"
