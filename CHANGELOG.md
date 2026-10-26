# 변경 기록

이 문서는 [Keep a Changelog](https://keepachangelog.com/ko/1.1.0/) 형식을 따르고, 버전은 [Semantic Versioning](https://semver.org/lang/ko/)을 따릅니다.

## [0.1.0] - 미발행 (첫 개발자 미리보기, Pre-release 준비 중)

첫 공개 예정 버전입니다. 최종 빌드 0.1.0 (3)을 2026-10-26에 만들었고, GitHub Pre-release로 발행할 준비 중입니다(아직 발행하지 않음). Apple Developer ID 서명·공증을 받지 않은 ad-hoc 서명 빌드라 첫 실행 때 macOS가 실행을 막으며, 시스템 설정에서 이 앱만 허용해야 합니다.

### 추가
- macOS 메뉴 막대에서 Codex · Claude Code · Google Antigravity(AGY)의 남은 사용 한도를 표시합니다.
  - 메뉴 막대 스타일 3종: 숫자형(기본), 최소형, 곰돌이형.
  - 서비스별 표시 선택, 연결되지 않은 서비스 숨김, 오래된 데이터(수신 후 15분 경과)는 회색으로 표시.
  - 팝오버 상세: 5시간·7일 잔여율(AGY는 statusLine `quota`의 버킷별 잔여율), 초기화 시각, 마지막 수신 시각.
  - Codex 사용 한도 재설정 권한의 남은 횟수와 사용 기한 표시(읽기 전용, 권한을 소모하지 않음).
- Codex: 공식 `codex app-server`의 읽기 전용 `account/rateLimits/read`를 5분마다 조회합니다.
- Claude Code·AGY: 앱 실행 파일이 statusLine 브리지 역할을 합니다(`Tokenly --statusline claude|agy`). Python이 필요 없습니다.
  - 한도 수치·초기화 시각·수신 시각만 `~/Library/Application Support/Tokenly/`에 권한 0600으로 저장합니다.
  - 이미 쓰던 statusLine이 있으면 그 명령을 같은 입력으로 실행해 출력을 그대로 보여 줍니다(시간 제한 10초, 재귀 방지).
- 명령줄 도구: `--status`(상태 확인), `--connect`·`--disconnect`(미리보기·확인·백업 후 연결·해제, 원래 설정 서식 그대로 복원).
- 설정 화면: 표시 서비스, 메뉴 막대 스타일, 화면 모드, 로그인 시 자동 실행, Claude·AGY 연결 명령 복사.
- 앱 아이콘.
- `scripts/release.sh`: universal Release 빌드, ad-hoc 서명, 검증, ZIP·SHA-256 생성.
  - Release 빌드의 코드 커버리지 계측을 끕니다(`CLANG_COVERAGE_MAPPING=NO`). 계측된 실행 파일이 상태줄로 실행될 때마다 사용자의 프로젝트 폴더에 `default.profraw`를 만들던 문제를 막습니다. arm64·x86_64 실행 파일에 LLVM 프로파일 섹션(`__llvm_prf`)이 없는지 검사합니다.
  - 실행 파일의 디버그 기호를 지웁니다(`strip -S`). 디버그 맵에 남던 개발자 홈 아래 소스 경로와 DerivedData 경로를 배포 파일에서 없애고, 남아 있으면 실패합니다.
  - Xcode 산출물을 임시 번들 ID로 빌드하고 배포 사본에만 정식 ID를 넣습니다. 산출물의 LaunchServices 등록 해제 때문에 개발 Mac의 설치본이 macOS 앱 목록에서 빠지던 문제를 막습니다.
  - 출력 폴더가 이미 있으면 멈춥니다(`--replace`는 기존 폴더를 지우지 않고 옆으로 옮기며, 정식 번들 ID로 등록된 앱이 들어 있으면 옮기지 않음). 기존 산출물을 지우던 `rm -rf`를 없앴고, 출력 경로는 실제 절대 경로로 바꾼 뒤 저장소 안이면 거부합니다.

### 수정
- 처음 설치한 앱에서 macOS가 로그인 항목 상태를 `notFound`로 보고하면 자동 실행 토글이 비활성화되어 앱 안에서 등록할 수 없던 문제. 설치 위치(`/Applications`, `~/Applications`)의 앱이면 등록을 시도할 수 있고, 토글은 등록 후 macOS가 보고한 상태로만 표시합니다. 실패하면 시스템 오류 설명이 들어간 안내를 보여 줍니다.
- `--disconnect`가 Python 브리지에서 전환한 연결을 해제할 때 이전 Python statusLine을 복원하지 않고 삭제하던 문제(안내 문구도 "연결 전에는 statusLine이 없었습니다"로 사실과 달랐습니다). 연결 기록(버전 2)에 연결 직전 statusLine(`previous`)과 연결 때 만든 백업(`backupFile`)을 따로 저장하고, 해제하면 연결 직전 상태를 원래 서식 그대로 복원합니다. 이전 형식 기록은 연결 때 만든 백업으로 판정하며, 판정할 수 없으면 삭제하지 않고 중단합니다. Python 브리지 파일이 없으면 복원하지 않습니다. `--status`에 연결 해제 시 동작을 표시합니다.
- 연결 상태 판정의 값 비교가 `true`와 `1`을 같게 보던 문제. 키 순서·공백은 무시하고 문자열·불리언·숫자·null 타입을 구분합니다(숫자 `1`과 `1.0`은 같은 값).

### 변경
- 번들 ID를 `io.github.jbbdyee.tokenly`로 정했습니다. 공개 전 개발 빌드(`com.tokenly.app`)의 설정·로그인 항목은 자동으로 이어지지 않습니다.
- 앱 카테고리를 유틸리티로 지정했습니다.

### 호환
- 0.1.0 개발 빌드의 Python 브리지(`ClaudeStatusLineBridge.py`, `AGYStatusLineBridge.py`)는 앱 안에 남아 있습니다. `--connect`를 실행하면 네이티브 브리지로 바뀝니다.

### 검증
- XCTest 112개, 3회 반복 모두 통과(2026-10-26).
- **최종 빌드 0.1.0 (3)** (`release.sh --final 0.1.0`, ZIP SHA-256 `b2890dd1…0d124`)으로 개발자 Mac(macOS 27)에서 확인(2026-10-26).
  - 최종 ZIP의 앱을 `/Applications`에 설치(설치본 내용이 ZIP의 앱과 같음), 메뉴 막대·팝오버·설정 화면 정상.
  - Codex·Claude·AGY 실사용 표시를 개발자가 직접 확인. 기존 설정·연결 기록·백업 유지.
  - 앱 안 로그인 항목을 켠 상태(`enabled, allowed`)에서 재로그인 후 자동 실행되는 것을 개발자가 직접 확인.
- **개발 빌드 0.1.0 (3)** (디버그 기호 제거 전)으로 먼저 확인한 것(2026-10-26).
  - 실제 Claude Code·AGY 전역 설정을 `--connect`로 Swift 브리지로 전환하고, 실제 세션에서 호출·한도 수신(0600, 허용 필드만)·AGY `stack_with_default` 유지 확인. `default.profraw`는 생기지 않았습니다.
  - `--disconnect`의 Python 브리지 복원은 실제 설정의 복사본에서 실행해 원본과 바이트 단위로 같아지는 것을 확인했고, 실제 설정에서는 미리 보기(`--dry-run`)만 실행했습니다.
- **검증하지 않은 것:** 내려받은 ZIP을 새 사용자 계정·다른 Mac에서 처음 여는 Gatekeeper 절차(G2, 0.1.0에서는 생략), 재부팅 후 자동 실행.

### 알려진 제한
- Apple 공증을 받지 않아 첫 실행 때 Gatekeeper가 실행을 막고, 시스템 설정 → 개인정보 보호 및 보안의 **그래도 열기**로 이 앱만 허용해야 합니다. 이 절차는 내려받은 ZIP으로 직접 확인하지 않았습니다.
- Claude 한도는 Pro·Max 구독에서, 세션의 첫 응답 이후에만 들어옵니다. Claude·AGY 값은 CLI가 상태줄을 그릴 때만 갱신됩니다.
- AGY는 statusLine이 보내는 버킷별 잔여 비율을 그대로 보여 줍니다. 개발자 계정에서는 버킷 2개(`3p-weekly`, `gemini-weekly`)가 들어왔고, 버킷 구성은 계정·요금제·AGY 버전에 따라 다를 수 있습니다.
- Codex `app-server`는 Codex CLI에서 실험 기능이라 CLI 업데이트에 따라 바뀔 수 있습니다.
