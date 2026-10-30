# Claude 개인 구독 사용량 독립 조회 실험 조사

2026-10-30 · 브랜치 `experiment/claude-usage-refresh` · 조사 뒤 승인된 단발성 조회 1회 완료

## 1차 검사 로직 정적 재분석과 모의 검증 (2026-10-30)

이 단계에서는 **추가 실계정 조회가 없었다.** 저장소 밖에 남은 1차 helper의 검사 코드와 공식 npm 패키지 `0.3.169`의 `sdk.d.ts`·`sdk.mjs`만 읽었다. 원본 실계정 응답, 인증 저장소, Keychain은 읽거나 복원하지 않았다.

- `sdk.mjs`의 usage 메서드는 `{subtype:"get_usage"}` 제어 요청을 보내고 성공 응답의 `.response`를 **검증·변환 없이 반환**한다. 1차 helper는 `response.rate_limits?.five_hour`와 `.seven_day`를 검사했다. 이 경로와 이름은 `sdk.d.ts`의 `SDKControlGetUsageResponse`에 일치한다. `utilization`은 **사용률 0–100**이고 `resets_at`은 ISO 8601 문자열이다. 잔여율은 `100 - utilization`으로 계산해야 하므로 사용률 100은 유효한 잔여율 0%이다.
- 타입 주석에서 `rate_limits_available=false`는 API 키·Bedrock·Vertex 또는 필요한 프로필 범위가 없는 세션의 플랜 한도 *비적용*을 뜻하며, 이때 `rate_limits=null`이라고 설명한다. 반대로 `true`가 각 창의 값 존재를 보장한다는 계약은 없다. 타입은 `rate_limits` 자체의 `null`, `five_hour?`·`seven_day?`의 부재/`null`, 내부 `utilization`·`resets_at`의 `null`을 허용한다. 즉 1차 `true`는 두 창의 숫자·시각이 확인됐다는 뜻이 아니다. `0.3.292`의 대응 타입도 두 창을 선택적으로 선언한다.
- 1차 helper의 `presentWindow(window)`는 `Boolean(window && typeof window.utilization === 'number')`, `resetPresent(window)`는 문자열에 `Date.parse`가 성공하는지만 검사했다. 이 출력은 **키 부재, 창 `null`, 사용률 `null`/비숫자를 모두 `false`로 합친다.** 시각도 키 부재와 `null`/형식 오류를 합친다. `Date.parse`는 비 ISO 문자열도 받아들일 수 있어 타입의 ISO 8601 계약을 엄격히 검증하지 못한다. 숫자 검사 역시 유한성·0–100 범위를 검사하지 않는다. 따라서 1차의 `false`는 사용 가능한 값 미확인만 의미하며 실제 누락 원인을 증명하지 않는다.
- 저장소 밖 임시 mock 스크립트에서 7개 가상 사례를 실행해 모두 통과했다: 두 창 있음, 5시간만 있음, 7일만 있음, 두 키 부재, 두 창 `null`, 창 내부 값 `null`, 사용률 100으로 잔여율 0%. `rate_limits_available=true`와 빈 `rate_limits={}`도 타입상 가능한 형태임을 별도 확인했다. 이는 **검사 함수 동작의 검증**이지 실제 서버 응답이나 계정 상태의 검증이 아니다.
- **확정된 코드 원인:** 검사 결과가 여러 상태를 하나의 `false`로 압축해 1차 응답의 정확한 형태를 알 수 없게 했다. **미확정된 데이터 원인:** 실제 창 키가 없었는지, `null`이었는지, 타입이 달랐는지, 사용률만 없었는지, SDK/CLI 버전 차이 또는 서버 데이터 조건 때문인지는 알 수 없다. 패키지 `0.3.169`는 응답을 가공하지 않으므로, 그 패키지가 값을 삭제했다고 볼 근거는 없다.

