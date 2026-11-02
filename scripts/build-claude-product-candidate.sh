#!/bin/bash
# Build an isolated product candidate app with a universal official Node runtime and pinned SDK.
# The app is never launched. Claude CLI and user authentication are never bundled.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
root="${TOKENLY_CLAUDE_CANDIDATE_BUILD_ROOT:-/private/tmp/tokenly-claude-product-candidate-20261102}"
archives="${TOKENLY_CLAUDE_NODE_ARCHIVES:-/private/tmp/tokenly-claude-portable-node-v24.22.1}"
bundle_id='io.github.jbbdyee.tokenly.claudecandidate.20261102'
version='v24.22.1'
case "$root" in /private/tmp/*) ;; *) echo 'build root must be under /private/tmp' >&2; exit 64 ;; esac
[[ ! -e "$root" && ! -L "$root" ]] || { echo 'build root already exists' >&2; exit 64; }
mkdir -p "$root"
umask 077

for arch in arm64 x64; do
  archive="$archives/node-$version-darwin-$arch.tar.gz"
  [[ -f "$archive" ]] || { echo "Node archive missing: $arch" >&2; exit 20; }
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  if [[ "$arch" == arm64 ]]; then
    expected='89c682593d76cd44233fa53b1563264e7de9cbb189cad169135c5b4fadfbc0a7'
  else
    expected='d132557e7ee2b85af08b0c8c34338e65c6430f2238d01f727728ef42dc83b035'
  fi
  [[ "$actual" == "$expected" ]] || { echo "Node checksum mismatch: $arch" >&2; exit 20; }
  mkdir -p "$root/node-$arch"
  tar -xzf "$archive" -C "$root/node-$arch" --strip-components=2 "node-$version-darwin-$arch/bin/node"
done

TOKENLY_CLAUDE_PACKAGE_OUT="$root/sdk-payload" TOKENLY_CLAUDE_OMIT_OPTIONAL=1 \
  bash "$repo/scripts/package-claude-helper-dev.sh" > "$root/package-info.txt"
xcodebuild -project "$repo/src/Tokenly.xcodeproj" -scheme Tokenly \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath "$root/DerivedData" \
  "PRODUCT_BUNDLE_IDENTIFIER=$bundle_id" \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) TOKENLY_CLAUDE_PRODUCT_CANDIDATE' \
  build > "$root/xcodebuild.log" 2>&1

app="$root/DerivedData/Build/Products/Debug/Tokenly.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" == "$bundle_id" ]]
plutil -replace CFBundleDisplayName -string 'Tokenly Claude 통합 후보' "$app/Contents/Info.plist"
node="$app/Contents/MacOS/TokenlyClaudeNode"
resources="$app/Contents/Resources/ClaudeUsageSDK"
lipo -create "$root/node-arm64/node" "$root/node-x64/node" -output "$node"
chmod 755 "$node"
mkdir -p "$resources"
cp "$root/sdk-payload/claude-usage-helper.mjs" "$root/sdk-payload/package.json" \
   "$root/sdk-payload/package-lock.json" "$resources/"
cp -R "$root/sdk-payload/node_modules" "$resources/node_modules"
[[ "$(lipo -archs "$node")" == 'x86_64 arm64' || "$(lipo -archs "$node")" == 'arm64 x86_64' ]]
! otool -L "$node" | grep -Eq '/opt/homebrew|/usr/local|@rpath'
"$node" --check "$resources/claude-usage-helper.mjs"
"$node" --input-type=module -e 'import(process.argv[1]).then(m=>{if(typeof m.query!=="function")process.exit(23)})' \
  "$resources/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs"
codesign --force --sign - --timestamp=none --identifier "$bundle_id.node" "$node"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$node"
codesign --verify --strict "$app"
printf 'app=%s\nnode=%s\nsdk=0.3.169\ncli=bundled_no\naccount_query=no\n' "$app" "$("$node" --version)"
