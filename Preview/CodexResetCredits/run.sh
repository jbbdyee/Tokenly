#!/bin/sh
# Offline render of the popover's Codex section with stubbed reset credits. Compiles the app's sources read-only.
set -e
cd "$(dirname "$0")"
APP=../../src/Tokenly
BUILD="${TMPDIR:-/tmp}/tokenly-codex-reset-credits"
mkdir -p "$BUILD"
swiftc -O -parse-as-library "$APP"/Models/*.swift "$APP"/Providers/*.swift "$APP/ExternalProviderStore.swift" \
    "$APP/ProviderDisplaySettings.swift" "$APP/UsageStore.swift" "$APP/KeychainAdminKeyStore.swift" \
    "$APP/SettingsWindowManager.swift" ../Shared/HeartGaugeView.swift "$APP/Views/UsageMenuView.swift" render.swift -o "$BUILD/render"
"$BUILD/render" "$(pwd)"