추가 실계정 호출은 **정적 분석을 마치는 데 필요하지 않다.** 다만 SDK만으로 개인 구독 두 창을 실제로 표시할 수 있는지 확정하려면 나중에 별도 승인된 1회 조회가 필요하다. 그때는 CLI `2.1.292`와 맞는 SDK `0.3.292`, `skipBehaviors:true`, 프롬프트 없는 제어 요청을 사용하고, 원본 수치 없이 다음 분류만 메모리에 계산해 출력한다: `rate_limits`가 `null`/객체인지, 각 창 키의 `hasOwn` 여부, 창 값이 `null`/객체인지, `utilization`의 자료형·유효 범위 여부, `resets_at`의 자료형·엄격한 ISO 8601 형식 여부, 모델 메시지·세션 비용 발생 여부. 계정 유형·원본 응답·실제 사용량은 출력하지 않는다. 타임아웃 타이머는 완료 시 해제해 요청 지연과 프로세스 총 시간을 구분한다. 인증 오류나 429는 재시도하지 않는다. 이 설계는 **제안이며 현재 추가 조회 승인은 없다.**

블로그 소재는 `rate_limits_available`와 실제 창 존재를 분리한 타입 해석, 비밀정보를 보존하지 않는 실험의 진단 한계, `null`·키 부재·0%를 구분하는 모의 검증이다. 기존 Tokenly 블로그 3편과의 중복 평가는 후속 ChatGPT 판단에 맡기며, 이번에는 본문을 쓰지 않는다.

## 승인된 단발성 실험 결과 (2026-10-30)

