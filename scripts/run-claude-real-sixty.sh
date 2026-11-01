#!/bin/bash
# One isolated, at-most-two-account-query development trial. Never retry this script.
set -euo pipefail

root='/private/tmp/tokenly-claude-real-sixty-20261101'
app="$root/DerivedData/Build/Products/Debug/Tokenly.app"
helper="$root/runtime/claude-usage-helper.mjs"
node='/opt/homebrew/opt/node@24/bin/node'
cli='/opt/homebrew/bin/claude'
bundle_id='io.github.jbbdyee.tokenly.claudereal60.20261101'
[[ -x "$app/Contents/MacOS/Tokenly" && -r "$helper" && -x "$node" && -x "$cli" ]] || exit 20
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" == "$bundle_id" ]] || exit 20
[[ ! -e "$root/attempt-1.reserved" && ! -e "$root/attempt-2.reserved" ]] || exit 20
[[ ! -s "$root/attempt.txt" && ! -s "$root/store.txt" ]] || exit 20
[[ ! -e "$HOME/Library/Application Support/Tokenly Claude Experiment/$bundle_id/refresh-checkpoint.json" ]] || exit 20
[[ "$(readlink "$root/runtime/node_modules")" == '/private/tmp/tokenly-claude-helper-package-final/node_modules' ]] || exit 20

env -u TOKENLY_CLAUDE_DEV_REAL_TWO -u TOKENLY_CLAUDE_DEV_REAL_ONCE \
    -u TOKENLY_CLAUDE_DEV_MOCK \
    TOKENLY_CLAUDE_DEV_ENABLE=1 TOKENLY_CLAUDE_DEV_REAL_SIXTY=1 \
    TOKENLY_CLAUDE_DEV_NODE="$node" TOKENLY_CLAUDE_DEV_HELPER="$helper" \
    TOKENLY_CLAUDE_DEV_CLI="$cli" \
    "$app/Contents/MacOS/Tokenly" >/dev/null 2>&1 &
app_pid=$!
trap 'kill "$app_pid" 2>/dev/null || true; wait "$app_pid" 2>/dev/null || true' EXIT

# The app has a durable two-slot gate. This supervisor closes only the new app after
# a failure, the second completion, or a fixed deadline. It never launches a retry.
for ((second=0; second<180; second++)); do
    count=$(grep -c '^status=' "$root/attempt.txt" 2>/dev/null || true)
    [[ "$count" =~ ^[0-9]+$ && "$count" -le 2 ]] || exit 21
    if (( count == 1 )); then
        first=$(grep '^status=' "$root/attempt.txt" | head -1)
        [[ "$first" == 'status=success' ]] || { printf 'first_query_failed\n'; exit 22; }
    fi
    if (( count == 2 )); then
        second_status=$(grep '^status=' "$root/attempt.txt" | tail -1)
        [[ "$second_status" == 'status=success' ]] || { printf 'second_query_failed\n'; exit 22; }
        store_count=$(grep -c '^source=' "$root/store.txt" 2>/dev/null || true)
        if (( store_count >= 2 )); then
            printf 'two_query_attempts_and_store_updates_completed\n'
            exit 0
        fi
    fi
    kill -0 "$app_pid" 2>/dev/null || { printf 'app_exited_early\n'; exit 23; }
    sleep 1
done
printf 'trial_deadline_reached\n'
exit 24
