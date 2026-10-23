#!/usr/bin/env python3
"""Opt-in Claude Code statusLine setup. Run only in the user's normal Terminal."""

import datetime
import json
import os
import pathlib
import stat
import sys
import tempfile


def main() -> int:
    project = pathlib.Path(__file__).resolve().parent.parent
    bridge = project / "src/Tokenly/ClaudeStatusLineBridge.py"
    settings = pathlib.Path.home() / ".claude/settings.json"
    if not bridge.is_file() or not settings.is_file() or settings.is_symlink():
        print("중단: 브리지 또는 일반 설정 파일을 확인할 수 없습니다.")
        return 2
    original = settings.read_bytes()
    try:
        values = json.loads(original)
    except ValueError:
        print("중단: 설정 JSON이 유효하지 않습니다.")
        return 2
    if not isinstance(values, dict) or "statusLine" in values:
        print("중단: 기존 statusLine이 있거나 설정 구조가 예상과 다릅니다. 덮어쓰지 않았습니다.")
        return 2
    original_mode = stat.S_IMODE(settings.stat().st_mode)
    backup = settings.with_name(
        "settings.json.tokenly-backup-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    )
    old_umask = os.umask(0o077)
    try:
        with os.fdopen(os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as output:
            output.write(original)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(backup, 0o600)
        if backup.read_bytes() != original:
            print("중단: 백업 검증 실패. 원본은 그대로입니다.")
            return 3
        values["statusLine"] = {
            "type": "command",
            "command": "/usr/bin/python3 '" + str(bridge) + "'",
        }
        updated = (json.dumps(values, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        # A concurrent settings edit must be reviewed rather than overwritten.
        if settings.read_bytes() != original:
            print("중단: 백업 이후 설정이 변경됐습니다. 원본은 그대로입니다.")
            return 3
        temporary = None
        try:
            with tempfile.NamedTemporaryFile("wb", dir=settings.parent, delete=False) as output:
                temporary = pathlib.Path(output.name)
                output.write(updated)
                output.flush()
                os.fsync(output.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, settings)
        finally:
            if temporary is not None and temporary.exists():
                temporary.unlink()
        after = json.loads(settings.read_bytes())
        if {k: v for k, v in after.items() if k != "statusLine"} != json.loads(original):
            print("오류: 기존 키가 달라졌습니다. 아래 백업으로 복원하세요.")
            return 4
        print("설정 완료; 기존 키 보존: 예")
        print("백업:", backup)
        print("백업 권한:", oct(stat.S_IMODE(backup.stat().st_mode)))
        print("원본 이전 권한:", oct(original_mode))
        print("설정 현재 권한:", oct(stat.S_IMODE(settings.stat().st_mode)))
        print("복원: cp '" + str(backup) + "' '" + str(settings) + "' && chmod " + format(original_mode, "04o") + " '" + str(settings) + "'")
        return 0
    except OSError as error:
        print("설정 작업 실패:", type(error).__name__, "(원본과 백업을 확인하세요)")
        return 3
    finally:
        os.umask(old_umask)


if __name__ == "__main__":
    sys.exit(main())
