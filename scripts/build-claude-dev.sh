#!/bin/zsh
set -euo pipefail

# Build only. Never launches the app or performs an SDK/account request.
repo_root="${0:A:h:h}"
build_root="${TOKENLY_CLAUDE_DEV_BUILD_ROOT:-/private/tmp/tokenly-claude-dev-20261031}"
bundle_id="io.github.jbbdyee.tokenly.claudeverify.20261031"
if [[ "$build_root" != /private/tmp/* ]]; then
  print -u2 'Build root must be below /private/tmp.'
  exit 2
fi
xcodebuild -project "$repo_root/src/Tokenly.xcodeproj" -scheme Tokenly \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath "$build_root/DerivedData" \
  "PRODUCT_BUNDLE_IDENTIFIER=$bundle_id" \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) TOKENLY_CLAUDE_DEV' build
app="$build_root/DerivedData/Build/Products/Debug/Tokenly.app"
plutil -replace CFBundleDisplayName -string 'Tokenly Claude 검증' "$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" == "$bundle_id" ]]
print -- "$app"
