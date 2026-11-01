# Claude 개인 구독 사용량 독립 조회 실험 조사

## 실행 경로·배포 준비 재검증 (2026-11-01)

- 이번 단계에는 실제 계정 조회, SDK helper 실행, 모델 요청, 자동 폴링을 하지 않았다. 정적 호출 경로는 개발 앱의 명시적 활성화 조건 → `ClaudeOptionalUsageProvider` → `ClaudeDirectUsageProvider` → `ClaudeSDKProcessRunner`/`ClaudeSubprocessExecutor` → Node helper의 `query()`/`initializationResult()` → 공식 SDK 0.3.169의 `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET()` → 최소 JSON → Swift 파서다. 일반 설치 앱은 기존 statusLine Provider를 계속 쓴다.
- helper는 사용자 프롬프트를 보내지 않고 `tools: []`, `persistSession: false`, `settingSources: []` 등으로 대화 경로를 제한한다. 관찰 가능한 사용자/assistant 메시지 또는 양의 세션 비용이 있으면 종료 코드 21로 거부한다. 숨은 서버 작업이나 비용이 전혀 없다는 보증은 아니다. Swift 실행기는 stdin/stderr를 `/dev/null`로 보내고 stdout을 메모리에서 16 KiB로 제한한다. 원본 오류·응답·인증 정보는 로그에 쓰지 않는다. Swift 자식 환경과 helper의 Claude Code 자식 환경에서 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`을 제거하며 부모 환경은 변경하지 않는다.
- Node 실행 파일·helper·Claude CLI의 누락은 프로세스 시작 전 `.unavailable`로 실패한다. SDK 패키지 누락은 helper의 모듈 로드 실패(종료 코드 20)로 분류한다. SDK를 호출하지 않는 빈 임시 폴더의 모듈 해석은 `ERR_MODULE_NOT_FOUND`였다. Mock 실행기는 정상·부분·null·비정상 종료·JSON 오류·타임아웃·취소·중복 요청을 시험한다. 실제 401/403/429 SDK 오류 형태는 확인되지 않았다.
- **배포 경계:** `package.json`은 SDK `0.3.169`를 정확히 지정하지만 잠금 파일이 없고, 개발 스크립트는 임시 `node_modules` 심볼릭 링크와 이 Mac의 Node/Claude CLI 절대 경로를 사용한다. 기존 `release.sh`는 Node, SDK, helper를 묶지 않는다. 따라서 현재 개발 앱의 성공을 다른 Mac의 실행 가능성으로 확대할 수 없다. 후속 배포안은 잠금 파일로 의존성 트리를 고정해 검증된 arm64/x86_64 Node 런타임·helper·SDK/필수 패키지를 앱 리소스에 넣고 서명·무결성·Gatekeeper·오프라인 누락 실패를 확인하는 것이다. 인증 재사용은 우선 사용자 설치 Claude CLI로 유지하고 경로/지원 버전을 검사한다. 번들된 CLI의 로그인 재사용은 별도 검증 전 채택하지 않는다. SDK가 실험 API인 만큼 버전 변경 시 Mock 계약과 단발성 실제 검증을 다시 수행한다. 이 배포안은 **설계이며 미구현**이다. [공식 SDK 실행 옵션](https://code.claude.com/docs/en/agent-sdk/typescript), [npm ci 잠금 파일 요구](https://docs.npmjs.com/cli/v11/commands/npm-ci/).
- 다음 개발 앱 실계정 단발 검증에는 별도 사용자 승인으로 정확한 앱 번들 ID, 최초 조회 최대 1회, 기존 로그인 재사용과 정상 인증 캐시 갱신 가능성, 오류 시 무재시도, 모델 메시지 금지, 민감 값 비기록을 명시해야 한다. 이번 검증은 그 승인이나 실행에 해당하지 않는다. 📸 캡처 추천: 비민감 Mock XCTest 결과와 앱 리소스 구성 표만 사용한다. 실계정 화면·원본 응답은 캡처하지 않는다.
- **이번 재검증:** Node 정책 테스트 9개, helper 문법 검사, 전체 macOS XCTest 438개, 일반 Debug·Release 빌드, `git diff --check` 통과. XCTest의 누락 Node/helper 시험도 통과했다. Xcode는 iOS CoreSimulator 버전 불일치 경고를 냈지만 macOS 작업 종료 코드는 0이었다. 이 결과는 다른 Mac의 실행과 실계정 SDK 오류 처리를 증명하지 않는다.

## 공식 SDK의 제한된 2회 자동 갱신 실계정 검증 (2026-11-01)

- 별도 Debug 앱 `Tokenly Claude 2회 검증`, 번들 ID `io.github.jbbdyee.tokenly.claudereal2.20261031`을 기존 설치 v0.3.0·Mock 앱·단발 앱과 분리해 실행했다. 실행 전 Node 24.22.1, Claude CLI 2.1.292, SDK 0.3.169, helper 해시/경로, 빈 예약·진단 파일을 확인했다. 첫 자동 승인 검토는 크레딧 부족 응답으로 거절됐고 앱은 실행되지 않았다. 사용자의 확인 뒤 같은 승격 경로가 허용됐으며 시스템 보호 설정을 바꾸거나 우회하지 않았다.
- **실제 관찰:** 공식 SDK 직접 조회가 2회 성공했다. 두 번 모두 파서에서 5시간·7일 창이 유효했고 Swift `ExternalProviderStore`에 직접 조회 출처, 두 창, 직접 성공 시각이 반영됐다. 첫 소요 **2.610초**, 둘째 **2.354초**, 기록된 오류 없음. 단조 시계 완료 시각은 496992158ms와 497294526ms이며, 두 번째 완료 시각에서 소요 시간을 빼면 **첫 성공 완료 후 300.014초**에 두 번째가 시작됐다. 성공 완료 간 간격은 302.368초다. 이는 이번 실행의 계측이며 공식 최소 호출 간격은 아니다. 30초 후에도 `O_EXCL` 예약 파일 2개와 비민감 진단 결과 2건뿐이었다.
- 첫 실패 시 중단과 중복 거부, 재실행 시 실패로 닫는 예약, 300초 기한은 Mock XCTest로 검증했다. 실계정에서는 두 조회가 성공했으므로 실패 분기·401/403/429·타임아웃·절전 복귀는 관찰하지 못했다. 두 슬롯이 모두 예약됐고 타이머는 반복하지 않으므로 실행 중인 앱에서 세 번째 SDK 시도는 Gate가 거부한다. 예약 파일을 삭제하지 않는다.
- helper가 관찰한 사용자/assistant 메시지 또는 양의 세션 비용은 전용 종료 코드 21을 발생시키지 않았다. 따라서 **관찰 가능한 모델 활동 신호는 없었지만**, 숨은 서버 작업·과금이 없다는 보증은 아니다. 실제 사용률·초기화 시각·계정·인증 정보·원본 응답은 출력하거나 저장하지 않았다. **UI 갱신은 사용자 화면 확인 대기:** Swift Store까지 두 번째 결과가 반영됐다는 비민감 기록만 있다. 화면 캡처를 공유한다면 해당 개발 앱의 Claude 영역에서 5시간·7일 항목과 `SDK 조회 마지막 성공` 문구만 남기고 실제 수치·시각·계정 정보는 가린다. 📸 캡처 추천: 같은 방식의 민감정보 가림 화면.
- 이번 실행 직전 안전장치 수정과 Mock 테스트는 로컬 작업 트리에 아직 미커밋이다. 개발 전용 관련 XCTest 21개, 별도 앱 Debug 빌드, `git diff --check`가 통과했다. 정식 앱의 자동 Claude 조회, 다른 Mac 배포, 장시간 안정성, 서버 신선도는 여전히 미검증이다.

## 자동 갱신 안정성 Mock 검증과 제한된 실계정 시험 준비 (2026-10-31)

- 시작 상태는 `experiment/claude-usage-refresh` / `96a961e`, 미추적 GPU 실측 로그 2개 외 미커밋 변경이 없었다. 앞선 단발성 실계정 검증과 사용자 UI 확인은 참고만 했다. **이번 단계에서는 실제 SDK helper, Claude 계정 조회, 모델 요청을 실행하지 않았다.** 정식 설치 v0.3.0 및 기존 Mock·단발 검증 앱도 변경하지 않았다.
- 기존 개발 자동 조회 정책은 Store의 300초 조건 검사와 별도 Gate의 성공 후 300초 최소 간격, 진행 중 중복 거부, 일시적 실패 후 5/10/20/40/60분 백오프, 401·403·429·SDK 부재/비호환/미지 오류 중단, 개발 빌드의 절전 복귀 기한 검사다. 이 5분은 **실험 초기값**이며 Anthropic이 보증한 최소 호출 간격이 아니다. Mock 테스트로 성공·타임아웃·취소·인증/권한/요청 제한·SDK 오류·중복·절전 기한을 검증했다. statusLine의 창별 대체와 마지막 직접 성공값·시각 보존도 Mock으로 검증했다. 실제 절전·장시간 폴링·실제 오류 응답 형식은 미검증이다.
- **다음 시험 전용 앱:** `/private/tmp/tokenly-claude-real-two-20261031/DerivedData/Build/Products/Debug/Tokenly.app`, 번들 ID `io.github.jbbdyee.tokenly.claudereal2.20261031`, 표시명 `Tokenly Claude 2회 검증`. 번들 ID별 `.standard` 설정 도메인은 정식 앱 `io.github.jbbdyee.tokenly`, 기존 Mock 앱 및 단발 앱과 구분된다. 개발 빌드의 Codex Provider는 비활성이고 AGY는 새 도메인에서 기본 숨김이다. 이 모드는 명시적 `TOKENLY_CLAUDE_DEV_ENABLE=1`과 `TOKENLY_CLAUDE_DEV_REAL_TWO=1`, 정확한 번들 ID, Node/helper/CLI 절대 경로가 모두 있을 때만 직접 조회를 만든다. 앱은 **아직 실행하지 않았다.**
- 다음 승인된 시험에서는 첫 직접 조회 성공 완료 뒤 300초에 **반복하지 않는 타이머 1개**로 두 번째를 예약한다. 첫 조회 실패 또는 직접 데이터 부재이면 statusLine이 성공해도 두 번째를 예약하지 않는다. Gate는 진행 중 중복을 막고 최대 2회만 허용하며, 모든 실패·취소 후 즉시 중단한다. 각 시도는 `/private/tmp/tokenly-claude-real-two-20261031/attempt-1.reserved`·`attempt-2.reserved`를 `O_EXCL`로 원자 예약한다. 앱 재실행·동시 실행에도 예약 파일이 남아 2회를 넘기지 않으며, 경로가 없거나 쓰기 불가이면 실패로 닫는다. 프로세스 시작 전에 실패해도 한 시도를 소비하는 보수적 정책이다. 이 파일을 임의로 삭제하거나 앱을 여러 번 시작하지 않는다.
- 비민감 진단은 성공/오류 종류, 5시간·7일 필드 유효성, Swift Store 출처·성공 시각 존재, 요청 소요 시간과 단조 시계 완료 시각만 남긴다. 원본 JSON·사용률·초기화 시각·계정·인증 정보는 기록하지 않는다. helper는 사용자/assistant 메시지 또는 양의 세션 비용이 관찰되면 전용 종료 코드 21을 반환하며 Swift는 `unexpectedModelActivity`로 분류하고 중단한다. 이는 **관찰 가능한 신호에 대한 방어**이지 숨은 서버 비용이 없다는 보증은 아니다. helper의 `CLAUDE_CODE_MAX_RETRIES=0`도 SDK 내부 모든 네트워크 재시도 부재를 증명하지 않는다. 다음 시험은 별도 사용자 승인 전까지 실행하지 않는다.
- 정적 환경: Node 24.22.1, Claude CLI 2.1.292, Agent SDK 0.3.169(`node >=18`), helper 문법·SHA-256, 분리 앱 번들 ID, 임시 runtime의 SDK 모듈 링크를 확인했다. `scripts/prepare-claude-real-two.sh`는 코드와 진단 파일만 준비하며 helper를 실행하지 않는다. 현재 SDK는 저장소 밖 임시 `node_modules`에 링크되어 있다. 다른 Mac에서 쓰려면 지원 Node와 정확한 SDK 의존성 설치/번들, 기존 Claude CLI 로그인, helper 경로·서명·배포, 실험 API 호환성을 따로 검증해야 한다. 지금 빌드만으로 이식 가능하다고 볼 수 없다.
- 검증: Node 정책 테스트 **9개**, 전체 XCTest **436개**, 개발 플래그 관련 XCTest **25개** 통과. 일반 Debug·Release 및 분리 개발 Debug 빌드, `node --check`, `git diff --check` 통과. 첫 전체 테스트는 새 테스트의 Swift 타입 생략 표기 오류로 컴파일되지 않았고 수정 후 재실행했다. 다음 전체 실행에서 Mock 상태줄의 15분 신선도보다 긴 대기값을 기대한 시험이 실패해 300초 시점으로 고친 뒤 최종 전체 테스트가 통과했다. 이는 테스트 조건 수정이며 제품 동작을 바꾸지 않았다.
- **미검증:** 실제 두 번째 SDK 성공, 300초 실시간 간격, 실제 401/403/429 오류 형태와 비용, 서버 데이터 신선도, 다른 Mac 배포, 장시간 안정성, 실제 절전 복귀. 정식 앱의 자동 조회는 계속 비활성이다. 📸 캡처 추천: 시험 전에는 분리 앱의 번들 ID와 비민감 예약 파일·진단 구조만 캡처하고 실제 계정 화면의 수치/시각은 공개하지 않는다.

## 별도 개발 앱의 승인된 단발 실계정 검증 (2026-10-31)

- 기존 Mock 앱 검증 변경 8개 파일을 `462c278`로 커밋했다. 미추적 GPU 로그 2개는 제외·보존했다. 실계정 검증 앱은 저장소 밖 `/private/tmp/tokenly-claude-real-once-20261031/DerivedData/Build/Products/Debug/Tokenly.app`에 별도 번들 ID `io.github.jbbdyee.tokenly.clauderealone.20261031`로 빌드했다. `.standard` 설정 도메인은 기존 설치 앱과 Mock 앱의 번들 ID와 다르다. 설치 앱과 Mock 앱을 교체하거나 종료하지 않았다.
- 실행 조건은 개발 컴파일 플래그, 명시적 활성화 환경 변수, **실계정 검증 번들 ID**, Node/helper/CLI 절대 경로를 모두 요구한다. `ClaudeDirectRefreshGate(maxAttempts: 1)`가 두 번째 직접 조회를 막는다. 이 앱의 `ExternalProviderStore.start()`는 최초 확인 뒤 반복 타이머와 절전 감시를 등록하지 않는다. Codex는 개발 빌드의 비활성 Provider이고 AGY는 기본 숨김 설정이다. 실제 모델 메시지 없이 `query()` 초기화와 공식 Agent SDK `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET()`만 사용했다.
- Node 24.22.1, Claude CLI 2.1.292, Agent SDK 0.3.169, helper SHA-256 일치와 모듈 해석을 사전 확인했다. 일반 샌드박스 XCTest는 SwiftUI 매크로 서버 오류로 중단됐고, 같은 소스의 승격 실행에서 관련 XCTest 13개가 통과했다. 별도 개발 Debug 빌드도 성공했다. 최초 셸 백그라운드 시작은 앱 프로세스가 즉시 종료됐고 비민감 진단 파일이 비어 있었다. 지속 세션으로 다시 시작했을 때 승인된 SDK 조회가 **1회** 완료됐다. 이것은 첫 시도에서 조회가 실행됐다는 의미가 아니다.
- 비민감 진단 결과: SDK 직접 조회 성공, 5시간·7일 창 모두 유효, 오류 코드 없음, 조회 소요 **2.085초**. Swift `ExternalProviderStore`는 직접 조회 출처, 두 창, 직접 조회 성공 시각 존재를 기록했다. 진단 파일에는 실제 사용률·초기화 시각·계정 식별자·원본 JSON·인증 정보를 쓰지 않았다. SDK 내부의 네트워크 요청 횟수와 서버 데이터 신선도는 측정하지 못했다. 이번 프로세스에서 모델 메시지·양의 세션 비용을 직접 관측하는 별도 진단은 없으므로 과금 부재를 새로 확정하지 않는다.
- **화면은 사용자 확인 대기:** Swift Store까지 전달된 것은 확인됐으나 실계정 Claude 팝오버와 메뉴 막대의 실제 표시는 아직 사용자가 보지 않았다. 검증 앱을 실행 상태로 유지해 Claude 5시간·7일 항목과 `SDK 조회 마지막 성공` 문구의 존재만 확인받는다. 실제 숫자·시각 캡처는 공유하지 않는다. statusLine 대체 및 다른 서비스 회귀는 이전 Mock/전체 테스트 범위이며 이번 실계정 조회에서 독립 검증하지 않았다.
- 남은 위험: SDK API의 실험적 계약, 다른 Mac의 Node/SDK 배포, 인증 오류 실제 형식, 서버 신선도, 반복 호출 한도, 장시간 자동 폴링과 화면 표시는 미검증이다. 이번 검증 결과로 정식 제품 자동 폴링을 활성화하지 않는다. 📸 캡처 추천: 실계정 화면은 민감 값이 있어 공개 캡처를 권장하지 않는다. 기술 블로그에는 비민감 상태 파일과 단발 게이트 구조만 사용할 수 있다.

## 개발 앱 가상 응답 사전 검증 (2026-10-31)

- 시작 상태: `experiment/claude-usage-refresh` / `b77d345`, 미추적 GPU 로그 2개 외 작업 트리 깨끗함. 기존 개발 앱의 번들 ID는 `io.github.jbbdyee.tokenly.claudeverify.20261031`, 표시명은 `Tokenly Claude 검증`, 경로는 `/private/tmp/tokenly-claude-dev-20261031/DerivedData/Build/Products/Debug/Tokenly.app`이다. 같은 번들 ID의 `.standard` UserDefaults 도메인은 설치 앱과 분리된다. Node 24.22.1, Claude CLI 2.1.292, SDK 0.3.169 설치 경로와 helper 파일 존재를 확인했지만 **실제 SDK/계정 조회는 실행하지 않았다**.
- 개발 빌드에 `TOKENLY_CLAUDE_DEV_MOCK=1` 전용 제한을 추가했다. 이 모드에서는 `/bin/sh`·`/usr/bin/true`·`/private/tmp/tokenly-claude-dev-mock-*` helper 경로만 허용하며 임시 상태줄 파일을 읽는다. 개발 빌드의 Codex Provider는 비활성 가짜 Provider이고 기본 화면에는 Claude만 표시된다. 따라서 가상 앱 실행이 Codex·AGY 인증 조회를 시작하지 않는다. 설정 화면의 연결 변경 버튼도 개발 빌드에서 숨겼다. 정식 빌드는 기존 Provider·기본값을 유지한다.
- 임시 Mock helper는 가상 5시간·7일 JSON만 출력하고 호출 시각만 기록한다. 가상 상태줄 파일도 임시 경로에 있다. 개발 앱 프로세스를 실행했지만 팝오버를 열기 전 가짜 helper 호출은 **0회**였다. 별도 개발 도메인에는 메뉴 막대 상태 항목만 생겼다. UI 자동화 native pipe가 시작되지 않아 화면은 직접 확인하지 못했다. 사용자에게 `Tokenly Claude 검증` 아이콘의 Claude 항목과 `가상 데이터` 안내 캡처를 요청했다. 프로세스 실행/가짜 helper 호출과 실제 Claude 조회 성공을 혼동하지 않는다.
- **사용자 화면 확인(후속):** 개발용 Mock 팝오버 캡처에서 가상 5시간 80%·7일 65% 잔여, 메뉴 막대와 팝오버 값 일치, 초기화 시각·가상 SDK 마지막 성공 시각·가상 데이터 안내를 확인했고 눈에 띄는 겹침/잘림은 없었다. 이 캡처는 가상 데이터 UI 검증이며 실제 SDK 호출·계정 조회의 증거가 아니다. 별도 calls.txt에는 호출 수가 기록되지 않아 프로세스 실행 횟수는 이 파일로 확정하지 않는다.
- Mock 통합 XCTest에서 첫 직접 결과가 Store에 반영되고 다음 가짜 실패 뒤 같은 성공 시각/값이 보존됨을 확인했다. 개발 조건 XCTest 13개와 일반 전체 XCTest 430개, 개발 Debug·일반 Release 빌드가 통과했다. 화면의 가상 직접 조회 값과 시각 문구는 사용자 캡처로 확인했고, 상태줄 폴백·실패 화면은 자동 테스트 범위다. 현재 개발 앱은 Mock으로만 실행 중이며 실제 SDK 호출이 가능한 환경 변수는 전달하지 않았다. 별도 임시 사전점검 폴더에 최신 helper 코드만 복사하고 기존 SDK `node_modules` 링크를 두어 Node 문법·SDK 모듈 경로 해석과 helper SHA-256 일치를 확인했다. SDK import, helper 실행, 인증 접근은 없었다.


## 개발 앱 전용 자동 조회 구현 (2026-10-31)

- `scripts/build-claude-dev.sh`는 저장소 밖 `/private/tmp/tokenly-claude-dev-20261031/`에 `TOKENLY_CLAUDE_DEV` 컴파일 조건과 별도 번들 ID `io.github.jbbdyee.tokenly.claudeverify.20261031`을 가진 Debug 앱을 빌드한다. 표시명도 `Tokenly Claude 검증`으로 구분한다. 빌드 스크립트는 앱을 실행하거나 SDK를 호출하지 않는다. 별도 번들 ID로 `.standard` UserDefaults 도메인이 분리되며, 기존 statusLine 수신 파일은 읽기 전용 폴백으로 유지한다. 개발 앱 설정 UI에서는 기존 Claude·AGY 연결 변경 버튼을 숨겼다. 기존 연결·설정·설치본은 변경하지 않았다.
- 개발 빌드에서도 런타임 `TOKENLY_CLAUDE_DEV_ENABLE=1`과 Node/helper/Claude CLI 절대 경로 3개를 명시해야 직접 조회 route가 생성된다. 누락 시 statusLine 전용이다. 정식 빌드에는 이 연결 코드가 컴파일되지 않는다. 개발 앱이 실행될 때 Codex·AGY 기존 경로는 남아 있으므로 실제 계정 검증 단계에서 별도 영향 점검이 필요하다. 이번에는 개발 앱을 실행하지 않았다.
- `ExternalProviderStore`의 기존 300초 타이머가 개발 앱의 Claude route를 조건부 검사한다. 별도 `ClaudeDirectRefreshGate`가 성공 뒤 최소 300초, 중복 진행 중 요청 거부, 일시적 실패 뒤 5/10/20/40/60분 백오프를 담당한다. 401/403, SDK 부재·비호환은 자동 조회를 중지하고, 429는 `Retry-After`가 현재 helper에서 전달되지 않으므로 자동 조회를 중지한다. 절전 복귀 알림은 개발 빌드에서만 기한 조건을 다시 검사한다. 이 주기는 공식 Anthropic 호출 제한이 아닌 초기 개발 정책이다. statusLine은 각 검사에서 계속 독립적으로 읽으며 마지막 직접 성공 시각을 실패 시 바꾸지 않는다.
- helper는 오류 원문을 출력하지 않고 `status`, `statusCode`, `response.status`의 숫자 값이 있으면 401/403/429만 전용 종료 코드로 변환한다. Swift Adapter는 이를 별도 오류로 바꾼다. 실제 SDK 오류 객체 형태와 `Retry-After` 지원은 미검증이므로 오류를 실제로 정확히 분류한다고 단정하지 않는다. 미지 SDK 오류(전용 종료 코드 22)는 자동 조회를 중지하고, 별도의 프로세스 전송 실패만 백오프한다. SDK/helper/Node가 없으면 앱은 statusLine으로 계속 동작한다.
- 검증: 기존 정책 Node 테스트 9개, 전체 XCTest **429개** 통과. 일반 Debug·Release 및 별도 ID 개발 Debug 앱 빌드 성공, `node --check`, Xcode 프로젝트 plist, `git diff --check` 통과. 개발 앱 번들 ID/표시명은 빌드 산출물에서 확인했다. CoreSimulator 버전 경고는 있었으나 macOS 테스트·빌드는 종료 코드 0이었다. SDK helper·실계정 자동 조회는 실행하지 않았다.
- 개발 UI는 직접 조회 성공 시각과 상태줄 수신 시각을 별도로 표시하며 개발 검증 표식을 쓴다. 두 창이 서로 다른 출처이면 스냅샷 시각은 더 오래된 수신 시각으로 보수적으로 잡는다. 창별 출처를 UI에 정확히 붙이는 상세 표시와 장시간 신선도 검증은 남았다. 현재 helper는 개발용 절대 경로 의존이며 lockfile·번들링·서명·다른 Mac 실행 검증이 없다. 실제 SDK 실행·계정 조회·모델 요청·장시간 자동 폴링은 이번 단계에 없었다.


## 개발 앱 완성·검증 계획 (2026-10-31, 계획만 확정)

**현재 상태:** `ClaudeDirectUsageProvider`/파서, SDK 자식 프로세스 Adapter·개발 helper, 기본 비활성 `ClaudeOptionalUsageProvider`와 Mock 테스트가 있다. 승인된 단발성 실계정 조회에서는 두 창의 사용률과 초기화 시각 형태가 확인됐다. 현재 `ExternalProviderStore` 기본 Claude Provider는 `ClaudeSubscriptionProvider`이고 앱 진입점·타이머·UI에서 SDK 실행기를 만들지 않는다. 이번 계획 단계에는 계정 조회, helper 실행, 자동 폴링 및 설치 앱 변경이 없다.

### 격리된 개발 앱과 연결 순서

1. 별도 소스/DerivedData/실행 경로와 번들 ID(예: `io.github.jbbdyee.tokenly.claudeverify.20261031`)로 개발 앱을 빌드한다. UserDefaults 도메인·Tokenly 앱 데이터 쓰기 경로를 분리하고 `/Applications/Tokenly.app`과 기존 statusLine 설정은 그대로 둔다. statusLine 폴백은 기존 수신 파일을 읽기 전용으로 이용하되 재연결 명령은 실행하지 않는다. Claude 인증은 실계정 단계에서 SDK/CLI의 공식 로그인 재사용만 허용하며 파일·Keychain 비밀값을 직접 읽거나 복사하지 않는다.
2. 개발 빌드 전용 구성에서만 `ClaudeSDKProcessRunner`와 `ClaudeOptionalUsageProvider.experimentalDirect`를 명시적으로 만들고 Store에 주입한다. 사용자의 별도 개발 앱 선택 전에는 비활성으로 둔다. 기존 앱/정식 빌드에는 토글과 실행 경로를 추가하지 않는다. 개발 앱 UI는 직접 조회와 statusLine의 출처·각 마지막 성공/수신 시각을 구분하며, 오래된 이전값을 최신 성공으로 표시하지 않는다. `마지막 수신`·`Claude 사용 중 갱신`이라는 현행 문구는 직접 조회가 활성화된 개발 앱에 그대로 쓰지 않는다.
3. 직접 조회 스케줄러는 statusLine 파일 재읽기 타이머와 분리한다. **초기 제안 정책**은 성공 후 최소 5분 간격의 조건부 검사다. 명시적으로 활성화하고 최초 조회를 승인받기 전에는 실행하지 않는다. 요청 중에는 중복 금지; 절전 복귀와 팝오버 재열기는 기한이 지났을 때만 1회 요청한다. 일시적 실패/타임아웃은 5·10·20·40·60분 지수 백오프(상한 60분)를 제안하고, 성공 시 초기화한다. 수동 조회의 정책·호출 제한은 실측 후 정한다. 이 수치는 공식 호출 제한이 아니라 안전한 개발 기본안이며 서버 제한 확인 전 제품 정책으로 확정하지 않는다.
4. `rate_limits_available=true`/`rate_limits=null`, 필드 부재/부분 성공, 잘못된 숫자·시각은 가용한 창만 채택하고 마지막 성공값의 원래 시각을 보존한다. 직접 조회 실패 시 statusLine을 창별로 사용한다. 15분 초과 값은 이전 데이터로만 표시하는 임시 신선도안을 검토한다. 401/403은 자동 조회를 멈추고 재로그인을 자동 실행하지 않는다. 429는 현재 `Retry-After`를 전달하지 못하므로 자동 중지한다. helper는 숫자 상태 필드만 401/403/429로 분류하지만 **실제 SDK 오류 형태를 확인하기 전에는 이 분류가 완전하다고 볼 수 없다.** 타임아웃·취소는 프로세스 그룹 정리와 상태 복원을 확인한다.
5. 개발 환경에서는 Node·SDK 0.3.169·helper·Claude CLI의 절대 경로를 주입한다. 다른 Mac 배포 후보는 호환 Node와 정확한 SDK 버전을 lockfile로 고정해 앱 내부에 포함하고 helper 무결성/서명·notarization·아키텍처·최소 macOS·Claude CLI 탐색/버전·오프라인 누락을 시험하는 것이다. 현재 package.json에는 lockfile이 없고 `scripts/release.sh`도 이 세 가지를 번들링하지 않는다. 외부 `node`/개발용 `node_modules` 절대 경로에 의존하는 빌드는 다른 Mac에서 실행 가능하다고 판정하지 않는다.

### 단계별 통과 기준과 중단 조건

| 단계 | 통과 기준 | 실패·보류 기준 |
| --- | --- | --- |
| Mock | 5시간·7일 및 부분/무값, 0% 잔여, 시각 파싱, 출처·성공 시각 보존, statusLine 폴백; 401/403/429·타임아웃·취소·중복·백오프·절전 가상 시계; 기본 빌드 SDK 호출 0회 | 이전값이 새 성공으로 표시되거나 중복/승인 없는 호출 |
| 개발 앱 통합 | 별도 ID·설정·쓰기 경로 확인, 직접 조회 기본 OFF, 명시적 개발 앱 선택 뒤 Mock helper로 화면/Store/타이머 검증; Codex·AGY 전체 회귀 테스트와 Debug·Release 빌드 | 설치 앱·기존 설정·statusLine 연결 변경, 출처/시각 혼동 |
| 실계정 (별도 승인) | 최초 1회, 이후 승인된 기간의 조건부 갱신에서 두 창과 초기화 시각·CLI 횟수/간격·시간·자원·오류를 비민감 형태로 검증; 모델 메시지·양의 비용 징후 없음 | 추가 인증, 예상 밖 모델 이벤트/비용, 401/403/429, 과도한 프로세스, 결과 미신뢰 시 즉시 중단 |
| 다른 Mac/배포 | 클린 macOS 14/15 및 지원 아키텍처에서 Node/SDK/helper/CLI 탐색·서명·Gatekeeper·업데이트·미설치/버전 불일치·오프라인 오류; v0.3.0 설정과 기존 statusLine 보존 | 개발자 Mac 전용 경로, 서명 실패, 인증/설정 변경, 공식 SDK 호환성 미확인 |

**출시 게이트:** 모든 단계와 실제 사용자 화면·장시간 안정성, 호출 제한/비용·약관 및 실험 API 변경 대응이 검증되기 전에는 v0.3.0 또는 다음 정식 버전에 포함하지 않는다. SDK의 401/403/429 형태, 공식 무과금/자동 폴링 계약, 서버 데이터 신선도, 다른 Mac 인증 재사용은 미확인이다. 블로그 본문은 작성하지 않는다.


## 선택적 조회 경로 준비 (2026-10-31)

- 새 `ClaudeOptionalUsageProvider`는 기본적으로 기존 statusLine Provider만 호출한다. 개발자가 별도 route를 명시적으로 주입할 때에만 이미 구현된 `ClaudeDirectUsageProvider`를 호출한다. 앱 진입점·기본 Store·설정·타이머에는 이 route를 연결하지 않았으므로 설치본과 빌드된 기본 앱에서 SDK 자동 조회는 실행되지 않는다. 기존 미커밋 단발성 실계정 조회 기록은 아래에 보존했다.
- 직접 조회 성공값과 statusLine 값은 5시간·7일 창별로 선택한다. 직접 조회 실패 시 이전 직접 성공값을 보존하고 statusLine으로 보충한다. 창별 출처 수신 시각과 전체 스냅샷의 보수적 시각을 분리한다. 오래된 값은 최신값으로 표시하지 않는다. 이 정책은 가상 데이터 Mock으로만 검증한다.
- `package.json`에는 SDK 0.3.169만 고정돼 있고 lockfile/Node/SDK/helper의 앱 번들링·서명·다른 Mac 실행은 준비되지 않았다. 현재 Claude UI는 statusLine의 `마지막 수신`을 전제로 하므로 제품 opt-in 전에 직접 조회 출처 표시가 필요하다. 401·403·429 실제 SDK 오류 형식, 반복 호출 제한, 취소 후 외부 프로세스 상태, SDK API 변경, 인증 캐시 영향은 미검증이다. SDK 조회 실패는 제품의 statusLine을 계속 사용할 수 있게 해야 한다.
- 검증: 실험 정책 테스트 9개 통과, 선택 경로 XCTest 5개 및 전체 XCTest 423개 통과. Debug·Release 빌드, Xcode 프로젝트 plist 검사, `git diff --check` 통과. 실제 SDK helper는 실행하지 않았다.
- 이번 단계에서 실제 Claude 계정 조회, SDK helper 실행, 모델 요청, 자동 폴링, 설치 앱 변경은 없었다. 블로그 소재는 실험적 SDK 경로를 분리하고 출처·시각을 혼동하지 않는 정책 및 배포 경계다. 블로그 본문은 작성하지 않았다. 📸 캡처 추천: 향후 사용자 선택 UI가 구현된 뒤 일반 Claude 화면과 직접 조회 출처 표시를 비교할 수 있는 화면; 현재는 캡처할 제품 UI가 없다.


2026-10-31 · 브랜치 `experiment/claude-usage-refresh` · 승인된 단발성 조회 총 4회 완료

## 격리 래퍼를 통한 네 번째 단발성 실계정 조회 (2026-10-31)

- 사용자가 승인한 `/private/tmp/tokenly-claude-usage-preflight-20261031/verify-once.mjs`를 **정확히 1회** 실행했다. 직전 점검에서 브랜치 `experiment/claude-usage-refresh`, HEAD `1f0783a`, 기존 문서 미커밋 변경과 GPU 로그 2개를 확인했다. helper 사본 SHA-256은 저장소 원본과 일치했고 두 스크립트의 `node --check`, Node/Claude CLI 존재, SDK `0.3.169` 경로 해석을 확인했다. 추가 로그인·인증 정보 추출·모델 프롬프트·자동 재시도는 없었다.
- **비민감 결과:** 래퍼 성공, 오류 없음, `rate_limits_available=true`, `rate_limits=object`; `five_hour`와 `seven_day` 모두 객체, `utilization`은 각기 숫자이며 0–100 범위 안, `resets_at`은 각기 문자열이며 래퍼의 ISO 8601 정규식·`Date.parse` 검사 통과. 경과 시간 약 **1,998 ms**. 원본 JSON, 실제 사용률·시각, 계정·인증 정보는 출력·저장하지 않았다. 이 검사는 현재 응답의 **형태**를 확인한 것이며 서버 데이터의 최신성·각 창의 의미까지 입증하지 않는다.
- helper는 사용자 메시지를 생성하지 않는 generator로 initialize 후 `get_usage` 제어 요청을 한 번 호출한다. 사용자/assistant 메시지가 관찰되거나 응답의 양의 세션 비용이 감지되면 성공 출력을 하지 않도록 되어 있다. 이번 성공은 이 검사에서 그런 징후가 **관찰되지 않았음**을 뜻한다. 래퍼는 별도의 모델 이벤트/비용 수치를 출력하지 않았고 서버 측 숨은 작업·최종 과금 정책은 확인할 수 없다. 모델 추론·유료 대화 요청을 의도적으로 보내지 않았다.
- 이전 세 번째 조회에서는 5시간 초기화 시각이 `null`이었으나 이번에는 두 창 모두 문자열이었다. 서버/계정 상태에 따라 nullable 필드가 바뀔 수 있다는 관찰이며 원인은 확정하지 않는다. 이전 두 차례의 차단 변수 조건에서 값 미확인/`true/null`, 세 번째와 이번의 변수 미설정 조건에서 객체가 온 차이는 변수 영향 가설을 강화하지만 시간·서버 캐시를 통제한 인과 실험은 아니다.
- **제품 판정:** 공식 SDK의 실험 API를 이용한 단발성 무프롬프트 조회로 표시 가능한 두 창의 필드가 실제 계정에서 반환될 수 있음을 확인했다. 그러나 인증 캐시·상태 파일 변경 여부를 이번에 측정하지 않았고, 401/403/429의 실제 오류 형태, 반복 호출 제한, 서버 신선도, 안정 API 계약, 제품 배포용 Node/SDK 번들링, 장시간 비용·이용 조건은 미검증이다. 기존 v0.3.0 앱·statusLine·설정은 직접 변경하지 않았고 SDK helper는 제품에 연결되지 않았다. 자동 폴링과 정식 적용은 **보류**한다.

**블로그 소재 판단용:** 같은 실험 API라도 `resets_at`이 앞선 조회에서는 `null`, 이번에는 유효한 형식 문자열이었다. nullable 응답을 고정 계약으로 오판하지 않고, 민감한 사용량을 출력하지 않는 래퍼로 필드 존재·형식만 재현한 과정이 핵심이다. 블로그 본문은 작성하지 않았다.


## 실계정 단발성 재검증 준비, 실행 보류 (2026-10-31)

- 시작 Git: `experiment/claude-usage-refresh` `1f0783a`, 미추적 GPU 로그 2개 외 변경 없음. 제품 Provider·Store·타이머는 그대로 비활성이다. 이 단계에는 **SDK helper 실행, 계정 조회, 모델 요청, 인증 저장소 접근이 없었다**. RAM-02 조사는 재개하지 않았다.
- 공식 SDK `0.3.169`의 공개 타입·패키지 구현에서 `Query.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET()`가 CLI에 `get_usage` **제어 요청**을 보낸다는 것을 다시 확인했다. [Anthropic SDK 변경 기록](https://github.com/anthropics/claude-agent-sdk-typescript/blob/main/CHANGELOG.md#03169)은 세션 비용과 플랜 한도를 반환하는 실험 API로 소개한다. 메서드는 프롬프트를 보내는 인터페이스가 아니며 helper의 입력 generator는 사용자 메시지를 생성하지 않는다. 하지만 Anthropic이 이 경로의 **모델 턴·과금 절대 불발생** 또는 개인 구독 제3자 자동 조회를 안정적으로 보증한 계약은 확인하지 못했다. 이전 승인 조회 3회에서 모델 메시지·양의 세션 비용이 관찰되지 않았다는 실측과 공식 보증을 구분한다.
- 실행 환경: 기존 Node `v24.22.1`, Claude Code CLI `2.1.292`, 저장소 밖 설치 SDK `0.3.169`를 읽기 전용으로 확인했다. `/private/tmp/tokenly-claude-usage-preflight-20261031/`에 현재 helper·패키지 선언의 사본을 두고 기존 임시 SDK `node_modules`에만 심볼릭 링크했다. helper 사본의 SHA-256이 저장소 원본과 일치하고 문법 검사·SDK 모듈 **해석만** 성공했다. SDK 코드를 import하거나 helper를 실행하지 않았다. 인증 파일·토큰은 이 경로에 복사하지 않았다. Node·SDK·CLI의 버전 호환성은 이전 실계정 성공 조회가 있더라도 향후 안정 계약이 아니다.
- 부모 환경의 비필수 트래픽 차단 변수, API key/OAuth override, `ANTHROPIC_BASE_URL`, Node 주입 변수는 **존재 여부만** 검사했고 모두 없었다. Swift Adapter와 Node helper는 자식 환경에서 해당 변수들을 제거하도록 작성돼 있다. 기존 세 번의 SDK 실험은 Claude Code 로그인 상태를 SDK/CLI가 자체 재사용해 제어 요청에 응답했지만, 이번 사전 점검에서는 현재 인증 상태를 다시 읽거나 로그인 명령을 실행하지 않았다.
- `verify-once.mjs`를 같은 임시 폴더에 준비하고 `node --check`만 했다. 사용자가 별도로 승인하면 이 래퍼는 helper를 **한 번** 실행하고 stdout의 최소 필드값을 메모리에서 분류해 `rate_limits_available`, 컨테이너/창 존재, 사용률 숫자·범위, 초기화 시각 자료형·ISO 파싱 여부, 성공·종료 코드·소요 시간만 출력하도록 설계됐다. 원본 응답·실제 비율·시각·계정·인증 정보 및 stderr는 기록하지 않는다. 35초 상한, 출력 크기 상한, 재시도 없음. **래퍼도 이번 단계에는 실행하지 않았다.**
- 예상 부작용: 실제 실행 시 공식 SDK/CLI의 초기화와 사용량 조회를 위한 네트워크 통신, 정상 인증 캐시 갱신, CLI 상태·로그 파일 쓰기는 가능하다. `settingSources: []`, 도구 비활성, 세션 영속화 비활성으로 범위를 줄였지만 관리 정책·CLI 내부 동작과 서버 측 과금 정책까지 보증하지 않는다. 추가 인증 요구, 모델 메시지/양의 세션 비용 징후, 401·403·429, 미지 응답이면 재시도하지 않고 중단한다. 401·403·429의 SDK 오류 형태는 아직 미확인이고 현재 helper는 원문을 숨겨 일반 실패로만 보고한다.
- **승인 대기 계획:** 임시 경로의 `verify-once.mjs`만 단 1회 실행한다. 결과는 위 비민감 분류만 확인하고, 두 창의 값과 시각을 출력하지 않는다. 이후 SDK/CLI 프로세스 종료와 Git·설치 앱 불변을 확인한다. 실제 사용량 조회가 성공해도 데이터 신선도, 반복 호출 제한, 제품 자동 폴링 적합성은 여전히 별도 검증이 필요하다. 이번 문서 변경은 조회 승인이 아니다.

**블로그 소재 판단용:** 실험 API를 통한 무프롬프트 제어 요청은 코드 경로와 세션 비용 관찰로 평가할 수 있지만, 그것만으로 공식 무과금 계약을 주장할 수 없다. 인증 원문을 보지 않고 기존 로그인 재사용과 네트워크·상태 파일 부작용을 분리해 검증하는 절차가 기술적 핵심이다. 블로그 본문은 작성하지 않았다.

## SDK 자식 프로세스 Adapter 구현과 가짜 helper 검증 (2026-10-31)

이번 단계는 **실계정 조회·모델 요청·인증 저장소 접근·자동 폴링 없이** 코드와 가짜 프로세스만 검증했다. 공식 SDK `0.3.169` 타입의 `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET()`는 프롬프트 없는 query 세션의 제어 요청으로 선언돼 있다. 이것은 실험 API이며 안정 계약이 아니다. 기존 제품의 Claude statusLine Provider와 `ExternalProviderStore`는 수정하지 않았다.

- **실행 경계:** `ClaudeSDKProcessRunner` actor가 `ClaudeProcessExecuting`을 주입받고 한 인스턴스의 진행 중 요청을 거부한다. `ClaudeSubprocessExecutor`는 Node 런타임, helper, Claude CLI의 절대 경로가 모두 주어질 때만 `posix_spawn`으로 별도 프로세스 그룹을 시작한다. 표준 입력과 오류 출력은 `/dev/null`, 표준 출력은 메모리에서 최대 16 KiB만 수집한다. 상한 초과·타임아웃·Task 취소 시 그룹에 종료 신호를 보내고 완료를 기다린다. 비정상 종료·종료 코드·빈/잘못된 JSON은 SDK 원문 없이 분류한다. 오류 원문을 기반으로 401·403·429를 임의 판정하지 않는다.
- **자식 환경:** Swift 실행기는 부모 딕셔너리에서 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, API key/OAuth override, `ANTHROPIC_BASE_URL`, Node 주입 변수를 제거해 자식에게만 전달한다. Node helper도 SDK가 시작할 Claude Code 자식 환경에서 같은 제한 변수와 인증 override를 제거한다. 부모 프로세스, 사용자 설정, Keychain, 로그인 파일은 직접 수정·복사·조회하지 않는다. SDK/CLI의 정상 상태 파일 쓰기 가능성은 실제 실행 단계에서 별도 평가가 필요하다.
- **helper:** `experiments/claude-usage-refresh/claude-usage-helper.mjs`는 개발 전용이다. SDK를 동적 import하고 사용자 메시지를 생성하지 않는 generator로 initialize 후 usage 제어 요청을 **1회만** 호출하도록 작성했다. 사용자/assistant 메시지 또는 양의 세션 비용이 관찰되면 성공 출력을 하지 않는다. 성공 stdout은 `rate_limits_available`와 `five_hour`/`seven_day`의 `utilization`·`resets_at`만 남기고 원본 응답·계정·세션·인증 정보는 버린다. 오류 원문과 SDK stderr는 기록하지 않는다. 실제 SDK helper는 이번 단계에서 **실행하지 않았다**. 코드 구조가 모든 숨은 모델 작업을 배제한다는 실계정 보증도 아니다.
- **배포 경계:** `package.json`은 `@anthropic-ai/claude-agent-sdk`를 `0.3.169`로 고정 선언했지만 npm 설치, lockfile, Node/SDK/helper 번들링, 앱 서명·업데이트·런타임 위치 결정은 하지 않았다. 현재 설치 v0.3.0과 빌드된 실험 앱 어디에서도 Adapter를 만들지 않으며 배포 완료 기능으로 간주하지 않는다. 추후 SDK/CLI 호환 버전, Node 포함 여부, 코드 서명, 프로세스 비용을 검토해야 한다.
- **검증:** 이전 Node 정책 테스트 **9개 통과**. `ClaudeSDKProcessRunnerTests` 5개는 가짜 셸 helper와 Mock executor로 환경 제거·성공 JSON, 일반/신호 종료·잘못된 JSON, 타임아웃·출력 제한, 중복 거부·취소를 검증했다. 전체 XCTest **419개 통과**, Debug·Release 빌드 성공, `node --check`, Xcode 프로젝트 plist, `git diff --check` 통과. XCTest 호스트는 Claude CLI·SDK를 실행하지 않았다. `ClaudeDirectUsageProvider`의 기본 runner는 계속 비활성이다.

**남은 확인:** 실제 SDK의 401·403·429 전달 형식, 인증 캐시 영향, 서버 시각·데이터 신선도, 로그·프로세스 자원, 자동 호출 제한, helper/SDK/Node 배포는 미검증이다. 단일 runner actor의 중복 차단은 앱 전체에 인스턴스가 여러 개일 때의 전역 중복 방지가 아니다. 직접 조회 stale 기준과 자동 주기는 아직 정하지 않는다. SDK helper의 실제 단발성 호출과 제품 통합은 각각 별도 승인 후 진행한다.

**블로그 소재 판단용:** 공식 SDK의 실험적 제어 요청을 앱 밖 자식 프로세스로 격리하면서 모델 메시지 경로와 출력 필드를 제한하고, 인증 원문을 앱 로그로 전파하지 않는 설계 과정. 타이머·취소 시 프로세스 그룹을 정리하고 개발 전용 helper를 제품 기능으로 오인하지 않도록 배포 경계를 명시한 점도 핵심이다. 블로그 본문은 작성하지 않는다.

## Swift Provider와 Mock 연결 단계 (2026-10-30)

이 단계는 실제 계정·SDK·모델·인증 저장소에 접근하지 않았다. 기존 미커밋 Node 정책·문서를 보존하고 Node 테스트 **9개 통과**를 기준으로 했다. `src/Tokenly/Providers/ClaudeDirectUsageProvider.swift`에 `ClaudeUsageRunning` 실행 경계, 항상 비활성인 기본 runner, `ClaudeDirectUsageParser`, `ClaudeUsageSelection`을 구현했다. Swift 파일을 Xcode 타깃 Sources에 등록했다. SDK 호출 adapter, `ExternalProviderStore`·팝오버 연결 및 자동 타이머는 **없다**. 설치 v0.3.0의 Claude 동작은 statusLine 그대로다.

- Mock `Data` 응답만 파싱한다. `rate_limits_available=true`이고 컨테이너가 객체일 때 각 창의 `utilization`이 JSON 숫자, 유한하고 0–100인지 독립적으로 검사한다. 잔여율은 `100 - utilization`이며 사용률 100은 유효한 잔여율 0이다. 부재·`null`·bool·문자열·범위 밖 값은 해당 창을 제외한다. `true/null` 또는 유효 창 0개는 `.noData`로 처리해 한도 미지원이라고 단정하지 않는다. 잘못된 JSON은 `.invalidResponse`다.
- `resets_at`은 ISO 8601 오프셋 포함 형식을 파싱하고 `null`·잘못된 형식은 `nil`로 둔다. 유효한 잔여율은 계속 보존한다. 로컬 조회 완료 `receivedAt`을 서버 측 갱신 시각으로 주장하지 않는다.
- 선택 모델은 5시간·7일의 값·출처·수신 시각을 따로 보존한다. 부분 성공은 새 창만 덮어쓰며 실패는 마지막 직접 성공 시각을 변경하지 않는다. 직접 조회의 freshness는 호출자가 주입하고 아직 확정하지 않았다. 신선한 직접 조회 → 신선한 statusLine → 이전 데이터 순으로 창별 선택한다. 기존 statusLine 15분 기준을 기본값으로 유지한다. UI 표현·저장 정책은 미구현이다.
- Runner 오류 유형에는 인증 필요, 권한 거부, rate limit, 타임아웃, CLI 부재, SDK 비호환, 전송 오류를 정의했다. **실제 SDK 오류 매핑·백오프·자동 폴링은 구현하지 않았다.** 이 경계는 향후 SDK 변경 시 실행 adapter만 교체하기 위한 것이다.
- `src/TokenlyTests/ClaudeDirectUsageTests.swift`의 **8개 XCTest 통과**: 정상·0% 잔여율, 창별 부재/null, `true/null`, 잘못된 자료형·범위, 초기화 시각 null/형식 오류, 비활성 기본 runner와 Mock 오류, 실패 보존·statusLine 대체·stale, 부분 성공 시각 보존. 전체 XCTest **414개 통과**, Debug·Release 빌드 성공, `git diff --check` 통과. 일반 샌드박스 XCTest는 SwiftUI 매크로 서버 응답 오류였고 승인된 Xcode 서비스 접근에서 동일 소스를 성공 검증했다. 빌드·테스트 산출물은 저장소 밖 임시 경로다.

**제품 적용 판단:** 현재 구조는 테스트 가능한 Swift 경계까지 구현됐으나 실제 SDK 호출과 앱 연결은 없다. 직접 조회 신선도, 401/403/429 오류 계약·호출 제한·인증 부작용·장시간 비용, 실제 statusLine과의 충돌·UI는 미검증이다. 자동 갱신 활성화에는 별도 설계·승인·검증이 필요하다. 블로그 소재로는 nullable SDK 응답을 창별 출처·시각으로 병합하면서 새 서버 조회와 로컬 파일 수신을 구분한 과정이 있다. 블로그 본문은 쓰지 않았다.

## 독립 조회 Provider 설계와 가상 응답 검증 (2026-10-30)

이번 단계는 **계정 조회·모델 요청·인증 접근 없이** 제품 코드를 읽고 `experiments/claude-usage-refresh/`에 순수 데이터 정책과 Node 내장 테스트만 추가했다. 실험 코드는 Tokenly 앱 타깃에 등록하지 않았고 SDK를 import하거나 프로세스·네트워크·파일을 실행하지 않는다. 제품 Provider, UI, 자동 폴링은 **미구현**이다.

### 현재 데이터 경계와 설계안

| 경로 | 입력과 시각 | 값 변환 | 데이터 신선도 |
| --- | --- | --- | --- |
| 현재 Claude statusLine | Claude Code 이벤트 `rate_limits.five_hour/seven_day.used_percentage`, Unix 초 `resets_at`; 브리지의 `captured_at`은 **로컬 수신 시각** | 유효한 창마다 `100 - used_percentage`; 초기화 시각이 없으면 `nil` | 파일 재읽기는 서버 조회가 아니다. 현재 Provider는 수신 후 15분 초과 시 stale |
| 실험적 SDK `get_usage` | `rate_limits_available`, nullable `rate_limits`; 각 창의 nullable `utilization`(0–100)·`resets_at`(ISO 8601 문자열). 수신 시각은 helper가 조회 성공 시 붙여야 함 | 각 창을 독립 검증한 뒤 `100 - utilization`; 100% 사용은 잔여 0% | 서버 데이터 시점은 SDK 응답에 별도 보장되지 않는다. 수신 시각을 서버 측 갱신 시각으로 부르지 않는다 |

제안하는 `ClaudeDirectUsageProvider`는 공식 SDK를 별도 자식 프로세스의 무프롬프트 제어 요청으로 호출하는 경계를 갖는다. 향후 제품 구현이 승인되면 자식 환경에서 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`를 제거하고, 응답을 **사용량 원문 없이** 필요한 창·오류 분류만 담은 내부 구조로 넘기도록 설계한다. 자식의 stdout/stderr·예외는 원문을 로그에 남기지 않는다. CLI 설치·인증·초기화·타임아웃·SDK 형식 변경은 별도 실패로 분류한다. 이 문단은 설계이며 현재 앱에 연결된 코드는 없다.

