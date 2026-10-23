#!/usr/bin/env python3
"""Print only Claude login and sanitized status-line receipt metadata."""

import json
import os
import pathlib
import stat
import subprocess


def main() -> None:
    try:
        auth = subprocess.run(
            ["/opt/homebrew/bin/claude", "auth", "status", "--json"],
            text=True, capture_output=True, timeout=12, check=False,
        )
        response = json.loads(auth.stdout or "{}")
        print("Claude 로그인:", response.get("loggedIn", "확인 불가"))
        print("인증 방식:", response.get("authMethod", "확인 불가"))
    except (OSError, ValueError, subprocess.TimeoutExpired):
        print("Claude 로그인: 확인 불가")

    path = pathlib.Path.home() / "Library/Application Support/Tokenly/claude-quota.json"
    print("수신 파일 존재:", path.is_file())
    if not path.is_file() or path.is_symlink():
        return
    print("수신 파일 권한:", oct(stat.S_IMODE(path.stat().st_mode)))
    try:
        data = json.loads(path.read_text())
        print("마지막 수신 시각:", data.get("captured_at", "없음"))
        limits = data.get("rate_limits", {})
        for name in ("five_hour", "seven_day"):
            item = limits.get(name) if isinstance(limits, dict) else None
            print(name + " 필드:", "있음" if isinstance(item, dict) else "없음")
    except (OSError, ValueError, TypeError):
        print("수신 파일: 해석 불가")


if __name__ == "__main__":
    main()
