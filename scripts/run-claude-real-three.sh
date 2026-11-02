#!/bin/bash
# One isolated development trial with at most three real SDK usage requests.
set -euo pipefail

root='/private/tmp/tokenly-claude-real-three-20261102'
app="$root/DerivedData/Build/Products/Debug/Tokenly.app"
helper="$root/runtime/claude-usage-helper.mjs"
node='/opt/homebrew/opt/node@24/bin/node'
cli='/opt/homebrew/bin/claude'
bundle_id='io.github.jbbdyee.tokenly.claudereal3.20261102'
[[ -x "$app/Contents/MacOS/Tokenly" && -r "$helper" && -x "$node" && -x "$cli" ]] || exit 20
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" == "$bundle_id" ]] || exit 20
for slot in 1 2 3; do [[ ! -e "$root/attempt-$slot.reserved" ]] || exit 20; done
[[ ! -s "$root/attempt.txt" && ! -s "$root/store.txt" ]] || exit 20
[[ ! -e "$HOME/Library/Application Support/Tokenly Claude Experiment/$bundle_id/refresh-checkpoint.json" ]] || exit 20
[[ "$(readlink "$root/runtime/node_modules")" == '/private/tmp/tokenly-claude-helper-package-final/node_modules' ]] || exit 20

env -u TOKENLY_CLAUDE_DEV_REAL_TWO -u TOKENLY_CLAUDE_DEV_REAL_ONCE \
    -u TOKENLY_CLAUDE_DEV_REAL_SIXTY -u TOKENLY_CLAUDE_DEV_MOCK \
    -u TOKENLY_CLAUDE_DEV_MOCK_SIXTY -u CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC \
    TOKENLY_CLAUDE_DEV_ENABLE=1 TOKENLY_CLAUDE_DEV_REAL_THREE=1 \
    TOKENLY_CLAUDE_DEV_NODE="$node" TOKENLY_CLAUDE_DEV_HELPER="$helper" \
    TOKENLY_CLAUDE_DEV_CLI="$cli" \
    "$app/Contents/MacOS/Tokenly" >/dev/null 2>&1 &
app_pid=$!
trap 'kill "$app_pid" 2>/dev/null || true; wait "$app_pid" 2>/dev/null || true' EXIT
printf 'three_query_dev_app_pid=%s\n' "$app_pid"

# The app gate reserves three durable slots. This supervisor stops on any failure,
# third Store update or four-minute deadline. It never retries or prints account data.
for ((second=0; second<240; second++)); do
    count=$(grep -c '^status=' "$root/attempt.txt" 2>/dev/null || true)
    [[ "$count" =~ ^[0-9]+$ && "$count" -le 3 ]] || exit 21
    if (( count > 0 )); then
        failure=$(grep '^status=' "$root/attempt.txt" | grep -v '^status=success$' || true)
        [[ -z "$failure" ]] || { printf 'query_failed_after_%s_attempts\n' "$count"; exit 22; }
    fi
    if (( count == 3 )); then
        store_count=$(grep -c '^source=' "$root/store.txt" 2>/dev/null || true)
        if (( store_count >= 3 )); then
            printf 'three_query_attempts_and_store_updates_completed\n'
            exit 0
        fi
    fi
    kill -0 "$app_pid" 2>/dev/null || { printf 'app_exited_early\n'; exit 23; }
    sleep 1
done
printf 'trial_deadline_reached\n'
exit 24
