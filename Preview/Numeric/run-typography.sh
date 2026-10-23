#!/bin/sh
# Numeric style typography study (weights, "/" gaps, 5h/7d drop). Compiles the app sources read-only.
set -e
cd "$(dirname "$0")"
APP=../../src/Tokenly
BUILD="${TMPDIR:-/tmp}/tokenly-numeric-typography"
mkdir -p "$BUILD"
swiftc -O -parse-as-library "$APP"/Models/*.swift "$APP"/Providers/*.swift "$APP/ExternalProviderStore.swift" \
    "$APP/ProviderDisplaySettings.swift" "$APP/UsageStore.swift" "$APP/KeychainAdminKeyStore.swift" \
    ../Shared/HeartGaugeView.swift "$APP/Views/MenuBarNumericRow.swift" typography.swift -o "$BUILD/render"
"$BUILD/render" "$(pwd)"
