#!/bin/bash
# Two mock SDK responses in one isolated development app process. Never invokes Claude or Node.
set -euo pipefail
app="${TOKENLY_CLAUDE_MOCK_SIXTY_APP:-/private/tmp/tokenly-claude-mock-sixty-app-20261101/Build/Products/Debug/Tokenly.app/Contents/MacOS/Tokenly}"
[[ "$app" == /private/tmp/* && -x "$app" ]] || { echo 'Isolated mock app missing' >&2; exit 20; }
bundle="$(dirname "$(dirname "$app")")"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$bundle/Info.plist")" == io.github.jbbdyee.tokenly.claudemock60.20261101 ]] || {
  echo 'Unexpected mock app bundle ID' >&2; exit 20
}
root="$(mktemp -d /private/tmp/tokenly-claude-dev-mock-sixty-XXXXXXXX)"
mkdir -p "$root/home"
chmod 700 "$root" "$root/home"
: > "$root/calls.txt"
chmod 600 "$root/calls.txt"
cp "$(dirname "$0")/fixtures/mock-ui-success.json" "$root/sdk-response.json"
cat > "$root/helper.sh" <<'HELPER'
#!/bin/sh
root="${TOKENLY_CLAUDE_DEV_MOCK_SIXTY_ROOT:?}"
count=$(/usr/bin/awk 'END { print NR+0 }' "$root/calls.txt")
[ "$count" -lt 2 ] || exit 29
/usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f\n", time' >> "$root/calls.txt"
/bin/cat "$root/sdk-response.json"
HELPER
captured=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')
printf '{"captured_at":"%s","rate_limits":{"five_hour":{"used_percentage":27},"seven_day":{"used_percentage":42}}}\n' "$captured" > "$root/feed.json"
chmod 700 "$root/helper.sh"
chmod 600 "$root/sdk-response.json" "$root/feed.json"
unset TOKENLY_CLAUDE_DEV_BUNDLED_ENABLE TOKENLY_CLAUDE_DEV_REAL_ONCE TOKENLY_CLAUDE_DEV_REAL_TWO TOKENLY_CLAUDE_DEV_REAL_SIXTY CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
HOME="$root/home" TOKENLY_HOME="$root/home" TOKENLY_CLAUDE_DEV_ENABLE=1 TOKENLY_CLAUDE_DEV_MOCK=1 TOKENLY_CLAUDE_DEV_MOCK_SIXTY=1 \
TOKENLY_CLAUDE_DEV_MOCK_SIXTY_ROOT="$root" \
TOKENLY_CLAUDE_DEV_NODE=/bin/sh TOKENLY_CLAUDE_DEV_HELPER="$root/helper.sh" TOKENLY_CLAUDE_DEV_CLI=/usr/bin/true \
TOKENLY_CLAUDE_DEV_STATUSLINE="$root/feed.json" "$app" >/dev/null 2>&1 &
app_pid=$!
( sleep 240; kill -TERM "$app_pid" 2>/dev/null || true ) &
watchdog_pid=$!
trap 'kill -TERM "$app_pid" "$watchdog_pid" 2>/dev/null || true' EXIT INT TERM
printf 'Mock 60-second app PID: %s (no real SDK call; stops within 4 minutes)\n' "$app_pid"
printf 'Non-sensitive call-time file: %s/calls.txt\n' "$root"
wait "$app_pid" || true
kill -TERM "$watchdog_pid" 2>/dev/null || true
printf 'Mock helper calls: %s\n' "$(/usr/bin/awk 'END { print NR+0 }' "$root/calls.txt")"
