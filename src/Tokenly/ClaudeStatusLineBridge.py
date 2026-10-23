#!/usr/bin/python3
"""Keep only Claude Code's documented subscription rate-limit fields."""
import datetime
import json
import math
import os
import pathlib
import sys
import tempfile

MAX_INPUT_BYTES = 2_000_000
DESTINATION = pathlib.Path.home() / "Library" / "Application Support" / "Tokenly"


def sanitized(payload):
    limits = payload.get("rate_limits")
    if not isinstance(limits, dict):
        limits = {}
    result = {}
    for name in ("five_hour", "seven_day"):
        entry = limits.get(name)
        if not isinstance(entry, dict):
            continue
        used = entry.get("used_percentage")
        if isinstance(used, bool) or not isinstance(used, (int, float)):
            continue
        if not math.isfinite(used) or not 0 <= used <= 100:
            continue
        reset = entry.get("resets_at")
        if isinstance(reset, bool) or not isinstance(reset, (int, float)):
            reset = None
        elif not math.isfinite(reset) or reset <= 0:
            reset = None
        result[name] = {"used_percentage": used, "resets_at": reset}
    return {
        "captured_at": datetime.datetime.now(datetime.timezone.utc)
        .isoformat(timespec="seconds").replace("+00:00", "Z"),
        "rate_limits": result,
    }


def receive():
    raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    if len(raw) > MAX_INPUT_BYTES:
        return
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        return
    output = sanitized(payload)
    DESTINATION.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(DESTINATION, 0o700)
    os.umask(0o077)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=DESTINATION, delete=False) as file:
        temporary = pathlib.Path(file.name)
        json.dump(output, file, separators=(",", ":"))
    os.chmod(temporary, 0o600)
    os.replace(temporary, DESTINATION / "claude-quota.json")


if __name__ == "__main__":
    try:
        receive()
    except (OSError, ValueError, TypeError):
        pass
    print("")