정책은 **창별 부분 성공**이다. `rate_limits_available=true`여도 `rate_limits=null`이면 한도 미지원 판정이 아니라 **데이터 미수신**으로 처리하고 마지막 성공값의 시각을 갱신하지 않는다. 컨테이너가 있더라도 5시간·7일 창은 각각 부재·`null`·잘못된 타입·범위 밖 숫자를 독립적으로 거른다. 유효한 숫자는 초기화 시각이 `null` 또는 잘못된 ISO 형식이어도 잔여율로 보일 수 있고, 시각은 **알 수 없음**으로 표시한다. 이때 리셋 시각을 추정하지 않는다. 적어도 한 창이 유효할 때만 직접 조회의 `lastSuccessAt`을 수신 시각으로 갱신하며, 다른 창의 이전 값·시각은 그대로 유지한다. 부분 성공을 전체 창의 동시 갱신으로 표시하지 않도록 창별 출처·수신 시각을 보존한다.

표시 선택안은 각 창에서 신선한 직접 조회를 우선하고, 그것이 없거나 오래됐으면 신선한 statusLine 값을 대체 표시한다. 둘 다 오래됐으면 마지막 값을 **이전 데이터**로만 표시하고 원래 수신 시각과 출처를 유지한다. 직접 조회 오류가 statusLine 파일의 `captured_at`을 바꾸지 않으며, statusLine 재읽기를 새 서버 조회로 세지 않는다. 현재 15분 statusLine stale 기준을 보존한다. 직접 조회의 stale 기준은 자동 갱신 주기·서버 신선도 계약이 없어 **미정**이며 실험 함수는 호출자가 이를 넘기도록 했다. 실제 제품의 `ExternalProviderStore`는 Claude 단일 Provider와 단일 상태를 가지므로 이 창별 병합·출처 시각을 구현하려면 별도의 좁은 변경과 UI 검증이 필요하다.

