# Claude 개인 구독 사용량 독립 조회 실험 조사

2026-10-30 · 브랜치 `experiment/claude-usage-refresh` · **조사만 완료, 실제 계정 조회 미실시**

## 목표와 현재 제품 경계

목표는 Claude Code를 사용하지 않는 동안 개인 Pro/Max 구독의 5시간·7일 사용률과 초기화 시각을 모델 추론 없이 조회할 수 있는지 검증하는 것이다. v0.3.0 설치 앱과 제품 코드는 변경하지 않았다. 이번 조사에서는 인증 저장소·Keychain·OAuth API에 접근하지 않았고 모델 요청과 자동 폴링도 실행하지 않았다.

Tokenly는 현재 Claude Code의 [statusLine JSON](https://code.claude.com/docs/en/statusline)에서 `rate_limits.five_hour`와 `seven_day`의 `used_percentage`, `resets_at`을 받는다. `StatusLineBridge`가 수신 시각을 `captured_at`으로 기록하고 개인용 파일에 필요한 필드만 저장한다. `ClaudeSubscriptionProvider`는 이를 잔여율 `100 - used_percentage`로 바꾸며, 수신 후 15분을 넘기면 오래된 데이터로 처리한다. `ExternalProviderStore`의 5분 타이머는 이 파일을 다시 읽을 뿐 서버 조회를 하지 않는다. 따라서 재읽기 시각을 새 조회 성공 시각으로 취급할 수 없다. 공식 문서상 statusLine 스크립트 재실행은 데이터의 서버 갱신을 보장하지 않으며, 첫 API 응답 전 `rate_limits`가 없을 수 있다.

설치된 Claude Code `2.1.292`의 읽기 전용 `--help`, `auth --help`에는 독립 사용량 명령이 없었다. [공식 CLI 참조](https://code.claude.com/docs/en/cli-reference)의 `-p`는 질문을 전달하는 기능이므로 자동 사용량 조회 후보에서 제외한다. [관리자용 Claude Code Analytics API](https://platform.claude.com/docs/en/manage-claude/claude-code-analytics-api)는 개인 Pro/Max의 실시간 5시간·7일 한도 API가 아니다.

## 후보와 근거 수준

| 방식 | 독립 조회와 필드 | 인증·모델 비용 | 판단 |
| --- | --- | --- | --- |
| 기존 statusLine·로컬 캐시 | 5시간·7일 사용률/초기화 시각을 수신하지만 Claude 세션의 이벤트와 서버 갱신에 의존 | 기존 Claude Code 관리 인증, 추가 모델 요청 없음 | 안정적인 현재 방식. 독립 최신 조회에는 부적합 |
| Claude Agent SDK `Query.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET()` / CLI `get_usage` 제어 요청 | [Anthropic SDK 변경 기록](https://github.com/anthropics/claude-agent-sdk-typescript/blob/main/CHANGELOG.md)에 세션 비용·플랜 rate limit 반환이 명시됨. [공개 이슈의 개발자 관찰](https://github.com/anthropics/claude-code/issues/93107)과 [타사 구현](https://github.com/ZingerLittleBee/Heeler/issues/494)은 5시간·7일 및 무프롬프트 제어 요청을 보고 | Claude Code/SDK가 기존 로그인을 자체 관리할 가능성이 높음. 무모델·무과금은 이 계정에서 미검증. 프로세스 시작 시 훅·상태/인증 캐시 쓰기 가능 | **단발성 실험의 최우선 후보**. 공식 배포 SDK의 명시적 실험 API이지만 안정된 제품 계약은 아님 |
| `/api/oauth/usage` 직접 호출 | [타사 구현](https://github.com/ohugonnot/claude-code-statusline)이 5시간·7일 조회에 사용. [이슈](https://github.com/anthropics/claude-code/issues/31021)에 실제 사용 사례 | 앱이 OAuth bearer 토큰을 읽어야 하므로 유출·로그·보관 위험. [429 지속 사례](https://github.com/anthropics/claude-code/issues/31637) 보고 | 비공식 내부 경로. Tokenly 제품 후보로 권장하지 않음. 이번 실험에서 호출 금지 |
| `/usage` 화면 또는 `~/.claude.json`의 캐시 | [이슈 #93107](https://github.com/anthropics/claude-code/issues/93107)의 관찰상 캐시는 화면 열기와 연결되어 오래될 수 있음 | UI 조작 또는 설정 파일 접근 필요 | 독립 신선도 보장 불가 |
| `claude -p`에 질문 전송 / 공용 Messages API | 개인 구독 한도 조회 계약 없음 | 모델 턴과 사용량 소비 가능 | 제외 |

[Headless 한도 명령 요청 #77018](https://github.com/anthropics/claude-code/issues/77018)은 `not planned`로 닫혔다. [statusLine 확장 요청 #82656](https://github.com/anthropics/claude-code/issues/82656)도 안정된 독립 조회 계약은 아니다. 공개 이슈의 재현과 타사 설명은 Anthropic의 지원 보증으로 해석하지 않는다.

## 위험과 실패 정책

- **인증:** SDK/CLI 제어 요청도 정상 로그인 캐시 갱신이나 상태 파일 쓰기를 일으킬 수 있다. Tokenly가 인증 파일·Keychain을 직접 읽거나 토큰을 외부로 전달하는 설계는 피한다. 추가 로그인, 로그아웃, 인증 초기화가 필요하면 실험을 중단한다.
- **401·403:** 비공식 OAuth 경로에는 공개된 오류 계약이 없다. 각각 인증 실패·권한/지원 범위 문제일 가능성이 있지만 원인으로 단정하지 않는다. 재시도나 자동 재로그인을 하지 않고 사용자에게 비민감 상태만 알린다.
- **429:** [이슈 #30930](https://github.com/anthropics/claude-code/issues/30930)과 [#31637](https://github.com/anthropics/claude-code/issues/31637)에 직접 endpoint의 지속적 제한과 부정확하거나 없는 `Retry-After`가 보고됐다. 이 수치는 서비스 계약이나 안전한 호출 간격의 근거가 아니다. 실험은 1회만 실행하고 429면 즉시 멈춘다. 제품화 단계의 호출 제한은 공식 계약이 나오기 전 확정하지 않는다.
- **호환성·자원:** SDK 메서드 이름 자체가 변경 가능을 명시한다. 제어 요청 형식, 응답 필드, 실행 플래그는 버전에 따라 달라질 수 있다. 타사 측정의 CPU/메모리 수치는 다른 환경의 관찰이므로 Tokenly의 비용으로 일반화하지 않는다.
- **약관·지원:** SDK 공개 배포와 소비자 Pro/Max 계정에서의 제3자 앱 무프롬프트 사용 허용 여부는 별도 문제다. [Anthropic 법률 문서](https://www.anthropic.com/legal)와 SDK 적용 조건을 제품화 전에 확인해야 하며, 현재 허용·금지 어느 쪽도 확정하지 않는다.

## 제안하는 단발성 검증 설계

1. 제품 코드와 분리된 일회성 helper를 준비하고 공식 Claude Code 바이너리 또는 Agent SDK의 `get_usage` 경로만 사용한다. 사용자 메시지·모델 프롬프트를 전송하지 않는다. 시작 훅과 세션 기록을 공식 옵션으로 끌 수 있는지 문서와 모의 프로세스로 먼저 확인한다. 공식 옵션이 없거나 모델 턴이 필요한 구조라면 실제 계정 실험을 하지 않는다.
2. **실제 조회 전에 사용자에게 별도 승인**을 받는다. 승인 범위에는 공식 CLI/SDK의 기존 로그인 재사용, 정상 인증 캐시·상태 파일 갱신 가능성, 단 1회 제어 요청을 명시한다. 토큰 추출·복사·로깅, 재로그인, 직접 OAuth 호출, 자동 재시도는 제외한다.
3. 일회 실행은 타임아웃을 두고 사용자 메시지·모델 요청 발생 징후가 있으면 즉시 종료한다. 결과에는 종료 코드, elapsed time, 5시간·7일 필드 존재·자료형, 초기화 시각 형식, 추가 인증 여부, 모델 턴·비용 발생 여부만 남긴다. 원본 응답·수치·계정 정보는 기록하지 않는다.
4. 성공해도 최소 두 창의 실제 신선도, 서버 캐시, 모델 비용 0, 인증 부작용, 연속 호출 제한, SDK 버전 변화, 이용 조건은 별도 미검증으로 둔다. 제품 통합과 폴링은 해당 검증과 추가 승인이 끝난 뒤 판단한다.

**현재 결론:** 공식 안정 인터페이스로 독립 조회가 가능하다고 말할 수 없다. 공식 SDK의 실험적 `get_usage` 경로는 직접 토큰 취급 없이 모델 턴 없는 조회가 가능한지 확인할 가장 유망한 후보이다. Tokenly에 안전하게 채택 가능한지는 단발성 실제 계정 검증과 지원·약관 확인 전에는 미정이다.
