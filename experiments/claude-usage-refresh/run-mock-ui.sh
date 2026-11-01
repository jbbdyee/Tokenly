#!/bin/bash
# UI-only fixture: no bundled SDK, Claude CLI, or real account access.
set -euo pipefail
mode="${1:-success}"
if [[ "$mode" != success && "$mode" != fallback ]]; then
  printf '%s\n' 'Usage: run-mock-ui.sh success|fallback' >&2
  exit 2
fi
repo="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
root=/private/tmp/tokenly-claude-dev-mock-ui-20261101
app=/private/tmp/tokenly-claude-portable-app-final-20261101/DerivedData/Build/Products/Debug/Tokenly.app/Contents/MacOS/Tokenly
[[ -x "$app" ]] || { printf '%s\n' 'Mock development app is missing' >&2; exit 20; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$(dirname "$(dirname "$app")")/Info.plist")" == io.github.jbbdyee.tokenly.claudebundle.20261101 ]] || {
  printf '%s\n' 'Unexpected app bundle ID' >&2; exit 20
}
mkdir -p "$root/home"
chmod 700 "$root" "$root/home"
: > "$root/calls.txt"
chmod 600 "$root/calls.txt"
if [[ "$mode" == success ]]; then
  cp "$repo/experiments/claude-usage-refresh/fixtures/mock-ui-success.json" "$root/sdk-response.json"
  cat > "$root/helper.sh" <<'HELPER'
#!/bin/sh
printf x >> /private/tmp/tokenly-claude-dev-mock-ui-20261101/calls.txt
cat /private/tmp/tokenly-claude-dev-mock-ui-20261101/sdk-response.json
HELPER
else
  cat > "$root/helper.sh" <<'HELPER'
#!/bin/sh
printf x >> /private/tmp/tokenly-claude-dev-mock-ui-20261101/calls.txt
exit 22
HELPER
fi
captured=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')
printf '{"captured_at":"%s","rate_limits":{"five_hour":{"used_percentage":27},"seven_day":{"used_percentage":42}}}\n' "$captured" > "$root/feed.json"
chmod 700 "$root/helper.sh"
chmod 600 "$root/feed.json"
[[ ! -f "$root/sdk-response.json" ]] || chmod 600 "$root/sdk-response.json"
unset TOKENLY_CLAUDE_DEV_BUNDLED_ENABLE TOKENLY_CLAUDE_DEV_REAL_ONCE TOKENLY_CLAUDE_DEV_REAL_TWO TOKENLY_CLAUDE_DEV_REAL_SIXTY CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
HOME="$root/home" TOKENLY_HOME="$root/home" TOKENLY_CLAUDE_DEV_ENABLE=1 TOKENLY_CLAUDE_DEV_MOCK=1 TOKENLY_CLAUDE_DEV_NODE=/bin/sh TOKENLY_CLAUDE_DEV_HELPER="$root/helper.sh" TOKENLY_CLAUDE_DEV_CLI=/usr/bin/true TOKENLY_CLAUDE_DEV_STATUSLINE="$root/feed.json" "$app" >/dev/null 2>&1 &
app_pid=$!
( sleep 240; kill -TERM "$app_pid" 2>/dev/null || true ) &
watchdog_pid=$!
trap 'kill -TERM "$app_pid" "$watchdog_pid" 2>/dev/null || true' EXIT INT TERM
printf 'Mock development app PID: %s (stops within 4 minutes; no real SDK request)\n' "$app_pid"
wait "$app_pid" || true
kill -TERM "$watchdog_pid" 2>/dev/null || true
printf 'Mock helper calls: %s\n' "$(wc -c < "$root/calls.txt")"
