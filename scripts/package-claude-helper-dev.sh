#!/bin/bash
# Build a development-only, account-free helper payload outside the repository.
# This does not run the helper, Claude CLI, or Tokenly app.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$root/experiments/claude-usage-refresh"
output="${TOKENLY_CLAUDE_PACKAGE_OUT:-/private/tmp/tokenly-claude-helper-package}"
case "$output" in /private/tmp/*) ;; *) echo 'output must be under /private/tmp' >&2; exit 64 ;; esac
[[ ! -e "$output" && ! -L "$output" ]] || { echo 'output already exists' >&2; exit 64; }
node="${TOKENLY_CLAUDE_PACKAGE_NODE:-$(command -v node || true)}"
[[ -n "$node" && -x "$node" ]] || { echo 'Node executable unavailable' >&2; exit 20; }
"$node" --version >/dev/null
[[ -f "$source_dir/package-lock.json" ]] || { echo 'SDK lockfile missing' >&2; exit 20; }

mkdir -p "$output"
cp "$source_dir/package.json" "$source_dir/package-lock.json" "$source_dir/claude-usage-helper.mjs" "$output/"
if [[ "${TOKENLY_CLAUDE_OMIT_OPTIONAL:-0}" == 1 ]]; then
  npm ci --prefix "$output" --omit=dev --omit=optional --ignore-scripts --no-audit --no-fund
else
  npm ci --prefix "$output" --omit=dev --ignore-scripts --no-audit --no-fund
fi
"$node" --check "$output/claude-usage-helper.mjs" >/dev/null
"$node" -e 'const p=require(process.argv[1]); if(p.version!=="0.3.169") process.exit(23)' \
  "$output/node_modules/@anthropic-ai/claude-agent-sdk/package.json"
[[ ! -L "$output/node_modules" ]] || { echo 'linked SDK tree is unsupported' >&2; exit 20; }
shasum -a 256 "$output/claude-usage-helper.mjs" "$output/package-lock.json" \
  > "$output/SHA256SUMS"
printf 'payload=%s\nsdk=0.3.169\nnode_build_host=%s\n' "$output" "$("$node" --version)"
printf '%s\n' 'Node runtime and Claude CLI are NOT bundled; no account query was performed.'
