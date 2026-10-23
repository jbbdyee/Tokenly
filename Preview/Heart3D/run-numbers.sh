#!/bin/sh
# Digits-only bear numbers: centring/clearance measurements and actual-size sheets.
# (copied next to the temporary binary, which is where Bundle.main looks for a command-line tool).
set -e
cd "$(dirname "$0")"
APP=../../src/Tokenly
BUILD="${TMPDIR:-/tmp}/tokenly-bear-numbers"
mkdir -p "$BUILD"
rm -rf "$BUILD/BearGauge" && cp -R "$APP/Resources/BearGauge" "$BUILD/"
swiftc -O -parse-as-library "$APP"/Models/*.swift "$APP"/Providers/*.swift "$APP/ExternalProviderStore.swift" \
    "$APP/ProviderDisplaySettings.swift" "$APP/UsageStore.swift" "$APP/KeychainAdminKeyStore.swift" \
    ../Shared/HeartGaugeView.swift "$APP/Views/BearGaugeView.swift" BearNumbers.swift -o "$BUILD/render"
"$BUILD/render" "$(pwd)"
