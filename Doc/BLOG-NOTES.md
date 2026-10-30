# Tokenly 기술 블로그 자료

## 실사용 환경 기반 Codex 검증으로 전환한 이유 (2026-10-30)

- **판단:** 읽기 전용 `.codex`를 강제한 격리 앱은 SQLite 상태 DB와 후속 EPERM 때문에 실사용 조건을 재현하지 못했다. root 추적·반복 EPERM 실험을 멈추고, 설치 앱과 다른 번들 ID·실행 경로의 Debug 사본을 준비했다. 공식 `CODEX_SQLITE_HOME`만 임시로 지정해 SQLite 쓰기를 분리하고 실제 Codex CLI의 일반 로그인 캐시를 사용하는 설계다.
- **기존 데이터 영향:** 앱 자체 UserDefaults는 새 bundle ID로 분리된다. 기본 Claude·AGY 표시는 꺼져 상태줄 파일 재읽기를 시작하지 않는다. 다만 CLI는 공식 [인증 문서](https://learn.chatgpt.com/docs/auth)에 따라 기존 로그인 캐시를 파일 또는 Keychain에서 재사용하고 사용 중 토큰을 자동 갱신할 수 있다. SQLite 경로 분리는 이 인증 변경 가능성을 없애지 않는다. 설정 화면·연결 버튼은 조작하지 않을 계획이다.
- **이번 세션 실제 결과:** `/private/tmp/tokenly-real-codex-verify-20261030/Build/Products/Debug/Tokenly.app` Debug 빌드 성공, bundle ID `io.github.jbbdyee.tokenly.realverify.20261030` 확인. 미실행 런처 구문 검사 완료. 앱과 실계정 CLI는 실행하지 않았으므로 initialize, 서버 사용량, 60초 갱신, 화면, 실행 횟수·시간·CPU·메모리는 모두 미검증이다. 승인 전 인증 캐시의 갱신 가능성을 사용자에게 제시한다.

## 두 번째 EPERM 진단 방법 점검 (2026-10-30)

- **기존 확인:** 첫 차단은 `~/.codex` 아래 SQLite 상태 런타임 초기화였고 공식 `sqlite_home`으로 임시 경로에 분리할 수 있었다. 그 뒤 남는 EPERM의 경로는 아직 확인되지 않았다. 이번에는 동일 실패를 재실행하지 않고 진단 도구의 권한과 로그 신뢰도를 조사했다.
- **진단 제약:** Apple 문서상 `fs_usage`는 syscall·경로·오류를 볼 수 있으나 root가 필요하다. 현재 일반/승격 실행에서 사용할 수 없었고 passwordless sudo도 없었다. 통합 로그의 `Sandbox:` 항목 중 Codex 경로가 나온 것은 다른 프로세스인 `logd_helper`의 거부였다. 검색 문자열을 포함한 `log show` 자체 실행 기록도 결과에 섞여 초기 필터의 거짓 양성 원인이 될 수 있다. 이번 app-server PID의 deny 경로는 확인되지 않았다.
- **환경 차이:** 설치된 v0.2.0 앱은 일반 사용자 홈에서 돌아가며, 검사한 서명 출력에 App Sandbox entitlement가 없었다. 격리 Debug 앱은 별도 번들 ID·`/private/tmp` 경로에 자식 `sandbox-exec` 홈 제한을 더했다. 설치 앱의 프로세스 존재는 Codex 조회 성공의 증거가 아니다. 사용자 화면·설정·인증은 읽거나 변경하지 않았다.
- **미검증:** 실제 인증 initialize, 최초 성공 조회, 60초 자동 갱신, 중복 요청과 CLI 비용. 정확한 두 번째 EPERM syscall·경로와 안전한 임시 쓰기 분리 방법이 확인될 때까지 실계정 테스트를 보류한다.

## Codex app-server 읽기 전용 초기화 실패의 분해 (2026-10-30)

- **실측 조건:** 공식 CLI `0.164.0-alpha.11.1`을 자식 `sandbox-exec`에서 실행했다. 실제 사용자 홈 쓰기를 전부 차단하고 `.codex` 읽기만 허용했다. RPC 원문·인증값·계정·사용량은 출력하거나 저장하지 않았고, stderr는 메모리에서 민감한 줄을 제거한 뒤 오류 종류만 확인했다.
- **확인된 첫 원인:** 기본 상태 위치의 app-server는 initialize 응답 전에 `failed to initialize sqlite state runtime under ~/.codex`로 종료 코드 1. `codex --version`은 같은 제한에서 실행됐다. 이는 CLI 파일 실행 실패나 인증 실패 판정이 아니라 SQLite 런타임 초기화 실패다.
- **공식 설정 적용:** [Codex 설정 참조](https://learn.chatgpt.com/docs/config-file/config-reference)의 `sqlite_home`을 임시 디렉터리로 옮기자 SQLite 오류는 없어졌다. 그러나 다음 EPERM으로 여전히 종료했다. 실제 `CODEX_HOME`을 명시하면 해당 경로 정규화가 거부됐고, 홈 상위 경로 메타데이터 읽기를 열어도 일반 EPERM이 남았다. 두 번째 거부의 정확한 파일·syscall은 미확정이다.
- **대조군:** 빈 임시 `CODEX_HOME`과 임시 `HOME`·`TMPDIR`·`sqlite_home`에서는 동일 app-server의 initialize가 성공했다. 이 결과는 임시 쓰기 저장소 설계가 가능함을 보여주지만 인증이 없어 서버 사용량을 조회하지 못한다. 인증 파일 복사·원본 수정·홈 쓰기 허용은 하지 않았다.
- **남은 검증:** 실제 Codex 인증 재사용, 사용량 최초 성공 조회, 60초 자동 갱신과 마지막 성공 시각, 중복 프로세스, 실제 CLI 실행 비용 및 화면은 모두 미검증. 별도 EPERM의 경로를 안전하게 식별하기 전에는 제품 코드 수정이나 실계정 앱 실행을 진행하지 않는다.

## 실제 Codex CLI 인증 재사용 시도의 경계 (2026-10-30)

- **설계 판단:** 기존 인증 파일을 복사하거나 열지 않고 공식 CLI가 스스로 읽도록 하되, 기존 사용자 홈 전체의 쓰기를 차단했다. `.codex` 읽기만 허용한 자식 샌드박스의 `codex --version`은 성공했다.
- **실제 결과:** 동일 제약의 `app-server --listen stdio://`는 `initialize` 응답 전에 종료 코드 1로 끝났다(약 14~16ms). stderr는 권한 오류 포함 여부만 메모리에서 판정하고 버렸으며 계정·사용량·인증값은 기록하지 않았다. 정확한 쓰기 대상과 인증 유효성은 확인하지 못했다.
- **미검증:** 최초 성공 조회, 성공 후 60초 재조회와 시각 갱신, 실제 화면·팝오버·수동·중복·절전 복귀, 실제 CLI 실행 시간과 자원 비용. 이전 실패 전용 임시 CLI의 300초 재시도 및 XCTest 결과와 구분한다. 사용자 홈 쓰기 권한을 열어 우회하지 않았고 제품 코드도 바꾸지 않았다.
- **후속:** 비밀정보를 노출하지 않고 app-server 초기화에 필요한 쓰기 경로를 확인한 다음, 기존 로그인 상태를 변경하지 않는 임시 경로 전환이 가능할 때만 실측을 재개한다.

## 격리된 실제 macOS 앱의 1분 갱신 관찰 (2026-10-30)

- **환경 [확인]:** 별도 Debug 앱 번들 ID `io.github.jbbdyee.tokenly.livecheck.20261030`, 실행 경로 `/private/tmp/tokenly-live-isolated-20261030/Build/Products/Debug/Tokenly.app`. 자식 샌드박스에서 실제 홈 읽기·쓰기를 차단하고 실패만 반환하는 임시 `codex`를 사용했다. `HOME` 변경만으로는 Foundation의 홈 경로가 격리되지 않아 실제 인증 재사용은 하지 않았다. 설치 앱은 건드리지 않았다.
- **실측 [확인]:** 테스트 앱 시작 직후 임시 CLI가 21:26:24 UTC에 시작했고 실패 상태의 다음 앱 CLI 시작은 21:31:24 UTC로 정확히 300초 뒤였다. 60초 타이머 tick은 CLI 호출과 다르다. 중간 단독 프로토콜 점검 실행은 앱 호출 횟수에서 제외했다. 앱 호출은 5분 51초 관찰 동안 2회다. 1분간 10초 간격 `ps` 6표본에서 앱 CPU 순간값 0.0~0.3%, RSS 85,840~86,224 KiB; 5분 25초 표본 83,072 KiB. 다른 단발 CPU 4.5% 표본이 있었고 CLI 완료 로그가 없어 CLI 실행 시간·장시간 자원 비용은 판정하지 않는다.
- **미검증:** 실제 서버 성공 조회와 성공 후 60초 자동 조회, 팝오버 재열기, 수동 새로고침, 실패 뒤 성공값·시각 유지 화면, 절전 복귀. 메뉴 막대 전용 격리 앱을 컴퓨터 사용 도구가 식별하지 못해 화면 조작을 수행하지 않았다. 성공/중복/절전 조건의 XCTest 결과를 이 실행의 관찰로 바꾸어 말하지 않는다.
- **📸 캡처 추천:** 이후 사용자가 격리 앱을 직접 조작할 때, 성공 조회 직후와 실패 직후의 Codex 팝오버에서 `마지막 갱신 시간`과 이전값 표기를 같은 위치로 캡처한다. 메뉴 막대의 앱 식별, 시점, 계정·토큰·사용자 경로 가리기를 함께 기록한다. 이번 검증에서는 캡처를 제작하지 않았다.

## Codex 1분 조건부 갱신 재검증 (2026-10-30)

- **설계 판단 [코드 확인]:** `UsageStore` 타이머는 60초마다 `refreshOnTimer()`를 호출한다. 마지막 성공 시각과 최근 시도가 모두 60초 이상 경과해야 조회한다. 팝오버 재열기와 절전 복귀는 같은 `refreshIfStale()`를 호출하므로 동시 트리거가 CLI 요청을 중복시키지 않는다. 진행 중 요청도 `isRefreshing`으로 차단한다. 타이머 tick은 조회 가능 여부를 확인하는 시점이므로 정확히 매분 성공한다는 뜻은 아니다.
- **실패 정책 [코드·테스트 확인]:** 실패 후 자동 타이머 재시도는 마지막 시도부터 300초를 기다린다. 팝오버·복귀 조건부 경로의 최근 시도 제한은 60초이며 수동 버튼은 그 제한을 우회한다. 실패 시 snapshot과 `fetchedAt`을 지우지 않고 오류 표시와 이전 성공값을 함께 유지한다. `마지막 갱신 시간`은 로컬 성공 조회 시각이며 서버 집계 시각이 아니다.
- **이번 세션 검증 [실행 결과]:** 샌드박스 내 첫 `xcodebuild test`는 SwiftUI 매크로 서버 malformed response로 컴파일에 실패했고, `simctl`은 CoreSimulatorService 연결 거부 및 로그 쓰기 거부를 보고했다. 승인된 승격 실행에서는 전체 XCTest 393개, Debug·Release 빌드, `git diff --check`가 통과했다. `testOneMinuteTimerBacksOffFailuresAndManualBypassesIt`, `testTimerDoesNotRepeatRecentPopoverSuccess`, 절전 알림·실패 후 이전 데이터 유지 테스트가 통과했다. 제품 회귀나 Xcode 설치 손상으로 단정할 근거는 없다.
- **남은 제약:** 설치된 v0.2.0 앱에는 이 변경이 없다. 실제 앱의 팝오버 재열기·절전 복귀·수동 새로고침 표시 및 장시간 CLI 실행 비용은 이번 자동 검증으로 확인되지 않았다. Claude·AGY 수집 경로, RAM 계산식, 색상은 변경하지 않았다.
- **📸 캡처 추천:** 후속 실제 앱 검증 시 새 빌드의 Codex 팝오버를 열어 `마지막 갱신 시간`과 실패 뒤 이전값 표시를 함께 기록한다. 시점은 성공 조회 직후와 실패 직후로 구분하고 계정·토큰·사용자 경로는 가린다. 이번 작업에서 캡처는 제작하지 않았다.

## 외부 사용량 불일치 제보: 증거가 없는 숫자를 고치지 않은 이유 (2026-10-29)

- **확인:** 코드와 fixture 테스트에서 Codex의 `100 − usedPercent`, Claude의 `100 − used_percentage`, AGY의 `remaining_fraction × 100`과 버킷 최솟값 대표 표시를 확인했다. RAM 사용률은 `internal − purgeable + wired + compressor`를 물리 메모리로 나눈 값이다. 제보에는 서비스·같은 시각·계정 일치 여부·비교 지표가 없어 실제 불일치의 원인은 미확정이다.
- **가설:** 계정/윈도우/버킷 차이, 이전 상태줄 데이터, RAM의 서로 다른 지표 비교는 각각 재현 자료가 있어야 판단할 수 있다. 인증 파일이나 원본 API 응답 대신, 비교 화면·시간대·지표명·잔여/사용 값·'마지막 수신' 표시를 받는다. **📸 캡처 추천:** 제보자가 같은 시각에 두 화면의 지표명·값·갱신 시각을 캡처하되 계정 식별자·토큰·경로는 가린다. 이 캡처 없이는 원인·수정 성공을 주장하지 않는다.

## UI 색상 조화: "한 화면이 마음에 들면 그 화면의 색을 나눠 쓴다" (2026-10-29)

- **[확인]** 기준은 RAM 팝오버의 구성 막대 색 세 개(민트 `#A5E2D7`, 파스텔 블루 `#A8CDF4`, 라벤더 `#C5B3EE`)였다. 새 색을 고르지 않고 이 값을 `HarmonyPalette` 하나에 모아 CPU·배터리·AI 화면이 참조하게 했다. 테스트가 RAM 상수와 같은 값인지 확인한다.
- **[함정]** CPU와 RAM 그래프는 같은 팔레트를 쓰고 있었다. 그 팔레트를 바꾸면 "건드리지 말라"던 RAM까지 바뀐다. CPU 전용 색 구성(`.cpu`)을 하나 더 만들어 CPU 뷰에만 넘겼다.
- **[확인]** 그래프 좌표 계산은 색을 받지 않는 구조라, 색을 바꿔도 값·축·높이가 바뀔 수 없다. 이것도 테스트로 고정했다. 색은 "높이 = 색" 규칙 그대로라 평소 10~20% CPU는 라벤더, 높아질수록 블루를 거쳐 민트로 보인다.
- **[판단]** 빨강(남은 한도 부족), 배터리 부족 앰버처럼 **의미가 있는 색은 그대로** 두었다. 조화보다 경고가 먼저다. 다만 "주의" 주황은 사용자 확인 뒤 RAM의 경고 앰버 `#F4D39A`로 부드럽게 바꿨다. 지정된 라이트 트랙 `#E8E8E8`과의 WCAG 상대 휘도 대비를 다시 계산하면 `#F4D39A`는 약 1.17:1, 선택한 `#B37914`는 약 3.03:1이다. 실제 material 위의 픽셀 대비와 가독성은 아직 화면 확인이 필요하다.
- **[확인]** AI 막대에 그라데이션을 넣으려니 macOS 기본 `ProgressView`는 단색 tint만 받았다. 막대를 새로 그리면 크기·트랙이 미묘하게 달라질 수 있어, 기본 막대는 그대로 두고 채움 위에만 같은 모양의 캡슐을 겹쳤다. 기본 막대의 프레임은 20pt인데 보이는 트랙은 가운데 8pt라는 것을 픽셀을 세어 알아냈고(처음 구현은 프레임 높이를 써서 막대가 두껍게 그려졌다), 고친 뒤 시작·끝·세로 범위가 기본 채움과 같고 남은 트랙이 픽셀 단위로 같은 것을 확인했다.
- **[한계]** macOS 기본 tint(주의 앰버·부족 빨강)는 화면 밖(비활성 창) 렌더에서 회색으로 그려져 실제 앱에서 봐야 한다. 트랙 높이 8pt는 macOS 27에서만 측정했다.
- **[후속 검증, macOS 27.0.1]** 가짜 Codex 35%/40%·Claude 30%·AGY 42%를 제품과 같은 `UsageMenuView`의 격리 창에 주입했다. 첫 다크·라이트 캡처는 막대가 모두 회색이었지만, 앱 활성 상태 표식에서 창이 비활성임을 확인했다. 창 활성화 후 다크 `#F4D39A`·라이트 `#B37914` 막대가 세 서비스 모두 나타났고 실제 `.regularMaterial` 위의 텍스트와 트랙이 시각적으로 구분됐다. **원인:** 비활성 창에서 macOS 기본 `ProgressView` tint가 회색이 되는 렌더링 상태. 제품의 색상 계산 결함은 확인되지 않았다. 이 검증은 격리 창의 정성적 화면 확인이며 설치본 팝오버·실제 픽셀 대비 수치·macOS 14/15 검증으로 확대하지 않는다. **📸 캡처 추천:** 블로그에는 격리 창의 활성 다크·라이트 두 장만 비교하고, 가짜 수치임을 표시한다. 비활성 회색 화면은 문제 분석 설명이 필요할 때만 보조로 쓴다.
- **📸 캡처 후보:** CPU 팝오버 전후(같은 테마), 배터리 막대 전후, RAM 옆에 CPU를 나란히 둔 화면.

## v0.2.0 기준 블로그 준비 자료 (2026-10-29)

아래는 코드·문서에서 확인한 사실만 모았다. 각 항목의 근거 파일을 함께 적었다. 이 아래의 단계별 메모가 세부 근거다.

### 1. 개발 동기
- 여러 AI 코딩 도구의 5시간·주간 한도를 확인하려고 매번 다른 화면·CLI를 열어야 했다. 메뉴 막대 한 곳에서, **공식적으로 제공되는 값만** 숫자로 보여 주는 것이 목표다(`README.md` "개발 동기"). 모르는 값은 0%로 채우지 않는다.

### 2. 기술 스택과 구조
- Swift 5, SwiftUI `MenuBarExtra`(시스템 팝오버는 `.window` 스타일), AppKit·Core Graphics·Core Text로 메뉴 막대 이미지를 직접 그림, ServiceManagement(`SMAppService` 로그인 항목), IOKit(전원·저장 장치·GPU 레지스트리), Mach(`host_statistics`), XCTest(호스트 앱 테스트). 외부 의존성 없음.
- 하나의 실행 파일이 GUI 앱이면서 명령줄 도구(`--status`·`--connect`·`--statusline`)다: `src/Tokenly/TokenlyMain.swift`, `BridgeCommand.swift`.
- 구조도: `README.md` "사용 기술과 구조".

### 3. Codex: CLI 인증 재사용과 app-server JSON-RPC
- Tokenly는 Codex의 인증 파일을 읽지 않는다. 설치된 `codex`를 `app-server --listen stdio://`로 실행하고(로그인은 CLI가 이미 가진 것을 그대로 씀), 표준 입출력으로 JSON-RPC를 주고받는다: `initialize`(clientInfo에 앱 버전) → `initialized` → `account/rateLimits/read`(읽기 전용). stderr는 버린다. 근거 `src/Tokenly/Providers/CodexUsageProvider.swift`.
- 응답의 `rateLimitsByLimitId["codex"]`(없으면 `rateLimits`)에서 `primary`·`secondary` 창을 읽고, `windowDurationMins`가 300이면 5시간, 10,080이면 7일 창으로 분류한다. `usedPercent`는 0~100일 때만 받고, `resetsAt`(초 단위 Unix 시각)은 0보다 클 때만 초기화 시각으로 쓴다. 화면에는 `100 − usedPercent`, 즉 **남은 비율**을 보여 준다(`Models/NumericGauge.swift`, `UsageSnapshot.swift`).
- 재설정 권한은 공식 스키마의 `rateLimitResetCredits`만 읽고, 소모하는 `…/consume`은 호출하지 않는다(`README.md` "서비스별 연동 방식").
- **비율 ≠ 토큰 수:** 이 API가 주는 것은 구독 한도 대비 **사용 비율과 창 길이·초기화 시각**이다. 토큰 개수나 요청 수는 오지 않으므로 Tokenly도 토큰 수를 표시하지 않는다.
- 테스트 근거: `TokenlyTests.swift`의 Codex 응답 파싱·CLI 탐색·클라이언트 버전 테스트.

### 4. Claude Code·Antigravity: statusLine 브리지
- 두 CLI는 상태 줄을 그릴 때 설정된 명령에 JSON을 넘긴다. `Tokenly --connect claude|agy`가 설정 파일의 `statusLine` 하나만 Tokenly 실행 파일로 바꾸고(미리 보기·확인·백업·연결 기록, 원래 쓰던 명령은 같은 입력으로 계속 실행해 출력 유지), `--statusline`이 받은 JSON에서 한도 수치·초기화 시각·수신 시각만 0600 파일로 저장한다. 근거 `StatusLineBridge.swift`, `StatusLineConnector.swift`, `README.md` "Claude Code·AGY 연결".
- Claude는 `rate_limits`의 5시간·7일 사용 비율, AGY는 `quota`의 버킷별 남은 비율·초기화 시각을 쓴다. 이벤트 기반이라 CLI를 쓰지 않으면 값이 멈추고, 15분이 지나면 회색으로 표시한다.
- 테스트 근거: `StatusLineTests.swift` 48개(임시 홈에서 연결·해제·바이트 단위 복원).

### 5. 시스템 모니터 (v0.2.0)
- 위젯 5개와 상세 팝오버, 측정·표시 코드 약 4,800줄(`src/Tokenly/SystemMonitor/`). 사양·검증 기록 `Doc/SYSTEM-MONITOR.md`.
- CPU: Mach 누적 tick 차이, RAM: VM 통계와 메모리 압박 수준, Disk: APFS 컨테이너 용량(사용 가능은 시스템 추정치라 "필요 시 확보 가능(추정)"으로 분리)과 `/`의 물리 장치를 IORegistry로 정확히 찾아 읽은 읽기·쓰기 바이트, GPU(실험적): 문서화되지 않은 IOAccelerator 사용률을 1초에 약 10번 읽어 평균, 배터리: IOPowerSources(공개)와 배터리 레지스트리(사이클·용량·온도).
- 측정할 수 없는 값은 `—`·"확인 불가", 그래프는 측정이 빈 구간을 잇지 않는다(2.5초 규칙). GPU 그래프는 60초 고정 축이라 켠 직후 오른쪽 끝에만 그려진다(5초 뒤 x 301–317 → 72초 뒤 x 5–317, `HANDOFF.md` 6-9C).
- 기본값: 저장값이 없을 때만 CPU·RAM·Disk·배터리 켜짐, GPU 꺼짐. `defaults.object(forKey:) as? Bool ?? 기본값`으로 "없음"과 "false"를 구분(`SystemWidgetController.swift`, 테스트 `SystemWidgetControllerTests.swift`).

### 6. 개발 중 해결한 문제 (근거: 아래 단계별 메모)
- 테스트가 사용자 Preferences에 빈 plist 1,082개를 남김 → 임시 폴더 suite로 전환(6-9B).
- Disk I/O에서 디스크 이미지까지 합산될 위험 → `/`에서 IORegistry를 거슬러 올라가 물리 장치 하나만 사용(6-4e).
- 배터리 온도 단위(0.1 K vs 1/100 °C)를 다른 센서 값과 대조해 확정(6-4f).
- 릴리스 빌드에 커버리지 계측이 들어가 사용자 폴더에 `default.profraw` 생성 → 빌드 설정과 검사 추가(0.1.0, `CHANGELOG.md`).
- Xcode 빌드 사본의 등록 해제로 설치본이 앱 목록에서 사라짐 → 임시 번들 ID로 빌드(0.1.0).
- 앱 버전이 코드 한 곳(Codex clientInfo)에 고정돼 있던 것 → 번들 버전 사용(6-11).

### 7. 테스트와 릴리즈 검증
- XCTest **386개**(파일별: TokenlyTests 57, StatusLineTests 48, MenuBarSystemImageTests 36, SystemMonitorStoreTests 34, SystemWidgetControllerTests 30, GPUTests 29, SystemWidgetPresentationTests 23, CPUPopoverTests 19, RAMPopoverTests 16, ProcessTopTests 16, DiskActivityTests 15, BatterySamplerTests 15, SystemMonitorTests 13, SystemMonitorWiringTests 12, BatteryPopoverTests 10, GPUPopoverTests 7, DiskTests 6).
- v0.2.0: 깨끗한 복제본에서 `release.sh --final 0.2.0`, universal, 해제본 = 서명본, 공개 URL에서 받아 SHA-256 `8b4c2c27…b34a1` 확인(`HANDOFF.md` 6-13B).

### 8. 기존 설정 보존과 안전한 업데이트
- 앱·설정(`defaults export`)·데이터 폴더를 검증된 백업으로 남기고, 기존 앱은 지우지 않고 옮긴 뒤 교체. 전후 설정 22개 동일, Claude·AGY 상태 줄 경로 동일, 설치 직후 Claude 수신 확인(`HANDOFF.md` 6-12).

### 9. 아직 검증하지 않은 것
- 다른 Mac·새 계정에서 내려받은 ZIP의 Gatekeeper 첫 실행, Intel Mac·다른 Apple silicon에서의 GPU·배터리 온도, 키보드·VoiceOver, 0.2.0 로그인 항목 재승인·재로그인 자동 실행, 업데이트 후 AGY 새 수신. Developer ID 서명·공증 없음.

### 10. 배운 점
- "빌드 성공"·"테스트 통과"·"실제 화면 확인"·"사용자 보고"를 문서에서 구분해 적어야 나중에 무엇을 믿을 수 있는지 안다.
- 문서화되지 않은 값은 "실험적"으로 표시하고, 단위·출처를 다른 근거와 대조한 뒤에만 보여 준다.
- 기본값을 바꿀 때는 "값 없음"과 "사용자가 끔"을 구분해야 기존 사용자를 해치지 않는다.

### 캡처 후보 (공개 전 개인 정보 가림)
- 메뉴 막대: AI 숫자형 + 시스템 위젯 5개(실제 화면). 현재 README 이미지는 렌더링 코드로 만든 것.
- 팝오버 5개 다크·라이트, GPU 켠 직후와 60초 뒤 비교, Disk 구성 막대와 "필요 시 확보 가능(추정)" 도움말, 배터리 온도 ⓘ.
- 터미널: `Tokenly --status`, `--connect claude --dry-run` 출력(홈 경로 가림).
- GitHub v0.2.0 Release 페이지와 `shasum -c` 결과.
- 로컬 보관 자료: `Doc/screenshots/`의 단계별 메뉴 막대 캡처, 워크스페이스의 디자인·조사 보관소(공개 대상 아님).

## Stage 6-12 업데이트를 "되돌릴 수 있게" 하기 (2026-10-29)

- **[확인]** 교체 전에 앱(내용 해시로 동일 확인), 설정(`defaults export`), 데이터 폴더(`diff -r`)를 백업하고, 기존 앱은 지우지 않고 백업 폴더로 **옮긴 뒤** 새 앱을 복사했다. 되돌리기는 복사 한 번이면 된다.
- **[확인]** 업데이트 전후 설정 22개가 한 글자도 다르지 않았다. 새 버전의 "신규 사용자 기본값"은 저장값이 있는 사용자에게 적용되지 않는다는 설계가 실제 설치에서도 그대로였다.
- **[확인]** 가장 확실한 연동 증거는 바로 이 작업을 하던 Claude Code 세션이었다. 설치 직후 상태 줄이 새 실행 파일을 불러 Claude 사용량 파일을 갱신했다.
- **[확인]** 같은 Mac에서 만든 ZIP에는 격리 속성이 없어 Gatekeeper 경고 없이 실행됐다. 내려받은 ZIP의 첫 실행 절차와는 다르다.

## Stage 6-11 버전을 올릴 때 숨은 버전 찾기 (2026-10-29)

- **[확인]** 앱 버전은 `Info.plist` 두 줄에만 있었지만, Codex `app-server`에 자기소개할 때 보내는 버전이 코드에 `"0.1.0"`으로 박혀 있었다. 번들에서 읽도록 바꾸고, 앞으로 어긋나지 않게 테스트를 붙였다. 같은 파일들에 있는 다른 `0.1.0`은 옛 Python 브리지 형식을 알아보는 호환 코드라 그대로 둬야 했다.
- **[확인]** 커밋하지 않은 상태로 RC를 만들기 위해, 깨끗한 clone에 작업 트리 변경을 patch로 적용해 빌드했다. 빌드 기록에 "dirty 7 paths"가 남아 정식 배포본과 구분된다.
- **[확인]** 업데이트 위험을 읽기만으로 줄였다. Claude Code와 AGY의 상태 줄이 모두 `/Applications/Tokenly.app`의 실행 파일을 가리켜, 같은 경로에 교체하면 다시 연결할 필요가 없다. OpenAI 키가 Keychain에 없어 서명 변경에 따른 재허용 창 위험도 없었다.

## Stage 6-10 "깨끗한 트리"가 필요할 때 아무것도 지우지 않는 법 (2026-10-29)

- **[확인]** 릴리스 스크립트의 final 모드는 깨끗한 작업 트리와 태그·버전 일치를 요구한다. 미추적 로그를 지우거나 stash하지 않고, 저장소 밖에 같은 커밋을 로컬 clone해 그 안에서 스크립트를 돌렸다. 원래 작업 트리는 한 글자도 바뀌지 않았다.
- **[확인]** 스크립트는 출력 폴더가 이미 있으면 멈추고, Xcode 산출물을 임시 번들 ID로 만들어 설치된 앱이 LaunchServices 목록에서 사라지지 않게 한다. 새 RC 폴더를 따로 주어 기존 Release 폴더는 그대로였다.
- **[판단]** 이번 RC는 코드가 크게 바뀌었는데도 버전이 발행본과 같은 `0.1.0 (3)`이다. 사용자 입장에서는 둘을 구별할 수 없으므로, 배포 전에 버전을 올리는 것이 먼저다.
- **[확인]** ad-hoc 서명 앱은 Gatekeeper 평가에서 거부된다. "빌드 성공"과 "배포 가능"은 다른 말이다.

## Stage 6-9C 클릭 없이 메뉴 막대를 검증하는 법과 그 한계 (2026-10-29)

- **[확인]** 접근성 권한 없이도 격리 앱의 설정 도메인에 값을 써 두고 재실행한 뒤 메뉴 막대를 캡처하면, "저장값 → 표시"는 실제 화면으로 확인할 수 있었다. 위젯 다섯 개를 하나씩만 켜 보는 방식이 붐비는 메뉴 막대(넘침 `«`)에서 가장 확실했다.
- **[확인]** GPU 그래프가 "오른쪽에 몰린다"는 의견은 측정으로 정리됐다. 켠 지 5초에는 점 4개가 오른쪽 끝(x 301–317)에, 72초에는 60개가 전체 폭(x 5–317)에 있었다. 최근 60초를 고정 축으로 쓰는 설계 그대로다.
- **[한계]** 클릭·키보드·VoiceOver처럼 사람이 조작해야 하는 항목은 이 방식으로 검증되지 않는다. 그 목록은 그대로 남겼다.

## Stage 6-9B 지운 설정이 파일로 남는 이유 (2026-10-29)

- **[확인]** 테스트가 `UserDefaults(suiteName: "tokenly.wiring.<UUID>")`처럼 일반 이름의 suite를 쓰고 끝에 `removePersistentDomain`을 불러도, cfprefsd가 나중에 빈 `<suite>.plist`(42바이트)를 사용자 Preferences 폴더에 써 둔다. 그렇게 1,082개가 쌓여 있었다.
- **[확인]** 해결책은 이미 저장소 안에 있었다. AI 테스트는 suite 이름을 임시 폴더의 **절대 경로**로 만들어, 파일이 Preferences가 아니라 임시 폴더에 생기고 테스트가 직접 지운다. System Monitor 테스트만 이 방식을 따르지 않았다. 9곳을 같은 도우미로 바꾸자 전체 테스트를 두 번 돌려도 남는 파일이 0개가 됐다.
- **[판단]** 지우는 함수에는 "테스트 폴더의 테스트 suite만 지운다"는 문지기를 붙였다. 실수로 앱의 실제 도메인 이름을 넘겨도 지우지 않는다.
- **[판단]** 이름에 tokenly가 들어갔다고 다 지우지 않았다. 생성 코드와 일치하고 비어 있는 것만 휴지통으로 옮기고, 진단·검증용 도메인과 주인을 모르는 파일은 남겼다.

## Stage 6-9A 기본값을 바꿀 때 "없음"과 "false"를 나누기 (2026-10-29)

- **[확인]** 신규 사용자 기본값을 CPU·RAM·Disk·Battery ON / GPU OFF로 바꿨다. 핵심은 `defaults.object(forKey:) as? Bool ?? 기본값`이다. `bool(forKey:)`는 키가 없을 때도 false라서, 일부러 끈 기존 사용자와 처음 온 사용자를 구분하지 못한다.
- **[확인]** 기본값은 저장하지 않는다. 그래야 나중에 기본값을 다시 바꿔도 "사용자가 고른 적 없는" 위젯만 따라 바뀐다.
- **[교훈]** 테스트 2개가 깨졌는데, 빈 설정 도메인을 "모두 꺼진 사용자"로 쓰고 있었기 때문이다. assertion을 지우는 대신 "모두 OFF로 저장한 기존 사용자"를 명시해 원래 의도를 살렸다.
- **[확인]** 번들 ID·Keychain·데이터 경로를 바꾼 격리 사본을 빈 설정으로 실행해, 메뉴 막대에 CPU·RAM·Disk·Battery만 나타나는 것을 캡처로 확인했다. 원래 앱과 설정은 그대로였다.

## Stage 6-9 검증의 경계: 격리된 앱 실행과 실제 UI 조작 (2026-10-29)

- **확인된 사실:** 원본 앱 PID 28707과 사용자 설정을 유지한 채, 임시 사본의 번들 ID·Keychain 서비스·AI 파일 루트를 분리한 테스트 앱을 별도로 실행·정상 종료했다. 전체 자동 테스트 380개, Debug·Release 빌드가 통과했다. UI 자동화는 메뉴 막대 앱을 선택하지 못했고 접근성 자동화 권한도 없어서 클릭·VoiceOver·실제 테마 렌더링은 확인하지 못했다.
- **코드에서 도출한 설명:** GPU Aurora 그래프의 X축은 최근 60초 고정이다. 켠 직후 짧은 기록은 오른쪽에만 놓인다. 오른쪽 치우침의 실제 원인은 화면과 60초 전후의 데이터로 비교하기 전에는 확정할 수 없다. Battery 정보 행 11pt·도움말 10pt도 실제 글자 크기·대비 확인 전에는 취향과 결함을 구분할 수 없다.
- **📸 캡처 추천:** 추가 재실행 없이 접근 가능한 테스트 앱에서 GPU를 켠 직후와 60초 이상 지난 뒤 같은 크기·테마로 그래프를 캡처하면 시간축 설명을 검증할 수 있다. Battery 상세 영역은 다크·라이트에서 동일 확대율로 캡처해 11pt 행과 10pt 도움말의 읽기 쉬움을 비교한다. 실제 프로세스 이름·기기 정보·계정 정보는 공개 전 가린다. 현재는 해당 캡처를 얻지 못했다.

**공개 범위 (Stage 6-8D):** 아래의 `Doc/logs/` 원본과 Workspace의 `.noindex` 보관소는 로컬 검증 자료다. 문서에는 확인된 결과와 당시 파일명을 남기지만 원본 로그는 공개 커밋에서 제외한다. 정적 디자인 시안은 예시 데이터이며 실제 계정·측정값으로 해석하지 않는다.

## Stage 6-8B 배포 검사의 숨은 구버전 의존성 (2026-10-29)

- **확인된 문제와 해결:** 곰돌이형 제품 에셋 제거 후에도 `release.sh`가 `BearGauge/bear-assets.json`을 필수로 검사했다. 제품의 일반 빌드는 통과하므로 배포 경로에서만 드러날 문제였다. 폐기 에셋 검사만 제거하고 AppIcon·두 상태줄 브리지 검사는 유지했다. 개발용 ZIP을 새로 만들어 빌드·서명·압축 해제·내용 동일성·체크섬까지 통과했다. 실제 GitHub 게시나 설치본 교체는 하지 않았다.
- **검증 자료:** `/private/tmp/tokenly-stage6-8b-release-verify/0.1.0-dev/build-info.txt`와 같은 폴더의 `.sha256`은 이번 실행 원본이다. 임시 빌드 산출물을 지울 필요 없이 보존하는 옵션으로 검증했다. `📸 캡처 추천`: 기존 `build-info.txt`의 리소스·서명·압축 해제 검사 통과 줄과 `shasum -c` 결과를 함께 캡처하면 일반 빌드와 배포 검증의 차이를 설명하기 좋다. 공개 전 로컬 경로·기기 정보가 보이는 줄은 가린다. 캡처만 위한 재실행은 필요 없다.
- **정리 판단:** 당시 바탕화면 Tokenly Preview 폴더 8개는 고유 시안 또는 실기기 기록이 있어 보존했다. 이후 Stage 6-8C에서 대표 근거 81개를 로컬 보관하고 원본 8개 폴더를 휴지통으로 이동했다. 반대로 무시된 Finder 메타데이터·과거 커버리지 파일·사용하지 않는 DerivedData와 이번 검증의 재생성 가능한 중간 폴더 **53개 항목**은 원래 경로를 기록하고 휴지통으로 이동했다. 휴지통을 비우지 않아 공간이 실제로 반환됐다고 주장하지 않는다.

## Stage 6-8A 실제 화면 승인과 공개 자료 구분 (2026-10-28)

- **확인된 사실:** 사용자가 최신 Debug 앱의 CPU·RAM·GPU·Disk·Battery 다크 계열 화면에서 플랫 차콜 디자인과 지표별 그래프·게이지·정보 표시를 확인·승인했다. 시스템 설정의 0.85배 스위치 5개도 축소 크기·정렬·ON/OFF 표시와 안내 문구를 눈으로 확인했다. 전체 380개 자동 테스트와 Debug·Release 빌드는 별도로 통과했다.
- **미검증:** 이번 빌드에서 스위치를 실제로 조작했는지, VoiceOver·키보드·재실행 복원·라이트 테마가 정상인지 확인되지 않았다. GPU 그래프의 오른쪽 치우침과 Battery 세부 글자 크기는 원인을 확인하지 않은 향후 검토 후보로만 남긴다. 이전 6-6B 상호작용 검증을 이 빌드의 결과로 옮기지 않는다.
- **공개 자료:** 6-2/6-3 스크린샷과 6-7A 시안은 정적 예시 데이터이며 실측값으로 소개하지 않는다. GPU 비용 로그에는 기기 모델·OS 빌드가 있어 공개 범위를 결정한 뒤 사용한다. 전체 이미지의 개인 정보 검토가 끝나기 전에는 일괄 스테이징하지 않는다. 기존 캡처로 충분하므로 캡처만을 위한 재실행은 권하지 않는다.
- **발견한 배포 경로 불일치:** 제품·Xcode 타깃에서 곰돌이 에셋을 제거했지만 `scripts/release.sh`의 필수 리소스 검사에는 옛 `BearGauge/bear-assets.json`이 남았다. 일반 Debug·Release 빌드 성공만으로 배포 ZIP 검증까지 통과했다고 말할 수 없는 사례다. 이번 단계에서는 스크립트를 실행하거나 고치지 않았으므로 실패 자체는 정적 코드 검토에 근거한 예상이며, 후속 수정·재검증이 필요하다.

## Stage 6-7B-2 최신 앱 교체와 시각 검증 한계 (2026-10-28)

- **확인:** 사용자 승인 뒤 기존 Debug PID 20516의 실행 경로를 검증하고 정상 종료했다. 최신 6-7B-2 Debug를 PID 24475로 실행해 같은 번들 ID·버전 `0.1.0 (3)`, 사용자 설정값 보존, Tokenly 단일 프로세스를 확인했다. 앱은 실행 상태다.
- **미확인:** 메뉴 막대 전용 앱이 UI 자동화 목록에 없고 직접 경로 선택도 시간 초과됐다. 따라서 새 RAM·GPU·Disk·Battery 화면·테마·클릭은 직접 확인하지 않았다. 자동 테스트 380개 통과와 앱 실행 성공은 디자인의 실제 화면 검증과 별개다.
- **📸 캡처 추천:** 현재 실행 중인 새 앱에서 RAM·GPU·Disk·Battery 팝오버를 필요한 테마로 열고 같은 폭에서 큰 수치와 고유 영역이 함께 보이게 캡처한다. GPU는 원래 OFF이므로 확인을 위해 켰다면 끝나자마자 OFF로 복원하고, 테마도 원래 `system`으로 되돌린다. 캡처에는 개인 프로세스·기기 정보가 보이지 않도록 한다.

## Stage 6-7B-2 큰 카드 제거와 지표별 정보 보존 (2026-10-28)

- **확인:** CPU 플랫 화면의 사용자 승인을 기준으로 RAM·GPU·Disk·Battery의 큰 핵심 카드 배경·클리핑·테두리만 제거했다. 전체 material은 유지하고 RAM 메모리 분해, GPU 실험적 안내, Disk APFS·I/O, Battery 충전·게이지·온도 정보를 보존했다. RAM·GPU는 CPU의 Aurora 면/glow 좌우 페이드를 재사용하지만 Disk I/O 그래프에는 적용하지 않는다. 관련 테스트와 전체 380개 자동 테스트, Debug·Release 빌드는 통과했다.
- **미확인:** 네 팝오버의 새로운 실제 앱 화면과 세 테마에서의 간격·가독성은 확인하지 못했다. 빌드는 `/private/tmp/tokenly-stage6-7b2-debug`에 준비됐지만 이전 PID 20516을 종료·교체하지 않았다. 이전 실기기 화면 확인 결과를 새 디자인 확인으로 옮겨 쓰지 않는다. CPU 라이트 테마와 세부 상호작용도 별도 확인 대상이다.
- **📸 캡처 추천:** 앱 교체 승인 뒤 RAM·GPU·Disk·Battery를 다크·라이트에서 열고 동일한 폭으로 캡처한다. 큰 카드 경계가 사라져도 지표별로 필요한 내부 구분이 남았는지 비교한다. GPU 미지원·Battery 상태는 실제 환경의 상태로 표기하고, 개인 프로세스 이름·기기 정보는 공개 전 가린다. 캡처만을 위한 불필요한 재실행은 피한다.

## Stage 6-7B-1 최신 Debug 앱 검증 한계 (2026-10-28)

- **확인:** 이전 PID 4050은 실행 직전 이미 없었다. 최신 Debug 빌드를 정상 실행해 PID 20516과 원래 번들 ID·버전 `0.1.0 (3)`, 설정값 보존, Tokenly 단일 프로세스를 확인했다. 앱 종료·강제 종료·설정 변경은 없었다.
- **미확인:** 메뉴 막대 전용 앱을 UI 자동화가 선택하지 못해 새 CPU 팝오버의 실제 카드 제거·수치 정렬·오로라 페이드·테마·클릭은 눈으로 확인하지 못했다. 코드와 테스트로 확인한 것과 실제 화면 확인은 분리해 기록한다.
- **📸 캡처 추천:** 현재 실행 중인 최신 Debug 앱의 CPU 팝오버를 다크·라이트에서 직접 열어 같은 크기로 캡처한다. 그래프 좌우 경계와 큰 수치/% 기준선을 보여주고, AI 팝오버와 배경 인상을 비교한다. 캡처 시점은 사용자 설정을 변경하기 전후 기록을 남긴 뒤이며 프로세스 이름 등 공개하기 어려운 정보는 가린다. 추가 앱 재실행은 캡처만을 위해 필요하지 않다.

## Stage 6-7B-1 CPU 카드 제거와 오로라 경계 (2026-10-28)

- **확인:** 승인된 플랫 차콜 A안을 CPU View에만 적용했다. 카드 배경·테두리·클리핑을 제거했고 전체 `.regularMaterial`은 유지했다. Aurora 그래프는 공유 View이므로 기본값 OFF의 CPU 전용 옵션으로 면 채움·glow의 양끝 5.5%만 페이드한다. 라인과 현재값 점은 페이드하지 않는다. 기존 379개에 새 회귀 테스트 1개를 더한 380개가 통과했고 Debug·Release 빌드가 성공했다.
- **오류와 원인:** 첫 픽셀 렌더 테스트는 60초 기록에서 오래된 첫 점이 버려지는 성질과 투명 이미지의 빈 픽셀을 잘못 가정해 실패했다. 보존 창 안의 샘플과 페이드 함수의 경계·기본 OFF를 검증하도록 고쳤다. 이 테스트는 실제 앱의 픽셀 품질을 보장하지 않는다. 첫 샌드박스 빌드의 SwiftUI 매크로 서버 오류는 일반 실행 환경에서 재시험해 통과했다.
- **미검증:** 이전 Debug 앱 PID 4050은 유지했으므로 새 플랫 CPU 화면은 실제 앱에서 아직 보지 않았다. 다크·라이트 material 위의 glow, 양끝의 자연스러운 페이드, TOP 5 가독성, UI 접근성은 이후 실제 화면에서 확인해야 한다. 6-7A 정적 시안은 실제 앱 캡처가 아니다.
- **📸 캡처 추천:** 앱 교체 승인 후 새 CPU 팝오버의 다크·라이트 화면을 같은 크기로 캡처해 `Preview/Stage6-7A-CPU/cpu-flat-{dark,light}.png`와 비교한다. 포인트는 정적 시안의 직각 그래프 가장자리를 실제 구현에서 페이드로 고친 과정이다. 프로세스 이름·사용자 정보가 보이면 공개 전에 가린다.

## Stage 6-7A 카드 경계와 Aurora 효과 분리 (2026-10-28)

- **확인:** CPU 카드 배경·클리핑·테두리는 `CPUPopoverView.swift`, 선·영역·빛 번짐은 `AuroraGraph.swift`에 구현되어 있다. 정적 SwiftUI 비교 시안 6장은 `Preview/Stage6-7A-CPU/`에 보존했다. 세 안은 동일한 예시 수치·그래프를 사용하므로 측정값 비교 자료가 아니다.
- **검증 필요:** 카드 경계를 제거했을 때 실제 앱의 material 위에서 glow가 어디까지 보이는지, 광원 대비와 실시간 갱신·접근성 동작이 유지되는지는 아직 제품 UI에 적용하지 않았으므로 확인되지 않았다. 시안은 실제 앱 캡처가 아니다.
- **📸 캡처 추천:** `Preview/Stage6-7A-CPU/`의 다크·라이트 3안 이미지를 나란히 배치한다. 캡처 시점은 사용자 시안 선택 전, 핵심은 동일한 예시 데이터에서 카드 경계만 바꾸어 비교한 판단 과정이다. 실측값·사용자 정보로 소개하지 않는다.

## Stage 6-6C 후속 실제 화면 확인 (2026-10-28)

- **사용자 수동 검증 완료:** 최신 Debug 앱에서 CPU·RAM·Disk·Battery 좌클릭 팝오버, AI 좌·우클릭, 시스템 항목 우클릭 `Tokenly 종료`, 시스템 스위치 5개, Battery `최대 용량`·ⓘ, 숫자형·최소형, 세 가지 테마, 재실행 후 설정 복원, 기존 종료 버튼·우클릭 종료·⌘Q 종료를 사용자가 직접 확인했다. 아래 6-6B의 '실제 클릭 미확인'은 당시 시점의 기록이다.
- **블로그에서 구분할 점:** 이 결과는 사용자 수동 확인이며 자동 UI 테스트나 계측 정확도 검증이 아니다. GPU 좌클릭 팝오버, 스위치 OFF의 내부 샘플링 중지, 팝오버와 우클릭 메뉴의 동시 표시 여부 등 사용자가 보고하지 않은 항목을 성공 사례로 확대하지 않는다. 기존 화면 캡처가 있다면 사용자 정보·경로를 가린 뒤 활용하고, 캡처만을 위한 앱 재실행은 하지 않는다.

## Stage 6-6~6-6B 기록 (2026-10-28)

- **확인된 사실:** `MenuBarExtra(.window)`는 기존 AI 1개와 시스템 5개에 쓰인다. SwiftUI의 공개 `MenuBarExtra` API에는 버튼별 우클릭 메뉴 지정자가 없다. 기존 좌클릭 팝오버를 보존하려고 앱 안의 상태 막대 창에 한정한 로컬 오른쪽 마우스 이벤트 처리 방식을 적용했다. 새 빌드에서 팝오버가 동시에 열리지 않는지는 실기기 확인 전이므로 성공 사례로 쓰지 않는다.
- **확인된 사실:** 저장된 `menuBar.displayStyle=bear`는 enum에서 사라지면 기존 미지원 스타일 이전 경로를 통해 `numeric`으로 저장된다. 다른 저장 키는 건드리지 않는다. 이전 곰돌이 렌더러와 에셋은 삭제 승인 전까지 파일로 보존하되 앱 타깃에서는 제외했다.
- **검증 결과:** 전체 테스트 379개 통과(옛 곰돌이 전용 테스트 7개 제거), Debug·Release 빌드 성공. 별도 번들 ID의 임시 앱 프로세스는 실행됐지만 UI 자동화에서 메뉴 막대 전용 앱을 선택할 수 없어 새 UI의 실제 클릭 결과는 미확인. 기존 실행 앱을 교체하지 않았다.
- **블로그 소재:** SwiftUI 메뉴 막대의 좌클릭 팝오버와 우클릭 메뉴를 함께 요구할 때 공개 API의 경계, 전역 감시 없이 이벤트 범위를 제한한 설계, 실제 앱 검증 전까지 추정과 사실을 분리한 과정. 캡처는 새 빌드에서 우클릭 메뉴와 좌클릭 팝오버가 각각 확인될 때만 추천한다. 앱 메뉴에 계정·토큰·민감 경로가 보이면 가린다.
- **6-6B 확인된 사실:** 기존 Debug PID 94237을 정상 종료하고 원래 번들 ID·설정값으로 최신 Debug PID 4050을 실행했다. 실행 전후 사용자 설정 9개 값이 동일했다. 메뉴 막대 전용 앱을 UI 자동화가 선택하지 못해 실제 클릭 결과는 확인하지 않았다. 접근성 권한을 바꾸지 않았으며, 클릭 성공을 추정으로도 기록하지 않는다.
- **예상 밖의 결과:** 새 Debug 앱 PID 4050 실행 약 17초 뒤 `/Applications/Tokenly.app` PID 4085가 함께 나타났다. 설치본에 정상 종료 요청을 보내고 5초 뒤 Debug 앱 하나만 남았다. 왜 설치본이 시작됐는지는 미확정이며 로그인 항목 때문이라고 단정하지 않는다. 다중 사본·같은 번들 ID가 UI 검증을 왜곡할 수 있으므로 검증 전후 PID·실행 경로를 함께 기록한 사례다.
- **파일 정리 판단:** 앱 타깃·테스트에서 곰돌이 렌더러와 17개 리소스가 참조되지 않는 것을 확인하고 Git 추적 파일을 삭제했다. `Preview/Heart3D/`는 원인 분석·제작 과정의 근거라 보존했다. 루트 `default.profraw`는 0바이트여서 삭제했고 `src/default.profraw`는 60,768바이트 과거 계측 원본이라 보존했다. 블로그에서는 "제품에서 제거"와 "기술 기록 보존"을 분리해 설명할 수 있다.

블로그 초안용 사실 정리입니다. 각 항목은 저장소 안의 코드·기록·이미지로 확인할 수 있는 것만 적었습니다. "근거"의 `IMP-PLAN §n`은 `Doc/IMP-PLAN.md`의 n절입니다. 기준 시점: v0.1.0 개발 버전(2026-10-23).

## 1. 배경과 해결하려던 문제

- Codex, Claude Code, Google Antigravity(AGY)를 함께 쓰면 각 서비스의 5시간·주간 한도를 확인하는 위치와 방식이 모두 다르다.
- 목표: 메뉴 막대 한 곳에서 **공식적으로 제공되는 데이터만** 보여 주고, 모르는 값은 0%로 채우지 않는다.
- 근거: `Doc/SPEC.md` 1절, `README.md` "개발 동기"

## 2. 전체 데이터 흐름

| 단계 | 내용 | 근거 |
|---|---|---|
| Codex 조회 | `codex app-server --listen stdio://` 실행 → `initialize` → `initialized` → `account/rateLimits/read`, 20초 제한, stderr 폐기 | `src/Tokenly/Providers/CodexUsageProvider.swift` |
| Codex 파싱 | `rateLimitsByLimitId["codex"]` 우선, 300분/10080분 창을 5시간/7일로, `rateLimitResetCredits` 별도 | 같은 파일 `CodexRateLimitParser` |
| Claude·AGY 수신 | 각 CLI의 `statusLine` 명령이 브리지 스크립트에 JSON을 넘기고, 브리지가 필요한 필드만 로컬 파일에 저장 | `src/Tokenly/ClaudeStatusLineBridge.py`, `AGYStatusLineBridge.py` |
| Claude·AGY 읽기 | 파일을 읽어 15분(`maxAge: 900`)이 지나면 stale | `Providers/ClaudeSubscriptionProvider.swift`, `AGYStatusLineProvider.swift` |
| 상태 보존 | 조회 중에도 마지막 결과를 보이도록 `settledStates`, 과거 유효 값 `lastValidQuotas` | `src/Tokenly/ExternalProviderStore.swift`, IMP-PLAN §23 |
| 표시 규칙 | 보일 서비스·숨김·stale·대표값(최저 잔여율) | `Models/HeartGauge.swift`, `Models/NumericGauge.swift` |
| 렌더링 | 메뉴 막대는 비트맵 이미지로, 팝오버는 SwiftUI | `Views/MenuBarNumericRow.swift`, `MenuBarGaugeRow.swift`, `BearGaugeView.swift`, `UsageMenuView.swift` |

## 3. 왜 Codex app-server JSON-RPC인가

- Codex CLI가 제공하는 공식 인터페이스이고, 로그인·토큰 처리를 CLI에 맡길 수 있다. Tokenly는 인증정보를 직접 다루지 않는다.
- `codex app-server generate-json-schema`로 프로토콜 스키마를 로컬에서 생성해 필드를 확인할 수 있다. 재설정 권한(`rateLimitResetCredits`)도 이 스키마에서 찾았다. 권한을 **소모하는** `account/rateLimitResetCredit/consume`은 쓰지 않는다.
- 한계: CLI에서 experimental로 표시된 기능이다.
- 근거: IMP-PLAN §37–38, `CodexUsageProvider.swift`, `TokenlyTests`의 `testResetCredits*`

## 4. Claude·AGY statusLine 브리지

- 두 CLI는 상태줄을 그릴 때 사용량을 포함한 JSON을 표준 입력으로 넘긴다. 브리지는 그중 한도 필드만 골라 `~/Library/Application Support/Tokenly/`에 저장한다.
  - Claude: `rate_limits.five_hour/seven_day`의 `used_percentage`, `resets_at`
  - AGY: 버킷별 `remaining_fraction`
- 폴더 0700, 파일 0600, 같은 폴더의 임시 파일을 이름 바꾸기로 원자적 교체. 세션·계정·경로 등 원본 JSON은 저장하지 않는다.
- **0.1.0 개발 빌드(첫 커밋):** Python 브리지(`ClaudeStatusLineBridge.py`, `AGYStatusLineBridge.py`)와 설정 스크립트(`scripts/enable_claude_statusline.py`, `enable_agy_statusline.py`). 스크립트는 기존 `statusLine`이 있으면 중단했다.
- **현재 소스:** 앱 실행 파일이 브리지를 겸한다(`Tokenly --statusline claude|agy`, `TokenlyMain.swift` → `BridgeCommand.swift` → `StatusLineBridge.swift`). 연결·해제는 `--connect`/`--disconnect`(`StatusLineConnector.swift`)로 미리 보기·확인·백업 후 `statusLine` 값만 제자리 편집하고, 기존 statusLine이 있으면 보존해 같은 입력으로 실행한 출력을 그대로 보여 준다. Python 파일은 호환용으로 남아 있다. 근거: IMP-PLAN §47–48, `StatusLineTests.swift`
- **이벤트 기반 갱신의 한계:** CLI를 쓰지 않으면 새 값이 오지 않는다. Tokenly의 새로고침은 파일 재읽기일 뿐이다.
- 근거: IMP-PLAN §13, §16, §19–21, §47–48

## 5. 3D 곰돌이 게이지와 메뉴 막대 렌더링

1. **2D → 3D:** 하트·곰돌이 윤곽 안에서 Poisson 방정식(∇²h = −1)을 풀어 풍선처럼 부풀린 높이를 만들고 메시를 생성했다. `Preview/Heart3D/HeartMesh.swift`, IMP-PLAN §26
2. **SceneKit PBR 렌더:** 투명 유리 껍질과 안쪽 젤리 코어, 림 조명. Blender가 없어 macOS 기본 SceneKit을 썼다. `Preview/Heart3D/Render3D.swift`, `BearModel.swift`
3. **게이지 구조:** 같은 조명으로 빈/채움 레이어를 따로 렌더링해 서비스 4종 × 2레이어 × @2x·@3x를 PNG로 내보낸다. 앱은 잔여율 높이에서 두 이미지를 합성만 하며, 런타임에 SceneKit을 쓰지 않는다. `BearExportB.swift`, `src/Tokenly/Views/BearGaugeView.swift`, IMP-PLAN §27, §32
4. **메뉴 막대 라벨:** `MenuBarExtra` 라벨은 일반 `Text`·`Image`만 안정적으로 그린다. 그래서 숫자·이름·외곽선까지 Core Graphics/Core Text로 정수 pt 비트맵 하나에 그려 넣는다. `MenuBarGaugeRow.swift`, `MenuBarNumericRow.swift`
5. 시안 이미지: `Preview/Heart3D/10-bear-original.png`, `12-bear-menubar-2x-retina.png`, `60-bear-b-app-actual-2x.png`

## 6. 주요 오류·원인·해결

| 문제 | 원인 | 해결 | 근거 |
|---|---|---|---|
| 3D 메시가 하트가 아니라 마름모 | 1단위 크기 경로에서 SwiftUI `Path.contains`가 곡선을 거칠게 근사 | `CGPath.contains` 사용 | `Preview/Heart3D/HeartMesh.swift` 주석, IMP-PLAN §26 |
| 메시 한쪽에 가시 | 길이 0 trim의 `currentPoint`가 nil → (0,0) | 반 칸 오프셋으로 샘플 | 같은 파일 |
| 곰돌이 귀 사이 V자 주름 | 중심 방사형 링 메시가 오목한 윤곽에서 접힘 | 격자 메시 + 윤곽 정점 이분법 | `GridMesh`, IMP-PLAN §26 |
| 유리가 밝은 배경에서 하얗게 뜸 | SceneKit 스냅샷이 premultiplied로 표시되지만 반투명 픽셀은 straight color(A=100, R=144) | 픽셀별 알파 곱 | `Render3D.swift` `premultiplied` |
| `100%`가 곰돌이 윤곽을 덮음 | 큰 시안의 글자 크기를 그대로 축소 | 실루엣 대비 잉크를 픽셀로 측정해 크기 조정, 회귀 테스트 | `TokenlyTests` `testBearDigitsCentredAndNamesHorizontal`, IMP-PLAN §27, §30 |
| 숫자가 시각 중앙에서 어긋남 | 텍스트 상자 = 어센더·행간·좌우 여백 포함 | Core Text 글리프 잉크 상자 기준 중앙 정렬, 잉크 가장자리를 픽셀 격자에 스냅 | `GaugeDigits`, IMP-PLAN §30, §32 |
| 이름 둘레에 외곽선이 다시 생김 | 이름 자리를 지운 뒤 외곽선 계산 | 외곽선 → 지우기 → 이름 순서 | `MenuBarGaugeRow.render`, IMP-PLAN §32 |
| 숫자형 열마다 이름 높이가 다름, 숫자–이름 간격 축소 | 열별 잉크 중앙 정렬, 대문자 높이 기준, `/`가 기준선 아래로 내려감 | 값과 무관한 글꼴 측정, 실제 글리프("0", "Cdl") 측정, `/` 잉크를 세로 중앙에 | `MenuBarNumericRow.vertical`, IMP-PLAN §33 |
| 시안과 앱 외곽선 색이 37px 다름 | 시안 스크립트의 곰돌이 소속 열 추정 오류 | 실루엣 구간 방식으로 통일, 픽셀 차 0 확인 | IMP-PLAN §29 |
| 흰 이름 색 테스트 실패 | premultiplied 픽셀을 그대로 평균 | 알파로 나눠 비교 | `TokenlyTests` `checkIcons` |
| 갱신 순간 하트/곰돌이가 깜박일 위험 | `.loading`이 이전 값을 버림 | 조회 완료 상태만 담는 `settledStates` | `ExternalProviderStore.swift`, IMP-PLAN §23 |
| Release 빌드가 arm64만 | 일반 `build`는 활성 아키텍처만 | `-destination 'generic/platform=macOS'`로 universal 확인 | IMP-PLAN §39 |
| 요청 해석 오류 | "간격"을 `/` 양옆으로 해석 | 사용자 정정 후 서비스 간격으로 수정 | IMP-PLAN §35–36 |

## 7. 테스트와 검증 방식

- XCTest 91개(호스트 앱 테스트, 2026-10-25 실행 전부 통과): 파싱, 만료, 표시 규칙, 재설정 권한, 스타일 저장·이전, 렌더 결과의 크기·정렬·잘림(픽셀 단위), statusLine 브리지·연결·해제(임시 홈). `src/TokenlyTests/TokenlyTests.swift`, `StatusLineTests.swift`
- 디자인 결정은 **실제 Retina 픽셀(2배율)과 보간 없는 확대**로 비교했다. 확대에서만 좋아 보이는 시안을 걸러내기 위해서다. `Preview/*/`
- GUI 자동화 권한이 없어 메뉴 막대 실화면은 개발자가 직접 확인했다. 자동 GUI 테스트는 없다.

## 8. 아직 해결하지 못한 한계

- 서명·공증된 설치 파일 없음(코드 서명 인증서 없음, Hardened Runtime 꺼짐) — IMP-PLAN §39
- (해결) 0.1.0 개발 빌드의 브리지는 `/usr/bin/python3`에 의존했고 설정 스크립트가 저장소 경로를 등록했다 → 현재 소스는 네이티브 브리지와 `--connect`로 대체. 실제 Claude Code·AGY 설정을 새 명령으로 바꾸는 전환은 아직 하지 않았다
- Claude·AGY는 이벤트 기반이라 CLI를 쓰지 않으면 값이 멈춤, stale 15분 기준은 임시값
- Codex app-server는 experimental
- 메뉴 막대 비트맵의 이름 색은 라벨의 `colorScheme`에 의존하며, 바탕화면에 따라 바뀌는 메뉴 막대에서의 동작은 충분히 검증되지 않음
- 이름 폭이 곰돌이 턱보다 넓어 "윤곽의 일부"로 완전히 통합되지 않음 — IMP-PLAN §31–32

## 9. System Monitor 개발 기록 (2026-10-27~)

System Monitor(CPU·RAM·Battery·Disk·GPU) 개발 중의 기술적 근거를 모은다. **[확인]**은 실측·테스트로 확인한 사실이고 **[추정]**은 검증하지 않은 해석이다. 측정 원본 로그는 세션 임시 폴더에만 있어 사라질 수 있으므로 수치와 재현 방법을 여기에 남긴다. 요구사항·현황은 `Doc/SYSTEM-MONITOR.md`, 단계별 검증 결과는 `Doc/HANDOFF.md`에 있다.

### 9.1 설계 원칙: "모르면 0이 아니라 모른다"

- 모든 지표는 `SystemMetric<Value>`(`.available` 또는 `.unavailable(사유)`)로 표현한다. 사유는 `awaitingBaseline`, `counterReset`, `noElapsedTicks`, `inconsistentValues`, `readFailed`, `noBattery`, `unsupported`다. 근거: `src/Tokenly/SystemMonitor/SystemMetrics.swift`
- 계산(순수 값 타입), 수집(Mach·IOKit 호출), 상태(Store)를 분리했다. 계산과 파싱은 하드웨어 없이 고정 입력으로 테스트한다. 근거: `SystemMonitorTests`, `BatterySamplerTests`, `SystemMonitorStoreTests`

### 9.2 CPU: 누적 tick의 차이와 32비트 카운터

- [확인] `host_statistics(HOST_CPU_LOAD_INFO)`는 부팅 이후 누적 tick을 `natural_t`(UInt32)로 준다. 사용률은 두 샘플 사이의 차이로만 구할 수 있어서 첫 샘플은 측정 불가다.
- [추정] 모든 코어를 합친 32비트 카운터는 코어 수에 따라 수 주 만에 한 바퀴 돈다(예: 16코어 × 100 tick/s 기준 약 31일). 감소와 재설정을 구분할 수 없어 감소한 구간은 건너뛰고 기준을 새로 잡는다.
- [확인] `mach_host_self()`는 호출할 때마다 send right 참조를 늘린다. 한 번만 얻고 해제하며, 1,000회 측정 뒤 참조 수가 그대로임을 테스트했다. 근거: `testRepeatedSamplingDoesNotLeakHostPortReferences`
- [확인] 측정 1회 CPU 약 6.5 µs(20만 회 반복, `swiftc -O` 독립 실행).

### 9.3 RAM: 활동 모니터 기준과 압축 메모리

- [확인] used = App(internal − purgeable) + Wired + Compressed(compressor가 차지한 물리 페이지). Cached Files는 회수할 수 있어 제외했다. 16 GiB Apple Silicon에서 페이지 수가 `vm_stat` 출력(wired 162,022 / compressor 360,056 / anonymous − purgeable 275,071 페이지 × 16 KiB)과 일치했다.
- [과거 추정] 초기 검증 때는 같은 화면 비교가 없어 측정 시점·반올림 차이를 예상했다. 위의 사용자 제공 동일 캡처가 이 설명만으로는 부족함을 보여 준다.

#### 별도 조사 주제: 세부 항목은 맞는데 전체 RAM만 다른 이유 (조사 종료·원인 미확정)

1. **문제 발견 [사용자 제공 값]:** 동일 캡처에서 물리 메모리 양쪽 24GB, 활성 상태 보기/Tokenly 전체 18.00/16.59GB. 앱 9.30/9.31GB, 와이어드 2.73/2.73GB, 압축 4.55/4.55GB. Apple 세부값 합도 16.58GB다. 캡처 원본은 이번 조사에서 직접 확인하지 않았다.
2. **가설 [미검증]:** 전체값의 분류 기준이 다르거나 세부 세 항목 밖의 영역이 있다. GB/GiB, 표시 반올림, 갱신 시점은 보조 가설이다. 특정 영역(GPU·커널 등)이나 Apple 내부 산식은 단정하지 않는다.
3. **검증 [확인]:** `SystemMetrics.swift`의 `MemoryUsage.calculate`는 `(internal_page_count − purgeable_count + wire_count + compressor_page_count) × pageSize`를 사용한다. `MachSystemSampler.swift`는 `HOST_VM_INFO64`를 읽고, `RAMPopoverView.swift`는 같은 `usedBytes`를 전체값으로 표시한다. Apple 활성 상태 보기 [사용 설명](https://support.apple.com/en-lb/guide/activity-monitor/actmntr1004/mac)은 각 항목의 의미를 설명하지만 전체 계산식은 제시하지 않는다. [XNU vm_statistics.h](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/vm_statistics.h)에서 speculative는 free에 이미 포함되며, [host.c](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/host.c)는 internal/external을 pageable 카운터에서 채운다. 이 코드만으로 Apple 앱의 전체 산식은 알 수 없다.
4. **다음 안전 진단 [설계]:** 제보된 Mac에서 활성 상태 보기의 전체·앱·와이어드·압축·Cached Files와 Tokenly 화면을 동시에 캡처한다. 바로 전후에 `date -u '+%Y-%m-%dT%H:%M:%SZ'; vm_stat; sysctl -n hw.memsize`를 실행해 페이지 크기와 free·speculative·internal(Anonymous)·external(File-backed)·purgeable·wired·compressor 및 물리 용량만 기록한다. 가능하면 짧은 간격으로 2~3회 반복해 갱신 지연을 구분한다. 프로세스 목록·계정·인증 정보·환경변수는 수집하지 않는다. 분석은 원시 바이트 기준으로 `Tokenly used`, `Tokenly Cached Files=(external+purgeable)×pageSize`, `total−used−cached−free`를 각각 산출한다. 마지막 값은 **미분류 차이**일 뿐 Apple 사용량의 누락분이라고 부르지 않는다. speculative를 free에 다시 더하지 않는다.
5. **원인·해결 [미확정]:** 같은 시점의 원시 카운터로 재현 가능한 계산 오류가 확인되면 먼저 반례 fixture 테스트를 추가한 뒤 최소 수정안을 제안한다. 서로 다른 지표라면 수치 보정 없이 Tokenly의 합산 기준과 활성 상태 보기 전체값과의 비교 한계를 UI 도움말에 밝히는 방안을 제안한다. 어느 경우에도 사용자 승인 전 RAM 계산식·UI는 변경하지 않는다.
6. **회귀 테스트 [계획]:** 기존 `SystemMonitorTests.swift`의 페이지 수·오버플로 검증과 `RAMPopoverTests.swift`의 구성 합산 검증을 기준선으로 삼는다. 확정된 원인에 맞는 원시 카운터 fixture, 0/상한·중복 집계·단위 변환·표시 문구 테스트만 추가한다. 이번 조사에서 새 테스트나 실제 수정 전후 결과는 없다.

**RAM-02 실측 [개발 Mac, 2026-10-29]:** 저장소 밖 `/private/tmp/tokenly_ram02_diagnostic.swift`가 `host_statistics64(HOST_VM_INFO64)`와 `host_page_size`, `ProcessInfo.physicalMemory`만 읽었다. macOS 27.0.1, 물리 17,179,869,184B(16GiB), 페이지 16,384B. UTC 05:50:36.484 / 37.494 / 38.500의 연속 3회에서 Tokenly 식 사용량은 14,095,466,496 / 14,116,896,768 / 14,169,833,472B, Cached Files **후보식**은 2,367,537,152 / 2,345,254,912 / 2,286,108,672B였다. 세부 합계는 매번 사용량과 정확히 같았다. `total−used−cached후보−free`는 603,373,568 / 597,016,576 / 595,607,552B(약 0.56GiB)였다. 이는 XNU 카운터 간 **잔차**이지 Apple 사용량의 누락분으로 확인된 값이 아니다. 제보 캡처의 Mac은 24GB로 이 개발 Mac과 다르며, 이번 3회에 대응하는 활성 상태 보기 GUI 값·Apple Cached Files 값은 없다. `ByteCountFormatter(.memory)`의 GB 표기는 이 환경에서 1024³B 기준으로 나타났으므로 표시 단위도 별도로 대조해야 한다. 제품 코드·UI·테스트는 변경하지 않았다.

**실측 원시 카운터 (free에 speculative 포함, 페이지 수):** ① internal 222,458 / purgeable 0 / wired 201,134 / compressor 436,727 / external 144,503 / free 6,927 / speculative 1,879. ② 223,395 / 0 / 201,473 / 436,759 / 143,143 / 7,367 / 2,267. ③ 225,967 / 0 / 204,404 / 434,487 / 139,533 / 7,832 / 2,418. 프로세스·계정·파일·인증 자료는 수집하지 않았다.

**RAM-02 추가 화면 증빙 [사용자 제공 표시값, 캡처 시각 미제공]:** 같은 화면의 16.00GB Mac에서 활성 상태 보기 전체 13.88GB / Tokenly 13.29GB(83%), 양쪽 앱 4.97GB·와이어드 2.94GB·압축 5.37GB, Apple Cached Files 2.05GB·스왑 5.85GB. 세부 표시값 합계는 13.28GB로 Tokenly 전체와 0.01GB 차이(표시 반올림 가능)지만 Apple 전체보다 0.60GB 낮다. 전체 표시 차이 0.59GB는 **이 화면에서 확인된 현상**이다. 원본 이미지·캡처 시각은 이번 조사에서 직접 확인하지 못했다. 스왑은 디스크 공간이므로 RAM 합계에 단순 가산하지 않는다. `16.00−13.88−2.05=0.07GB`는 표시값만의 산술 관계이며 Apple 산식의 증거가 아니다.

**RAM-02 추가 원시 측정 [이 개발 Mac, UTC 06:02:37.502 / 38.512 / 39.517]:** `date -u`는 직전 06:01:40Z, `sysctl -n hw.memsize`는 17,179,869,184B, 별도 `vm_stat`는 16,384B 페이지·free 5,988·anonymous 256,524·purgeable 27·wired 206,871·compressor occupied 393,002·file-backed 147,480이었다. 이 명령들은 순차 실행이므로 서로 같은 순간의 샘플이 아니다. 이어서 같은 `HOST_VM_INFO64` 호출에서 읽은 3회 결과는 아래와 같다. 단위는 페이지 수 또는 원시 바이트다.

| UTC 시각 | internal / purgeable / wired / compressor / external / free / speculative (페이지) | Tokenly used = 세부 합계 (B) | Cached Files 후보 (B) | total−used−cache후보−free (B) |
|---|---|---:|---:|---:|
| 06:02:37.502 | 264,014 / 0 / 199,046 / 384,458 / 157,246 / 6,955 / 1,877 | 13,885,734,912 | 2,576,318,464 | 603,865,088 |
| 06:02:38.512 | 261,388 / 1,260 / 205,154 / 383,534 / 154,422 / 7,209 / 1,837 | 13,907,001,344 | 2,550,693,888 | 604,061,696 |
| 06:02:39.517 | 256,430 / 8 / 214,049 / 381,250 / 152,135 / 7,858 / 1,852 | 13,954,596,864 | 2,492,710,912 | 603,815,936 |

**가설 평가:** 세부 합산과 원시 카운터의 매핑은 이 3회에서 일치했다. 잔차는 약 0.604GB(십진)로 안정적이지만 캡처의 0.59GB와 시각이 연결되지 않아 동일 영역이라고 확정할 수 없다. `Cached Files` 후보도 같은 순간 Apple 2.05GB와 직접 비교하지 못했다. GB/GiB·1초 Tokenly 갱신·활성 상태 보기 갱신/반올림의 기여도도 미확정이다. Apple 전체 계산식·잔차의 정체·계산 오류 여부는 여전히 미확정이며 고정 보정값을 쓰지 않는다. 다음에는 캡처 UTC 시각을 포함해 원시 샘플 바로 전후 화면값을 짝지어 비교한다. 제품 계산식·UI는 수정하지 않았다.

**동시 측정 준비 [완료, 이후 사용자 실행]:** 저장소 밖 `/private/tmp/tokenly_ram02_simultaneous.swift`를 `swiftc -typecheck`한 뒤 사용자에게 전달했다. 5초 준비 시간 뒤 1초 간격 12회, 각 회의 UTC·원시 페이지 카운터·물리 RAM·Tokenly 식 세부값/합계·Cached Files 후보·잔차를 바이트/십진 GB/이진 GiB로 출력한다. 이 준비 단계에서는 실행하지 않았고, 이후 사용자가 실행해 아래 결과를 제공했다.

**RAM-02 12회 로그 분석 [사용자 실행 결과, UTC 06:12:35.528~46.572]:** 원본 `/private/tmp/tokenly-ram02-simultaneous.txt`의 12회 모두 물리 17,179,869,184B(16GiB), 페이지 16,384B. 표의 사용량·캐시는 GiB(1024³B), 잔차는 십진 GB(10⁹B)와 GiB를 병기했다. 매회 앱+와이어드+압축=Tokenly 식 사용량이다.

| # | UTC 시:분:초 | Tokenly 식 GiB | Cached Files 후보 GiB | 잔차 GB / GiB |
|---:|---|---:|---:|---:|
| 1 | 06:12:35.528 | 13.508 | 1.774 | 0.604 / 0.563 |
| 2 | 06:12:36.534 | 13.461 | 1.855 | 0.601 / 0.560 |
| 3 | 06:12:37.539 | 13.498 | 1.831 | 0.601 / 0.559 |
| 4 | 06:12:38.544 | 13.571 | 1.757 | 0.628 / 0.585 |
| 5 | 06:12:39.550 | 13.518 | 1.793 | 0.627 / 0.584 |
| 6 | 06:12:40.551 | 13.545 | 1.758 | 0.628 / 0.585 |
| 7 | 06:12:41.556 | 13.531 | 1.786 | 0.629 / 0.586 |
| 8 | 06:12:42.559 | 13.535 | 1.741 | 0.631 / 0.588 |
| 9 | 06:12:43.560 | 13.606 | 1.726 | 0.630 / 0.587 |
| 10 | 06:12:44.565 | 13.489 | 1.784 | 0.630 / 0.587 |
| 11 | 06:12:45.570 | 13.572 | 1.734 | 0.630 / 0.586 |
| 12 | 06:12:46.572 | 13.594 | 1.734 | 0.628 / 0.584 |

**같은 화면 비교 [사용자 제공 표시값, 캡처 UTC 미확인]:** Apple 전체 14.12GB / Tokenly 13.49GB, Apple 세부 4.40+3.10+5.98=13.48GB, Tokenly 세부 4.41+3.10+5.98=13.49GB, Apple Cached Files 1.85GB. 표시 전체 차이 0.63GB. #10의 Tokenly 식 13.489GiB는 전체 표시 13.49에 수치상 가장 가깝지만 원시 세부 앱/와이어드/압축이 3.368/3.398/6.723GiB라 화면의 4.41/3.10/5.98과 맞지 않는다. #12는 사용량 13.594GiB, 세부 3.662/3.353/6.579GiB로 역시 화면값과 다르다. 12회 중 어느 샘플도 세부값을 동시에 재현하지 않으므로 화면과 특정 원시 샘플을 같은 시점의 값으로 연결할 수 없다. #8의 `used+잔차` 14.123GiB가 Apple 전체 14.12와 수치상 가까운 것도 공식 산식의 증거가 아니다.

**가설 평가 [원인 미확정]:** 잔차는 0.601~0.631 **십진 GB**(0.559~0.588GiB), 사용량은 13.461~13.606GiB, 캐시 후보는 1.726~1.855GiB로 변했다. 이전 별도 3회 잔차 약 0.604GB와 이번 #1~3은 가까웠고, #4부터 약 0.628GB로 올라 안정됐다. 앞선 화면 전체 차이 0.59와 이번 0.63은 모두 **표시 GB**이며, 원시 잔차의 십진 GB와 단위를 확인하지 않고 숫자만 비교하면 안 된다. Tokenly `ByteCountFormatter(.memory)`는 이 환경에서 이진 단위를 GB로 표기했다. Apple 표시 단위·반올림·화면 갱신 시각은 아직 확인되지 않았다. [XNU vm_statistics.h](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/vm_statistics.h)는 `speculative`가 free에 포함되고 `total_uncompressed_pages_in_compressor`는 압축 전 페이지 수라고 정의한다. [XNU host.c](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/host.c)가 `active`/`inactive`를 페이지 큐에서, internal/external을 pageable 분류에서 채우는 점을 보면 서로 독립된 잔차 항목처럼 더해서는 안 된다(코드에서의 추론). `HOST_VM_INFO64`에는 잔차와 직접 대응한다고 확인된 단일 필드가 없다. 메모리 예약·VM 관리 범주가 후보일 수 있지만 이 로그로 특정할 수 없다. Apple [활성 상태 보기 설명](https://support.apple.com/en-lamr/guide/activity-monitor/actmntr1004/mac)은 전체의 정확한 산식을 공개하지 않는다. 고정 보정값·RAM 계산식·UI 변경 없음.

**다음 검증:** 원본 캡처에서 보이는 `SAMPLE #`와 UTC를 확인해 같은 프레임의 화면값을 특정한다. 그래도 세부 항목이 어긋나면 1초보다 빠른 화면 갱신을 단정하지 말고, 같은 구도의 짧은 연속 화면 기록으로 두 앱의 값 변화와 로그 시각을 짝짓는다. 캡처 ③(원인 확정 후 회귀 테스트)은 아직 필요하지 않다.

**RAM-02 갱신 시점 코드 추적 [2026-10-29, 정적 검증]:** `SystemWidgetController.init`는 RAM 저장값이 ON이면 앱 시작 때 `SystemMonitorStore.setEnabled(.memory, true)`를 호출한다. Store는 CPU/RAM 공용 1초 타이머(허용 오차 0.1초)를 만들고 즉시 첫 Task를 시작한다. 이미 Task가 있으면 다음 tick을 건너뛴다. `MachSystemSampler.sample()`은 CPU tick을 읽고 `SystemSnapshot(sampledAt: Date(), ..., memory: readMemory())`를 반환한다. `readMemory()`에서 `HOST_VM_INFO64`를 읽어 즉시 `MemoryUsage.calculate`를 호출하므로 `sampledAt`은 RAM 읽기보다 조금 앞선 시각이다. Store는 Task 완료 후 메인 액터에서 `memory`를 게시하고, `RAMPopoverView`의 `@ObservedObject`가 다음 SwiftUI 렌더에서 그 값을 쓴다. Store는 RAM 읽기·게시 시각을 별도 저장하거나 팝오버에 표시하지 않는다. 팝오버의 열림/닫힘은 `ProcessTopStore`의 프로세스 TOP 5만 제어하고 전체 RAM 측정을 새로 시작하거나 멈추지 않는다. 팝오버 전용 세부값 캐시는 없으나 다음 게시 전까지 기존 `store.memory`가 유지된다. 읽기 실패는 `—`로 바꾸며, 위젯 OFF는 값을 지운다. 긴 Task·메인 루프 지연이 있다면 값이 오래 보일 여지는 있지만 그 발생은 이번 로그에서 확인되지 않았다. 메뉴 막대 숫자 이미지는 정수 퍼센트가 같으면 재사용하므로 GB 세부값 변화와 메뉴 막대 이미지 갱신을 혼동하지 않는다.

**가설별 반례:** 12개 원시 샘플의 앱 메모리는 3.232~3.677GiB, 압축은 6.579~6.946GiB였다. 사용자 화면의 Tokenly 앱 4.41GB·압축 5.98GB는 이 범위 밖이며, 같은 화면의 전체 13.49GB와 수치상 가까운 #10도 세부값은 3.368/3.398/6.723GiB다. 0.01GB 표시 반올림으로 설명되지 않는다. 1초 갱신과 오래된 게시값은 **가능한 시점 차이 경로**지만, 화면이 어느 시점의 Store 샘플인지 현재 코드·로그로 증명할 수 없다. 원본 캡처에서 터미널의 UTC와 `SAMPLE #`가 보이는지 먼저 확인하고, 필요할 때만 짧은 화면 기록으로 변화 순서를 대조한다. 정확한 앱 내부 연결에는 UI를 바꾸지 않는 격리 Debug 빌드에서 RAM 읽기 직후와 Store 게시 직후의 UTC·집계 바이트만 기록하는 진단이 필요하다. 설치 앱·설정·제품 계산식·UI는 변경하지 않는다.

**RAM-02 표시 시각 진단 설계 [준비, 추가 측정 전]:** 기존 캡처의 터미널에는 #11(06:12:45.570Z)·#12(06:12:46.572Z)가 보인다. 이는 화면이 그 시각 부근에 캡처됐다는 단서일 뿐, Tokenly 상세값이 두 원시 호출 중 하나에서 왔다는 증거가 아니다. #11의 앱/와이어드/압축은 3.528/3.340/6.703GiB, #12는 3.662/3.353/6.579GiB로 화면의 4.41/3.10/5.98GB와 일치하지 않는다. 터미널 출력 시각과 화면 렌더 시각도 별도로 계측하지 않았고, 캡처 원본의 메타데이터는 이 조사에서 확인하지 못했다. **가능한 설명**은 화면이 더 이전 Store 값이거나 독립 수집 스크립트와 앱의 위상이 다른 것, 캡처·로그 시점의 차이 등이다. 이 중 어느 것도 현재 증거로 확정되지 않았다.

제품과 설치 앱을 건드리지 않는 **격리 Debug 복사본 진단안**: 저장소 밖 소스 복사본과 다른 번들 ID·UserDefaults 도메인·AI 수신 경로·Keychain 서비스로 빌드한다. 앱 이름과 메뉴 막대 라벨도 진단용으로 구분하고 실제 계정 조회·상태줄 연결은 비활성화한 것을 먼저 확인한다. Debug 복사본에만 일정한 `sampleID`를 부여하고 CPU/RAM 타이머 콜백(시작 또는 진행 중 Task 때문에 건너뜀), `MachSystemSampler`의 RAM `host_statistics64` 호출 직전/직후, `MemoryUsage.calculate` 완료, `SystemMonitorStore.apply` 직전/직후, RAM 팝오버가 새 Store 값을 관찰한 시점을 UTC와 단조 시계로 기록한다. 각 단계에 같은 ID와 앱/와이어드/압축/전체 원시 바이트를 남겨 연결한다. 실제 화면 반영은 SwiftUI 관찰 콜백만으로 증명되지 않으므로 같은 ID·값이 보이는 진단용 별도 화면 기록 또는 프레임 관찰 지점과 타임스탬프를 대조한다. 기존 RAM UI에는 진단 표식을 추가하지 않는다. 로그에는 시스템 메모리 수치·시각·ID만 넣고 계정·프로세스·경로·인증 정보는 넣지 않는다. 현재 진단 빌드·측정은 아직 실행하지 않았다.

**판정 기준:** `tick`은 왔으나 `samplingTask != nil`이면 **건너뛴 tick**으로 직접 센다. tick 자체가 늦게 도착한 것은 timer tolerance/메인 런 루프 지연으로 따로 기록한다. `readEnd−readStart`는 Mach 호출 비용, `calcEnd−readEnd`는 계산 시간, `publish−calcEnd`는 Task 완료/메인 액터 게시 대기, `viewObserved−publish`는 SwiftUI 관찰 지연의 상한 후보로 나눈다. 화면 캡처 프레임에서 읽힌 세부값 세 개를 **동시에** 특정 `sampleID`의 표시 반올림값과 맞춰야 화면과 샘플을 짝지을 수 있다. 한 항목만 같거나 전체값만 비슷하면 연결 실패다. 화면에 보인 ID의 게시 시각과 캡처 시각의 차이로 값의 나이를 계산하고, 1초 주기보다 긴 공백이 실제 있는지 본다. 0.1초 timer tolerance만으로 1초 넘는 지연을 설명하지 않는다. Apple 화면은 별도 갱신 주기이므로 같은 프레임의 값도 같은 커널 호출이라는 뜻은 아니다. 다음 단계 측정이 필요할 때 짧은 동시 화면 기록과 위 진단 로그를 함께 수집한다. 이 단계에서는 실행하지 않고 사용자에게 방법을 안내한 뒤 결과를 기다린다. Apple 공식 산식·잔차 정체·계산 오류·실제 UI 지연은 계속 **미확정**이다.

**격리 Debug 계측 준비 [2026-10-29, 실제 측정 전]:** `/private/tmp/tokenly-ram02-timing-src/src`에 제품 `src`의 별도 복사본을 만들고, 진단 앱 번들 ID `dev.local.tokenly.ram02timing`, 표시 이름 `Tokenly RAM-02 진단`, 별도 UserDefaults suite `dev.local.tokenly.ram02timing.settings`, 별도 Keychain 서비스 및 `TOKENLY_HOME` 경로로 분리했다. 임시 `TokenlyApp` 진입점은 RAM 팝오버·System Monitor만 생성하며 AI Store/Provider, 설정·로그인 항목, 상태줄 연결을 시작하지 않는다. 진단용 앱은 실제 사용자 앱과 다른 메뉴 막대 항목으로 나타난다. `@TaskLocal sampleID`가 Store Task에서 Mach 읽기까지 전달되고, 전용 로컬 로그 `/private/tmp/tokenly-ram02-timing-data/events.log`에 UTC 밀리초·단조 ns·원시 페이지·세부/전체 바이트 및 tick/skip/read/calculated/published/viewObserved를 기록하도록 임시 복사본에만 계측했다. View 관찰 이벤트는 화면 픽셀 출력 시각이 아니므로 실제 화면과의 연결은 후속 짧은 화면 기록에서 세부값을 대조해야 한다. 원본 저장소의 Swift·RAM 계산식·UI는 수정하지 않았다.

**자동 검증:** 격리 Debug 빌드 성공. 격리 복사본의 `SystemMonitorStoreTests` 11개 통과(기존 10개 + 진단용 가짜 샘플 ID/건너뛰기 테스트 1개). 별도 검증기 `/private/tmp/tokenly_ram02_verify_timing.py --self-test`는 **가짜 데이터만** 사용해 이벤트 순서·ID·건너뛰기·시간차·세부 합계 일치를 통과시켰고 불일치를 거부했다. 실제 Mach 호출, 실제 SwiftUI 렌더링 및 화면 표시 지연은 아직 실행·검증하지 않았다. 빌드 첫 시도는 Xcode 모듈 생성의 샌드박스 오류로 실패했으며 허용된 별도 빌드로 성공했다. 후속 격리 테스트 첫 시도는 임시 진입점에서 테스트가 참조하는 `AppAppearanceApplier` 정의를 빠뜨려 컴파일 실패했고, 임시 복사본에 원본 보조 정의를 추가한 뒤 통과했다. `RAMPopoverTests.swift:47`의 불필요한 `try`는 기존 경고다. 사용자 실행용 `/private/tmp/tokenly_ram02_run_timing.sh`는 문법·번들 ID 검사 후 앱을 직접 실행하도록 준비했지만 **실행하지 않았다**. 설치 앱·인증·기존 설정은 건드리지 않았다. 후속 측정에서 로그 검증기는 `python3 /private/tmp/tokenly_ram02_verify_timing.py /private/tmp/tokenly-ram02-timing-data/events.log`로 실행한다.

**격리 UI 표시 후속 [2026-10-29, 실행 결과]:** 사용자가 초기 진단 앱의 메뉴 막대 아이콘을 찾지 못해 상태를 재확인했다. 초기 격리 앱 PID 94549는 실행 중이고 Mach 읽기·Store 게시 로그가 계속 있었으므로 앱 시작 실패는 아니었다. 그 시점에 메뉴 막대 항목이 실제로 화면에 보였는지는 접근성 권한이 없어 확인하지 못했고, 기존 SwiftUI `MenuBarExtra`가 왜 찾기 어려웠는지도 확정하지 않는다. 격리 복사본만 `NSStatusBar.system.statusItem`의 명시적 `RAM-02` 텍스트 항목으로 바꾸고, 메뉴 막대 공간과 무관하게 RAM 화면을 보여주는 별도 진단 창을 추가했다. 새 빌드 `/private/tmp/tokenly-ram02-timing-build-v3/Build/Products/Debug/Tokenly.app` PID 96645에서 `status_item_created button=1`, `diagnostic_window_opened`, 매초 `view_observed`가 기록됐다. Core Graphics 창 목록에서 `RAM-02 진단 — 격리 앱` 창의 `onscreen=1`, 위치 (735,33), 크기 340×334를 확인했다. 같은 실행의 로그 검증기는 sampleID·계산/게시/View 바이트 일치 검사에 통과했다. 이는 **격리 진단 창의 Store→View 관찰 경로**가 동작한다는 증거이며, 픽셀 표시 지연이나 원래 설치 앱과 Apple 전체값 차이의 원인 증거는 아니다. 이전 격리 앱만 경로 확인 후 정상 종료하고 설치 Tokenly·색상 미리보기 앱은 유지했다. 기존 실행 로그는 삭제하지 않고, 검증기가 마지막 실행의 `tick id=1`부터 분석하게 했다.

**RAM-02 화면 녹화와 계측 로그 대조 [2026-10-29, 실제 격리 앱]:** 사용자가 제공한 로컬 MOV(생성 UTC 07:16:45, 길이 26.283초, 2144×1002)를 열어 활성 상태 보기와 격리 RAM 창을 직접 확인했다. 원본 MOV에는 프로세스명·사용자 식별 정보가 보여 공개 저장소에 복사하지 않았다. 로그의 같은 시간대 sampleID 311~336은 26개 모두 tick→Mach 읽기→계산→Store 게시→View 관찰이 완결됐고, `tick_skipped` 0건, Mach 오류 0건, 계산/게시/View 바이트 불일치 0건이다. tick 간격 25개는 0.9972~1.0034초(중앙값 1.0000초). 아래는 5초 간격 대표 프레임의 표시값을 로그의 네 세부/전체 값과 맞춘 결과다. 화면 영상 프레임과 View 콜백의 정확한 픽셀 시각은 동기화하지 않았으므로 `sampleID`는 표시 숫자 네 항목의 **반올림 일치**로 연결했다.

| 로그 ID / View UTC | 격리 Tokenly 전체 (GB) | Apple 전체 (GB) | 화면 전체 차이 (GB) | 격리 앱/와이어드/압축 (GB) | Apple 앱/와이어드/압축 (GB) | Apple 전체−Apple 세부 합계 (GB) |
|---|---:|---:|---:|---|---|---:|
| 313 / 07:16:47.905 | 13.35 | 13.95 | 0.60 | 3.65 / 3.46 / 6.24 | 3.67 / 3.46 / 6.23 | 0.59 |
| 318 / 07:16:52.906 | 13.37 | 13.96 | 0.59 | 3.64 / 3.42 / 6.31 | 3.64 / 3.42 / 6.31 | 0.59 |
| 323 / 07:16:57.908 | 13.32 | 13.95 | 0.63 | 3.72 / 3.39 / 6.22 | 3.72 / 3.43 / 6.21 | 0.59 |
| 328 / 07:17:02.901 | 13.37 | 13.93 | 0.56 | 3.69 / 3.43 / 6.24 | 3.69 / 3.41 / 6.24 | 0.59 |
| 333 / 07:17:07.908 | 13.38 | 13.97 | 0.59 | 2.80 / 3.84 / 6.74 | 2.80 / 3.84 / 6.74 | 0.59 |

**계측 지연(위 26개, 단조 시계 기준; ms):** tick→읽기 시작 중앙값 1.193 / 최대 4.959; Mach 읽기 시작→완료 0.756 / 최대 2.710; 읽기 완료→계산 완료 0.639 / 최대 2.008; 계산 완료→Store 게시 0.920 / 최대 2.943; Store 게시→View 관찰 6.096 / 최대 13.302; 읽기 시작→View 관찰 8.622 / 최대 20.962. 이 구간에서 **초 단위의 수집 건너뜀 또는 Store→View 관찰 지연은 확인되지 않았다.** SwiftUI `onChange`는 실제 프레임 합성 완료 시각이 아니므로 픽셀 지연의 상한/하한으로 단정하지 않는다.

26개 ID 각각의 UTC·단계별 ms·원시 바이트 환산값은 저장소 밖 `/private/tmp/tokenly-ram02-video-timing.tsv`에 1행/ID로 보관했다. 이 TSV는 프로세스명·사용자 계정·인증 정보·영상 프레임을 포함하지 않는다.

**해석 [확인/미확정 구분]:** 격리 Tokenly 화면과 내부 raw/Store/View 값의 연결은 다섯 대표 프레임에서 확인됐다. Apple 세부값도 근접하거나 정확히 같지만, Apple 자체의 `사용된 메모리`는 세부 세 항목 합보다 표시값 기준 약 0.59GB 높다. 따라서 이 녹화의 전체값 차이를 **Tokenly의 1초 수집·게시 지연만으로 설명할 근거는 없다.** Apple의 내부 전체 집계식, 세부 항목 외의 정확한 메모리 범주, Apple 화면의 각 숫자별 수집 시각은 여전히 미공개·미확정이다. 비슷한 숫자의 잔차를 그대로 동일한 원인으로 취급하거나 고정 보정값을 쓰지 않는다. 이 계측 로그에는 `free_count`가 없어 같은 시간대 잔차를 재계산할 수 없다. 다음 수정은 공식 산식 또는 재현 가능한 반례가 확인된 뒤 별도 검토한다. 이번 단계에서 제품 RAM 계산식·UI·설치 앱은 변경하지 않았다.

**RAM-02 최종 원인 검토 [2026-10-29, 추가 측정 없음]:** Apple의 [활성 상태 보기 설명](https://support.apple.com/en-euro/guide/activity-monitor/actmntr1004/mac)은 `Memory Used`와 App/Wired/Compressed/Cached Files의 뜻은 설명하지만 전체값의 계산식이나 세부 세 값과의 정확한 합산 관계는 공개하지 않는다. 공개 [XNU `vm_statistics64`](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/vm_statistics.h)는 internal(anonymous), external(file-backed), purgeable, wired, compressor occupied, free, speculative, throttled 등의 카운터를 정의한다. [XNU `vm_stats`](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/host.c)는 macOS의 `wire_count`에 throttled 및 low-page free 카운터를 포함하고, internal/external은 pageable 카운터에서 가져온다. 이 분류들은 Tokenly의 단순 `used + cached후보 + free`가 물리 RAM의 완전한 분할이라고 보장하지 않는다. 그러나 어떤 카운터가 Apple 전체값에 추가되는지, 12회 로그의 0.601~0.631 **십진 GB** 잔차와 녹화의 0.56~0.63 **화면 표기 GB** 차이가 같은 영역인지는 공개 자료와 현재 데이터로 판정할 수 없다. speculative는 free에 이미 포함되며, active/inactive·throttled·압축 전 페이지 수를 별개 사용량으로 더하는 것은 중복 위험이 있다.

**가설 분리:** ① **확인된 현상:** 26개 ID의 수집→View 전달이 이어졌고 대표 5프레임에서 Tokenly 화면과 로그가 맞았다. Apple **자체** 전체값은 Apple 자체 세부 3값 합보다 각 프레임 0.59GB 높았다. 이는 전체/세부 표시 정의가 단순 합과 다르거나 내부 갱신 시각 등이 다를 수 있음을 보여주지만 공식 산식을 증명하지 않는다. ② **유력하나 미증명:** Apple 전체 집계 범위 또는 항목 분류가 Tokenly의 세 항목 합과 다를 가능성. 정확한 누락 메모리 범주는 지정하지 않는다. ③ **보조 요인:** 같은 UI의 네 수치가 소수 둘째 자리로 반올림된다면 `전체−세부 3개 합`의 최대 반올림 오차는 약 0.02 표기 단위이며 0.59를 설명하지 못한다. Tokenly `ByteCountFormatter(.memory)`는 이 환경에서 이진 GiB 수치를 `GB`로 표기했지만 Apple 단위 규칙은 확인하지 못했다. Apple 자체 화면의 전체−세부 차이에는 앱 간 GB/GiB 변환이 개입하지 않는다. 두 앱의 독립 갱신 시각은 작은 프레임별 차이에 영향을 줄 수 있으나, Tokenly 읽기→View 최대 20.962ms와 프레임 대조상 **Tokenly의 초 단위 게시 지연**은 관찰되지 않았다. Apple 각 표시값의 취득 시각·픽셀 합성 시각은 계측하지 않았다. ④ **반례/한계:** 기존 12개 raw 샘플은 녹화의 26개와 다른 시각이며 첫 캡처의 세부값과도 맞지 않는다. 26개 로그에는 free가 없어 같은 프레임의 잔차를 계산할 수 없다. 잔차의 수치적 근접성은 원인 동일성의 증거가 아니다.

**판정·후속 [설계 판단]:** RAM-02는 `전체 사용량 차이 재현·원인 미확정·제품 수정 보류`로 정리한다. 0.6GB 보정, 임의 카운터 가산, Apple 산식 재현 주장은 하지 않는다. 지금은 추가 측정이나 제품 회귀 테스트가 필요하지 않다. 향후 Apple 산식의 공개 근거 또는 **같은 시점의 원시 카운터·Apple 전체/세부값으로 재현되는 구체적 반례**가 확보되면 테스트를 먼저 설계하고 계산식/설명 문구 변경을 별도 승인받는다. UI가 Apple과 같은 전체값을 보장한다는 문구는 피하고 `앱+와이어드+압축의 합(독립 계산)`처럼 측정 정의를 명시하는 방안을 후속 검토한다. 기존 녹화·12회 로그·26개 ID 결과가 블로그의 문제 발견→가설→검증→미확정 결론을 뒷받침하므로 새 캡처는 필요 없다. 원인 확정 후 회귀 테스트 캡처만 조건부로 남긴다.

**조사 종료 기록 [2026-10-29, 사용자 결정]:** RAM-02 상태는 **조사 종료·원인 미확정·제품 수정 보류**다. 재조사는 ① Apple이 전체 사용량의 공식 산식을 확인할 수 있는 자료를 공개하거나 ② Tokenly 계산의 재현 가능한 **구체적 반례**가 확보될 때만 검토한다. RAM 계산식뿐 아니라 제품 UI 설명도 이번 작업에서는 변경하지 않는다. 위의 이전 단계별 “다음 측정” 안내는 당시 계획을 기록한 것이며 현재 수행 대기 항목이 아니다.

**블로그용 핵심 근거 [사실/가설 분리]:** 첫 24GB 사례는 Apple 18.00GB/Tokenly 16.59GB(차이 1.41GB), 후속 16GB 사례는 13.88/13.29GB(차이 0.59GB)였다. 격리 진단 녹화에서는 sampleID 311~336 **26개 모두** 수집→계산→게시→View 관찰값이 연결됐고 tick 건너뜀·바이트 불일치가 0건이었다. 읽기 시작→View 관찰 최대 20.962ms, 대표 5프레임의 Apple−Tokenly 전체 차이는 0.56~0.63 화면 표기 GB, Apple 전체−Apple 세부 합계는 각 프레임 약 0.59GB였다. 별도 12개 원시 샘플의 잔차는 0.601~0.631 **십진 GB**였지만 녹화와 다른 시점이라 동일 원인이라는 증거가 아니다. **가설:** Apple 전체값과 세부값의 집계 범위·분류가 다를 수 있다. **미확정:** Apple 전체 산식, 차이를 구성하는 페이지 범주, Apple 항목별 취득 시각. 글의 결론은 “차이를 재현하고 Tokenly 전달 경로를 검증했으나 원인은 특정하지 못했다”로 제한한다. 이미 확보한 비교 녹화와 정제된 로그 표를 활용하고, 원인 해결 또는 회귀 테스트 성공 캡처는 만들지 않는다.

**격리 진단 자료 위치 [로컬 전용, 삭제하지 않음]:** 앱 복사본 `/private/tmp/tokenly-ram02-timing-build-v3/Build/Products/Debug/Tokenly.app`, 계측 소스 `/private/tmp/tokenly-ram02-timing-src/`, 이벤트 로그 `/private/tmp/tokenly-ram02-timing-data/events.log`, 26개 ID 요약 `/private/tmp/tokenly-ram02-video-timing.tsv`, 12회 원시 로그 `/private/tmp/tokenly-ram02-simultaneous.txt`, 실행 스크립트 `/private/tmp/tokenly_ram02_run_timing.sh`, 검증기 `/private/tmp/tokenly_ram02_verify_timing.py`. 해당 경로는 로컬 조사 위치의 기록이며 영구 보관 보장은 아니다. 화면 녹화 원본은 개인정보가 보여 저장소에 넣지 않는다. 이번 종료 정리에서 파일 삭제·재실행·추가 계측은 하지 않았다.

**📸 캡처 추천 (최대 3장):** ① 이미 확보한 양쪽 화면 비교(전체 차이와 세부값 동시 표시), ② 이미 보존한 시각·원시 카운터의 정제된 진단 출력(개인 경로 가림), ③ 원인이 확정되고 수정한 경우에만 회귀 테스트 결과. 새 캡처를 위해 측정이나 앱을 재실행하지 않는다.

### 9.4 Battery: 레지스트리 키가 OS마다 다르고, Apple 수치는 재현되지 않는다

- [확인] 이 Mac(Mac16,12, macOS 27)의 `AppleSmartBattery`에는 최상위 `DesignCapacity`·`AppleRawMaxCapacity`·`Temperature`가 **없다**. 용량은 중첩 사전 `BatteryData`의 `DesignCapacity`(4629)와 `FullChargeCapacity`(4635)에만 있다.
- [확인] 최상위 `MaxCapacity`는 Apple Silicon에서 100(%)이다. [추정] 널리 알려진 대로 Intel에서는 mAh일 수 있다. 그래서 이 값은 쓰지 않는다.
- [확인] 시스템 정보의 "최대 용량"은 99%다. 레지스트리 값으로 계산하면 FCC ÷ 설계 100.1%, Nominal ÷ 설계 102.9%로 어느 쪽도 99%가 아니다. 그래서 건강도는 "추정치"로 표시하기로 했다.
- [확인] 온도 키가 없고, 과거 `Temperature` 키는 단위가 문서화되어 있지 않아 지원 불가로 처리했다. 임의로 단위를 가정하지 않는다.
- [확인] 실시간 상태는 공개 API IOPowerSources를 사용한다. AC 연결·완충 상태에서 `Power Source State` "AC Power", `Is Charging` false, `Is Charged` true였고, `pmset -g batt`("AC Power", 100%, charged)와 일치했다. "전원 연결"과 "충전 중"은 별개 값이다.
- 미확인: 어댑터 분리, 충전 중, 전원 알림 반영 속도.

### 9.5 Store: 숨긴 위젯은 측정하지 않는다

- CPU·RAM은 1초 타이머 하나를 공유한다. 둘 다 꺼지면 타이머를 멈추고, 다시 켜면 Sampler를 새로 만든다. 멈춰 있던 시간 전체를 평균한 엉뚱한 CPU 값을 막기 위해서다.
- Battery는 전원 변화 알림(`IOPSNotificationCreateRunLoopSource`)과 60초 보조 확인으로 읽는다. 1회 약 165 µs다.
- 중복 방지: 이미 켜진 지표를 다시 켜면 무시하고, 측정이 진행 중이면 새로 시작하지 않는다. 늦게 도착한 결과는 세대 번호로 버린다.
- 테스트 방법: 타이머와 전원 알림을 `SystemMonitorScheduling` 프로토콜로 주입하고, 테스트에서는 수동으로 발생시킨다. 느린 측정은 continuation으로 붙잡아 겹침 방지를 검증했다.
- [확인] CPU·RAM·Battery를 모두 켜고 70초 실행했을 때 프로세스 CPU 0.048%였고, 모두 끈 뒤 3초 동안은 0.0004초였다.

### 9.5-1 Disk: "사용 가능"은 하나가 아니다 (4단계)

- [확인] 공개 API `URL.resourceValues(forKeys:)`를 선택했다.
  - Foundation의 문서화된 키이고, APFS 컨테이너 기준 값을 돌려준다.
  - 보수적 가용 값과 "중요한 용도" 기준 가용 값을 키로 고를 수 있다.
  - `statfs`는 더 빠르지만(3.3 µs) 보수적 가용 값만 준다.
- [확인] 같은 디스크에서 "사용 가능"이 세 가지로 나온다(Mac16,12, 2026-10-27).

  | 키 | 값 | 의미 |
  |---|---|---|
  | `volumeAvailableCapacity` | 52.19 GB | 지금 비어 있는 공간 |
  | `…ForImportantUsage` | 65.90 GB | 중요한 요청에 확보 가능한 공간의 시스템 추정치(삭제 가능한 데이터를 비워 얻는 공간 포함 가능) |
  | `…ForOpportunisticUsage` | 45.87 GB | 여유분을 남긴 값 |

  첫 번째 값은 `statfs`, `df`, `diskutil`, 시스템 정보, Finder AppleScript와 모두 일치했다.
- [확인] `df /`의 Used는 13.3 GB(21%)다. 봉인된 시스템 볼륨 하나의 사용량이라 실제 사용률(78.8%)과 전혀 다르다.
- [확인] **URL resource value 캐시 함정:** 같은 `URL` 객체를 재사용하면 1 GiB를 쓴 뒤에도 여유 공간이 52.189 GB 그대로였고, 새 URL은 51.115 GB를 보였다.
- [확인 → 정정] 처음에는 65.90 − 52.19 = 13.7 GB를 "purgeable 공간"이라고 기록했다. Codex 리뷰에서 지적받아 고쳤다. 이 차이는 시스템이 자체 규칙으로 계산한 추정치의 차이이며, 정확한 purgeable 총량이라는 근거는 없다.
- [확인] 시스템 설정 > 저장 공간(사용자 GUI 확인): 전체 245.11 GB, 사용 중 179.45 GB, 남은 공간 65.66 GB. 중요한 용도 기준 가용 65.55 GB와 0.11 GB 차이였다. [추정] 시스템 설정은 같은 계열의 값을 쓰는 것으로 보인다. 측정 시점이 달라 완전 일치는 주장하지 않는다.
- 그래서 "디스크 사용률"이 기준에 따라 78.8%(보수적) 또는 73.3%(시스템 설정 계열)로 달라진다. 메뉴 막대 기준은 6단계에서 정한다.
- [확인] 키별 비용: total + available 11 µs, important usage 4,176 µs(약 380배). [추정] 시스템 서비스에 질의하기 때문으로 보이며, 확인하지 않았다.
- 결정
  - 모델의 기본 "사용 가능"은 보수적 값이다. 중요한 용도 기준 값은 보조 필드로 함께 제공한다.
  - Disk를 끌 때는 취소 요청과 늦은 결과 폐기만 보장한다. 이미 시작된 동기 API 호출은 끝까지 실행될 수 있다.
  - 표시는 Finder와 같은 10진 GB를 쓴다.
  - 60초 간격으로, 메인 스레드 밖에서 읽는다.
- 미확인: Finder 창의 사용 가능 수치(사용자 캡처에 표시되지 않음).

### 9.5-2 GPU: 공개 API가 없는 지표를 어떻게 판단했나 (5단계 기술 검증)

- [확인] 공개 API 조사
  - Metal `counterSets`는 이 M4에서 `timestamp` 하나뿐이었다. `StageUtilization` 세트가 있어도 내 앱 명령 버퍼의 카운터라 시스템 전체 사용률이 아니다.
  - SDK 공개 헤더에는 GPU 사용률 키가 없다.
  - `powermetrics`는 root가 필요하다.
- [확인] 문서화되지 않은 경로: IORegistry `IOAccelerator`(`AGXAcceleratorG16G`) → `PerformanceStatistics` → `Device Utilization %`. 일반 권한으로 읽혔고 1회 약 40 µs다.
- [확인] **"정답"을 직접 만들어 비교:** Metal 컴퓨트 셰이더로 부하를 주고, 명령 버퍼 `gpuStartTime`/`gpuEndTime`으로 실제 실행 비율을 쟀다.
  - 최대 부하: Device 99.0%, 실행 비율 99.2%
  - 50% 부하: Device 53.4%, 실행 비율 47.7%
  - 같은 부하에서 Renderer·Tiler는 44%·21%에 그쳐, 이름만 보고 키를 고르면 틀린다는 근거가 됐다.
- [확인] **"1초에 한 번 읽으면 된다"는 가정이 틀렸다.** 값이 수십 ms마다 0과 100 사이를 오가서, 1초 1회 읽기는 평균 오차 42.7%p였다. 100 ms 간격 평균은 11.5%p였다. 이 Mac에서 CPU tick 카운터가 최대 약 1초까지 멈추는 것(9.6 표)과는 반대 성격의 함정이다.
- 판단: B, 실험적 지원 가능. 문서화되지 않은 키라 다른 기종·macOS에서의 지원과 의미를 보장할 수 없다. 사용자가 B안을 승인했다.
- **정정할 점 (Codex 리뷰)**
  - Metal 명령 버퍼 실행 비율은 검증용 비교 기준이지 시스템 전체 GPU 사용률의 정답이 아니다. 다른 프로세스의 GPU 사용이 빠져 있다.
  - "100 ms 간격 평균 오차 11.5%p"는 일반적인 정확도가 아니다. 부하 주기(100 ms)와 읽는 주기가 같은 특정 조건의 관찰값이고, 이 조건에서는 aliasing이 생길 수 있다.
- **[확인] aliasing 대응 설계와 시뮬레이션 (5단계 구현)**
  - 1초를 100 ms 슬롯 10개로 나누고, 슬롯 안 읽기 시각을 시드 기반 의사난수로 분산했다.
  - 50 ms/50 ms 주기 부하에서 고정 위상은 모든 1초 구간이 100%였고, 분산 방식은 1분 평균 51.0%였다.
  - 단, 1초 값은 20~90%로 흩어졌다. 분산은 치우침을 없애지만 표본 수 부족에서 오는 잡음은 남는다.
- **[확인] 마이크로벤치마크와 실제 비용의 차이 (5단계 구현)**
  - 연속 반복 읽기는 1회 수십 µs(실행마다 19~45 µs)였지만, 실제처럼 100 ms 간격으로 따로 읽으면 약 290~350 µs였다(세 번 측정, 서비스 탐색 116~146 µs + 속성 읽기 약 210 µs). 원본은 `Doc/logs/2026-10-27-gpu-cost.txt`.
  - 실제 Store를 60초 돌리면 프로세스 CPU 약 0.5%였다. 가짜 Sampler로 스케줄링만 해도 0.19%였다.
  - "40 µs × 10회 = 0.04%"라는 처음 추정은 약 10배 빗나갔다. [추정] 따로 읽을 때마다 캐시가 식어 있고, 타이머로 깨어나는 비용이 더해지기 때문으로 보인다.
  - 배터리 영향은 측정하지 않았다.
- **[확인] 오래된 값 게시 버그 (Codex 리뷰 Medium, 안정화에서 수정)**
  - "창이 끝나면 게시"만 확인해서, 타이머가 창 시작 1.9초 뒤 재개되면 약 1초 전 데이터를 현재값으로 게시했다.
  - 닫는 읽기 지연(≤ 0.25초)과 마지막 유효 읽기 나이(≤ 0.75초)를 함께 보도록 고쳤다.
  - 기준을 너무 빡빡하게(0.5초) 잡으면 끝의 몇 번이 실패한 정상 창까지 버린다는 것을 테스트 작성 중에 발견했다.
- **[확인] 테스트가 호환성을 과장했던 문제:** 실기기 테스트가 "arm64면 반드시 읽힌다"고 가정했다. 검증한 Mac(Mac16,12 + macOS 27.0.1)만 지원을 필수로 하도록 고쳤다. 테스트가 통과한다고 지원 범위가 넓어지지 않게 하려는 것이다.
- **[확인] 서비스 핸들 재사용의 효과와 대가**
  - 같은 측정 프로그램으로 30초씩 번갈아 비교했다. 프로세스 CPU 0.446% → 0.373%(약 16%), IOKit 몫만 약 26% 감소했다.
  - 같은 버전끼리의 편차도 그만큼 커서 감소 크기는 대략값이다.
  - 대가로 핸들 소유권, 재검증(10초, 2초 공백), 실패 후 재시도 제한이라는 상태가 생겼다. 이를 가짜 레지스트리 테스트로 검증했다. 핸들을 줄 때마다 세어, 모두 한 번씩만 해제됐는지 확인한다.
- **[확인] 실패마다 같은 벌을 주면 안 된다 (Codex 최종 리뷰 Medium)**
  - 최적화 직후의 재시도 제한은 모든 실패에 5초였다. "GPU 없음"을 초당 10번 찾지 않으려고 넣은 규칙이 이상값 한 번이나 일시적 IOKit 오류에도 적용되어, 곧 정상이어도 5초 동안 측정 불가였다.
  - 실패를 성격별로 나눴다.
    - 값 이상: 서비스는 살아 있으므로 대기 없음
    - 일시 실패: 0.25초에서 2초까지 지수적으로 증가
    - 지원 불가: 5초
  - 회귀 테스트는 대기 간격 자체(0.25/0.5/1/2/2초)를 검증한다. 처음에는 0.1초씩 더한 시계가 부동소수점 오차로 0.25초 경계를 넘지 못할 수 있음을 실행 전에 발견했다. 그래서 2진수로 정확한 간격(1/8, 1/16초)으로 바꿨다.
- **[확인] 상태를 가진 Sampler를 컴파일러로 묶기:** `@MainActor`를 붙이자 기본 인자 `gpu: any GPUSampling = GPUSampler()`가 컴파일 오류가 됐다(기본 인자는 비격리 문맥에서 평가됨). 옵셔널 인자로 받고 init 안에서 만드는 방식으로 해결했다. 락이나 큰 리팩터링 없이 "한 실행 문맥에서만 사용"을 컴파일러가 보장한다.
- 실패하거나 쓸 수 없던 접근: Metal 카운터(지원 세트 없음, 범위도 앱 한정), `powermetrics`(root 필요), Renderer·Tiler 키(컴퓨트 부하 미반영), 1초 1회 읽기(오차 과다).

### 9.5-3 메뉴 막대 간격·정렬과 "진짜 100%" (6-3 실기기 확인 뒤 보완)

- **[확인] 메뉴 막대 아이템 간격은 앱 몫이 아니다:** 30pt 이미지가 46pt 아이템 창이 됐다. macOS가 좌우 각 8pt를 더한다. 바꿀 공개 수단은 시스템 전체 설정(`NSStatusItemSpacing`)뿐이라 다른 앱까지 바뀐다. 그래서 앱 이미지 안의 빈 공간만 줄였다.
- **[확인] 숨은 빈 공간:** 1초마다 폭이 흔들리지 않게 `100%` 기준으로 폭을 고정했더니, 평소 값(`24%`)에서는 좌우 각 4.7pt가 비었다. 기준을 "가장 넓은 두 자리 값"으로 바꾸고 `100%`에서만 넓히자 1.2pt가 됐다(이미지 32 → 25pt, 잉크 사이 간격 약 25 → 18pt). 대가는 99↔100%에서의 폭 변화이고, 이를 문서에 남겨 되돌릴 수 있게 했다.
- **[확인] 한 줄 위젯은 어디에 둘까 (세 번 바뀐 결정):** 이름 행이 없는 Battery를 22pt 행 가운데에 두었더니 다른 위젯 숫자보다 약 3pt 낮았다. 윗줄 숫자에 맞췄더니 실제 메뉴 막대에서 아래가 비어 떠 보였다. 최종 확정은 "한 줄 위젯은 전체 높이의 중앙"(기준선 15.23pt)이다. 정렬 기준은 숫자 값이 아니라 실제 화면을 보고 정해야 했다. 실제 메뉴 막대를 캡처해 후보 이미지를 합성해 비교한 방법이 판단에 도움이 됐다.
- **[확인] 따로 스냅하면 간격이 흔들린다:** 번개와 숫자를 각각 픽셀 격자에 맞추자 값에 따라 빈 간격이 1~3px로 달라졌다. 스냅된 숫자의 실제 잉크 위치에서 번개 위치를 거꾸로 계산해 고정했다.
- **[확인] 시스템 초록은 밝은 배경에서 약하다:** sRGB 0.20/0.78/0.35는 흰 배경 대비 약 2.2:1이다. 라이트 모드만 더 진한 초록(약 3.5:1)으로 바꿨다.
- **[확인] 반올림된 100%는 완충이 아니다:** 4,627/4,629는 반올림하면 `100%`다. "외부 전원 + 100%면 번개"를 반올림된 값으로 판단하면 덜 찬 배터리에 완충 표시를 하게 된다. 반올림 전 정수(`Current == Max`)로 따로 판정한다. 충전·전원·완충 중 하나라도 모르면 번개를 붙이지 않는다(12가지 조합 테스트).
- 📸 캡처: 보완 전후 메뉴 막대(AI 숫자형 옆 시스템 위젯), 어댑터 연결·완충 시 `⚡100%`.

### 9.5-4 같은 정보, 다른 순서: 통일형과 구분형 (6-3 후속)

- AI와 시스템 위젯이 모두 "숫자 위 / 이름 아래"라 한 줄로 이어 보이면 어디까지가 AI인지 구분하기 어렵다. 시스템 위젯만 "이름 위 / 숫자 아래"로 뒤집는 선택지를 넣었다(기본값은 기존 통일형).
- **[확인] 뒤집기 규칙:** 새 간격을 고르지 않고, 기존 상자(숫자 윗선 3.60 ~ 이름 기준선 19.40pt)를 그대로 위아래로 뒤집었다. 위 행의 대문자 윗선과 아래 행의 기준선을 바꿔 끼우면 행 사이 간격이 저절로 같아진다.
- **[확인] "기존과 픽셀 동일"을 증명하는 법:** 바꾸기 전에 196개 조합의 이미지 해시를 기록해 두고 바꾼 뒤 비교했다. 리팩터링 전에 기준을 남기는 습관이 유용했다.
- **[확인] "처져 보인다"를 숫자로:** 잉크 상자로는 AI와 같은 위치였지만, 픽셀 불투명도로 가중한 세로 무게중심은 12.76pt로 AI(약 10.8~11.1pt)보다 1.6~1.9pt 낮았다. 큰 숫자가 아래 행에 오기 때문이다. 0.5pt·1pt 올림을 비교해 1pt(11.76pt)를 택했다. 이름을 키우는 안(7pt)도 만들었지만, 사용자는 크기가 아니라 위치 문제라고 판단했고 측정도 그것을 뒷받침했다.
- **[확인] 하지 않기로 한 보정:** 숫자(무거움)와 `%`(가벼움) 때문에 가로 무게중심이 평균 1.15pt 왼쪽이지만, 0.5pt 여백 안에서 줄 수 있는 보정은 0.25pt 미만이고 값마다 치우침이 달라 고정 보정으로는 없앨 수 없었다. 측정 결과로 "안 하는 이유"를 남겼다.
- 📸 캡처: 설정 > 테마의 선택지, 같은 값으로 통일형·구분형 메뉴 막대 비교. 보존된 비교: `Doc/screenshots/stage6-3-split-final/`.

### 9.5-5 마지막 0.5pt들: 테두리, AGY, 구분형 2pt (6-3 최종)

- **[확인] 승인 미리보기 = 앱 출력:** 미리보기 단계의 렌더 결과를 원시 픽셀로 저장해 두고, 구현 후 앱 출력과 비교했다(구분형 128, AI 4, Battery 테두리 20개 모두 동일). "미리보기에서 고른 것"과 "실제로 들어간 것"이 같다는 것을 증명하는 방법이다.
- **[확인] 테두리는 덧그리기만:** 미니멀 이미지를 정수 pt(3pt) 오프셋으로 그대로 두고 테두리만 더했다. 테스트가 "미니멀의 모든 잉크 픽셀이 테두리형에서도 같은 값"인지 확인한다. 반쯤 픽셀 오프셋이었다면 재표본으로 숫자가 흐려졌을 것이다.
- **[확인] AGY만 움직이기:** 공통 세로 계산을 건드리지 않고 "7일 칸이 없는 열"의 숫자 기준선에만 0.5pt를 뺐다. Codex·Claude 열과 AGY 이름 행이 픽셀 단위로 그대로인지 테스트한다.
- **[확인] 0.5pt와 3× 화면:** 0.5pt는 3×에서 1.5px라 이름·숫자가 서로 다른 픽셀로 스냅될 수 있다. 구분형은 1pt 단위(총 2pt)로 움직여 2×·3× 모두 같은 픽셀만큼 함께 이동한다.
- 📸 캡처: 테마 탭의 배터리 스타일, 미니멀/라운드 전환 전후 메뉴 막대, 구분형 + AGY 최종 모습.
- **[확인] 1.2pt인데 1px뿐인 간격:** 숫자–% 간격은 1.2pt(2×에서 2.4px)였지만, 글자 가장자리 안티에일리어싱이 양쪽을 채워 `24%`·`82%`에서 완전히 빈 열은 1px뿐이었다. 0.5pt를 더하자 2~3px가 됐고, 이미지 폭은 정수 올림 덕분에 그대로였다. 이 값은 AI의 `/` 간격과 공유하던 것이라 시스템 전용 값으로 분리했다.
- **[확인] 테두리는 위아래로만:** 테두리 높이를 15.75 → 17.5pt로 바꿀 때 내용(숫자·번개)은 픽셀 단위로 그대로이고 선만 0.875pt씩 바깥으로 이동한다. 17.5pt는 미리보기 후보(16.75·17.75)에 없던 값이라 셋을 나란히 다시 그려 확인했다.

### 9.5-6 "측정 안 함"과 "점이 없음"은 다르다 (6-4a, M1)

- **[확인]** 그래프는 측정 실패(`nil`)에서 선을 끊었지만, 잠자기나 타이머 정지처럼 **점 자체가 없는** 시간은 몰랐다. 1초×5 → 20초 공백 → 1초×3이 한 선으로 이어져, 측정하지 않은 20초가 그럴듯한 직선으로 그려졌다.
- **[확인]** 이웃한 두 점의 시간 간격이 2.5초(1초 주기 × 2.5)를 넘으면 끊는다. 2초가 아니라 2.5초인 이유: 한 번 건너뛴 틱은 약 2초인데, 타이머 흔들림으로 2초를 조금 넘으면 선이 깜빡이며 끊긴다. 경계(정확히 2.5초는 연결)를 테스트로 고정했다.

### 9.5-7 CPU 팝오버: 예쁜 그래프와 정확한 그래프 사이 (6-4b)

- **[확인] 여러 번의 미리보기:** 원형 게이지 제거 → 글래스 파도(얇고 평평) → 깊은 파도(선을 따라가는 광택이 다크에서 "두 번째 선"처럼 보여 폐기) → 구조가 다른 4안(수면·오로라·조각 면·막대) → 오로라 3변형 → B1 채택. 매 회차 같은 가상 데이터로 디자인 차이만 비교했다.
- **[확인] 보간은 정직하게:** 단조 3차 보간(Fritsch–Carlson)은 측정점을 모두 지나고 이웃한 두 값 사이를 벗어나지 않는다. 일반 곡선 보간(Catmull-Rom 등)은 측정하지 않은 봉우리를 만들 수 있다. 테스트로 "이탈 0"을 고정했다.
- **[확인] 색은 높이의 함수:** 오로라 색을 값(높이)에만 묶어 같은 값은 항상 같은 색이다. 색이 별도 의미(경고)를 갖지 않게 했다.
- **[확인] 아이콘은 이름이 아니라 PID로:** 실행 중인 앱으로 등록된 프로세스만 그 앱 아이콘을 쓰고, 보조 프로세스는 기본 아이콘. (PID, 시작 시각)으로 캐시해 재사용된 PID를 구분한다.
- **[확인] 두 신호, 한 결과:** 팝오버 열림·닫힘을 화면 이벤트와 창 가시성 두 가지로 받되, 수집 쪽이 멱등이라 중복이 없다. 오프스크린 렌더링 중 창이 화면에 없자 수집이 멈춘 것이 안전장치가 동작한 증거였다.
- **[확인] 실기기에서만 보인 문제:** 자동 테스트 336개가 모두 통과했지만, 실제로 톱니바퀴를 누르자 설정 창이 팝오버 뒤에 떴다. 메뉴 막대 팝오버 창은 일반 창보다 높은 층에 있기 때문이다. 팝오버를 먼저 닫고 설정 창을 띄우도록 고쳤다.
- **[확인] 손쉬운 사용 권한 없이 실기기 확인하기:** 자동 클릭 대신 1초마다 창 목록(크기·화면 표시 여부)과 CPU를 기록하고, 팝오버가 보일 때만 스크린샷을 찍었다. 사용자가 클릭하는 동안 창 높이 변화(245 → 335 → 409pt)로 "불러오는 중 → TOP 5 → 도움말 펼침"을 확인할 수 있었다.
- **[확인] 고친 뒤 다시 실기기로:** 다시 빌드한 앱에서 톱니바퀴 두 번 모두 팝오버가 닫히고 설정 창이 맨 앞에 왔다. 로그에는 열고 닫을 때마다 두 신호(화면 이벤트·창 가시성)가 짝을 이뤄 `scan on`/`scan off`가 찍혔다. 팝오버를 열면 앱 CPU가 평균 약 1.4%p 늘었다(1.9% → 3.3%).
- **[확인] 임시 패치 대신 재현부터:** 첫 수정(창별 `NSWindow.appearance`)은 팝오버만 보고 고친 것이라 설정 창에서 같은 증상이 다시 나왔다. 같은 구조의 작은 앱을 만들어 세 방식을 5가지 전환 순서로 자동 측정했다. `.preferredColorScheme`은 "라이트 → 시스템"에서 깨지고, 창별 외관은 SwiftUI가 덮어써 거의 항상 깨졌다. `NSApp.appearance` 하나만 30단계 모두 맞았다. 판정은 창을 실제로 찍은 픽셀로 했다(뷰를 그대로 복사하면 창 배경이 빠져 잘못된 값이 나왔다).
- **[확인] 실기기 판정 자동화:** 손쉬운 사용 권한이 없어 클릭은 사용자가 하고, 판정기가 1초마다 창을 찍어 "배경과 반대 밝기의 픽셀 비율"로 글자가 보이는지 판정했다. 먼저 재현 앱의 오류 상태를 잡아내는지 확인한 뒤 실제 앱에 썼다.
- **[확인] 메뉴 막대 팝오버와 앱 외관:** `.preferredColorScheme`은 메뉴 막대 팝오버 창의 외관을 바꾸지 못해, 앱 설정을 라이트→다크로 오가자 "어두운 배경에 검은 글자"가 됐다. 창의 `NSWindow.appearance`를 직접 바꾸니 배경과 글자가 함께 바뀌었다. 이것도 자동 테스트가 아니라 사용자의 실사용에서 발견했다.
- **[확인] 잘린 이름은 UI 탓이 아니다:** "Google Chrome Helper (Aperitif"는 커널의 `pbi_name`(31자 제한)에서 이미 잘려 온다.
- 📸 캡처: 실제 메뉴 막대에서 연 CPU 팝오버(`real-app-check/`), 미리보기 회차별 비교.

### 9.5-8 RAM 구성 막대: 더해도 되는 숫자인가 (6-4c 미리보기)

- **[확인]** 네 칸을 100% 막대로 그리기 전에, 칸끼리 겹치지 않는지부터 확인했다. 앱(익명 − 퍼지 가능)·와이어드·압축(압축기가 차지한 물리 페이지)은 서로 다른 페이지다. 압축된 원본 크기("압축기에 저장된 페이지")를 쓰면 실제 차지 공간보다 커져 합이 맞지 않는다.
- **[확인]** 네 번째 칸을 "여유"라고 부르면 빈 메모리처럼 읽힌다. 실제로는 캐시된 파일이 대부분이라 "사용 가능(캐시 포함)"으로 정했다.
- **[확인]** 메모리 압박은 사용률과 다른 지표다(이 Mac은 81% 사용에 압박 "경고"). 공개 sysctl로 읽을 수 있지만 아직 수집하지 않아 미리보기에서는 예시로 표시했다.

### 9.5-9 31자에서 잘린 이름 되살리기 (6-4c)

- **[확인]** 커널의 `pbi_name`은 31자까지만 담아 "com.apple.Virtualization.Virtua"처럼 잘린다. 모든 프로세스에 경로 조회를 하지 않고, **이름이 31자로 꽉 찬 경우만** `proc_pidpath`의 실행 파일 이름을 읽어, 그것이 잘린 이름으로 시작할 때만 바꿨다. 다른 실행 파일 이름으로 엉뚱하게 바뀌는 일이 없다.
- **[확인]** 메모리 압박은 `kern.memorystatus_vm_pressure_level`(1회 약 2µs)로 읽는다. 값 1·2·4는 공개 `DispatchSource.MemoryPressureEvent`의 normal·warning·critical과 같다. 읽기 실패를 "정상"으로 보이게 하지 않으려고 "확인 불가"를 따로 뒀다.
- **[확인]** 아이콘 캐시를 CPU·RAM 팝오버가 공유하는데, 각자 "지금 목록만 남기기"를 하면 서로의 아이콘을 지운다. 두 목록의 키를 함께 유지하도록 했다.

### 9.5-10 GPU: 보여 줄 수 있는 것과 보여 주면 안 되는 것 (6-4d 조사)

- **[확인]** 프로세스별 GPU 시간(`AGXDeviceUserClient`의 `accumulatedGPUTime`)은 관리자 권한 없이 읽혔고, 2초 차이의 합이 장치 사용률과 비슷했다(21~27% ↔ 19~27%). 하지만 문서화되지 않은 값이라 "실험적 선택안"으로만 두었다.
- **[확인]** Apple Silicon의 GPU는 통합 메모리를 쓴다. 드라이버가 잡은 시스템 메모리나 Metal의 작업 한도(12.7 GB)를 "GPU 메모리"로 보여 주면 별도 VRAM처럼 오해된다. 그래서 넣지 않았다.
- **[확인]** 구현에서는 칩 이름을 공개 Metal API에서, 코어 수를 사용률을 읽는 바로 그 장치 항목에서 한 번만 읽었다. 코어 수 키는 문서화되지 않아서, 정수이고 1~1024일 때만 보이고 아니면 줄을 숨긴다. "Apple M4"나 8 같은 값은 코드 어디에도 없다.
- **[확인]** GPU 온도는 공개 경로가 없다. 검증 안 된 센서를 보여 주기보다 칸을 비우는 쪽을 택했다.

### 9.5-11 Disk: "사용 가능"은 빈 공간이 아니다 (6-4e 조사)

- **[확인]** 같은 순간 이 Mac에서 "지금 비어 있음"은 45.7 GB, "사용 가능"(시스템 추정)은 59.6 GB였다. 차이 13.9 GB는 macOS가 필요하면 비울 수 있다고 보는 공간인데, 정확한 purgeable 총량이라는 보장은 없다. 그래서 막대에서 줄무늬로 "추정"을 따로 그렸다.
- **[확인]** 읽기·쓰기 속도는 공개 IOKit 헤더에 정의된 누적 바이트 키로 관리자 권한 없이 읽힌다(1회 약 1 ms). 함정: 마운트된 디스크 이미지마다 같은 드라이버가 하나씩 더 있어서, 전부 더하면 가상 장치의 읽기가 섞인다.
- **[확인]** SMART 상태는 `diskutil`이 "Verified"라고 보여 주지만 공개 API가 없다. 앱에는 넣지 않는다.
- **[판단]** 저장 공간 %는 60초마다 0.1%p 움직이는 값이라 그래프로 그리면 변화를 과장한다. 그래프 자리는 실시간 읽기·쓰기에 주고, 둘을 한 축에 섞지 않았다.

### 9.5-12 Disk: "어느 디스크의 속도인가"를 증명하기 (6-4e 구현)

- **[확인]** `/`에서 IORegistry를 위로 따라가면 APFS 스냅샷 → 볼륨 → 컨테이너 → 파티션 → 디스크 → 드라이버가 한 줄로 이어졌다(이 Mac에서 10단계, 각 단계의 부모 1개). 그래서 "첫 번째 내장 디스크"를 고르는 대신 그 줄 끝의 드라이버만 쓰고, 갈래가 생기면(여러 물리 저장소) 고르지 않고 "확인 불가"로 둔다.
- **[확인]** 속도는 누적 바이트 차이를 실제 경과 시간으로 나눈다. 타이머가 1.1초 만에 돌면 1.1로 나눠야 10% 과대가 안 생긴다. 잠자기를 건너는 구간은 시계가 잠자기 중에도 흐르게 해(`CLOCK_MONOTONIC`) 긴 간격으로 잡히고, 평균을 내지 않고 새 기준값으로 버린다.
- **[판단]** 그래프 오른쪽 위 숫자는 "최대"가 아니라 "눈금 상한"이다. 실제 최고값이 13 MB/s여도 눈금은 20 MB/s라서, "최대 20 MB/s"라고 쓰면 거짓말이 된다.
- **[확인]** 읽기 1회 0.067 ms, Disk를 켠 30초 동안 CPU 약 0.28% 코어(측정 프로그램 기준). 실제 앱에서는 Disk 꺼짐 0.85% → 켜짐 1.25% 코어(60초씩, 메뉴 막대 이미지 갱신 포함).
- **[교훈]** 교체 전 앱이 3.03%로 더 높게 나왔는데, 그 앱은 Xcode 디버거에 붙어 있었다. "전후 비교"는 같은 빌드에서 설정만 바꿔 재야 한다.

### 9.5-13 Battery: "최대 용량"은 어느 숫자인가 (6-4f 조사)

- **[확인]** 이 Mac의 배터리는 완충 4631 mAh, 설계 4629 mAh라서 비율이 100%인데, 시스템 정보는 "최대 용량 99%"라고 한다. Apple은 레지스트리에 없는 값으로 계산한다. 그래서 팝오버에는 "최대 용량 (배터리 보고값)"이라고 쓰고, 시스템 설정의 배터리 성능 상태라고 부르지 않는다.
- **[확인]** 남은 시간·완충까지 시간은 공개 키(분 단위, -1 = 계산 중)가 있지만, 헤더 설명대로 배터리 전원이거나 충전 중일 때만 의미가 있다. 어댑터에 꽂혀 완충된 지금은 0이라 아무것도 보여 주지 않는다.
- **[확인]** 충전 전력(W), "정상/서비스 권장" 문구는 공개 경로로 읽히지 않았다.
- **[정정]** 처음엔 "온도 키가 없다"고 적었다. 배터리 서비스 본체만 봤기 때문이다. 자식 항목(`AppleSmartBatteryPack`)의 `BatteryData`에 `Temperature` 2939가 있었다. 0.1 K로 읽으면 21.9 °C, 1/100 °C로 읽으면 29.39 °C인데, 비공개 HID 센서 "gas gauge battery"가 29.40 °C를 보여서 후자로 확정했다. 그래도 둘 다 같은 게이지에서 나온 숫자라 "정확하다"는 근거는 아니다. 그래서 "실험적" 딱지를 붙인다.
- **[확인]** 같은 사전에 평균 온도 235, 최고 37처럼 단위가 다른 값이 섞여 있다. 키 이름만 보고 단위를 짐작하면 틀린다.
- **[확인]** SMC는 연결은 되는데, 이 macOS 27에서는 어떤 키를 읽어도 "잘못된 인자"를 돌려줬다.
- **[판단]** 잔량은 60초 동안 거의 변하지 않아서, 다른 팝오버처럼 60초 그래프를 넣으면 평평한 선만 남는다. 대신 잔량 막대 하나와 상태 배지(아이콘 + 글자)로 정리했다.

### 9.5-14 Battery 팝오버: 상태 하나를 고르는 순서 (6-4f 구현)

- **[판단]** 잔량 12%인데 충전기에 꽂혀 있으면 "배터리 부족"이 맞을까? 사용자가 알아야 할 것은 "지금 충전되고 있다"이다. 그래서 충전 중을 가장 먼저 보고, 부족은 배터리 전원일 때만 쓴다. 꽂혀 있지만 충전하지 않으면 "충전 대기"이고, 이유(최적화 충전 등)는 모르니 쓰지 않는다.
- **[판단]** 온도는 "읽기 실패"(확인 불가)와 "오래된 값"(—)을 나눴다. 잠자기에서 깨어난 직후에는 마지막 값이 몇 시간 전일 수 있는데, 그걸 지금 온도처럼 보여 주면 안 된다. 팝오버는 새로 읽지 않고, 열려 있는 동안 15초마다 "얼마나 오래된 값인가"만 다시 판단한다.
- **[판단]** 어댑터 30W는 정격 출력이다. 지금 그만큼 충전된다는 뜻이 아니라서 "전원 어댑터 연결됨 · 30W"로만 쓴다.
- **[확인]** Battery 한 번 읽기(전원 + 어댑터 + 레지스트리 + 팩)는 0.37 ms였다. 60초에 한 번이라 새 타이머 없이 기존 흐름에 얹었다.

### 9.6 오류·원인·해결

| 문제 | 원인 | 해결 | 근거 |
|---|---|---|---|
| `VMPageCounters`의 `internal` 필드가 컴파일되지 않음 | `internal`은 Swift 접근 제어 키워드 | `anonymous`로 이름을 바꾸고 주석에 원래 필드명(`internal_page_count`)을 남김 | `SystemMetrics.swift` |
| 테스트 1개 실패: 실패 후 복구 시 기록이 사라짐 | 실패 샘플은 실제 `Date()`, 스크립트 샘플은 고정 날짜(2026-05)를 써서 "시계 역행"으로 기록이 초기화됨 | Store에 시계(`now`)를 주입. 실제 앱에서는 두 시각이 같은 시계에서 나옴 | `testFailureIsAGapNotZeroAndRecovers`, HANDOFF 3-1 |
| 장시간 실행 시 footprint가 10분간 2.18 → 3.15 MB로 계속 증가 | autorelease pool을 비워도 같았다. `heap` 비교 결과 libdispatch `_dispatch_source_set_handler` 할당이 초당 약 4개씩 쌓였고, `malloc_history`로 추적하니 측정 하네스의 `-[NSRunLoop runUntilDate:]` → `__CFRunLoopRun` 경로였다. 제한 시간을 둔 run loop에 다시 들어갈 때마다 생긴다. Store 코드와는 무관하다 | 하네스를 `CFRunLoopRun()` 한 번만 쓰도록 수정. malloc 객체 수가 1분·5분 30초 모두 1,302개로 같았고, `vmmap`에서 실제 사용 메모리(dirty + 압축) 증가는 4분 동안 +48 KB | HANDOFF "검증 결과 (3-1단계)" |
| 상위 프로세스 목록이 시스템 전체를 담지 못함 | [확인] 작업 셸에서 `proc_pid_rusage`가 812개 중 420개 EPERM. Codex가 entitlement 없는 임시 `.app`으로 재검증해도 792개 중 417개 EPERM이었고, 성공한 PID는 확인 가능한 범위에서 현재 사용자 소유였다. 활동 모니터 상위의 `WindowServer`·`kernel_task`는 조회되지 않았다. 샌드박스 탓이 아니라 일반 사용자 권한의 한계 | 범위를 "조회 가능한 프로세스의 TOP 5"로 확정하고 권한 거부 수를 함께 기록(3-2, Codex 구현) | SYSTEM-MONITOR V4, HANDOFF "3-2" |
| CPU 시간 단위 함정 | [확인, Codex 기록] `rusage_info`의 CPU 시간은 Mach tick이라 `mach_timebase_info`로 변환해야 한다. 변환 뒤 단일 코어 부하가 약 100%로 측정됨 | 시간 변환을 계산에 포함하고 테스트 | HANDOFF "3-2 사전 기술 검증" |
| 간헐 실패: `testMachSamplerReportsBaselineThenValidRanges` (`XCTUnwrap failed: expected non-nil value of type "CPUUsage"`) | [확인] `HOST_CPU_LOAD_INFO` 카운터는 일정하게 오르지 않는다. 5 ms 간격 관찰에서 최대 993 ms 동안 네 값이 모두 멈췄다. 200 ms 간격 150회 중 65회, 900 ms 간격 60회 중 2회, 1000 ms 간격 30회 중 0회가 `noElapsedTicks`였다. [추정] 원래 실패도 같은 원인으로 보이지만, 그 실행의 사유는 기록되지 않아 직접 확인하지 못했다. 커널 쪽 메커니즘도 미확인 | 대기를 1.1초로 늘리고, 설계상 건너뛰는 사유(`noElapsedTicks`, `counterReset`)에 한해 최대 3회 재시도한다. 그 밖의 사유는 즉시 실패시키고 사유를 출력한다. 10회 반복 통과. 제품 쪽 영향(1초 측정에서도 가끔 빈 구간)은 UI 단계 과제로 남김 | HANDOFF "3-2 안정화", SYSTEM-MONITOR §4 CPU |
| 프로세스 목록 조회 실패가 "프로세스 0개"로 보임 (Codex 리뷰, Medium) | [확인] `proc_listpids` 실패 시 빈 배열로 처리해 정상적인 0개와 구분하지 못했다 | 결과를 `SystemMetric`으로 바꿔 조회 실패는 `.unavailable(.readFailed(errno))`, 정상 0개는 `.available` + `readableCount == 0`. 조회 함수를 주입할 수 있게 해 errno까지 테스트 | `ProcessTopSampler.swift`, `testLiveReaderReportsInjectedListFailureWithErrno` |
| 팝오버를 닫아도 프로세스 순회가 계속되고, 늦게 끝난 이전 작업이 새 작업 상태를 지울 수 있음 (Codex 리뷰, Medium) | [확인] 중지할 때 타이머만 취소했고, 완료 처리가 세대와 무관하게 `sampling`·`pendingSample`을 초기화했다 | 중지 시 Task 취소, Sampler·PID 순회(64개마다)에서 협력적 취소 확인, 같은 세대일 때만 상태 변경, 다시 열면 즉시 새 수집 시작. 취소를 무시하는 가짜 Sampler로 경쟁 상태를 테스트 | `ProcessTopStore.swift`, `testReopenStartsImmediatelyEvenIfTheOldScanIgnoresCancellation` |
| GPU 일시 오류·이상값 한 번에 최대 5초 측정 불가 (5단계, Codex 최종 리뷰 Medium) | [확인] 재시도 제한이 실패 종류와 관계없이 5초였다 | 값 이상은 대기 없이 핸들 유지, 일시 실패는 0.25→0.5→1→2초, 지원 불가만 5초. 기존 테스트 하나가 바로 이 잘못된 동작을 기대하고 있어 교체했다 | `GPUSampler.fail`, `testRepeatedTransientFailuresBackOffToTwoSeconds`, `testSingleBadValueRecoversOnTheNextRead` |
| `@MainActor` 적용 후 컴파일 오류 `call to main actor-isolated initializer ... in a synchronous nonisolated context` | Store init의 기본 인자 `GPUSampler()`는 비격리 문맥에서 평가된다 | `gpu: (any GPUSampling)? = nil`로 받고 메인 액터인 init 안에서 생성 | `SystemMonitorStore.init` |
| GPU 오래된 값 게시 (5단계, Codex 리뷰 Medium) | [확인] 창이 끝난 뒤 1초 미만이면 무조건 게시했다. 창 시작 1.9초 뒤 타이머가 재개되면 약 1초 전 평균이 현재값이 됐다 | 닫는 읽기 지연 ≤ 0.25초와 마지막 유효 읽기 나이 ≤ 0.75초를 함께 확인하고, 아니면 폐기하고 측정 불가로 바꾼다. 0.5초 기준은 정상 창도 버려 완화했다 | `GPUUtilizationWindow.isFresh`, `testWindowClosedOnePointNineSecondsAfterItsStartIsDropped` |
| 실기기 테스트가 arm64 전체 지원을 가정 (5단계, Codex 리뷰 Medium) | [확인] `#if arch(arm64)`에서 GPU 값이 반드시 읽힌다고 단정했다. 검증한 기기는 1대뿐이다 | 검증 환경(Mac16,12 + macOS 27.0.1)만 지원을 필수로 하고, 다른 기기는 미지원 판정 허용. 지원 여부와 값 유효성을 따로 검사 | `GPUTests.testLiveReadOnThisMac` |
| idle wakeups를 실제보다 3~7배 크게 보고 (5단계 측정) | [확인] `top -stats idlew`의 IDLEW 열은 초당 값이 아니라 프로세스 시작 이후의 누적 카운터다("41+", "52+", …). 누적값들의 평균을 샘플 간격(4초)으로 나눠 29.3/s, 10.2/s, 9.8/s라고 보고했다 | 첫·마지막 기록의 차이 ÷ 경과 시간으로 다시 계산했다: GPU 켬 60초 약 4.3/s, 가짜 Sampler 약 2.8/s, 실제 Sampler 약 3.4/s(짧은 구간의 대략값, 이 프로세스만). 로그를 다시 보다가 숫자가 계속 커지는 것을 보고 발견했다 | `Doc/logs/2026-10-27-gpu-cost.txt` B절, SYSTEM-MONITOR §4 "GPU (5)" |
| GPU 비용이 예상의 약 10배 (5단계) | [확인] 연속 반복 벤치마크(1회 약 40 µs)로 비용을 추정했다. 실제처럼 100 ms 간격으로 따로 읽으면 1회 약 300~350 µs였고, 실제 Store 60초 실행에서 프로세스 CPU 약 0.5%였다(스케줄링만 0.19%) | 엔진은 요구대로 유지하고 실측값을 문서화했다. 완화 대안(서비스 핸들 재사용, 읽기 횟수 축소, 팝오버가 열릴 때만 고빈도)은 사용자 결정 대기 | SYSTEM-MONITOR §4 "GPU (5)" |
| Disk 여유 공간이 갱신되지 않을 위험 (4단계 구현 전 발견) | [확인] `URL`은 resource value를 객체에 캐시한다. 재사용한 URL은 1 GiB 쓰기 뒤에도 이전 값을 돌려줬다 | `DiskSampler.read`가 매번 새 `URL`을 만든다(주석에 근거) | `DiskSampler.swift`, SYSTEM-MONITOR V6 |
| 테스트 컴파일 오류 `'await' in an autoclosure that does not support concurrency` | `XCTUnwrap(try await sampler.sample().value)`. `XCTUnwrap`의 인자는 동기 autoclosure다 | `await` 결과를 먼저 변수에 받은 뒤 `XCTUnwrap` | `ProcessTopTests.swift` |
| 0.5pt 여백에서 렌더러 경계 테스트 실패(`100%`의 잉크가 이미지 첫 열에 닿음) (6-3 보완) | [확인] 여백이 2×에서 1px뿐이고, 올림으로 생긴 여분이 오른쪽에만 갔다. 고치고 나서도 `⚡100%`는 숫자·`%`·번개를 따로 픽셀 스냅해 마지막 열에 안티에일리어싱이 닿았다 | 올림 여분을 좌우에 나누고(`left(width:)`), 경계 테스트를 "가장자리에 진한 잉크가 없다(글자가 잘리지 않았다)"로 바꿨다. 이미지 밖으로 나가는 잉크는 없다 | `MenuBarSystemImageTests.testInkStaysInsideTheTwentyTwoPointRowAtTwoAndThreeTimes` |
| GPU 사용률 출처 | [확인] 공개 API가 없다. 문서화되지 않은 `Device Utilization %`는 부하와 연동되지만 순간값이라, 1초 1회 읽기는 평균 오차 42.7%p였다 | 5단계 검증에서 판단 B(실험적 지원, 짧은 간격 평균) 제안. 구현은 승인 대기 | SYSTEM-MONITOR V5 검증 기록, 9.5-2 |

### 9.7 재현 명령 (공개 시 주의)

- 배터리 레지스트리: `ioreg -rn AppleSmartBattery -d1`. 출력에 **배터리 일련번호(`Serial`)가 들어 있으므로** 캡처할 때 가린다.
- 전원 상태: `pmset -g batt`(출력에 기기 ID가 있음), `system_profiler SPPowerDataType`(일련번호 가리기)
- 메모리: `vm_stat`
- GPU: `ioreg -r -c IOAccelerator -d1 | grep "Utilization %"`
- Disk: `df -k / /System/Volumes/Data`, `diskutil info / | grep -E "Container (Total|Free)"`, `system_profiler SPStorageDataType`(Volume UUID 가리기)
- 누수 분석: 실행 파일을 `MallocStackLogging=1`로 실행하고 `heap <pid>`, `malloc_history <pid> -allBySize`, `vmmap --summary <pid>`, `leaks --atExit -- <실행 파일>`
- 경로에 사용자 이름이 들어가면 `~` 또는 `<repo>`로 바꾼다.

## AI 색상 조화의 접근성 검증 경계 (2026-10-29)

- **확인:** 가짜 한도(35%·30%·42%)를 쓰는 격리 Debug 창에서 실제 `UsageMenuView`의 AX 트리에 세 서비스 버튼과 `ProgressView` 값이 노출됐다. 색상 오버레이는 접근성에서 숨겨 기본 막대의 값 전달을 유지한다.
- **자동 점검 당시 미확인:** Tab·Space 입력은 포커스 변화/버튼 활성화의 증거를 남기지 못했다. 이후 사용자가 격리 창에서 AI 이름·사용량과 스위치 이름·ON/OFF의 VoiceOver 읽기를 확인했다(아래). 시스템 팝오버와 설치본은 별도 미검증이다. 그래프 기록은 코드상 접근성에서 숨겨져 있으며 추세의 음성 설명은 없다.
- **기록 가치:** 색상 픽셀 검증과 접근성 트리 검증은 서로 다른 증거다. 캡처가 필요하면 격리 AI 창의 AX 트리에서 막대 이름·값만 남기고 계정/경로는 가린다. 실제 VoiceOver 검증 전에는 접근성 완료 사례로 쓰지 않는다.
- **후속 준비:** 별도 Debug 사본의 실제 AI·시스템 설정 View에서 다섯 스위치 AX 이름과 OFF, CPU 클릭 시 ON→OFF 복원, 세 서비스 막대 값을 확인했다. 키보드 자동 입력은 포커스 이동을 입증하지 못했고 VoiceOver 발화는 아직 확인 전이다. 앱을 한 창에 나란히 배치한 데서 생긴 AX 요소 교차 순서는 제품 결함 증거로 쓰지 않는다.
- **사용자 수동 확인:** VoiceOver는 격리 AI 서비스 이름·사용량과 시스템 스위치 이름·ON/OFF를 읽었다. Control+F2는 상단 메뉴 막대로 이동했다. Tab 여러 번으로 Codex 버튼 포커스 이동은 관찰되지 않았다. 키보드 탐색 설정을 확인하지 않았으므로 원인은 미확정이고 결함/정상 판정은 보류한다. 정확한 퍼센트 발화 형식·설치본·macOS 14/15는 증명하지 않았다. 수동 검증은 종료했으며 추가 조작 캡처는 요청하지 않는다.
- **색상 브랜치 화면 검증 결정:** CPU·배터리 변경 색은 기존 화면 밖 다크·라이트 렌더 검증 결과를 수용한다. 실제 앱 화면과 라이트 배터리 막대 채도는 아직 확인하지 않았고 후속 검증으로 남긴다. 격리 AI 주의 막대의 활성 다크·라이트 실제 화면 확인과 구분해 기록한다.
