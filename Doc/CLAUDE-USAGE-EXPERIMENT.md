# Claude 개인 구독 사용량 독립 조회 실험 조사

2026-10-30 · 브랜치 `experiment/claude-usage-refresh` · 승인된 단발성 조회 총 3회 완료

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
