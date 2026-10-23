#!/bin/sh
# Numeric style hierarchy study. Compiles the app's sources read-only.
set -e
cd "$(dirname "$0")"
APP=../../src/Tokenly
BUILD="${TMPDIR:-/tmp}/tokenly-numeric"
mkdir -p "$BUILD"
swiftc -O -parse-as-library "$APP"/Models/*.swift "$APP"/Providers/*.swift "$APP/ExternalProviderStore.swift" \
    "$APP/ProviderDisplaySettings.swift" "$APP/UsageStore.swift" "$APP/KeychainAdminKeyStore.swift" \
    ../Shared/HeartGaugeView.swift "$APP/Views/MenuBarNumericRow.swift" render.swift -o "$BUILD/render"
"$BUILD/render" "$(pwd)"
