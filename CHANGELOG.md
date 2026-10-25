# 변경 기록

이 문서는 [Keep a Changelog](https://keepachangelog.com/ko/1.1.0/) 형식을 따르고, 버전은 [Semantic Versioning](https://semver.org/lang/ko/)을 따릅니다.

## [0.1.0] - 미출시 (첫 개발자 미리보기)

첫 공개 버전입니다. Apple 공증을 받지 않은 ad-hoc 서명 빌드이며 GitHub Pre-release로 배포합니다.

### 추가
- macOS 메뉴 막대에서 Codex · Claude Code · Google Antigravity(AGY)의 남은 사용 한도를 표시합니다.
  - 메뉴 막대 스타일 3종: 숫자형(기본), 최소형, 곰돌이형.
  - 서비스별 표시 선택, 연결되지 않은 서비스 숨김, 오래된 데이터(수신 후 15분 경과)는 회색으로 표시.
  - 팝오버 상세: 5시간·7일(AGY는 버킷별) 잔여율, 초기화 시각, 마지막 수신 시각.
  - Codex 사용 한도 재설정 권한의 남은 횟수와 사용 기한 표시(읽기 전용, 권한을 소모하지 않음).
- Codex: 공식 `codex app-server`의 읽기 전용 `account/rateLimits/read`를 5분마다 조회합니다.
- Claude Code·AGY: 앱 실행 파일이 statusLine 브리지 역할을 합니다(`Tokenly --statusline claude|agy`). Python이 필요 없습니다.
  - 한도 수치·초기화 시각·수신 시각만 `~/Library/Application Support/Tokenly/`에 권한 0600으로 저장합니다.
  - 이미 쓰던 statusLine이 있으면 그 명령을 같은 입력으로 실행해 출력을 그대로 보여 줍니다(시간 제한 10초, 재귀 방지).
- 명령줄 도구: `--status`(상태 확인), `--connect`·`--disconnect`(미리보기·확인·백업 후 연결·해제, 원래 설정 서식 그대로 복원).
- 설정 화면: 표시 서비스, 메뉴 막대 스타일, 화면 모드, 로그인 시 자동 실행, Claude·AGY 연결 명령 복사.
- 앱 아이콘.
- `scripts/release.sh`: universal Release 빌드, ad-hoc 서명, 검증, ZIP·SHA-256 생성.

### 변경
- 번들 ID를 `io.github.jbbdyee.tokenly`로 정했습니다. 공개 전 개발 빌드(`com.tokenly.app`)의 설정·로그인 항목은 자동으로 이어지지 않습니다.
- 앱 카테고리를 유틸리티로 지정했습니다.

### 호환
- 0.1.0 개발 빌드의 Python 브리지(`ClaudeStatusLineBridge.py`, `AGYStatusLineBridge.py`)는 앱 안에 남아 있습니다. `--connect`를 실행하면 네이티브 브리지로 바뀝니다.

### 알려진 제한
- Apple 공증을 받지 않아 첫 실행 때 Gatekeeper 확인이 필요합니다.
- Claude 한도는 Pro·Max 구독에서, 세션의 첫 응답 이후에만 들어옵니다. Claude·AGY 값은 CLI가 상태줄을 그릴 때만 갱신됩니다.
- Codex `app-server`는 Codex CLI에서 실험 기능이라 CLI 업데이트에 따라 바뀔 수 있습니다.