실패 정책 초안: 401은 인증 필요로 표시하고 **자동 재로그인·즉시 재시도 없음**; 403은 권한/대상 불명으로 표시하고 재시도 보류; 429는 가능한 공식 `Retry-After`와 충분한 보수적 하한 중 늦은 시각까지 중지하되 SDK가 헤더를 노출하지 않으면 임의의 짧은 주기를 가정하지 않는다. 네트워크·타임아웃·`true/null`은 일시적 데이터 미수신 후보로 분류하고 마지막 성공값 유지 및 지수 백오프·최대 간격 검토; 구체 주기는 서비스 계약 검토 전 **미확정**이다. SDK 메서드·타입 변경이나 미지 응답은 형식 오류로 다루며 자동 반복을 중단하고 statusLine을 유지한다. 진행 중 요청은 단일 in-flight gate로 중복 차단하고, 종료·취소 시 자식 프로세스 수명까지 정리한다. 초기 구현 전에 401/403/429 원인과 SDK 오류 전달 형식을 모의 프로세스로 확인해야 한다.

### 가상 데이터 테스트 결과

`node --test experiments/claude-usage-refresh/policy.test.mjs`: **9개 통과, 실패 0**. 두 창과 사용률 100→잔여율 0, 창별 부재·`null`, `true/null`의 데이터 미수신 판정, `resets_at`의 `null`·형식 오류, 잘못된 사용률의 창별 거부, 실패 시 성공값·시각 유지, 직접 조회 우선과 statusLine 대체, 오래된 값의 원래 시각 유지, in-flight·허용 시각 gate를 검증했다. 이 테스트는 SDK·CLI 호출, Swift Provider, 실제 앱 표시, 서버 신선도, 401/403/429 런타임, CPU·메모리, 자동 주기의 성공을 입증하지 않는다. 이번 단계에서 XCTest·Debug/Release 빌드는 실행하지 않았다(제품 코드 변경 없음).

