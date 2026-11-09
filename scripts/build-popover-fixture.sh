#!/bin/bash
# Account-free system-popover test app for another Mac. Never installs or starts it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${TOKENLY_POPOVER_FIXTURE_OUT:-/private/tmp/tokenly-popover-fixture-20261102}"
bundle_id='io.github.jbbdyee.tokenly.popoverfixture.20261102'
[[ "$out" == /private/tmp/* && ! -e "$out" ]] || { echo 'Choose a new /private/tmp output directory' >&2; exit 64; }
mkdir -p "$out"
xcodebuild -project "$root/src/Tokenly.xcodeproj" -scheme Tokenly -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$out/DerivedData" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  "PRODUCT_BUNDLE_IDENTIFIER=$bundle_id" \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) TOKENLY_POPOVER_FIXTURE' \
  CLANG_COVERAGE_MAPPING=NO ENABLE_CODE_COVERAGE=NO clean build > "$out/build.log" 2>&1
app="$out/DerivedData/Build/Products/Release/Tokenly.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" == "$bundle_id" ]]
[[ "$(lipo -archs "$app/Contents/MacOS/Tokenly")" == *arm64* ]]
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Tokenly Popover Test' "$app/Contents/Info.plist"
strip -S -x "$app/Contents/MacOS/Tokenly"
if LC_ALL=C grep -a -q -F "$HOME/" "$app/Contents/MacOS/Tokenly"; then
  echo 'Build executable contains a local home path' >&2; exit 20
fi
codesign --force --deep --sign - --identifier "$bundle_id" --timestamp=none "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/Tokenly-Popover-Fixture.zip"
shasum -a 256 "$out/Tokenly-Popover-Fixture.zip" > "$out/Tokenly-Popover-Fixture.zip.sha256"
printf 'app=%s\nzip=%s\nbundle_id=%s\naccount_providers=disabled\n' \
  "$app" "$out/Tokenly-Popover-Fixture.zip" "$bundle_id"