- 시작 Git: `experiment/claude-usage-refresh` `c934e7a`, 미추적 GPU 로그 2개 외 변경 없음. 설치 Claude Code CLI `2.1.292`; 프로젝트·전역 Agent SDK 설치 없음. 공식 npm 패키지 `@anthropic-ai/claude-agent-sdk@0.3.169`를 저장소 밖 임시 경로에 설치했다. 설치 스크립트와 선택적 바이너리는 실행하지 않았다.
- 공식 [TypeScript SDK 참조](https://code.claude.com/docs/en/agent-sdk/typescript)는 `query()`가 문자열 또는 사용자 메시지 비동기 스트림을 받고, 별도 `startup()`은 **프롬프트 전 initialize만** 수행한다고 설명한다. 공개 패키지 `sdk.d.ts`는 실험적 usage 메서드가 `/usage`의 5시간·7일·모델별 한도를 반환할 수 있다고 명시한다. 공개 `sdk.mjs`에서 이 메서드는 `get_usage` 제어 요청 하나를 보내며, 비동기 입력 스트림에서 메시지를 내보내지 않으면 사용자 메시지를 전송하지 않는 것을 확인했다. `startup()`이 돌려주는 `WarmQuery`에는 usage 메서드가 없으므로 메시지 없는 `query()`로 initialize 후 usage를 1회 요청했다.
- 실험 프로세스는 임시 디렉터리에서 실행했다. 기존 CLI 실행 파일을 지정하고 safe mode, 사용자·프로젝트 설정 미로드, MCP 비활성화, 세션 영속화 비활성화, 도구 없음으로 시작했다. 환경에서 별도 API 키·OAuth 토큰 주입 변수는 자식 프로세스에 전달하지 않았다. SDK/CLI의 정상 로그인 재사용 이외에 토큰을 직접 읽거나 복사하지 않았다.
- **관찰:** initialize 성공, `get_usage` 응답 성공, `rate_limits_available=true`. 민감 값 없는 검사에서 5시간·7일의 **숫자 사용률**과 유효한 초기화 시각은 확인되지 않았다. 검사 함수가 숫자와 유효한 시각을 요구하므로 이 결과만으로 필드 키 자체가 없었다고 단정할 수 없다. 원본 응답을 저장하지 않았고 승인 범위가 1회라 재조회하지 않았다. 따라서 개인 구독의 두 창 조회 성공은 **미검증**이다.
- 사용자 메시지·assistant 메시지는 관찰되지 않았고, 해당 새 세션 응답에는 모델별 사용 기록과 양의 세션 비용이 없었다. 이는 이번 요청에 모델 추론이 발생했다는 증거가 없다는 뜻이지, SDK 초기화의 모든 네트워크 동작·서버 과금 정책을 보증하지는 않는다. 오류 401·403·429는 관찰되지 않았다.
- 조회 응답까지 약 **445 ms**였다. 실험 스크립트의 25초 안전 타이머가 Node 종료까지 살아 있어 외부 명령의 총 벽시계 시간은 약 **25초**였다. 후자는 CLI 조회 지연이 아니다. 알려진 `~/.claude.json`의 크기·수정 시각은 전후 같았고, 파일 기반 `.credentials.json`은 두 시점 모두 없었다. **Keychain과 다른 상태 저장소의 변화는 확인하지 않았다.** 파일 내용은 읽지 않았다.
- 공개 패키지 `0.3.292`의 `claudeCodeVersion`은 설치 CLI `2.1.292`와 일치한다. 해당 버전 타입은 5시간·7일 필드를 여전히 *선택적*으로 정의하고 `skipBehaviors` 옵션을 추가했다. 이 패키지는 타입만 조사했으며 **실계정 조회를 반복하지 않았다**. 0.3.169/CLI 2.1.292 버전 차이, 응답 내 `null`, 해당 계정 한도 노출 조건 중 어느 것이 숫자 필드 미확인의 원인인지는 아직 모른다.

### 기술 블로그 소재 판단용 기록

새로 확인한 점은 공식 SDK의 실험적 usage 메서드가 독립적인 `get_usage` 제어 요청이며, 빈 입력 스트림을 이용해 모델 대화 없이 initialize와 사용량 요청을 분리할 수 있다는 것이다. 실제 계정에서는 요청 성공과 두 창의 사용 가능한 값 확보가 **서로 다른 검증 항목**임이 드러났다. 공개 SDK 타입의 버전 차이와 `null` 가능성을 조사했지만, 단발성 승인과 비밀정보 비저장 원칙 때문에 원인을 확정하지 않았다. 이 과정은 기존 statusLine 설계 및 Codex·AGY 자동 갱신 글과 겹치지 않는 기술적 제약·실험 설계 사례가 될 수 있다. 실제 두 창 조회와 제품 적용성이 확인되기 전에는 완결된 구현 사례로 쓰지 않는다. 블로그 본문은 작성하지 않았다.

📸 캡처 추천: 이번에 이미 끝난 실행의 **비민감 요약 출력만** 사용한다. 화면/명령은 임시 실험 helper의 요약 JSON, 시점은 2026-10-30 단발성 조회 직후, 설명할 핵심은 initialize·usage 요청 성공과 숫자 창 미확인을 분리한 판정이다. 캡처만을 위해 재실행하지 않는다.

## 목표와 현재 제품 경계

목표는 Claude Code를 사용하지 않는 동안 개인 Pro/Max 구독의 5시간·7일 사용률과 초기화 시각을 모델 추론 없이 조회할 수 있는지 검증하는 것이다. v0.3.0 설치 앱과 제품 코드는 변경하지 않았다. 초기 조사에서는 인증 저장소·Keychain·OAuth API에 접근하지 않았고 모델 요청과 자동 폴링도 실행하지 않았다. 이후 위 단발성 실험에서 공식 SDK가 기존 CLI 로그인을 재사용했다.

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

**현재 결론:** 실험적 `get_usage`는 모델 대화 없이 응답을 받았으나, 이번 응답에서 사용할 수 있는 5시간·7일 숫자와 초기화 시각을 확인하지 못했다. 공식 안정 인터페이스나 Tokenly 제품 적용 가능성을 입증하지 못했다. 추가 실제 조회·폴링은 새 승인과 더 좁힌 필드 검사 계획 전까지 보류한다.
