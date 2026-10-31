#!/bin/zsh
set -euo pipefail

# Builds a separate one-shot validation app. Does not launch it or access an account.
repo_root="${0:A:h:h}"
build_root='/private/tmp/tokenly-claude-real-once-20261031'
bundle_id='io.github.jbbdyee.tokenly.clauderealone.20261031'
xcodebuild -project "$repo_root/src/Tokenly.xcodeproj" -scheme Tokenly \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath "$build_root/DerivedData" \
  "PRODUCT_BUNDLE_IDENTIFIER=$bundle_id" \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) TOKENLY_CLAUDE_DEV' build
app="$build_root/DerivedData/Build/Products/Debug/Tokenly.app"
plutil -replace CFBundleDisplayName -string 'Tokenly Claude 실계정 검증' "$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" == "$bundle_id" ]]
print -- "$app"
