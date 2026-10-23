#!/usr/bin/python3
"""Receive AGY's official status-line payload; persist quota fields only."""
import datetime
import json
import math
import os
import pathlib
import sys
import tempfile

try:
    payload = json.loads(sys.stdin.read(2_000_001))
    quota = {}
    for name, item in payload.get("quota", {}).items():
        if not isinstance(name, str) or not isinstance(item, dict):
            continue
        fraction = item.get("remaining_fraction")
        if isinstance(fraction, (int, float)) and math.isfinite(fraction) and 0 <= fraction <= 1:
            quota[name] = {
                "remaining_fraction": fraction,
                "reset_time": item.get("reset_time") if isinstance(item.get("reset_time"), str) else None,
            }
    if not quota:
        raise ValueError("no quota fields")
    folder = pathlib.Path.home() / "Library" / "Application Support" / "Tokenly"
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(folder, 0o700)
    os.umask(0o077)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=folder, delete=False) as output:
        json.dump({"captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"), "quota": quota}, output)
        temporary = output.name
    os.replace(temporary, folder / "agy-quota.json")
except (OSError, ValueError, TypeError):
    pass

print("")
