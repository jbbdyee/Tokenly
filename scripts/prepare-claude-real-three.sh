#!/bin/zsh
set -euo pipefail

# Static preflight. No app, helper or account request is launched.
repo_root="${0:A:h:h}"
root='/private/tmp/tokenly-claude-real-three-20261102'
runtime="$root/runtime"
sdk_root='/private/tmp/tokenly-claude-helper-package-final/node_modules'
node='/opt/homebrew/opt/node@24/bin/node'
cli='/opt/homebrew/bin/claude'
umask 077
[[ -x "$node" && -x "$cli" && -d "$sdk_root/@anthropic-ai/claude-agent-sdk" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$root/DerivedData/Build/Products/Debug/Tokenly.app/Contents/Info.plist")" == \
   'io.github.jbbdyee.tokenly.claudereal3.20261102' ]]
mkdir -p "$runtime"
cp "$repo_root/experiments/claude-usage-refresh/claude-usage-helper.mjs" "$runtime/claude-usage-helper.mjs"
if [[ ! -e "$runtime/node_modules" ]]; then
  ln -s "$sdk_root" "$runtime/node_modules"
fi
[[ "$(readlink "$runtime/node_modules")" == "$sdk_root" ]]
[[ "$(shasum -a 256 "$runtime/claude-usage-helper.mjs" | awk '{print $1}')" == \
   "$(shasum -a 256 "$repo_root/experiments/claude-usage-refresh/claude-usage-helper.mjs" | awk '{print $1}')" ]]
"$node" --check "$runtime/claude-usage-helper.mjs"
for name in attempt.txt store.txt; do
  [[ -e "$root/$name" ]] || : > "$root/$name"
  chmod 600 "$root/$name"
done
print -- 'static_preflight=ok'