**블로그 소재 판단용:** 두 출처가 같은 잔여율처럼 보여도 `captured_at`과 조회 수신 시각은 다른 의미다. `rate_limits_available=true`와 실제 창 데이터, 숫자 사용률과 초기화 시각의 유효성도 각각 다른 조건이다. 부분 성공을 전체 갱신으로 표시하지 않는 창별 출처·시각 설계가 핵심이다. 이 기록은 기술적 메모이며 블로그 본문은 작성하지 않았다.

## 비필수 트래픽 제한 변수를 제거한 세 번째 단발성 조회 (2026-10-30)

- 시작 상태: `experiment/claude-usage-refresh` HEAD `08a5817`; 추적 파일 변경 없이 미추적 GPU 로그 2개만 있었다. 공식 Agent SDK `0.3.169`와 Claude Code CLI `2.1.292`를 유지했다. 부모 환경의 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, 주요 Claude 트래픽 제한·인증 경로 변경 변수는 **이름의 존재 여부만** 검사했고 설정돼 있지 않았다. SDK의 `settingSources: []`는 사용자·프로젝트·로컬 설정 로드를 배제하지만 모든 CLI 내부 또는 관리 정책을 배제한다는 뜻은 아니다.
- 저장소 밖 기존 helper를 복제해 **Claude Code 자식 환경에서만** `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`를 삭제했다. 기존 `CLAUDE_CODE_SAFE_MODE=1`, `CLAUDE_CODE_MAX_RETRIES=0`, 사용자 메시지를 내보내지 않는 generator, `initialize` → 실험적 `get_usage` 1회, MCP·세션 영속화 제한, 25초 타임아웃을 유지했다. 새 helper는 문법 검사 후 승인된 실계정 조회를 **정확히 1회** 실행했다. 실패 시 재시도 경로는 실행되지 않았다.
- **실제 응답의 비민감 분류:** initialize와 usage 제어 요청 성공, 오류 없음, `rate_limits_available=true`, `rate_limits=object`; `five_hour`와 `seven_day` 모두 객체이며 `utilization`은 숫자이고 각각 0~100 범위 안에 있었다. `five_hour.resets_at=null`, `seven_day.resets_at=string`. 이 helper는 **ISO 8601 파싱 가능 여부를 검사하지 않았으므로 미확인**이다. 실제 사용률·초기화 시각·원본 응답·계정 정보는 출력하거나 저장하지 않았다. usage 응답까지 약 802 ms였다.
- 사용자·assistant 메시지, 양의 세션 비용, 모델별 사용 기록은 관찰되지 않았다. 이 관찰은 해당 프로세스에서 확인 가능한 범위의 결과이며 서버 측 내부 작업이나 비용 정책의 보증은 아니다. 정상 CLI의 인증 캐시·상태 파일 쓰기 가능성은 있었으나 이번에는 민감 저장소를 열거나 변경 전후 메타데이터를 측정하지 않았다.
- **앞선 두 조회와 비교:** 첫 실험은 두 창의 값을 확인하지 못했고 응답 컨테이너 형태를 구분하지 못했다. 두 번째는 `true/null`을 명시적으로 확인했다. 두 실험 모두 자식 환경에 차단 변수를 설정했다. 세 번째는 그 변수만 제거한 뒤 `true/object`와 두 숫자 필드를 확인했다. 동일 계정·SDK·CLI·helper 흐름에서 관찰된 차이는 이 변수가 `null`을 유발했다는 가설을 **강하게 지지**한다. 하지만 시간 경과, 서버 상태·캐시 변화를 통제한 반복 A/B가 아니고 공식 문서가 `get_usage`를 차단 대상으로 명시하지 않으므로 확정된 인과나 공식 해결 계약으로 단정하지 않는다.
- **제품 판단:** 숫자 두 창은 확인됐지만 5시간 초기화 시각이 `null`이고 7일 시각의 형식은 미검증이다. SDK API도 실험적이며 응답 신선도·인증 부작용·호출 제한·429 처리·약관상 제3자 자동 폴링 허용 범위가 확인되지 않았다. 따라서 Tokenly 제품 코드와 자동 폴링은 여전히 **보류**하고 기존 Claude statusLine·stale 표시를 유지한다. 후속 검증은 공식 API 계약 또는 별도 승인된 제한적 실험에서 시각 필드, 신선도, 호출 제한을 확인한 뒤 판단한다. 이번 작업에서 추가 계정 조회는 하지 않는다.
- **블로그 소재:** 안전을 위한 전역 트래픽 차단 플래그가 무모델 사용량 조회의 데이터 가용성과 충돌할 수 있음을 로컬 조건 변경으로 확인했다. `initialize`·제어 요청 성공, `rate_limits_available`, 실제 창의 존재, 표시 가능한 초기화 시각을 각각 별도 검증해야 한다. 앞선 실험 문서의 원인 미확정 판단은 이 새 관찰을 반영해 갱신하되, 인과 확정이나 제품 출시 성공담으로 쓰지 않는다. 블로그 본문은 작성하지 않는다.

