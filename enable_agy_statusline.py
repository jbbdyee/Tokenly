#!/usr/bin/env python3
"""User-run, one-time AGY statusLine setup. Never prints existing settings."""

import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
from datetime import datetime


settings = Path.home() / ".gemini/antigravity-cli/settings.json"
bridge = Path(__file__).resolve().parent / "src/Tokenly/AGYStatusLineBridge.py"
if not settings.is_file() or settings.is_symlink() or not bridge.is_file():
    raise SystemExit("설정 파일 또는 Tokenly 브리지를 확인할 수 없습니다. 변경하지 않았습니다.")
original = settings.read_bytes()
if stat.S_IMODE(settings.stat().st_mode) != 0o600:
    raise SystemExit("설정 파일 권한이 0600이 아닙니다. 변경하지 않았습니다.")
data = json.loads(original)
if not isinstance(data, dict) or "statusLine" in data:
    raise SystemExit("statusLine이 이미 있거나 JSON 구조가 예상과 다릅니다. 변경하지 않았습니다.")

command = "/usr/bin/python3 '" + str(bridge).replace("'", "'\\''") + "'"
block = {"type": "command", "command": command, "stack_with_default": True}
text = original.decode("utf-8")
end = text.rfind("}")
if end < 0:
    raise SystemExit("최상위 JSON 끝을 찾을 수 없습니다. 변경하지 않았습니다.")
insertion = ("," if data else "") + "\n  \"statusLine\": " + json.dumps(block, ensure_ascii=False) + "\n"
updated = (text[:end].rstrip() + insertion + text[end:]).encode("utf-8")
check = json.loads(updated)
if {k: v for k, v in check.items() if k != "statusLine"} != data or check["statusLine"] != block:
    raise SystemExit("변경 전후 JSON 검증에 실패했습니다. 변경하지 않았습니다.")

backup = settings.with_name(settings.name + ".tokenly-backup-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
try:
    with os.fdopen(os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as out:
        out.write(original)
except PermissionError:
    raise SystemExit("백업 생성 권한이 없습니다. 원본은 변경하지 않았습니다. 일반 사용자 터미널에서 실행하세요.")
os.chmod(backup, 0o600)
if backup.read_bytes() != original:
    raise SystemExit("백업 검증에 실패했습니다. 원본은 변경하지 않았습니다.")

fd, temp_name = tempfile.mkstemp(prefix=".settings.tokenly-", dir=settings.parent)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "wb") as out:
        out.write(updated)
        out.flush()
        os.fsync(out.fileno())
    os.replace(temp_name, settings)
finally:
    if os.path.exists(temp_name):
        os.unlink(temp_name)

print("JSON 유효성: 확인; 권한: 0600; 기존 설정 값: 보존")
print("추가된 항목: statusLine(type, command, stack_with_default=true)")
print("백업:", backup)
print("복원: cp -p '" + str(backup) + "' '" + str(settings) + "'")
