#!/bin/zsh
set -euo pipefail

# Separate three-attempt development app. Building never calls the account SDK.
repo_root="${0:A:h:h}"
root='/private/tmp/tokenly-claude-real-three-20261102'
bundle_id='io.github.jbbdyee.tokenly.claudereal3.20261102'
xcodebuild -project "$repo_root/src/Tokenly.xcodeproj" -scheme Tokenly \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath "$root/DerivedData" \
  "PRODUCT_BUNDLE_IDENTIFIER=$bundle_id" \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) TOKENLY_CLAUDE_DEV' build
app="$root/DerivedData/Build/Products/Debug/Tokenly.app"
plutil -replace CFBundleDisplayName -string 'Tokenly Claude 3회 검증' "$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" == "$bundle_id" ]]
print -- "$app"