📸 캡처 추천: 이번 비민감 분류 출력(값과 계정 정보 없는 터미널 화면), 실행 시점 2026-10-30, 핵심은 `true/null`에서 `true/object`로 바뀌었지만 5시간 시각은 `null`이라는 점. 캡처용 재조회는 하지 않는다.

## 이전 `rate_limits=null` 원인 조사와 당시 실험 보류 판단 (2026-10-30)

이번 단계는 **정적 분석·공개 자료 조사만** 수행했다. 실제 계정 조회·OAuth 호출·인증 저장소 접근·모델 요청은 없었다.

- **확인된 로컬 조건:** 두 차례의 임시 helper가 모두 Claude Code 자식 환경에 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`을 명시했다. Anthropic [공식 환경변수 문서](https://code.claude.com/docs/en/env-vars)는 이 변수가 비필수 네트워크 트래픽을 막고, `0` 같은 비어 있지 않은 값도 활성화한다고 설명한다. 그러나 공식 문서는 `get_usage` 사용량 조회가 이 변수의 차단 대상이라고 명시하지 않는다.
- **직접 재현한 외부 근거:** [T3 Code 이슈 #15364](https://github.com/pingdotgg/t3code/issues/15364)의 기여자가 Claude Code 2.1.285·SDK 0.3.276·Max 계정에서 해당 변수가 있을 때 약 300 ms와 `rate_limits_available=true, rate_limits=null`, 제거했을 때 약 800 ms와 5시간·7일 데이터가 채워지는 A/B 관찰을 보고했다. 같은 이슈에는 Pro(2.1.289/SDK 0.3.289)와 Team(2.1.288)에서도 `true/null`이 보고됐다. 작성자는 CLI 내부 사용량 fetch가 정상 상태를 반환하지 않을 때 `null`이 된다고 분석했지만 Anthropic의 공식 판정은 아니다. T3 Code의 수정은 이 조합을 **지원 불가 계정이 아닌 조회 실패**로 표시하는 UI 처리이며 Claude CLI의 사용량 fetch를 고친 것은 아니다.
- **타입·구현 근거:** 공식 npm SDK `0.3.169`의 `sdk.d.ts`는 `rate_limits_available=false`일 때 플랜 한도가 적용되지 않고 `rate_limits=null`이라고 설명한다. `rate_limits` 자체는 nullable이고 두 창은 선택적이다. SDK `sdk.mjs`의 usage 메서드는 CLI `get_usage` 응답을 그대로 전달한다. `true`가 한도 객체의 존재를 보장하지 않는다. 최신 대응 SDK `0.3.292`에도 nullable 구조가 유지된다. 공식 [SDK 변경 기록](https://github.com/anthropics/claude-agent-sdk-typescript/blob/main/CHANGELOG.md)에서 이 `true/null` 조합의 원인을 특정하거나 해결하는 안정 계약을 확인하지 못했다. [공식 TypeScript SDK 참조](https://code.claude.com/docs/en/agent-sdk/typescript)에도 이 실험 메서드의 지원된 복구 절차는 없다.
- **대안 가설의 평가:** Pro·Max·Team 공개 사례가 있어 특정 플랜만의 문제로 보기 어렵다. 2.1.285~2.1.295와 더 새로운 SDK의 보고가 있어 `0.3.169`/CLI `2.1.292` 버전 차이만으로 설명하기 어렵다. 만일 한도가 모두 소진됐다면 표시 가능한 사용률 100이 올 것으로 예상되지만, 실제 서버 계약과 응답을 보지 않았으므로 이를 원인 배제의 증거로 삼지 않는다. [statusLine 공식 문서](https://code.claude.com/docs/en/statusline)의 첫 API 응답 전 빈 한도는 별도 이벤트 경로의 조건이다. 공개 이슈의 활성 세션에서도 `get_usage`가 `null`인 사례가 있어 이번 무프롬프트 세션만의 필수 조건으로 확정할 수 없다. 401·403·429 또는 빈 서버 응답이 내부에서 흡수됐는지도 알 수 없다.
- **원인 판정:** 가장 유력한 설명은 **실험 helper가 강제로 켠 비필수 트래픽 차단 변수**가 사용량 fetch를 억제했을 가능성이다. 로컬에서는 변수 제거 전후 비교를 하지 않았으므로 확정된 인과 관계나 공식 해결책으로 기록하지 않는다. 사용자 전역 설정을 바꾸거나 토큰을 추출할 필요는 없다. 향후 별도 승인된 실험이 필요하다면 자식 프로세스의 이 변수만 **설정하지 않는** 조건을 검토하고, 나머지 무프롬프트·비밀정보 비저장 원칙을 유지해야 한다. 이 제안은 이번 작업의 실행 승인이 아니다.

**당시 제품 판단(세 번째 조회 전):** 두 실계정 조회 모두 표시 가능한 5시간·7일 데이터가 없었고, SDK 메서드는 실험적이다. Claude 독립 자동 갱신 구현·폴링은 **보류**한다. 재검토 조건은 (1) Anthropic이 이 경로의 한도 응답과 실패 의미·호출 제한을 안정된 계약으로 공개하거나, (2) 별도 승인하에 플래그를 자식 환경에서만 제거한 단발성 무모델 조회가 두 창을 반환하고 인증·비용 영향이 안전하다고 검증되는 경우다. 그때도 서버 신선도·429·버전 호환성과 제품 사용 조건은 별도 평가해야 한다. 기존 Claude statusLine과 stale 표시는 유지한다.

**블로그 소재 판단용 새 내용:** 보안을 위해 켠 광범위한 네트워크 차단 옵션이 조회 대상의 네트워크 요청까지 막을 수 있다는 실험 설계의 함정, 제어 요청 성공과 사용 가능한 한도 데이터 확보의 구분, `true/null`을 지원 불가가 아닌 조회 실패로 처리해야 한다는 관찰을 기록한다. 로컬 A/B가 없으므로 “원인을 해결했다”는 서사는 사실과 다르다. 기존 Tokenly 글 3편과 중복 여부는 후속 ChatGPT가 판단하고, 이 문서에는 블로그 본문을 쓰지 않는다.

## 두 번째 승인된 단발성 필드 분류 (2026-10-30)

- 시작 브랜치 `experiment/claude-usage-refresh`, HEAD `6ffa8c5`; 미추적 GPU 로그 2개만 있었다. 이전 helper와 공식 SDK `0.3.169` 설치 상태를 확인했다. 분류 함수는 저장소 밖 임시 경로에 만들고 가상 응답 8종(두 창, 한쪽 창, 부재, `null`, 빈 객체, 멤버 `null`, 범위 밖 숫자 등)으로 먼저 확인했다. 제품 코드·설치 앱은 변경하지 않았다.
- 기존 Claude Code CLI `2.1.292`와 공식 SDK `0.3.169`로 프롬프트 없는 `query()`를 열어 `initialize` 후 `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET()`를 **정확히 1회** 호출했다. 동일한 safe mode·설정 미로드·MCP 제한·세션 영속화 비활성 조건을 유지했다. 추가 인증, OAuth 직접 접근, 자동 재시도, 폴링은 없었다. 원본 응답·계정 정보·실제 사용량과 초기화 시각은 출력하거나 저장하지 않았다.
- **실제 분류:** initialize 성공, usage 제어 요청 성공, `rate_limits_available=true`, 그러나 `rate_limits=null`. 따라서 `five_hour`와 `seven_day` 각각은 **필드 부재나 `null`로 분류할 수 없음**(`rate_limits` 컨테이너 자체가 `null`). 각 `utilization`과 `resets_at`도 접근 불가다. 숫자 유효 범위 검사 결과가 없는 이유는 값이 범위 밖이라서가 아니라 검사할 객체가 없기 때문이다. 응답까지 약 355 ms였다.
- 사용자·assistant 메시지, 양의 새 세션 비용, 모델별 사용 기록은 관찰되지 않았다. 401·403·429 오류도 보고되지 않았다. 이 관찰은 이번 프로세스의 표시 가능한 모델 사용이 없었다는 근거이며 숨은 서버 작업·과금 정책의 보증은 아니다.
- `SDKControlGetUsageResponse` 타입 주석의 `rate_limits_available=false` → `rate_limits=null` 설명은 **역방향 조건을 보장하지 않는다.** 이번 런타임 응답은 `true`와 `null`이 공존했다. 이는 플랜 한도 조회 대상 여부와 실제 한도 데이터 확보를 따로 판단해야 함을 보여준다. 원인으로 서버 데이터 부재·일시적 조회 실패·인증/프로필 범위·SDK/CLI 버전 차이 등이 가능하지만 **증거 없이 어느 것도 확정하지 않는다.** 첫 번째 응답도 `null`이었다고 소급해 단정할 수 없다.
- **제품 적용 판정:** 이 환경에서 두 차례의 승인된 단발성 실험은 표시할 5시간·7일 숫자와 초기화 시각을 제공하지 않았다. 독립 자동 갱신 기능에 사용할 수 있다고 판단할 근거가 없다. 공식 SDK 기능은 실험적이며 반복 호출 한도·서버 신선도·계정별 응답 조건도 미확인이다. 추가 실계정 조회는 새 승인 전까지 중단한다.

블로그 소재로 남길 새 기술적 발견은 `rate_limits_available=true`와 `rate_limits=null`이 실제로 동시에 나타났다는 점, 제어 요청 성공과 제품에 필요한 데이터 확보를 분리해야 한다는 점, 컨테이너 `null`을 각 창의 누락으로 오해하지 않는 분류 설계다. 기존 Tokenly 블로그 3편과의 중복 평가는 후속 ChatGPT 판단에 맡기며 본문은 작성하지 않는다.

## 1차 검사 로직 정적 재분석과 모의 검증 (2026-10-30)

이 단계에서는 **추가 실계정 조회가 없었다.** 저장소 밖에 남은 1차 helper의 검사 코드와 공식 npm 패키지 `0.3.169`의 `sdk.d.ts`·`sdk.mjs`만 읽었다. 원본 실계정 응답, 인증 저장소, Keychain은 읽거나 복원하지 않았다.

- `sdk.mjs`의 usage 메서드는 `{subtype:"get_usage"}` 제어 요청을 보내고 성공 응답의 `.response`를 **검증·변환 없이 반환**한다. 1차 helper는 `response.rate_limits?.five_hour`와 `.seven_day`를 검사했다. 이 경로와 이름은 `sdk.d.ts`의 `SDKControlGetUsageResponse`에 일치한다. `utilization`은 **사용률 0–100**이고 `resets_at`은 ISO 8601 문자열이다. 잔여율은 `100 - utilization`으로 계산해야 하므로 사용률 100은 유효한 잔여율 0%이다.
- 타입 주석에서 `rate_limits_available=false`는 API 키·Bedrock·Vertex 또는 필요한 프로필 범위가 없는 세션의 플랜 한도 *비적용*을 뜻하며, 이때 `rate_limits=null`이라고 설명한다. 반대로 `true`가 각 창의 값 존재를 보장한다는 계약은 없다. 타입은 `rate_limits` 자체의 `null`, `five_hour?`·`seven_day?`의 부재/`null`, 내부 `utilization`·`resets_at`의 `null`을 허용한다. 즉 1차 `true`는 두 창의 숫자·시각이 확인됐다는 뜻이 아니다. `0.3.292`의 대응 타입도 두 창을 선택적으로 선언한다.
- 1차 helper의 `presentWindow(window)`는 `Boolean(window && typeof window.utilization === 'number')`, `resetPresent(window)`는 문자열에 `Date.parse`가 성공하는지만 검사했다. 이 출력은 **키 부재, 창 `null`, 사용률 `null`/비숫자를 모두 `false`로 합친다.** 시각도 키 부재와 `null`/형식 오류를 합친다. `Date.parse`는 비 ISO 문자열도 받아들일 수 있어 타입의 ISO 8601 계약을 엄격히 검증하지 못한다. 숫자 검사 역시 유한성·0–100 범위를 검사하지 않는다. 따라서 1차의 `false`는 사용 가능한 값 미확인만 의미하며 실제 누락 원인을 증명하지 않는다.
- 저장소 밖 임시 mock 스크립트에서 7개 가상 사례를 실행해 모두 통과했다: 두 창 있음, 5시간만 있음, 7일만 있음, 두 키 부재, 두 창 `null`, 창 내부 값 `null`, 사용률 100으로 잔여율 0%. `rate_limits_available=true`와 빈 `rate_limits={}`도 타입상 가능한 형태임을 별도 확인했다. 이는 **검사 함수 동작의 검증**이지 실제 서버 응답이나 계정 상태의 검증이 아니다.
- **확정된 코드 원인:** 검사 결과가 여러 상태를 하나의 `false`로 압축해 1차 응답의 정확한 형태를 알 수 없게 했다. **미확정된 데이터 원인:** 실제 창 키가 없었는지, `null`이었는지, 타입이 달랐는지, 사용률만 없었는지, SDK/CLI 버전 차이 또는 서버 데이터 조건 때문인지는 알 수 없다. 패키지 `0.3.169`는 응답을 가공하지 않으므로, 그 패키지가 값을 삭제했다고 볼 근거는 없다.

정적 분석 당시 추가 실계정 호출은 필요하지 않았다. 당시 SDK만으로 개인 구독 두 창을 실제로 표시할 수 있는지 확정하려면 별도 승인된 조회가 필요하다고 판단했다. 그때 제안한 경로는 CLI `2.1.292`와 맞는 SDK `0.3.292`, `skipBehaviors:true`, 프롬프트 없는 제어 요청이었다. 이번 두 번째 실험은 사용자 지정에 따라 SDK `0.3.169`를 유지하고, 필드 분류만 강화했다. 이후의 새 실계정 조회에는 다시 별도 승인이 필요하다.

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

**현재 결론(세 번째 조회 반영):** 실험적 `get_usage`에서 모델 대화 없이 두 창의 범위 내 숫자는 확인했지만 5시간 초기화 시각은 `null`이고 7일 시각의 파싱 가능 여부는 미확인이다. 공식 안정 인터페이스나 Tokenly 제품 자동 폴링의 안전성은 입증되지 않았다. 추가 실제 조회·폴링은 별도 승인과 검증 계획 전까지 보류한다.
