# Tokenly 구현 계획

## 1. 범위와 검증 결과

Tokenly는 SwiftUI `MenuBarExtra`로 여러 AI 서비스의 사용량을 보여 줄 독립적인 macOS 앱이다. 사용자는 Codex와 AGY의 실제 한도 표시 성공을 보고했다. 이후 사용자가 아코디언 열림과 AGY 접기/펼치기를 확인했다. OpenAI API 연동은 보류한다. Claude 구독은 공식 Claude Code 상태줄 JSON 수신 코드를 구현했지만 실제 계정 수신·사용자 설정 연결·GUI가 미검증이다. Gemini는 조사 단계로 유지한다. AGY는 Gemini API·Gemini CLI와 별도로 검증한다. 토큰 수, 구독 한도, API 비용을 합산하지 않는다.

2026-10-22 일반 macOS 사용자 터미널에서 공식 Codex app-server의 `initialize` → `initialized` → `account/rateLimits/read`로 읽기 전용 실제 조회에 성공했다. 버킷은 1개였고, 당시 300분 창은 사용 35%·잔여 65%·초기화 2026-10-23 01:42 KST, 10080분 창은 사용 77%·잔여 23%·초기화 2026-10-27 15:47 KST였다. **이는 검증 당시 수치이며 앱에는 고정하지 않는다.** 작업 샌드박스에서는 app-server의 SQLite 상태 저장소 권한 문제로 같은 조회를 완료하지 못했다. 현재 CLI는 `codex-cli 0.163.0-alpha.10.2`다. 공식 프로토콜과 필드는 [Codex app-server 문서](https://learn.chatgpt.com/docs/app-server)를 따른다.

## 2. 구현 순서와 현황

| 순서 | 구현·검증 | 현황 |
| --- | --- | --- |
| 1. 기술 검증 | 공식 읽기 전용 경로, 실제 300분·10080분 창 확인 | 일반 사용자 터미널에서 완료 |
| 2. 프로젝트 초기화 | Routine Scout와 별도 Xcode macOS 프로젝트, `MenuBarExtra` | 기존 앱의 실제 메뉴 막대·Codex 조회 성공 (사용자 확인) |
| 3. 모델·Provider | JSONL stdio 통신, 한도 필드 검증, CLI 부재·오류 처리 | 유지; 현재 Xcode XCTest 총 16개 통과 |
| 4. 메뉴 UI | 사용·잔여 비율, 초기화 시각, 데이터 없음·조회 중·오류 | 캡슐형 표시 오류 확인; 현재 단일 텍스트에서 두 한도 표시를 실제 GUI 확인, 부분 글꼴 차이는 미미함; 예외 상태 GUI 확인 필요 |
| 5. 갱신 | 수동 및 5분 자동 새로고침, 중복 요청 방지, 이전 데이터 표시 | 연속 조회·실패 상태 단위 테스트 통과; 실제 버튼·타이머 확인 필요 |
| 6. 검증·배포 | 실제 계정 값 대조, XCTest, GUI 확인, README·서명 검토 | 미완료 |

## 3. 프로젝트 구조

```text
Tokenly/
├── Doc/
│   ├── SPEC.md
│   ├── TODO.md
│   └── IMP-PLAN.md
└── src/
    ├── Tokenly.xcodeproj
    ├── Tokenly/
    │   ├── TokenlyApp.swift            # 메뉴 막대 진입점
    │   ├── UsageStore.swift            # 화면 상태·새로고침
    │   ├── Models/UsageSnapshot.swift  # 창 길이·비율·시각
    │   ├── Models/ExternalUsage.swift   # AGY 쿼터·OpenAI API 토큰/비용
    │   ├── Models/HeartGauge.swift      # 하트 대표 잔여율·상태 계산, 팝오버 하트 대시보드
    │   ├── Providers/UsageProvider.swift
    │   ├── Providers/CodexUsageProvider.swift
    │   ├── Providers/OpenAIAPIUsageProvider.swift
    │   ├── Providers/AGYStatusLineProvider.swift
    │   ├── Providers/ClaudeSubscriptionProvider.swift
    │   ├── ExternalProviderStore.swift
    │   ├── KeychainAdminKeyStore.swift
    │   ├── ProviderDisplaySettings.swift
    │   ├── AGYStatusLineBridge.py
    │   └── Views/UsageMenuView.swift, TokenlySettingsView.swift, HeartGaugeView.swift  # 젤리 하트 컴포넌트
    └── TokenlyTests/TokenlyTests.swift
```

`UsageProvider`·`UsageSnapshot`은 검증된 Codex 300분·10080분 창 전용으로 유지한다. 다른 지표는 `ExternalUsageProvider`·`ExternalUsageSnapshot`·`ExternalMetrics`로 분리했다. OpenAI API에는 기간별 토큰·비용, AGY에는 버킷별 잔여 비율·초기화 시각을 사용하므로 모든 Provider에 5시간·7일 창을 강제하지 않는다. AGY 실제 표시 성공 이후에도 두 Provider의 지표 의미가 달라 공통화는 별도 검토한다. Routine Scout의 코드·아이콘·설정은 사용하지 않는다.

## 4. 데이터 흐름과 보호 경계

```mermaid
flowchart LR
    U[수동/5분 갱신] --> S[UsageStore]
    S --> P[CodexUsageProvider]
    P --> C[로컬 Codex CLI app-server]
    C --> P
    P --> M[검증된 UsageSnapshot]
    M --> V[SwiftUI MenuBarExtra]
    P --> E[부재·연결·응답 오류]
    E --> V
```

Provider는 `Process`로 설치된 CLI의 `app-server --listen stdio://`를 실행한다. JSONL로 `initialize` 응답을 받은 후 `initialized`를 보내고 `account/rateLimits/read`를 호출한다. `rateLimitsByLimitId.codex` 또는 기본 `rateLimits`에서 300분·10080분 창을 찾는다. 유효 범위 0~100의 `usedPercent`가 있을 때만 `100 − usedPercent`를 표시하고, `resetsAt` Unix 초를 현지 시각으로 변환한다. CLI가 없거나 실행되지 않으면 앱은 오류 상태를 표시한다. 타임아웃은 20초다.

앱은 인증정보 파일을 직접 읽거나 수정하지 않는다. 계정 식별자·토큰·원시 JSON·app-server 진단 출력을 기록하지 않는다. 마지막 성공 스냅샷은 메모리에만 두며 후속 요청이 실패하면 `이전 데이터`로 표시한다.

## 5. 테스트 계획

- 비밀 없는 고정 JSON으로 300분·10080분 창, 잔여 계산, 부분·빈·잘못된 응답, 읽기 오류를 확인한다.
- CLI 부재와 탐색 경로를 테스트한다. 타임아웃·반복 갱신은 실제 앱에서 별도 확인한다.
- 일반 사용자 환경에서 앱의 표시값을 공식 Codex 표시값과 비교한다. 원시 응답과 계정 식별정보는 기록하지 않는다.
- Xcode에서 메뉴 막대 표시, 수동 갱신, 5분 자동 갱신, 조회 실패, 앱 재실행을 확인한다.
- 앱 빌드와 XCTest 실행, 실제 GUI 실행 결과를 구분해 기록한다. 작업 샌드박스의 `xcodebuild test`는 테스트 서비스 접근 제한으로 실행되지 않았지만, Xcode GUI에서 현재 XCTest 16개가 통과했다.

## 6. 위험과 대응

| 위험 | 대응 |
| --- | --- |
| CLI 미설치·인증 없음·샌드박스의 상태 저장소 접근 제한 | 앱은 종료하지 않고 실패 안내; 일반 사용자 환경에서 재검증 |
| CLI 버전이나 JSON 계약 변경 | 선택 필드·부분 창을 안전하게 처리하고 실제 계약을 다시 확인 |
| 창이 없거나 다른 길이로 제공됨 | 수치를 추정하지 않고 데이터 없음으로 표시 |
| 과도한 호출·중복 요청 | 5분 간격, 진행 중 재호출 차단, 20초 제한 |
| 오래된 값 또는 조회 실패 | 마지막 성공 시각과 `이전 데이터` 명시 |
| 다른 서비스 지표와 혼동 | Provider별 조회 경계와 지표 단위 분리; 후속 서비스 지원 확정 금지 |
| 인증정보 노출 | 공식 로컬 CLI만 호출하고 인증 파일·원시 응답을 취급하지 않음 |

## 7. 다음 확인

사용자는 캡슐 변경 이전 앱에서 실제 Codex app-server 조회와 macOS 메뉴 막대 표시 성공을 확인했다. 현재는 그때 동작한 **단일 텍스트 라벨**로 복구해 실제 응답 기반 잔여 비율을 `5h 29% · 7d 17%` 형식으로 만든다. 한 창만 있으면 다른 창은 `—`, 응답이 비어 있으면 `데이터 없음`, 첫 조회 중이면 `조회 중`, 실패 시 성공값이 없으면 `조회 실패`, 이전 성공값이 있으면 `이전 · …`로 표시한다. 팝오버의 진행 막대는 잔여 비율이며 초록(50% 초과)·주황(20% 초과~50%)·빨강(20% 이하)으로 구분한다. 팝오버 대비 개선과 수동·5분 자동 갱신 코드는 유지했다.

Xcode에서 현재 앱·테스트 타깃 빌드와 XCTest 16개 통과를 확인했다. 테스트는 디코딩된 두 한도 값과 스타일 적용 후 원문 보존을 확인한다. 사용자는 현재 메뉴 막대에서 **두 한도 수치가 정상 표시됨**을 실제 GUI에서 확인했으며, 부분 글꼴의 시각적 차이는 거의 없었다. 누락·이전 데이터 표시, 수동 버튼 클릭과 5분 타이머, 현지 시간대 표시와 실제 계정 값 대조는 별도 확인이 필요하다. 배포 서명·공증은 별도 검토가 필요하다.

## 8. 메뉴 막대 라벨과 팝오버의 현재 방식

[Apple의 `MenuBarExtra` 문서](https://developer.apple.com/documentation/swiftui/menubarextra)는 `init(content:label:)`로 사용자 지정 SwiftUI `View`를 라벨로 제공하고 `.window` 스타일로 팝오버형 내용을 표시할 수 있음을 명시한다. 이전 시도에서 라벨 안에 `ForEach`로 만든 두 캡슐 그룹과 개별 숫자 색상을 넣었지만, 사용자의 실제 GUI에서는 **아이콘과 `5h`만 표시**됐다. `UsageStore.menuBarText`는 두 값을 이미 단일 문자열로 만들고 기존 GUI에서도 표시됐으므로 데이터 계산·바인딩보다는 새 라벨 구성에서 표시가 끊긴 것으로 판단한다. 다만 메뉴 막대 가용 폭에 따른 잘림인지 SwiftUI 라벨 레이아웃·색상·배경 처리 중 무엇이 직접 원인인지는 확정할 근거가 없다.

**당시 방식(17절에서 변경):** 시스템 아이콘 옆에 한 개의 `Text`를 둔다. `UsageStore.menuBarText` 문자열을 `AttributedString`으로 감싸고 `5h`·`7d` 범위만 10pt 보통 굵기, 나머지 비율은 12pt 굵기로 지정한다. [Apple의 `Text(AttributedString)` 문서](https://developer.apple.com/documentation/swiftui/text/init%28_%3A%29)는 문자열 범위별 스타일을 한 `Text`에 전달하는 방식을 지원한다. 기존처럼 두 값, 누락값 `—`, 이전 데이터 `이전`을 동일한 문자열로 전달하며 캡슐·개별 색상·별도 그룹은 사용하지 않는다. 빌드와 XCTest 13개가 통과했고 사용자는 실제 메뉴 막대에서 두 비율이 모두 표시됨을 확인했다. **부분 글꼴 스타일은 실제 GUI에서 눈에 띄는 차이가 없었다.** 수치가 정상 표시되는 현재 텍스트 라벨을 안정적인 기본 방식으로 유지하고 추가 SwiftUI 라벨 실험은 중단한다. 캡슐형은 실제 GUI에서 표시 오류가 발생했다. 그룹형·색상형 디자인은 향후 테마 기술 검증으로 보류한다.

팝오버의 불투명한 `NSColor.windowBackgroundColor` 배경은 다크 모드에서 검게 무거워 보인다는 실제 GUI 피드백이 있었다. 현재는 [SwiftUI `regularMaterial`](https://developer.apple.com/documentation/swiftui/material)을 루트 배경으로 사용한다. Apple 문서상 일반 재질은 배경을 흐리면서 일부 투과시키고 외관에 따라 반응한다. [AppKit `NSVisualEffectView`](https://developer.apple.com/documentation/appkit/nsvisualeffectview)는 팝오버에서 시스템이 이미 생성하는 시각 효과이므로 별도 뷰·커스텀 윈도우를 추가하지 않았다. 일반 재질은 더 얇은 재질보다 불투명해 지나친 배경 비침을 줄이려는 선택이다. 다만 실제 투명도와 가독성은 두 외관에서 GUI 확인이 필요하다.

제목과 잔여 수치는 기존 강조를 유지하고 보조 정보는 기본 전경색과 작은 글꼴로 위계를 둔다. 초기화 시각은 사용 비율과 같은 `HStack`에서 분리해 별도 줄에 놓고 세로 방향 줄바꿈을 허용한다. 마지막 성공 시각도 줄바꿈을 허용한다. 폭 300pt와 14pt 안쪽 여백은 유지해 팝오버가 불필요하게 커지지 않게 했다. 메뉴 막대 단일 텍스트 라벨, Provider, 잔여 막대의 색상 기준, 5분 갱신은 변경하지 않았다. 변경 후 앱 빌드와 XCTest 12개가 통과했으며 실제 GUI의 라이트·다크 모드 결과는 미검증이다.

## 9. 장기 확장과 문서 관리

당시 메뉴 막대 테마 계획은 숫자형 하나였고, 17절에서 숫자형·최소형·아이콘형을 구현했다. 후속 테마 개발에서는 AppKit `NSStatusItem`·`NSStatusBarButton`에 속성 문자열을 적용하거나 사용자 지정 뷰를 사용하는 방식을 **기술 검증 후보**로 비교한다. 메뉴 막대 렌더링·폭·접근성을 실제 GUI에서 확인한 뒤에만 채택하고, 테마별 라벨을 조회 모델과 분리한 다음 사용자 설정 저장을 설계한다. 추가 Provider의 실제 계정 계약을 검증한 뒤 서비스별 로고·메뉴 막대 표시 대상 선택과 시간 단위·잔여 비율 구분을 설계한다. Tokenly 전용 앱 아이콘은 Routine Scout와 독립적인 콘셉트를 나중에 결정한다. Claude 구독·Gemini는 자동 조회 후보 검증 단계이고 OpenAI API는 연결 보류 중이다. AGY는 사용자 보고로 실제 한도 표시가 확인됐다.

새 요구사항이나 사용자 동작·설계 변경이 생기면 관련 문서를 갱신한다. 미래 아이디어는 현재 구현과 분리하고 구현·테스트·실제 GUI 검증을 각각 기록한다. 무효가 된 계획은 정리하며 문서 사이의 모순을 확인한다. 사용자 기능이나 설계를 바꾸지 않는 내부 코드 수정에는 불필요한 문서 변경을 하지 않는다.

## 10. 독립 실행과 로그인 항목

Release 구성으로 `Tokenly.app`을 빌드해 `dist/Tokenly.app`에 복사했다. 번들 식별자는 `com.tokenly.app`이고 기존 `Info.plist`의 `LSUIElement=true`가 메뉴 막대 전용 실행을 담당한다. 앱은 개발용 DerivedData 경로를 참조하지 않으며 Codex CLI·인증정보를 내장하지 않는다. 이번 번들은 로컬 임시 사용을 위한 ad-hoc 서명이며 일반 배포를 위한 Developer ID 서명·공증은 아직 하지 않았다.

Finder에서 시작한 앱은 터미널의 `PATH`를 그대로 받지 않을 수 있다. Provider는 전달받은 `PATH`를 먼저 살핀 뒤 `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.npm-global/bin`의 실행 가능한 `codex`를 찾는다. 찾지 못하거나 실행할 수 없으면 기존 오류 상태를 사용한다. 사용자는 `/Applications` 설치 후 Xcode 없이 실행해 실제 Codex 사용량 조회 성공을 확인했다. 이 결과는 설치 환경에서 CLI 탐색과 app-server 조회가 함께 동작했음을 보여 주지만, 선택된 CLI 경로는 별도로 기록하지 않았다. 사용자별 버전 관리자 등의 다른 경로는 현재 자동 탐색 범위 밖이다.

[Apple `SMAppService` 문서](https://developer.apple.com/documentation/servicemanagement/smappservice)에 따라 메인 앱의 로그인 항목에 `SMAppService.mainApp`을 사용한다. 사용자가 토글을 조작할 때만 `register()`/`unregister()`를 호출하고, 시작 시에는 `status`만 읽는다. `enabled`·`notRegistered`·`requiresApproval`·`notFound`를 구분해 안내한다. Xcode/임시 폴더 실행에서는 설치 위치를 확인해 토글을 비활성화하고, `/Applications` 또는 `~/Applications`의 앱에서만 변경한다. 번들 식별자와 안정된 설치 위치가 필요하며 서명·시스템 승인 조건은 실제 설치 환경에서 확인해야 한다. 테스트는 가짜 컨트롤러로 등록·해제·실패를 검증했으며 사용자 로그인 항목은 변경하지 않았다.

앱·테스트 타깃 빌드, ad-hoc 서명 번들 검증, XCTest 16개 통과를 확인했다. 사용자는 `/Applications`에 설치한 앱을 Xcode 없이 실행해 실제 Codex 사용량 조회 성공을 확인했다. 최초에는 앱이 로그인 시 자동 실행 상태를 확인하지 못했으나 **정확한 원인은 미확정**이다. 이후 사용자가 macOS 시스템 설정에서 Tokenly를 로그인 항목에 직접 추가하자 앱에 `켜짐 · 다음 로그인부터 실행됩니다.`가 표시됐다. 이는 시스템 설정을 통한 등록과 앱의 활성 상태 조회가 동작한 검증 결과다. 앱 내부 토글만으로 신규 등록·해제하는 동작과 재로그인 후 자동 실행, 독립 앱 종료 후 재실행은 아직 검증하지 않았다.

## 11. 추가 Provider 기술 조사 (2026-10-23)

이번 조사는 공식 문서·공개 스키마와 설치된 CLI의 **버전·도움말만** 확인했다. 계정별 API 호출, 모델 요청, 로그인, 키 열람, 설정 변경은 하지 않았다. `claude` 2.1.292와 `agy` 1.4.5는 `PATH`에서 확인됐고 `gemini`는 발견되지 않았다. `claude --help`와 `agy --help`에는 독립적인 비대화형 사용량 조회 명령이 보이지 않았다. 이는 기능 부재의 증명이 아니며, 특히 AGY는 대화형 `/usage`와 공식 상태줄 계약이 따로 있다. OpenAI API용 관리자 자격이나 과금 상태는 확인하지 않았다.

| 서비스 | 공식 조회 경로·가능 지표 | 잔여 비율·초기화 | 인증·제약 | 현재 상태 |
| --- | --- | --- | --- | --- |
| **Codex** | 공식 app-server `account/rateLimits/read`: 구독 300분·10080분 창의 사용률·초기화. API 토큰·비용과 별개 | `100 − usedPercent`, `resetsAt` 확인 | 기존 로컬 Codex CLI 인증; 5분 새로고침 | **실제 조회 검증 완료** (설치 앱 포함) |
| **Claude** | [Claude Usage and Cost Admin API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api): 조직 API 토큰·USD 비용. [Rate Limits API](https://platform.claude.com/docs/en/manage-claude/rate-limits-api): 설정된 API 한도. 개인 구독은 [Settings → Usage](https://claude.com/pricing)에서 확인 | Admin 보고 API가 개인 구독 잔여 비율·초기화 시각을 준다는 근거 **미확인**; API 보고 버킷 시각은 있음 | Admin API 자격 또는 `org:admin` 등 조직 권한 필요; 개인 계정에 Admin API 미적용. 보고 데이터 보통 5분 지연, 지속 폴링 권장 1분 이상 | **공식 API 보고 지원 확인, 실제 조회 미검증**. 개인 구독의 공식 기계 조회 방법 미확인 |
| **Gemini** | [Gemini API AI Studio Usage·Billing](https://ai.google.dev/gemini-api/docs/billing/) 및 [Rate limits](https://ai.google.dev/gemini-api/docs/rate-limits): 프로젝트별 API 사용·비용·RPM/TPM/RPD. 별도 [Gemini CLI `/stats model`](https://geminicli.com/docs/resources/quota-and-pricing/)은 세션 토큰·적용 한도 표시 | API 대시보드의 구독형 잔여 비율·재설정 시각 필드 **미확인**; RPD는 태평양 시간 자정 재설정 | API 키·프로젝트/청구 권한 또는 CLI 로그인 필요; 과금·호출 제한은 프로젝트·모델별. 현지 `gemini` 실행 파일 미발견 | **공식 대시보드·CLI 표시 확인, 실제 조회 미검증**. 안전한 프로그램 조회 계약은 추가 확인 필요 |
| **OpenAI API** | [조직 Usage GET](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/completions): 토큰·요청 수; [Costs GET](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/costs): USD 비용 | 보고 버킷 시작·종료 시각은 있음. Codex 구독 잔여 비율·초기화 아님. [API 응답 rate-limit 헤더](https://developers.openai.com/api/docs/guides/rate-limits)는 요청 단위 잔여·재설정이나 조회를 위해 모델 호출을 새로 만들지 않음 | 조직 Admin API 키·권한 필요; 보고 조회도 접근 권한과 호출 제한 확인 필요 | **공식 읽기 전용 API 확인, 실제 조회 미검증·관리자 설정 필요** |
| **Google Antigravity(AGY)** | [AGY CLI `/usage`/`/quota`](https://antigravity.google/docs/cli/commands/usage): 모델별 쿼터 TUI. [공식 상태줄 입력 계약](https://antigravity.google/docs/cli/statusline): 모델/버킷별 `quota.remaining_fraction`, `reset_time`, 선택적 `reset_in_seconds` | 실제 수신 파일에서 `3p-weekly`·`gemini-weekly` 키 확인. `context_window.remaining_percentage`는 대화 문맥 용량이므로 구독 쿼터로 사용하지 않음 | 기존 AGY 로그인 세션 필요. 상태줄은 CLI 설정과 명령 실행이 필요하고 입력에 이메일·경로·세션 식별자도 포함되므로 선별 추출·비저장 필요. TUI는 자동 조회 계약이 아님 | **사용자가 실제 한도 표시 성공을 보고; 이번 UI는 별도 검증 필요** |

### 서비스별 구현 판단

- **Claude:** 현재 `claude` 설치 확인만 완료했다. 구독 5시간·주간 한도는 [Claude 요금·사용량 안내](https://claude.com/pricing)에 있으나, `claude --help`나 검토한 공식 자료에서 Tokenly가 기존 로그인으로 안전하게 반복 호출할 개인 구독 읽기 전용 API를 확인하지 못했다. 조직 API 지표는 별도 상품의 토큰·비용이므로 구독 한도 대용으로 표시하지 않는다. 조직 관리자 권한이 있다면 별도 승인 후 최소 범위의 Usage/Cost GET만 검증한다.
- **Gemini:** Gemini API, Gemini CLI, Gemini 웹 구독은 동일 지표가 아니다. 현지 Gemini CLI가 없으므로 설치 없이 CLI 실제 조회는 불가하다. AI Studio의 프로젝트별 대시보드는 공식이지만 현재 Tokenly용 안전한 계정별 읽기 전용 사용량 API 계약은 확인하지 못했다. API 키로 모델 생성 요청을 보내 헤더나 사용량을 얻는 방식은 이번 검증에서 제외한다.
- **OpenAI API:** 관리자 조회는 Codex 구독과 인증·계정·단위가 다르다. 조직·프로젝트 범위, 관리자 권한, 보고 지연과 비용 권한을 먼저 확인한다. 표준 모델 요청의 rate-limit 헤더를 구독 잔여량으로 오인하지 않는다. 관리자 키를 앱 번들에 넣지 않고 사용자가 명시적으로 연결할 안전한 자격 관리 방식을 추후 설계한다.
- **AGY:** `agy` 설치를 확인했다. 대화형 `/usage`는 백엔드에서 새 쿼터를 확인하지만 TUI 파싱을 안정적인 앱 계약으로 확정하지 않는다. 공식 상태줄은 AGY가 JSON을 **푸시**하는 계약으로, Tokenly가 임의 시점에 조회하는 API가 아니다. 문서 예제에 있는 `email`·`session_id`·`cwd` 등은 저장·표시하지 않고 `quota`의 검증된 필드만 취급하는 설계를 먼저 검토한다. 이를 사용하려면 사용자 CLI 설정 변경이 필요하므로 이번에는 실행하지 않았다. AGY 버킷을 Gemini API 프로젝트 쿼터와 합치지 않는다.

### 우선순위와 다음 안전 검증

1. **AGY 데이터 계약 검증:** 이 환경에 CLI가 있고 공식 상태줄 쿼터 필드가 있다. 먼저 사용자에게 현재 AGY 사용 여부와 상태줄 설정 변경 허용 여부를 확인한다. 승인 전에는 설정·세션을 수정하지 않는다. 실제 필드가 확인되어도 푸시 방식의 갱신 빈도와 종료 시 데이터 부재를 처리해야 한다.
2. **OpenAI API 또는 Claude 조직 API:** 해당 조직의 관리자 권한과 읽기 전용 사용 목적이 확인되면 보고 GET만 검증한다. 두 서비스 모두 API 토큰·비용 Provider이며 구독 잔여율 Provider가 아니다. 권한이 없다면 보류한다.
3. **Gemini API/CLI:** 사용 중인 제품·인증 형태를 먼저 확인하고 공식 프로그램 조회 계약 또는 사용자가 직접 확인 가능한 대시보드 범위를 좁힌다. CLI 설치나 유료 모델 요청은 승인 전 수행하지 않는다.
4. **Claude 개인 구독:** 공식 기계 조회 계약을 확인할 때까지 구현 보류. 웹 표시나 로컬 인증 파일을 파싱하지 않는다.

구현 시 공통 화면 모델은 `subscriptionQuota`, `apiTokens`, `apiCost`를 다른 지표로 유지한다. 각 Provider는 공식 데이터 원천·권한·기간·단위·조회 시각·오류를 자체적으로 보고한다. **문서상 공식 지원과 현재 계정 실제 조회는 다르며, 현재 추가 후보 네 서비스 중 실제 계정 조회 검증 완료는 없다.**

## 12. 팝오버·설정 창 분리: 현재 구현과 후속 계획

**현재 구현:** 팝오버에서 로그인 토글·상태 안내를 제거하고 사용량·새로고침·설정 열기·종료를 둔다. 별도 설정 창에 일반, AI 서비스, 메뉴 막대, 테마 탭을 구성했다. 로그인 토글은 일반 탭에서 기존 `LoginItemManager`와 `SMAppService.mainApp`을 그대로 사용한다. AGY는 이후 사용자 보고로 실제 한도 표시가 확인됐고 OpenAI API 연결은 보류했다. 메뉴 막대 라벨과 `.regularMaterial` 팝오버, Codex 조회·5분 갱신은 바꾸지 않았다.

### macOS 구현 후보와 제약

- [Apple SwiftUI `Settings` scene](https://developer.apple.com/documentation/swiftui/settings)과 [SwiftUI `OpenSettingsAction`](https://developer.apple.com/documentation/swiftui/opensettingsaction)을 채택했다. 팝오버 버튼은 `openSettings()`를 호출하고 `NSApp.activate`로 메뉴 막대 전용 앱을 활성화한다. 설정 창에 넣은 작은 `NSViewRepresentable`이 실제 `NSWindow`를 약하게 참조하여 이미 보이는 경우 같은 창을 `makeKeyAndOrderFront`로 앞으로 가져온다. 닫힌 창은 다시 `openSettings()`로 연다. 별도 커스텀 창은 만들지 않았다. `LSUIElement=true`에서 창 표시·키보드 포커스·재열기·중복 방지·닫힌 뒤 앱 유지 동작은 **Xcode와 설치 앱의 실제 GUI에서 검증 필요**하다.
- Codex 팝오버 표시 여부는 `ProviderDisplaySettings`가 앱 `UserDefaults`의 `provider.codex.visibleInPopover` 키로 저장한다. `@Published` 값을 설정 창과 팝오버가 공유하며 기본값은 `true`다. `UserDefaults`를 주입할 수 있어 별도 테스트 저장소에서 저장·재로드를 검증하도록 했다. 인증정보나 사용량 응답은 저장하지 않는다. 로그인 항목은 저장된 Boolean 대신 `SMAppService`의 실제 상태를 표시하고 최초 실행에 등록하지 않는다. 이후 17절에서 메뉴 막대 표시 스타일과 앱 외관 설정을 저장하도록 확장했다.
- 서비스 표시 설정은 Provider의 **구현·계정 조회 가능 상태**와 분리한다. Codex는 기본 표시이며 숨겨도 기존 조회와 메뉴 막대 수치를 유지한다. AGY는 상태줄 수신 파일이 있을 때만 표시를 선택할 수 있으며 숨기면 자동 조회 대상에서 제외한다. OpenAI API는 연동 보류 중이므로 Provider 코드와 저장된 선택값은 보존하되 설정 조작·조회·팝오버 표시를 중단한다. 연결 조건이 없어지거나 조회가 실패하면 0으로 대체하지 않고 상태를 표시한다. Claude·Gemini는 선택할 수 없다. AGY 푸시 데이터와 Codex의 5분 조회 주기를 동일시하지 않는다. 구독 한도·API 토큰·API 비용을 한 지표로 합치지 않는다.
- 메뉴 막대 표시 설정에는 앞쪽 시스템 아이콘 표시/숨김, Provider·지표 선택, 숫자형·아이콘형·캐릭터형·미니멀형을 둔다. 모두 숨겨 메뉴 막대에서 앱 접근이 끊기지 않도록 기본 표시 또는 안전한 대체 라벨을 설계한다. 현재 `MenuBarExtra` 캡슐형은 실제 GUI에서 일부만 표시됐고 단일 `Text`의 부분 글꼴 스타일은 차이가 거의 없었다. 따라서 [Apple `MenuBarExtra`](https://developer.apple.com/documentation/swiftui/menubarextra)의 라벨 표현을 더 확장하기 전에 AppKit `NSStatusItem`·`NSStatusBarButton`의 속성 문자열/사용자 지정 뷰를 기술 검증하고 폭·접근성·라이트/다크 모드에서 비교한다. 17절에서 숫자형·최소형은 단일 텍스트 방식을 유지하고 아이콘형은 작은 SF Symbol 조합으로 구현했다.

### 단계별 작업과 검증 순서

1. **구현:** 초기에는 Codex만 선택 가능한 설정과 기본 표시 `true`, 숨김은 팝오버에만 적용하고 조회는 유지하는 정책을 정했다. 이후 13절의 OpenAI API·AGY 연결 조건부 선택을 추가했다. 위 11절의 Provider 조사 기록은 유지한다.
2. **구현, GUI 미검증:** `Settings` scene과 저장 모델, 팝오버 열기와 기존 창 재사용을 구성했다. 설치 앱에서 열기·닫기·재열기·포커스·메뉴 막대 앱 계속 실행을 확인해야 한다.
3. **구현, GUI 미검증:** 로그인 시 자동 실행 설정을 일반 탭으로 옮겼다. 기존 로그인 항목 모의 테스트는 남겨 두었지만 이번 환경에서 XCTest 실행은 중단됐다. 앱 내부 신규 등록·해제 및 재로그인 자동 실행은 별도 실기 검증으로 남긴다.
4. **구현, GUI 미검증:** Codex 표시 선택의 저장·재로드, 숨긴 상태의 빈 안내, 미지원 후보의 읽기 전용 안내를 구성했다. 뒤이어 OpenAI API·AGY의 연결 조건부 선택과 별도 지표 모델을 추가했다. 테스트 코드는 컴파일됐으나 전체 실행 통과는 확인하지 못했다. 두 서비스의 실제 계정 계약은 사용자 연결 후 검증한다.
5. 메뉴 막대 아이콘 숨김·표시 대상 선택의 안전한 기본 표시를 검증하고, AppKit 상태 막대 방식의 기술 시험 후 테마 구현 여부를 결정한다. 화면별 실제 GUI 결과와 빌드·단위 테스트를 구분해 기록한다.

기능·기술 판단 또는 실제 검증 상태가 바뀌면 SPEC·TODO·이 계획과 사용자 사용법 문서를 함께 맞추되, 미구현 후보를 현재 지원 기능처럼 기록하지 않는다.

이번 변경은 Debug 앱과 테스트 타깃 `build-for-testing`, Release 앱 빌드가 성공했다. 새 Release 앱은 `/private/tmp/tokenly-settings-release/Build/Products/Release/Tokenly.app`에 있으며 `/Applications` 설치본과 기존 `dist`는 변경하지 않았다. XCTest 18개는 컴파일됐지만 `xcodebuild test`가 샌드박스의 `IDETestProgressNotification` 게시 제한으로 종료되어 **통과로 기록하지 않는다**. `xcrun xctest` 직접 실행은 앱 호스트 심볼을 찾지 못해 대체 검증으로 사용하지 않았다. 설정 창 활성화와 포커스는 실제 GUI 확인 전까지 미검증이다.

## 13. 추가 Provider 연동 구현과 남은 검증 (2026-10-23)

11절은 **연동 전 기술 조사 기록**이다. 이번 작업에서는 설치된 `claude` 2.1.292·`agy` 1.4.5의 도움말을 다시 확인했다. 두 CLI의 `--print`는 모델 턴 실행용이며 한도 조회로 호출하지 않았다. Codex의 `UsageProvider`와 메뉴 막대 표시를 그대로 두고, 다른 지표를 `ExternalUsageProvider` → `ExternalProviderStore` → 팝오버 카드로 분리했다. 각 서비스는 자체 조회 중·성공·설정 필요·인증 필요·권한 오류·연결 실패·타임아웃 상태를 갖는다. 이전 정상 데이터가 있으면 실패와 마지막 성공 시각을 함께 표시한다.

| Provider | 구현 방식과 경계 | 실제 계정 확인 |
| --- | --- | --- |
| Claude 구독 | 당시에는 공식 상태줄 한도 필드를 확인하지 못해 `ClaudeSubscriptionProvider`가 `unsupported`를 반환하도록 구현했다. 이후 [공식 상태줄 계약](https://code.claude.com/docs/en/statusline)을 확인했으나 실제 계정 수신과 앱 연동은 여전히 미검증이다. 조직 API 토큰 보고는 별도 데이터 유형이다. | 실제 수신 미실시; 현재 앱 구독 한도 연동 불가 |
| AGY CLI | [공식 상태줄 JSON](https://antigravity.google/docs/cli/statusline)의 `quota.*.remaining_fraction`·`reset_time`만 브리지가 `~/Library/Application Support/Tokenly/agy-quota.json`으로 추출한다. 이메일·세션 ID·경로는 버린다. 수신 파일이 없거나 15분 넘으면 설정 필요/오래된 데이터로 표시한다. 앱은 AGY 설정을 수정하거나 `/usage` TUI를 파싱하지 않는다. IDE 사용량·Gemini API와 합치지 않는다. [대화형 `/usage`](https://antigravity.google/docs/cli/commands/usage). | 이후 사용자 보고로 실제 한도와 아코디언·세 메뉴 막대 스타일의 팝오버 열기 확인; AGY stale 실기 검증은 별도 |
| OpenAI API | [Organization Usage Completions GET](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/completions)과 [Costs GET](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/costs)을 UTC 오늘·이번 달로 페이지 조회한다. Completions 입력/출력 토큰과 조직 전체 USD 비용을 **다른 범위**로 표시한다. 모델 생성 요청은 없다. `sk-admin-` [조직 관리자 키](https://platform.openai.com/docs/api-reference/admin-api-keys)만 Keychain에 보관·전송하고 일반 키는 차단한다. 401·403·408·타임아웃·응답 오류를 구분하며 서버 본문·키는 기록하지 않는다. | 미실시; 관리자 키·조직 권한 필요 |
| Gemini | 기존 API 대시보드·CLI 자료 조사 상태를 유지한다. AGY와 별도 Provider이며 이번 구현 대상이 아니다. | 미실시 |

**AGY 연결 순서:** 사용자가 새 앱을 안정된 위치에 설치한 후 설정 창의 `상태줄 명령 복사`로 앱 번들 안의 `AGYStatusLineBridge.py` 실행 명령을 받는다. 사용자가 AGY CLI의 `/statusline`에서 직접 지정해야 한다. 이는 기존 상태줄 명령을 대체할 수 있어 앱은 자동 변경하지 않는다. CLI가 실행되어 상태가 바뀔 때만 새 JSON이 푸시되며, Tokenly의 새로고침은 로컬 수신 파일을 다시 읽을 뿐 백엔드 쿼터를 강제 갱신하지 않는다. 브리지는 `/usr/bin/python3`을 사용하고 파일·폴더 권한을 사용자 전용으로 제한한다. 앱은 개인정보가 포함된 원본 JSON을 보관하지 않는다. 브리지의 가짜 입력으로 `quota`만 남는 것을 확인했지만 실제 AGY 계정 필드는 아직 확인하지 못했다.

**설정과 갱신:** `ProviderDisplaySettings`는 Codex·AGY·OpenAI API의 팝오버 표시 Boolean만 `UserDefaults`에 저장한다. 기본값은 Codex 표시, 나머지 숨김이다. OpenAI 관리자 키는 별도 Keychain 항목이며 설정 저장소·문서·로그에 넣지 않는다. AGY·OpenAI API를 선택하면 `ExternalProviderStore`가 서비스별 5분 갱신과 수동 재조회로 상태를 관리한다. Codex를 숨겨도 기존 Codex 조회와 메뉴 막대 수치는 유지한다. 숨겨진 AGY·OpenAI API는 자동 호출하지 않는다. 팝오버 카드의 실제 렌더링과 설정 재시작 복원은 사용자 GUI 검증이 필요하다.

**검증과 남은 위험:** Debug 앱·테스트 타깃 컴파일, Release 앱 빌드, AGY 브리지의 가짜 입력 필터링이 성공했다. 기존 XCTest에 AGY 파싱·신선도, OpenAI API 집계·인증 누락·일반 키 차단·403·타임아웃, 설정 저장 테스트를 추가했다. 이번 작업 샌드박스에서 `xcodebuild test`는 `IDETestProgressNotification` 제한으로 종료되어 전체 XCTest 통과는 **미검증**이다. 실제 API 요청, Keychain 실제 저장·재실행, AGY 상태줄 연결, 라이트·다크 GUI, 새 설정 창 포커스도 미검증이다. Release 앱은 `/private/tmp/tokenly-provider-release/Build/Products/Release/Tokenly.app`에 있으며 `/Applications`와 기존 `dist`는 변경하지 않았다. 관리자 키의 저장·삭제와 실제 조회는 사용자가 설치 앱에서 진행해야 한다. 일반 배포 서명·공증은 별도 과제다.

## 14. 팝오버 회귀 수정과 AGY 설정 연결 상태 (2026-10-23)

**팝오버:** 사용자는 Xcode 재실행 후 메뉴 막대 수치는 정상이나 클릭 시 상세 창이 나타나지 않는다고 확인했다. `TokenlyApp`의 `MenuBarExtra(.window)` 라벨·스토어는 그대로이며, `SettingsWindowManager`는 톱니바퀴를 눌렀을 때만 동작한다. 최근 추가된 팝오버 최상위 `ScrollView`는 명시적 높이 없이 최대 높이만 560pt여서 메뉴 막대 창의 고유 크기 결정에 영향을 줄 가능성이 있다. 직접 원인 확정은 실제 GUI 전후 비교가 필요하다. 루트만 이전의 `VStack`·300pt 폭으로 되돌리고 `.regularMaterial`, 카드, 설정 버튼, Codex 조회는 유지했다. 설치 앱과 Xcode 앱의 중복 실행 여부, 화면 밖·뒤쪽 창 표시 여부는 프로세스/GUI 접근 제한으로 확인하지 못했다. 새 빌드에서 클릭 → 상세 정보 → 설정 창 포커스 → 닫기 → 재실행을 확인해야 한다. 복수 AGY 버킷으로 높이가 커지는 경우에는 실제 창 크기를 확인한 다음 내부 카드 영역만 제한된 스크롤로 설계한다.

**AGY:** 사용자 승인 뒤 설정 변경 직전에 `~/.gemini/antigravity-cli/settings.json`이 유효한 JSON·0600·`statusLine` 없음임을 재확인했다. 샌드박스가 같은 폴더의 0600 백업 생성부터 `Operation not permitted`로 거부하여 원본은 변경되지 않았다. `enable_agy_statusline.py`는 일반 사용자 터미널 실행용으로, 현 상태를 다시 검사하고 0600 백업을 검증한 뒤 기존 최상위 JSON을 보존하면서 공식 `statusLine`의 `type=command`, Tokenly 브리지 명령, `stack_with_default=true`만 추가한다. 임시 가짜 설정에서 기존 값 보존·백업 권한·JSON 유효성을 확인했다. 실제 설정 차이와 복원 경로는 스크립트 출력으로 확인하며, 복원은 출력된 백업을 `cp -p`로 원본에 복사한다. [공식 상태줄 계약](https://antigravity.google/docs/cli/statusline)은 CLI 상태 변화 시 JSON을 stdin으로 보내며 `quota.*.remaining_fraction`·`reset_time`을 제공할 수 있다고 설명한다. 그러나 실제 계정에서 이 필드가 왔는지, CLI가 이벤트를 보냈는지는 아직 확인되지 않았다. 설치된 `/Applications` 앱에는 새 브리지가 없으므로 기존 앱을 덮어쓰지 않는 범위에서 개발 빌드 또는 별도 위치의 Release 앱으로 GUI를 검증한다.

**보류 범위와 검증:** Claude 구독 연결 불가 및 Gemini 조사 상태는 유지한다. OpenAI API 구현·Keychain 코드는 삭제하지 않았지만 이번 단계에서는 설정 입력·API 요청·팝오버 표시를 중단했다. Codex 메뉴 막대 표시는 변경하지 않았다. Debug·Release 빌드는 성공했으며 XCTest 실행은 샌드박스의 Xcode 분산 알림 제한으로 종료돼 통과로 표시하지 않는다. Release 앱은 `/private/tmp/tokenly-popover-release/Build/Products/Release/Tokenly.app`에 생성했으며 기존 설치본과 `dist`는 변경하지 않았다.

## 15. Provider 아코디언과 팝오버 레이아웃 (2026-10-23)

11~14절의 미검증·백업 실패 문구는 각 작업 당시의 기록이다. 이후 사용자가 AGY 실제 한도 표시 성공을 보고했고 로컬 수신 파일에서 두 버킷 키를 확인했다. 아래 상태를 현재 기준으로 사용한다.

**상태:** `ProviderDisplaySettings`에 Codex/AGY 펼침 Boolean을 독립적으로 두고 각각 `UserDefaults`에 기록한다. 기본값은 Codex 펼침·AGY 접힘이다. 기존 Provider 표시 설정과는 별개다. 접어도 `UsageStore`·`ExternalProviderStore`의 5분 타이머와 새로고침은 그대로 동작한다. 설정에서 숨긴 Provider만 팝오버에서 제외한다.

**요약 계약:** Codex는 기존 `UsageSnapshot.menuBarSummary`와 오류·이전 데이터·소진 상태를 사용한다. AGY는 하나의 버킷을 전체의 대표로 선택하지 않는다. `AGYQuotaSummary`는 한 버킷이면 ID와 해당 비율, 복수면 `N개 버킷 · 최저–최고%`를 반환한다. 따라서 `3p-weekly` 100%와 `gemini-weekly` 0%는 전체 AGY가 0%라는 단정 없이 `2개 버킷 · 0–100%` 및 `일부 버킷 소진`으로 표시한다. `AGYQuotaLabel`이 원본 ID와 UI 이름 매핑을 분리하지만 공식 의미가 확인된 이름이 없어 지금은 원문을 그대로 반환한다. [공식 상태줄 문서](https://antigravity.google/docs/cli/statusline)는 `quota` 키를 모델/버킷 ID로 설명하지만 `3p-weekly`의 사용자용 뜻은 확정하지 않는다.

**뷰와 높이:** 루트는 폭 340pt의 `VStack`과 `.regularMaterial`이다. 상단에 전역 새로고침·설정, 가운데 독립 아코디언, 하단에 갱신 주기·종료를 배치했다. 접힌 행은 이름·요약·chevron과 필요한 상태만 보이고 상세 문구를 숨긴다. 펼친 Codex 행은 남은 비율 막대와 제공된 사용 비율·초기화, AGY 행은 버킷별 막대·초기화·마지막 수신을 표시한다. 이전에 팝오버 전체를 최대 높이만 가진 `ScrollView`로 감쌌을 때 메뉴 막대 클릭 후 창이 보이지 않는 회귀 보고가 있어 루트 스크롤은 사용하지 않는다. AGY 버킷이 3개 이상이면 **그 목록만** 명시적 높이의 `ScrollView`로 감싸고 화면의 가시 높이를 기준으로 상한을 둔다. 실제 다중 버킷·긴 현지화 문구·작은 화면에서 잘림이 없는지는 GUI 확인 전까지 미검증이다.

**검증:** 아코디언 기본값·저장 복원, 숨김과 독립성, 복수 버킷 범위/0%·100%, 접힌 AGY의 조회 지속 테스트 코드를 추가했다. Debug 앱과 테스트 타깃 컴파일, Release 앱 빌드가 성공했다. `test-without-building`은 샌드박스가 `IDETestProgressNotification` 게시를 막아 종료됐으므로 XCTest 통과로 기록하지 않는다. 새 Release 앱은 `/private/tmp/tokenly-accordion-release/Build/Products/Release/Tokenly.app`이며 `/Applications`와 기존 `dist`는 수정하지 않았다. 이후 사용자가 메뉴 막대 클릭 후 팝오버 열림, AGY 접기/펼치기와 접힌 높이 축소, Codex 표시를 GUI에서 확인했다. 두 Provider 동시 펼침의 화면 내 표시, 설정 창 왕복, 재실행 상태 복원, 라이트·다크 모드 대비는 추가 확인이 필요하다.

## 16. AGY 상태줄 만료 조사와 최소 수정 (2026-10-23)

사용자는 이번 아코디언 GUI에서 팝오버 열림·AGY 토글·높이 축소·Codex 표시를 확인했다. AGY의 이전 실제 쿼터 표시와 현재 `조회 불가` 상태 사이를 읽기 전용으로 조사했다. `~/.gemini/antigravity-cli/settings.json`은 유효한 JSON·0600이고 `statusLine`은 활성화되어 있으며 Tokenly 브리지 명령 파일도 존재한다. 브리지는 공식 JSON에서 유효한 `quota`만 `~/Library/Application Support/Tokenly/agy-quota.json`에 0600으로 저장한다. 확인 시 파일에는 `3p-weekly`·`gemini-weekly` 두 유효 버킷과 초기화 시각이 있었고, 한 버킷은 0%, 다른 버킷은 양수였다. 마지막 수신은 2026-10-23 01:41 KST였으며 점검 시 약 7시간 20분이 지났다.

`AGYQuotaParser`는 `captured_at`이 현재 시각보다 최대 60초 미래이거나 15분보다 오래되면 `.staleData`를 반환한다. 첫 표시는 파일이 유효하고 15분 이내였을 때 가능했다. 이후 새 이벤트가 없어서 만료된 것으로 판단한다. 다만 CLI가 실제 종료됐는지, 실행 중이나 상태 변화가 없었는지, 새 이벤트의 `quota`가 비어 브리지가 저장을 건너뛰었는지는 현재 증거로 구분할 수 없다. 브리지는 원본 JSON과 인증정보를 저장하지 않고 쿼터가 없으면 기존 파일을 유지한다. 무료 계정의 한 버킷 0%는 유효한 한도 소진값이며 연결 실패의 증거가 아니다.

`ExternalProviderStore`의 300초 타이머는 AGY 표시가 켜져 있을 때 `AGYStatusLineProvider.fetch()`를 호출해 **같은 로컬 파일을 다시 읽는다**. 공식 상태줄은 CLI 상태 변화 시 JSON을 푸시한다. 공식 [`/usage`](https://antigravity.google/docs/cli/commands/usage)는 백엔드를 갱신하지만 대화형 TUI이고, [상태줄 계약](https://antigravity.google/docs/cli/statusline)은 Tokenly가 호출할 비대화형 쿼터 조회 API를 제공하지 않는다. 조사한 공식 자료·설치 CLI 도움말에서 무료·무과금 읽기 전용 최신 조회 인터페이스는 확인되지 않았다. 모델 요청용 headless `agy -p`를 쿼터 조회로 사용하지 않는다.

이번 코드는 만료값 표시 정책을 유지하고, 이전 성공값이 메모리에 없는 재실행 직후 stale 상태의 접힌 요약을 `조회 불가` 대신 `최신 데이터 없음`으로, 상태를 `상태줄 갱신 대기`로 바꿨다. 상세 오류는 15분 기준과 CLI 종료 또는 이벤트 부재 가능성을 설명한다. 같은 앱 실행 중 정상 값이 만료되면 기존 동작대로 `이전 데이터`와 마지막 성공 시각을 붙여 보여 준다. 재실행 뒤에도 오래된 파일의 비율을 복원해 표시하면 참고에는 유용하지만 현재 잔여량으로 오해할 수 있고, 오래된 값이 여러 날 남을 수 있다. 이 정책 변경은 별도 결정 전까지 보류한다. 수신 시각만 오류 상태에 표시하는 방안도 후속 GUI 확인과 함께 검토한다.

검증은 유효한 0%/100%와 15분 전후 만료를 분리하는 XCTest를 추가했다. Debug·Release 앱과 테스트 타깃 빌드는 성공했다. `test-without-building`은 샌드박스의 Xcode 테스트 서비스 제한으로 종료되어 통과로 기록하지 않는다. 새 stale 안내 문구와 AGY CLI 재실행 후 갱신은 실제 GUI 미검증이다. 새 Release 앱은 `/private/tmp/tokenly-agy-stale-release/Build/Products/Release/Tokenly.app`에 있으며 설치본과 기존 `dist`는 변경하지 않았다. AGY 사용자 설정·인증·브리지·기존 쿼터 파일도 변경하지 않았다.

## 17. 통합 UI 간결화와 표시 설정 (2026-10-23)

**메뉴 막대:** 이전 캡슐 `HStack`은 실제 GUI에서 일부가 사라졌고 단일 `Text`의 부분 글꼴은 눈에 띄지 않았다. 따라서 숫자형(기본)·최소형은 각각 단일 `Text` 라벨을 쓴다. 아이콘형에만 단순한 SF Symbol `bolt.fill`과 한 `Text`를 배치한다. `MenuBarPresentation`은 `UsageSnapshot`의 실제 잔여 비율, 누락 창, 조회 중, 실패, 이전 데이터 문자열을 스타일별로 만든다. 숫자형은 `5h … · 7d …`, 최소형은 두 비율만, 아이콘형은 5시간 비율 하나(없을 때 `7d` 명시)다. 복잡한 그룹·색상·커스텀 AppKit 뷰는 넣지 않았다. `ProviderDisplaySettings.menuBarStyle`을 기존 주입 가능한 `UserDefaults`에 저장하고 `@Published`로 설정 창과 `MenuBarExtra`를 갱신한다. 실제 렌더링·클릭·잘림은 GUI 확인이 필요하다. 캐릭터형, Provider/지표 선택, `NSStatusItem` 검증은 후속이다.

**팝오버:** 루트 `VStack`·`.regularMaterial`을 유지해 과거 무제한 루트 `ScrollView` 회귀를 피한다. 보통 화면은 AGY 쿼터 목록에만 제한 스크롤을 적용하고, 가용 높이가 650pt 미만이며 두 Provider가 모두 펼쳐진 경우에는 Provider 영역에 명시적 높이의 스크롤을 둔다. 상단 새로고침 하나가 `UsageStore.refresh()`와 `ExternalProviderStore.refreshSelected()`를 호출한다. Codex는 공식 app-server에 새로 요청하고 AGY는 최신 이벤트를 만들지 않고 기존 로컬 상태줄 파일을 다시 읽는다. 이를 버튼 툴팁과 하단 문구에 표시한다. Provider별 반복 설명·새로고침 버튼은 없앴다. 접힌 요약·오류·stale 표시는 유지하고 상세에만 막대, 사용률, 초기화, 마지막 수신을 둔다. AGY 여러 버킷을 합치거나 대표 버킷으로 오인시키지 않는 기존 `AGYQuotaSummary`를 유지한다.

**날짜:** `CompactDateTime`은 현재 Calendar와 TimeZone으로 날짜 경계를 판단한다. 오늘·내일은 로케일의 `RelativeDateTimeFormatter`, 그 외 같은 해는 월/일, 다른 해는 연도/월/일 템플릿을 사용하고 현지 짧은 시각을 붙인다. 주입된 `now`로 경계를 판단해 연말 테스트가 가능하다. 전체 날짜·시간은 보조 텍스트의 툴팁으로 제공한다. 자정이 지난 뒤 열린 팝오버가 즉시 재표시되는지까지는 GUI 확인이 필요하다.

**설정과 외관:** 네 탭을 유지하며 440×300pt 창 안에서 AI 서비스 목록만 스크롤한다. 일반은 `SMAppService` 상태와 개발 빌드/Applications 설치본 차이를 설명한다. AI 서비스에는 Codex의 조회 상태·마지막 성공과 AGY의 마지막 수신 시각을 간결하게 표시한다. 메뉴 막대 탭은 세 스타일 라디오 선택과 현재 `UsageStore` 값의 미리보기를 둔다. `ProviderDisplaySettings.appearance`는 `system`(기본)·`light`·`dark`를 `UserDefaults`에 저장하고 `preferredColorScheme`으로 팝오버·설정 창에 적용한다. 메뉴 막대 자체는 macOS 외관을 따른다. 로그인 항목 로직과 Codex/AGY Provider, 인증, 수신 경로는 바꾸지 않았다.

**당시 검증:** 세 스타일의 0%·100%·누락·이전 상태, 스타일/외관 저장 복원, 연도 경계 날짜 테스트를 추가했다. Debug 앱·테스트 타깃과 Release 앱 컴파일은 성공했다. `test-without-building`은 이 샌드박스에서 `testmanagerd` 연결 제한으로 종료됐으므로 XCTest 통과로 기록하지 않는다. 이후 사용자 GUI 결과는 18절에 반영했다. 당시 새 앱은 `/private/tmp/tokenly-ui-release/Build/Products/Release/Tokenly.app`에 생성했고 설치 앱과 기존 `dist`는 유지했다.

## 18. v1 안정화 및 테스트 실행 환경 (2026-10-23)

**검증 증거:** 사용자는 숫자형·최소형·아이콘형 메뉴 막대 표시와 세 스타일의 팝오버 열기, 팝오버 간결화·통합 새로고침 버튼, 설정 창 네 탭, 스타일·테마의 즉시 반영, 앱 재실행 후 설정 복원을 실제 GUI에서 확인했다. 이 결과로 UI 관련 17절의 미검증 표시를 갱신한다. 작은 화면·긴 오류 문구의 잘림, 두 Provider 동시 펼침, 각 테마의 보조 텍스트 대비, Codex 인증 만료·AGY 새 이벤트, 로그인 항목 등록·해제와 재로그인은 별도 검증 대상이다.

**테스트 경계:** `xcodebuild -list -json`에서 `Tokenly` Scheme과 `Tokenly`·`TokenlyTests` 타깃을 확인했다. 테스트 타깃은 `Tokenly.app`을 `TEST_HOST`/`BUNDLE_LOADER`로 사용한다. 별도 `/private/tmp` DerivedData에서 `build-for-testing`은 성공했고 테스트 번들까지 생성됐다. `xcodebuild test`는 빌드 완료 뒤, `test-without-building`은 시작 직후 각각 exit 133으로 끝났다. 로그에는 분산 알림 `IDETestProgressNotification` 게시가 샌드박스에 차단되고 `com.apple.testmanagerd.control` 연결이 `Sandbox restriction`으로 거부됐다고 명시된다. `Test Case` 실행 행이 없고 정상 결과 번들도 만들어지지 않았다. 실행 로그는 `/private/tmp/tokenly-v1-xctest.log`와 `/private/tmp/tokenly-v1-final-xctest.log`에 있다. 따라서 **테스트 타깃 컴파일 성공**, **XCTest 실행 실패**, **테스트 통과 미확인**을 구분한다. 이 로그만으로 테스트 코드의 성공·실패를 판정할 수 없다. 시스템 보안 설정 변경이나 우회는 하지 않는다.

**코드 점검:** Codex CLI 부재는 명시적 오류, app-server 요청·연결·타임아웃은 메시지와 재시도 버튼으로 처리하고 이전 성공값은 실패 표시와 함께 보존한다. AGY는 파일 없음, 유효한 0%, 15분 만료를 구분하며 수동·5분 갱신은 로컬 파일 재읽기다. `UsageStore`는 Codex 조회를 utility 작업으로 실행해 UI 대기를 줄인다. 설정 창 매니저는 보이는 기존 창을 앞으로 가져오고, UserDefaults의 알 수 없는 스타일·외관 값은 안전한 기본값으로 돌아간다. 기존 테스트에 손상 설정값과 AGY 만료 후 새 수신 복구 케이스를 추가했다. 실제 인증 만료, 타이머 중 사용자 조작, 반복 팝오버, 다중 앱 실행, 로그인 항목 시스템 동작은 실행 환경에서 확인해야 한다. 이번 점검에서 앱 코드의 재현 가능한 결함은 확인되지 않아 기능 코드는 수정하지 않았다.

| 안정성 항목 | 확인된 근거 | 남은 검증 |
| --- | --- | --- |
| Codex 미로그인·만료·재시도 | app-server 오류를 민감 정보 없이 안내하고 이전 값은 `이전`으로 표시; 실패 후 재시도 테스트 코드 존재 | 실제 계정의 인증 만료와 재로그인 뒤 회복 |
| AGY 없음·0%·만료·새 수신 | 파서가 상태를 구분하고 새 수신 복구 테스트 코드 추가 | 실제 CLI 이벤트와 파일 갱신, 15분 경과 GUI |
| 5분 자동 갱신·반응성 | Codex는 utility 작업, AGY는 작은 로컬 파일 읽기; 중복 Codex 요청 방지 | 타이머 실행 중 클릭·설정 조작 |
| 팝오버·설정 창 | 사용자가 세 스타일 팝오버와 네 탭 확인; 창 매니저의 기존 창 재사용 테스트 코드 존재 | 반복 열기·닫기, 중복 생성·재열기 |
| 로그인 항목 | `SMAppService` 상태 조회·등록/해제 분리, 가짜 컨트롤러 테스트 코드 존재 | 설치 앱의 토글과 재로그인 |
| 개발본·설치본 중복 | 두 앱 번들이 존재하고 같은 Bundle ID를 사용함 | 현재 프로세스 열람은 샌드박스가 차단; 동시 실행 GUI 확인 |
| 설정 손상·누락 | 알 수 없는 스타일·외관은 숫자형·시스템 외관 기본값; 테스트 코드 추가 | 실제 설정 파일 손상 상황은 재현하지 않음 |
| 외관·작은 화면 | 사용자가 테마 즉시 반영과 복원을 확인 | 각 외관의 대비 및 작은 화면 잘림 |

**일반 사용자 Xcode 절차:** [프로젝트](../src/Tokenly.xcodeproj)를 Xcode에서 열고 Scheme `Tokenly`, 목적지 `My Mac`을 선택한 뒤 `Product > Test`(⌘U)를 실행한다. Test navigator의 `TokenlyTests` 전체 결과와 실패한 케이스 이름·메시지를 확인한다. 앱 메뉴 막대가 중복되면 기존 설치 앱과 개발 앱 중 어느 쪽이 실행 중인지 먼저 확인하고, 테스트를 위해 시스템 로그인 항목을 임의 변경하지 않는다.

**빌드:** 최종 Debug 앱·테스트 타깃 빌드와 Release 앱 빌드가 성공했다. 새 Release 번들은 `/private/tmp/tokenly-v1-release/Build/Products/Release/Tokenly.app`이다. `/Applications/Tokenly.app`과 기존 `dist`는 변경하지 않았다. 배포용 서명·공증, Xcode에서 실제 전체 XCTest 통과, 로그인 항목 등록·해제 및 재로그인, 작은 화면·대비·중복 실행 확인은 배포 전 남은 항목이다.

## 19. Claude 구독 상태줄 사전 조사 (2026-10-23)

**검증 상태 갱신:** 위 18절의 XCTest 실행 실패는 작업 샌드박스에서 발생한 과거 결과다. 이후 사용자가 **일반 사용자 Xcode에서 당시 XCTest 33개 실제 실행·전부 통과, 코드 커버리지 54%**를 확인했다. 이는 Claude 구현 전 결과다. 새 Claude 테스트의 컴파일과 실제 통과 여부는 20절에서 구분한다.

**읽기 전용 로컬 확인:** `/opt/homebrew/bin/claude` 버전 `2.1.292`가 설치되어 있고 공식 `claude auth status --json` 명령이 있다. 이 작업 샌드박스에서 민감 필드를 버리고 `loggedIn`·`authMethod`만 확인한 결과는 종료 코드 1, `loggedIn=false`, `authMethod=none`이었다. 일반 macOS 사용자 터미널의 구독 로그인 상태까지 뜻하지 않는다. `CLAUDE_CONFIG_DIR`가 설정되지 않은 이 환경에서 `~/.claude/settings.json`과 확인한 프로젝트 범위 `.claude/settings.json`·`.local`은 없으므로 확인 가능한 기존 `statusLine` 명령도 없다. 인증 파일은 열지 않았다. 일반 사용자 환경·상위 프로젝트·관리형 설정의 유효값은 별도 확인이 필요하다. [Claude Code 인증 방식](https://code.claude.com/docs/en/authentication), [설정 범위와 우선순위](https://code.claude.com/docs/en/settings).

**공식 계약과 실수신의 경계:** [Claude Code 상태줄 공식 문서](https://code.claude.com/docs/en/statusline)는 설정의 `statusLine` 명령에 세션 JSON을 stdin으로 전달하며 `rate_limits.five_hour.used_percentage`·`seven_day.used_percentage`(0–100), 각각의 `resets_at`(Unix 초)을 설명한다. Pro/Max 구독 또는 별도 gateway 조건에서 첫 API 응답 후에만 `rate_limits`가 올 수 있고, 창은 독립적으로 누락되거나 초기화 시각 이후 사라질 수 있다. 설치 버전이 문서의 계약과 실제로 일치하는지는 **사용자 계정의 상태줄 이벤트를 수신하기 전까지 미검증**이다. 이번 조사에서는 상태줄 설정·세션·모델 요청을 생성하지 않았고 실제 구독 수치를 받지 않았다. `/usage` 대화형 출력 파싱, 비공식 OAuth 호출, 인증 파일·키체인 열람은 사용하지 않는다. Anthropic [조직 Usage/Cost Admin API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)는 API 토큰·비용으로 구독 한도와 별개다.

**승인 후 연동안:** 일반 사용자 터미널에서 공식 인증 상태를 안전한 필드만 표시해 재확인하고, Claude Code 세션의 첫 응답 뒤 실제 상태줄 JSON에 필요한 필드가 있는지 개인정보를 버리는 수신기로 검증한다. 기존 `statusLine`이 있으면 원본 명령을 덮어쓰지 않고 한 번 받은 stdin을 메모리에서 기존 명령과 Tokenly 브리지에 전달하는 보존안을 검토한다. 실제 명령의 안전성·호환성을 검토한 후 정확한 변경안을 다시 제시한다. 브리지는 5시간/7일의 검증된 사용률·초기화 Unix 초·수신 시각만 권한 0600의 별도 로컬 파일에 저장하고 세션 ID, 경로, 이메일, 인증정보와 전체 JSON은 저장하지 않는다. `ClaudeSubscriptionProvider`는 현재 `unsupported`이므로 추후 별도 Provider로 수신 파일을 읽도록 하고, 기존 `ExternalUsageSnapshot`의 쿼터/시각/오류 표현과 팝오버의 잔여 막대·간결한 날짜 행을 재사용한다. `UsageSnapshot`의 Codex 전용 300/10080분 모델이나 AGY 버킷 이름을 Claude에 강제하지 않는다. 현재 Codex·AGY 조회·인증과 메뉴 막대 수치는 변경하지 않는다.

**신선도 정책 초안:** 각 창의 `used_percentage`가 0–100인 경우에만 `100 − 사용률`을 잔여율로 계산한다. 제공되지 않은 창은 `0%` 대신 미제공으로 표시한다. 마지막 **수신 시각**을 별도로 보이고, 이벤트가 끊기면 실제 수신 간격을 관찰해 정한 만료 기준 이후 `오래된 데이터`로 표시한다. 초기화 시각을 지난 창은 과거 비율을 최신 값으로 유지하지 않는다. CLI 종료 시 로컬 재읽기는 서버 갱신이 아니며 5분 앱 타이머 역시 새 상태줄 이벤트를 만들지 않는다. AGY의 15분 기준을 검증 없이 Claude에 복사하지 않는다.

**변경 전 보호 절차:** 실제 사용자 설정 파일과 우선순위를 변경 직전에 다시 검사한다. 기존 `~/.claude/settings.json`이 있다면 같은 내용을 권한 0600의 별도 백업으로 보관하고 변경 전후 JSON 키 차이를 확인한다. 파일이 없으면 새 파일 생성 전 그 사실을 기록하고, 복원 시 새로 추가한 `statusLine`만 제거하거나 당시 새 파일만 제거한다. 기존 명령이 있다면 래퍼의 기존 출력·종료 동작을 확인해야 하며 덮어쓰지 않는다. 설정 변경은 사용자 승인 후에만 수행한다. 예상 변경 대상은 Claude 사용자 설정의 `statusLine`, 새 Tokenly Claude 브리지/Provider·표시/테스트 파일이다. 이번 단계에서는 이 파일들을 만들거나 수정하지 않았다.

## 20. Claude 구독 앱 측 구현과 승인 대기 (2026-10-23)

**설정 재확인:** 이번 점검에서는 `~/.claude/settings.json`이 유효한 JSON으로 존재하며 `statusLine` 키가 없고 파일 권한이 0644였다. 확인한 Tokenly·상위 프로젝트 `.claude/settings.json`·`.local`에는 해당 설정이 없었다. 앞선 조사에서 파일 부재로 보인 것과 차이가 있으므로 변경 직전에 다시 검사해야 한다. 샌드박스의 공식 `claude auth status --json`은 종료 1, `loggedIn=false`, `authMethod=none`을 반환했다. 이 결과로 일반 사용자 터미널의 로그인 여부를 확정하지 않는다. 설정 내용·인증정보는 문서나 로그에 옮기지 않았다.

**구현:** `ClaudeStatusLineBridge.py`는 공식 상태줄 stdin에서 `rate_limits.five_hour`·`seven_day`의 유효한 `used_percentage`와 `resets_at`만 추출한다. 원본의 세션·계정·경로는 버리고 로컬 수신 시각과 선택 필드만 `claude-quota.json`에 원자적으로 0600 저장한다. 두 창이 모두 빠진 이벤트도 빈 한도 수신으로 기록해 오래된 수치를 최신처럼 재표시하지 않는다. `ClaudeSubscriptionProvider`는 이 파일만 읽으며 0–100 사용률을 잔여율로 바꾸고, 지난 초기화 창은 제외한다. 수신 후 15분 경과는 별도 stale 상태로 표시한다. 이 임시 기준은 실제 상태줄 이벤트 간격 확인 후 조정한다. Codex는 app-server 능동 조회, AGY와 Claude는 CLI가 푸시한 상태줄 파일을 Tokenly가 재읽는 방식이다. Claude의 상태줄을 설치하거나 서비스에 직접 요청하는 코드는 없다.

**UI·설정:** Claude는 자체 표시·아코디언 설정을 `UserDefaults`에 저장하며 기본값은 숨김·접힘이다. 설정 창에서 Claude를 표시 대상으로 선택하고 로컬 수신을 확인할 수 있다. 팝오버의 상단 새로고침과 5분 타이머는 표시 중인 Claude 파일을 다시 읽는다. 메뉴 막대 숫자형·최소형·아이콘형은 Codex 전용 그대로이며 AGY 조회 경로와 OpenAI API 보류 상태도 유지했다. 데이터 없음·설정 필요·오래된 데이터·이전 성공값을 구분하며 수치를 만들어내지 않는다.

**검증 경계:** 가짜 상태줄 입력을 임시 HOME으로 보내 비밀 필드가 결과에서 빠지고 0600 파일이 생성되는 것을 확인했다. Debug `build-for-testing`과 Release `build`가 성공해 앱·테스트 타깃은 컴파일됐다. 새 XCTest는 `test-without-building`이 `testmanagerd` 샌드박스 제한으로 케이스 실행 전에 exit 133으로 끝났으므로 **통과 미확인**이다. 사용자 Xcode의 기존 33개 통과·커버리지 54%는 이번 변경 전 결과다. 실제 Claude 구독 `rate_limits` 수신, 설치된 CLI의 런타임 계약, 사용자 GUI는 확인하지 못했다. 새 Release 앱은 `/private/tmp/tokenly-claude-release/Build/Products/Release/Tokenly.app`이며 설치본과 기존 dist는 그대로다.

**설정 변경 승인 단계:** 현재 사용자 설정에는 기존 `statusLine`이 없으므로, 승인 후 재확인 결과도 같다면 `~/.claude/settings.json`의 기존 모든 키를 보존하고 `statusLine: {"type":"command","command":"/usr/bin/python3 '<프로젝트 경로>/src/Tokenly/ClaudeStatusLineBridge.py'"}` 하나만 추가한다. 이는 개발 프로젝트 경로를 참조하므로 프로젝트를 이동하면 명령 경로를 갱신해야 한다. 변경 전 원본과 권한을 확인해 권한 0600의 별도 백업을 만들고, 새 JSON 유효성·설정 차이·CLI 이벤트 수신을 확인한다. 복원은 백업 파일을 원위치에 복사하고 당시 권한 0644를 복구하는 방식이다. **현재 파일 권한 0644와 명령의 경로 의존성을 승인 전에 함께 검토해야 한다.** 기존 `statusLine`이 새로 발견되면 이 변경안을 적용하지 않고 보존·체인 방안을 다시 제시한다. 실제 사용자 설정은 이번 단계에서 변경하지 않았다.

## 21. 승인 후 설정 연결 시도와 환경 제한 (2026-10-23)

사용자가 위 설정 변경을 승인했다. 변경 직전 읽기 전용 재확인에서 `~/.claude/settings.json`은 유효한 JSON·`statusLine` 없음·권한 0644였다. 그러나 같은 경로에 권한 0600 백업을 생성하는 첫 쓰기부터 샌드박스가 `Operation not permitted`를 반환했다. **실제 백업은 생성되지 않았고 원본 설정도 바뀌지 않았다.** 여기서 홈 디렉터리 변경을 중단했다.

`scripts/enable_claude_statusline.py`를 일반 사용자 터미널용으로 준비했다. 실행 시 기존 `statusLine`이 있으면 중단하고, 기존 JSON 전체를 별도 0600 백업에 저장·대조한 다음 기존 키를 보존해 공식 `statusLine` 명령 하나만 추가한다. 원본 설정은 원자적으로 교체하고 권한을 0600으로 강화하며, 성공 시 실제 백업 경로·복원 명령을 출력한다. 임시 HOME의 가짜 설정으로 키 보존, 0600 백업/설정, 중복 실행 중단을 확인했다. `scripts/check_claude_statusline.py`는 공식 인증 상태의 안전한 필드와 로컬 수신 파일의 존재·권한·시각·한도 필드 유무만 출력한다. 현재 샌드박스에서는 로그인 `false`, 파일 없음이었다. 일반 사용자 환경의 로그인과 공식 CLI의 실제 상태줄 이벤트는 아직 확인되지 않았다.

작업을 이어가려면 사용자가 일반 macOS 터미널에서 `python3 scripts/enable_claude_statusline.py`를 실행하고, 기존 Claude Code 세션에서 첫 응답 이후 상태줄 이벤트가 발생할 때 `python3 scripts/check_claude_statusline.py`를 실행해야 한다. 앱의 5분 타이머는 파일 재읽기일 뿐 새 Claude 이벤트를 만들지 않는다. 개인정보가 있는 전체 상태줄 JSON이나 인증 출력은 공유하지 않는다. 실수신이 성공하면 파일 필드·시각과 사용자 GUI를 확인하고 15분 임시 만료 기준을 재검토한다. 현재 실제 계정 수신·GUI·새 XCTest는 미검증이며 설치 앱·dist는 그대로다.

## 22. 팝오버 Provider 표시 순서 변경 (2026-10-23)

`UsageMenuView.providerSections`의 섹션 배치를 Codex → Claude → Google Antigravity로 바꾸고 구분선 조건도 그에 맞췄다. `ProviderDisplaySettings.visibleSupportedProviders`도 같은 순서로 반환한다. 저장 키·아코디언 바인딩·조회 로직·메뉴 막대 라벨은 변경하지 않았다. 세 Provider를 모두 켠 상태의 순서를 확인하는 XCTest `testPopoverProviderOrderIsCodexClaudeAGY`를 추가했다. Debug·Release 빌드는 성공했다. 작업 환경에서 Debug XCTest 38개가 실제로 실행되어 전부 통과했다(이전 33개와 Claude 테스트 포함). 빌드 산출물은 작업용 임시 DerivedData에만 만들었고 `dist`와 설치 앱은 덮어쓰지 않았다. 새 순서의 GUI 확인은 남아 있다.

## 23. 하트 게이지 UI 1차 시제품 (2026-10-23, GUI 피드백 반영)

**변경 경위:** 1차 시제품은 메뉴 막대에 숫자 없는 하트, 팝오버 상단에 큰 하트 대시보드를 두었다. 사용자가 실제 GUI를 확인한 뒤 요청한 내용은 다음과 같다. 하트 디자인은 유지하고, 대시보드를 제거하고, 메뉴 막대 하트 안에 잔여율·아래에 이름을 넣는다. `UsageMenuView`는 하트 작업 이전(순서 변경 직후)과 동일한 코드로 되돌렸고 `HeartDashboard`를 삭제했다.

**구조:** `Views/HeartGaugeView.swift`는 데이터 모델에 의존하지 않는 렌더링 계층이다.
- `HeartShape`·`HeartPalette`·`JellyHeart`는 1차 시제품 그대로다. 미확인 팔레트 이름만 `stale`로 바꿨다.
- `MenuBarHeart`: 하트 + 내부 숫자 + 하단 이름. 크기·글꼴·겹침 상수가 한곳에 있다.
- `MenuBarHeartRow`·`MenuBarHeartImage`: 하트 행과 메뉴 막대용 이미지 생성.

`Models/HeartGauge.swift`는 `fresh`/`stale` 판독과 숨김(`nil`) 판정, 표시 설정 필터, 팔레트 선택을 담는다.

**메뉴 막대 렌더링:**
- `MenuBarExtra` 라벨은 일반 `Text`·`Image`만 안정적으로 그린다. 그래서 `ImageRenderer`로 최소 2배율 비트맵을 만들고 `isTemplate = false`로 색을 유지한다.
- 이름 글자는 비템플릿 이미지라 메뉴 막대 외관에 맞춰 색이 바뀌지 않는다. 그래서 라이트·다크 양쪽에서 보이는 서비스 진한 색(`rim`)을 쓴다.
- `ImageRenderer` 경로에서는 `minimumScaleFactor`가 적용되지 않아 `100%`가 `10…`으로 잘렸다. 네 글자일 때만 글꼴 크기를 명시적으로 줄였다.
- 첫 배치는 높이가 22.34pt로 상태 항목 높이를 넘었다. 이름 겹침을 1.5pt에서 2pt로 늘려 21.84pt로 맞췄다.
- 사용자 GUI 확인 뒤 간격만 넓혔다. 하트 사이 간격은 4pt에서 8pt로 늘렸다. 이름은 하트 끝이 글자 윗부분을 약 0.4pt 덮던 배치에서, 테두리 아래로 약 0.85pt 떨어진 배치로 바꿨다(약 1.75pt 개선). 6pt 이름의 SwiftUI 줄 상자는 8pt이며 글자 위 1.6pt, 아래 1.9pt가 비어 있다(픽셀 측정). `Codex`·`Claude`·`AGY`에는 아래로 내려가는 글자가 없으므로 아래 1.6pt를 음수 패딩으로 잘랐다. 그만큼 겹침을 2pt에서 0.25pt로 줄여도 높이는 21.99pt로 22pt 안에 남는다. 하트·숫자·이름 크기는 바꾸지 않았다. 앞으로 아래로 내려가는 글자(g·p·y)가 있는 이름을 쓰면 `nameBottomTrim`을 줄여야 한다.
- 이미지 가장자리 점검에서 하트 윗부분 테두리의 절반(약 0.5pt)이 이미지 위쪽 끝에서 잘리는 것을 확인했다. 이는 2차 수정에서 세로 여백을 없앤 뒤부터 있던 상태이며, 이번 간격 조정과는 무관하다. 고치려면 22pt 안에서 이름 간격 0.5pt를 다시 써야 하므로 사용자 확인 전까지 바꾸지 않는다.
- 이미지 생성이 실패하면 `Codex 30% Claude 94%` 텍스트로 대체한다.
- 하트형 라벨에서는 `externalStore.start()`도 호출해 팝오버를 열기 전에도 Claude·AGY 값을 읽는다.

**높이 제약:** 이 장비의 `NSStatusBar.system.thickness`는 22pt다. 노치 화면이라 메뉴 막대 자체는 약 33pt다. 22pt 안에서 하트·숫자·이름을 모두 배치할 수 있음을 오프라인 렌더링으로 확인했다. 숫자는 6.5pt(`100%` 5.4pt), 이름은 6pt로 작다. 실제 화면에서 읽기 어렵다면 다음 대안을 검토한다.
1. 이름을 빼고 하트를 22pt 가까이 키우기
2. 이름 대신 서비스 색만으로 구분하고 이름은 접근성 설명·도움말로 두기
3. 노치 화면처럼 메뉴 막대가 높은 환경에서만 더 큰 배치를 쓰기

**수신 이력:** `ExternalProviderStore`에 `settledStates`와 `lastValidQuotas`를 추가했다. 기존 `states`·조회·stale 정책은 그대로다.
- `settledStates`는 `.loading`을 거치지 않으므로 5분 갱신 중에도 하트가 숨거나 깜박이지 않는다.
- `lastValidQuotas`는 성공 시의 쿼터로 갱신한다. 그 전 실패 시에는 Provider의 `storedQuotaRecord()`를 쓴다. 이 함수는 수신 파일을 나이·초기화와 무관하게 다시 읽어 유효 값만 반환한다. Codex·OpenAI는 기본 구현(`nil`)이다.
- 판정 규칙은 다음과 같다.
  - 성공 → 최신
  - `setupRequired` → 숨김
  - 그 외 실패 → 마지막 유효 값이 있으면 회색, 없으면 숨김
  - 조회 전 → 숨김

**검증:** Debug·Release 빌드에 성공했다. Debug XCTest는 **45개를 실제 실행해 전부 통과**했다(xcresult 기준). 하트 관련 7개는 다음을 다룬다: 대표값, Codex 상태, 외부 상태, 저장 기록 파싱, 오래된 AGY 파일 → 회색과 파일 없음 → 숨김의 저장소 통합, 스타일 저장·전환, 기존 저장값 유지. 하트 1·2·3개와 중립 아이콘은 오프라인 PNG(2배·6배, 라이트·다크 배경)로 확인했다. 작업용 빌드는 실행 인자로 하트형을 지정해 6초간 실행했고 종료되지 않았다. 이 인자는 설정에 저장되지 않으며 저장된 스타일 값이 그대로임을 확인했다. 화면 녹화·손쉬운 사용 권한이 없어 **실제 메뉴 막대 표시와 클릭은 확인하지 못했다.** `dist`·설치 앱은 바꾸지 않았다.

## 24. 메뉴 막대 하트 글자 가독성 시안 (2026-10-23, 비교 중·앱 미적용)

`Preview/HeartLegibility/render.swift`는 앱의 `HeartGaugeView.swift`를 읽기 전용으로 함께 컴파일해 A/B/C 시안을 렌더링한다. 실행은 `./run.sh`이며 Xcode 프로젝트에 포함하지 않는다. 각 행은 앱과 같은 방식의 비트맵으로 만들어 같은 경계에서 잘린다. 확대본은 실제 1배율·2배율 픽셀을 보간 없이 키운 것이다.

- **A 현재:** 숫자 6.5pt(`100%` 5.4pt) heavy, 흰 흐림 그림자. 숫자가 `JellyHeart` 라벨 슬롯 안에 있어 하트 전체 그림자가 글자에도 적용된다. 이름은 6pt bold, 서비스 진한 색(`rim`).
- **B 대비 강화:** 크기는 같고 한 단계 두꺼운 black이다. 숫자를 하트 위 overlay로 옮겨 하트 그림자가 글자를 흐리지 않게 했다. 흐림 그림자 대신 0.35pt 흰 외곽선을 쓴다. 이름은 heavy이고 라이트 막대에서는 더 진한 색, 다크 막대에서는 밝은 색이다.
- **C 숫자 우선:** B를 바탕으로 숫자 7.3pt(세 자리 6.1pt)에 `%`를 4.8pt(4.3pt)로 줄였다. 숫자 뒤에 옅은 흰 빛(투명도 0.42, 흐림 1.2pt)을 깔아 하이라이트·수면선 간섭을 줄였다.

**관찰:**
- 앱 코드 경로에서는 `100%`가 5.4pt에서도 하트 폭을 거의 다 쓴다. 그래서 전체 글자를 키우는 대신 `%`를 줄이는 방식(C)을 택했다.
- B·C의 heavy 이름은 행 너비를 79pt에서 80.5pt로 늘린다.
- 위쪽 테두리 약 0.5pt 잘림은 세 시안이 같다(하트를 바꾸지 않음). 2배율 픽셀 기준으로 한 줄 정도라 실제 크기에서는 거의 보이지 않는다. 22pt 안에서 없애려면 이름 간격 0.5pt를 쓰거나 테두리를 안쪽으로 그려야 한다. 따라서 적용하지 않고 대안만 정리했다.
- 이미지 크기가 정수가 아니라(높이 21.99pt, B·C 너비 80.5pt) 메뉴 막대에서 재표본화돼 흐려질 수 있다. 이 가설은 GUI 확인이 필요하다.

**검증:** 비교 이미지 렌더링만 했다. 앱 코드는 바뀌지 않았으므로 이번 단계에서 빌드·XCTest는 다시 실행하지 않았다. 실제 메뉴 막대 GUI 비교도 하지 않았다.

## 25. 하트 스타일 시안: 소프트 3D·글래스 젤리 (2026-10-23, 비교 중·앱 미적용)

`Preview/HeartStyles/render.swift`는 앱의 `HeartShape`·`JellyHeart`·`MenuBarHeart`와 간격 상수를 읽기 전용으로 재사용한다. 실행은 `./run.sh`이며 Xcode 프로젝트 밖에 있다.

- **B `SoftHeart`:** 두꺼운 테두리·큰 반짝임을 없앴다. 거의 흰 빈 영역 위에 채도 있는 채움, 왼쪽 위에서 빛을 받는 흐린 안쪽 그림자, 넓게 퍼진 윗빛, 0.5pt 안쪽 실선, 약한 그림자를 쓴다.
- **C `GlassHeart`:** 반투명 색 유리 몸체(옅은 서리 포함), 반투명 젤리 채움, 0.5pt 수면선, 유리 가장자리 안쪽 빛, 끝부분 집광, 왼쪽 위 가는 반사선, 0.6pt 안쪽 윤곽을 쓴다. 숫자 뒤에만 서리를 한 겹 더 깔아 중앙 대비를 확보한다.
- **공통:** 채움은 `fraction`으로 그리는 SwiftUI 뷰라 실제 잔여율에 따라 바뀐다(`gauge-steps.png`). 숫자·이름은 하트 그림자 밖 별도 레이어다. 윤곽은 경로를 안쪽으로 줄여 그리므로 위쪽 테두리가 잘리지 않는다(위 가장자리 투명도 A 0.90, B·C 0.02–0.06). 비트맵은 정수 크기 81×22pt(162×44px)로 맞췄다.
- **관찰:**
  - B는 라이트·다크 모두 채움 높이와 숫자가 가장 잘 읽힌다.
  - C는 라이트 막대에서 가장 세련됐다. 다크 막대에서는 반투명 몸체가 막대 색을 받아 빈 영역이 탁한 회색이 되고, 채움 경계와 숫자 대비가 약해진다.
  - 실제 메뉴 막대가 바탕화면 색을 비추면 C의 색이 배경에 따라 달라질 수 있다. GUI 확인이 필요하다.
- **검증:** 비교 이미지만 렌더링했다. 앱 코드는 바뀌지 않았으므로 빌드·XCTest는 다시 실행하지 않았다. 실제 메뉴 막대 GUI 비교도 하지 않았다.

## 26. 3D 렌더 에셋 시안: 하트 → 작은 귀 글래스 젤리 곰돌이 (2026-10-23, 시안·앱 미적용)

**도구와 한계:** Blender와 Python 이미지 라이브러리는 이 Mac에 없다. 사용자 승인 없는 대용량 설치는 하지 않았다. macOS 기본 **SceneKit(Metal, PBR 재질)**으로 렌더링했다. SceneKit에는 실제 굴절과 서브서피스 산란이 없다. 그래서 젤리감은 다음의 조합으로 근사했다.
- 투명 유리 껍질(dual-layer 투명, clear coat)
- 안쪽 젤리 코어(약한 자체 발광)
- 정수리 림 조명

레퍼런스는 생성 이미지라 실제 18pt(36px) 픽셀이 담을 수 없는 디테일을 보여 준다. 재질감은 원본 렌더에서만 가깝다.

**3D 형태:**
- 앱 하트·곰돌이 2D 윤곽 안에서 Poisson 방정식(∇²h = −1)을 풀어 풍선처럼 부풀린 높이를 만든다. 테두리에서 0, 중앙에서 최대다.
- z = T·h^p로 앞·뒤 면을 만든다. 하트는 p=0.5, 곰돌이는 p=0.4로 작은 귀도 둥글게 부풀렸다.
- 곰돌이는 귀 사이 오목부 때문에 중심 방사형 메시가 접혔다. 그래서 격자 메시를 쓰고, 윤곽 정점을 이분법으로 실제 곡선에 붙였다.
- 정투영 카메라라 실루엣이 2D 윤곽과 같다.

**게이지 구조(앱 이식 가능):**
- 같은 기하·조명으로 **빈 레이어**(옅은 젤리 코어)와 **채움 레이어**(채도 있는 코어)를 렌더링한다. 각 레이어는 8배 슈퍼샘플링 후 Lanczos로 축소했다.
- `assets/`에 서비스 4종(codex·claude·antigravity·stale) × 2레이어 × @1x/@2x/@3x PNG 24개와 `bear-assets.json`을 둔다. JSON에는 실루엣 채움 행 범위, 숫자 중심 8.87pt, 흰 숫자 전환점 0.70이 들어 있다.
- `BearGauge.swift`(SceneKit 미사용, CoreGraphics만 사용)는 다음 순서로 합성한다.
  1. 빈 레이어
  2. 잔여율 높이까지 채움 레이어(경계 행은 부분 알파)
  3. `sourceAtop` 수면선
- 비교 시트의 메뉴 막대 이미지는 모두 내보낸 PNG를 이 코드로 합성했다.

**적용 방법(승인 시):**
1. `assets/`의 PNG를 `src/Tokenly/Resources/BearGauge/`로 복사하고 리소스 빌드 단계에 등록한다(또는 Asset Catalog 이미지 세트 1x/2x/3x로 등록한다).
2. `BearGauge.swift`를 앱 대상에 추가하고, 번들 경로에서 `load`한다.
3. `MenuBarHeart`의 `JellyHeart` 대신 합성 이미지 `Image(decorative:scale:)`를 쓴다. 숫자(`NumberLabel`)·이름 레이어와 22pt 정수 크기 스냅을 유지한다. 높이 예산상 이름 트림은 1.6pt에서 1.75pt가 된다.
4. `HeartGaugeReading`·숨김 정책·`MenuBarHeartImage`(ImageRenderer) 경로는 그대로 쓴다.
5. 숫자 색 규칙: Claude만 채움이 숫자를 덮으면(0.70 이상) 흰 숫자로 바꾸고, 노랑·하늘색은 진한 잉크를 유지한다. 18pt에서 흰 숫자는 대비가 부족했다.
6. 화면 배율에 맞는 @2x/@3x를 고른다. 렌더링 비용은 이미지 2장 그리기라 기존 SwiftUI 경로보다 가볍다.

**검증:**
- 원본·단계·메뉴 막대 실제 Retina 픽셀과 확대 이미지를 렌더링해 눈으로 확인했다.
- 메뉴 막대 행은 정수 크기다(3개 81×22pt, 7개 197×22pt).
- 앱 코드는 바뀌지 않았으므로 빌드·XCTest는 다시 실행하지 않았다. 실제 메뉴 막대 GUI 확인도 하지 않았다.

## 27. 곰돌이형 앱 적용 (2026-10-23)

**구성:**
- `Preview/Heart3D/assets`의 PNG 24장과 `bear-assets.json`을 `src/Tokenly/Resources/BearGauge/`에 복사했다. 폴더 참조로 리소스 단계에 등록해 번들 `Contents/Resources/BearGauge/`에 들어간다.
- `Views/BearGaugeView.swift`는 다음을 담는다.
  - `BearGaugeCompositor`: CoreGraphics 합성
  - `BearAssets`: 번들 로드·캐시
  - `MenuBarBear`, `MenuBarBearRow`
  - `MenuBarBearImage`: 22pt 정수 비트맵, `isTemplate = false`
- `TokenlyApp`의 `MenuBarBearLabel`은 하트형과 같은 `HeartGauge.readings`를 쓰고, stale이면 `stale` 에셋을 고른다. 조회·stale 정책 코드는 바꾸지 않았다.

**합성 방식:**
1. 빈 레이어를 그린다.
2. 잔여율 높이 아래에 채움 레이어를 덮는다. 경계 행은 부분 알파로 그린다.
3. `sourceAtop` 수면선을 그린다.

채움 영역은 "채움 위 빈 레이어"다. 유리가 반투명해 아래의 옅은 젤리가 조금 비친다. 시안·100%와 같은 방식이며 어두운 막대의 비침을 줄인다. 테스트도 이 방식에 맞췄다.

**숫자 크기 점검:** 시안의 `100%`(6.1pt black)는 2배율 36px 중 35px를 차지해 실루엣 밖으로 1–2px 나갔다. 숫자 크기를 두 자리 7.0pt, `%` 4.6pt, 세 자리 5.3pt, `%` 3.8pt로 바꾸고 weight를 heavy로 낮췄다. 그 결과 모든 경우 밖으로 나가는 픽셀이 0이고, 좌우 여백은 최소 2px가 됐다. XCTest로 회귀를 막는다.

**이름 색:** 비템플릿 이미지라 시스템이 색을 바꿔 주지 않는다. 그래서 라벨의 `colorScheme`으로 검은색/흰색을 고른다. 앱 테마의 `preferredColorScheme`은 팝오버·설정 창에만 걸려 있어 라벨에는 영향이 없다. 바탕화면에 따라 메뉴 막대 외관이 바뀌는 환경에서 라벨 `colorScheme`이 그대로 따라가는지는 실제 화면 확인이 필요하다.

**테스트(추가 5개, 기존 1개 수정):**
- 스타일 저장·전환
- 4종 × 3배율 에셋 번들
- 합성(0%·없음 = 빈, 아래/위 행)
- 81×22pt 정수 이미지
- 숫자 실루엣 이탈 0
- 스타일 목록에 `.bear` 추가

**검증:** Debug·Release 빌드 성공, XCTest 50개 실행·전부 통과(xcresult 기준), 곰돌이형 실행 8초 유지와 저장 스타일 값 불변을 확인했다. 앱 렌더 경로로 만든 라이트·다크 행 이미지를 눈으로 확인했다. 실제 메뉴 막대 GUI·클릭·팝오버는 화면 녹화·손쉬운 사용 권한이 없어 확인하지 못했다. `dist`·설치 앱은 바꾸지 않았다.

## 28. 곰돌이 외곽선 강도 시안 (2026-10-23, 시안·앱 미적용)

`Preview/Heart3D/BearOutline.swift`(`./run-outline.sh`)는 앱 코드(`MenuBarBearImage`)가 만든 실제 행 비트맵에 외곽선을 후처리한다. 앱 소스는 읽기 전용으로 컴파일하고, 에셋은 임시 실행 파일 옆에 복사한다.

**방식:**
- 곰돌이 띠(위 16pt)만 대상으로 알파에서 부드러운 실루엣 마스크를 만든다. 마스크는 (α−0.06)/0.4이며 이름은 제외한다.
- 약 1px 원판 팽창에서 원래 마스크를 뺀 바깥 링에, 곰돌이 색조의 어두운 색을 기존 픽셀 **뒤에**(destination-over) 칠한다.
- 중간·강함은 1px 침식 경계에 옅은 흰 선을 더해 유리 림과 이중선을 만든다.
- 사각형 경계가 아니라 실루엣을 따른다. 링이 18pt 프레임 밖 간격으로 나갈 수 있도록 곰돌이 단위가 아니라 행 이미지 단위로 처리한다. 2배율에서 프레임 안 여유가 좌우·아래 1px, 1배율에서는 0px이기 때문이다.

**강도:**
- 약함: 바깥 0.30
- 중간: 바깥 0.45, 안쪽 0.12
- 강함: 바깥 0.62, 안쪽 0.20

이미지 크기(81×22pt)는 그대로다.

**적용안(선택 시):** 바깥 링은 빈/채움 레이어에서 같으므로, 24장 에셋에 미리 굽는 방식이 가장 단순하다. 단 2배율 좌우 1px, 1배율 0px 여유 때문에 프레임 가장자리 링이 잘린다. 따라서 `MenuBarBearImage`가 만든 행 이미지에 런타임 후처리하는 방식(이 시안과 동일)을 권장한다. 비용은 162×44px 한 번의 순회다.

**검증:** 비교 이미지 렌더링만 했다. 앱 코드는 바뀌지 않아 빌드·XCTest는 다시 실행하지 않았다. 실제 메뉴 막대 GUI 비교도 하지 않았다.

## 29. 곰돌이 외곽선 "강함" 앱 적용 (2026-10-23)

`BearGaugeView.swift`에 `BearOutline`을 추가했다. `MenuBarBearImage.make`가 행 비트맵을 만든 뒤 외곽선을 후처리한다. 에셋 PNG는 바꾸지 않았다(굽는 방식은 2배율 1px·1배율 0px 여유 때문에 링이 잘림).

**알고리즘:** 28절 시안과 같다.
- 곰돌이 띠(위 16pt) 마스크 (α−0.06)/0.4
- 2배율에서 원판 팽창·침식(가장자리 1, 대각 0.75). 3배율은 약 1.5px 커널로 같은 pt 두께를 맞춘다.
- 바깥 링 0.62를 기존 픽셀 뒤에 칠한다.
- 안쪽 빛 0.20

곰돌이별 색조는 점유 열 구간(8pt 간격으로 분리)으로 정한다.

**시안 오류 수정:** 시안 스크립트는 26pt 칸 추정으로 색조를 정해 Claude 오른쪽 가장자리 37px를 AGY 색으로 칠했다(최대 채널 차 24). 시안도 앱과 같은 구간 방식으로 고쳐 다시 렌더링했다. 그 결과 라이트·다크·밝은 하늘색 × 2행에서 **앱 출력과 시안 픽셀이 완전히 같다**(차이 0).

**테스트(추가 2개):**
- 실루엣 밖 링 존재(>150px)
- 좌우 끝 열·맨 위 행 알파 0(잘림 없음)
- 이름 행 불변
- `MenuBarBearImage` 출력에 외곽선 포함

**검증:** Debug·Release 빌드 성공, XCTest 52개 실행·전부 통과(xcresult 기준), 곰돌이형 실행 8초 유지를 확인했다. 실제 메뉴 막대 GUI는 권한이 없어 확인하지 못했다. `dist`·설치 앱은 바꾸지 않았다.

## 30. 곰돌이 숫자 % 제거·시각 중앙·간격 12pt (2026-10-23)

**변경:** `BearGaugeView.swift`의 SwiftUI `Text` 오버레이를 `BearNumber`로 바꿨다. `BearNumber`는 Core Text로 합성 게이지 비트맵에 숫자를 그린다.
- `CTLineGetBoundsWithOptions(.useGlyphPathBounds)`로 글리프 잉크 상자를 구한다. 그 중심을 manifest의 얼굴 중심(9, 8.87pt)에 맞추고, 원점을 2배율 픽셀 격자에 스냅한다.
- SwiftUI `Text` 상자는 어센더·행간과 좌우 여백을 포함해 시각 중심과 어긋나므로 쓰지 않았다.
- 외곽 헤어라인(8방향 0.35pt)과 색 규칙(Claude가 덮이면 흰 숫자)은 그대로다.
- `MenuBarBearRow.spacing`은 8에서 12pt로 바꿨다. 하트형 `MenuBarHeartRow.heartSpacing`은 8pt 그대로다.
- `BearOutline`의 곰돌이 구분은 점유 열 구간 방식이라 간격 변경에 영향이 없다.

**측정(`Preview/Heart3D/run-numbers.sh`, 숫자를 투명 레이어에 그려 잉크만 측정):** 4종 × 0/9/54/89/100과 `?` 모두에서 중심 오차가 가로 ≤0.25pt, 세로 ≤0.38pt(`100`)이고, 실루엣 가장자리까지 ≥2px다. 처음 6.8pt였던 `100`은 1px라 6.2pt로 줄였다. 배경과의 차이로 잉크를 찾던 첫 측정은 Claude 흰 숫자의 일부를 놓쳐 오차를 0.63pt로 과대 계산했고, 투명 레이어 측정으로 바로잡았다.

**테스트:**
- 숫자 문자열(`%` 없음)
- 4종 × 5값의 중심(±0.5pt)과 가장자리 2px 여유
- 합성 곰돌이에서 실루엣 이탈 0
- 간격 12/하트 8
- 행 폭 89pt
- 외곽선 테스트 폭 갱신

**검증:** Debug·Release 빌드 성공, XCTest 54개 실행·전부 통과, 곰돌이형 실행 8초 유지를 확인했다. 실제 크기 비교 이미지는 `Preview/Heart3D/40`–`41`이다. 실제 메뉴 막대 GUI는 확인하지 못했다. `dist`·설치 앱은 바꾸지 않았다.

## 31. 곰돌이 B안 시안: 이름-윤곽 통합·확대·귀 1.05배 (2026-10-23, 시안·앱 미적용)

**가능성 계산:**
- 이름 잉크 폭(6pt heavy): Codex 20.0, Claude 22.3, AGY 13.2pt
- 현재 실루엣: 17.0×13.5pt, 턱(하단 윤곽) 폭 5–13pt
- 이름이 턱보다 2–4배 넓어 "윤곽선 일부만 대신"할 수 없고, 곰돌이 아랫부분을 가로지른다.
- 확대 상한은 높이가 아니라 **폭**이다. 89pt 행 = 1 + 3×W + 2×12 + 1이므로 W ≤ 21pt(+16.7%)다.

**B 렌더:**
- `BearModel.bearOutline(earScale:)`(기본 1 → 기존 에셋 재현성 유지)로 귀 타원 반지름만 1.05배 키웠다.
- SceneKit 8배 슈퍼샘플 후 42×37px(21×18.5pt)로 줄였다.
- 동적 채움은 앱 `BearGaugeCompositor`, 숫자는 앱과 같은 Core Text 잉크 중심 방식(9.3 / 3자리 7.2pt)이다.
- 행 전체에 앱과 같은 강함 외곽선을 그린 뒤, 이름 글리프 1.5px 주변을 지우고(녹아웃) 이름을 그린다.

**측정:**
- 실루엣 ×1.176 폭, ×1.185 높이
- 숫자 잉크 높이 5.9에서 6.9pt(×1.167)
- 귀 폭: 얼굴 대비 ×1.050, 절대 3.81에서 4.66pt(곰돌이 확대 포함 ×1.225)
- 숫자 아래 끝과 이름 녹아웃 사이 약 2.6pt
- 라이트·다크·하늘색 × 2행 모두 이미지 가장자리 알파 0(잘림 없음)

**평가:**
- B는 실제 크기에서 숫자가 분명히 더 잘 읽힌다.
- 이름은 턱을 가로질러 곰돌이 아랫부분이 이름 모양으로 비고, 실루엣의 아래 곡선이 사라진다. 의도한 "윤곽선 일부를 대신하는 타이포그래피"보다는 "곰돌이 하단에 겹친 이름"에 가깝다.
- 사용자 선택 전까지 앱 적용은 하지 않는다. 앱 코드가 바뀌지 않아 빌드·XCTest는 다시 실행하지 않았다.

## 32. 곰돌이형 B안·하트형 개선 앱 적용 (2026-10-23)

**에셋:**
- `Preview/Heart3D/run-bear-b.sh`(`BearExportB.swift`)가 `BearRenderer(earScale: 1.05)`로 21pt 프레임 에셋을 내보낸다. 구성은 @2x 42×37px, @3x 63×56px, 서비스 4종 × 빈/채움 16장과 manifest v2다.
- manifest v2에는 배율별 프레임 크기, 실루엣 행, 숫자 중심 8.98pt, 흰 숫자 전환점 0.78이 들어 있다.
- 앱 `Resources/BearGauge`를 교체했다. 기존 A 에셋은 `Preview/Heart3D/assets`에 바이트 동일하게 보존돼 있다(교체 전 diff 확인).

**공통 행 렌더러 `Views/MenuBarGaugeRow.swift`:**
- `GaugeIcon`: 채움이 끝난 몸체 이미지, 몸체 프레임, 숫자 중심, 이름 중심 y, 숫자 크기·색, 이름, 외곽선 색조
- `GaugeDigits`: 숫자 문자열(`%` 없음), Core Text 글리프 잉크 상자
- 그리기 순서:
  1. 몸체를 그린다.
  2. 숫자를 그린다. 8방향 0.35pt 헤어라인을 쓰고, 잉크 상자 왼쪽·아래 가장자리를 픽셀 격자에 스냅한다(원점 스냅보다 선명하고 중심 오차 ≤¼pt).
  3. (곰돌이만) `BearOutline` 강함을 적용한다. `rows` 인자를 추가해 행 전체를 대상으로 한다.
  4. 이름 글리프 마스크를 0.75pt 원판으로 넓혀 그 영역을 지운다.
  5. 이름을 검정/흰색으로 그린다.
- 순서가 중요하다. 외곽선 뒤에 지워야 외곽선이 이름 둘레를 다시 따라가지 않는다.

**곰돌이:** `MenuBarBearImage.icons`가 manifest의 귀 위·턱 행으로 "귀 링(−0.5pt)–이름 아래끝"을 22pt 안에 세로 중앙 정렬한다(프레임 위 0pt). 이름 중심은 턱(18pt)이다.

**하트:** `MenuBarHeartImage.icons`가 `JellyHeart(width: 20)`를 1pt 여백과 함께 `ImageRenderer`로 그린다. 하트 위 1pt, 끝 18.6pt에 이름 중심을 두고, 숫자 중심은 하트 위와 이름 지움 위 경계의 중간이다. 처음 21pt 폭은 테두리·그림자가 좌우 경계 알파 53–61, `Codex`가 아래 행에 닿아 20pt로 줄였다.

**라벨:** `MenuBarHeartLabel`도 `colorScheme`으로 이름 색을 정한다. 이전 하트 SwiftUI 행(`MenuBarHeart`·`MenuBarHeartRow`·이름 아래 줄·8pt)은 앱에서 빠졌다. 옛 시안 스크립트용으로 `Preview/Shared/LegacyMenuBarHeart.swift`에 옮기고 해당 run.sh 3개에 추가했다.

**시안 스크립트 상태:** `Preview/Heart3D`의 `run-outline.sh`·`run-numbers.sh`·`run-name-outline.sh`는 그 시점의 앱 API(`MenuBarBearRow`·`BearNumber`)와 A 에셋에 맞춰져 있어 이제 다시 실행되지 않는다. 결과 PNG(30–52)는 그대로 남아 있다.

**측정(`run-gauge-rows.sh`, 앱 코드 출력):** 곰돌이·하트 × 4종 × 0/9/54/89/100 결과는 다음과 같다.
- 숫자 중심 오차 ≤0.42pt
- 실루엣까지 ≥2px
- 숫자–이름 간격: 곰돌이 ≥2.0pt, 하트 ≥3.0pt
- 이름 잉크 높이 4.5–5.0pt(수평·무곡선), 이름 중심 오차 ±0.25pt
- 라이트·다크·하늘색 행 가장자리 알파 0(하트 위쪽 2/255)

**테스트(XCTest 53개 전부 통과):**
- B 에셋·manifest v2
- 합성 채움
- `%` 없음
- 두 스타일 89×22·23×22 정수 크기·간격 12
- 이미지 경계 잘림 없음
- 두 스타일 × 4종 × 5값의 숫자 중심·가장자리 2px·숫자–이름 간격, 이름 수평(잉크 높이·폭)·중앙·검정/흰색
- 곰돌이 강함 외곽선 유지

옛 곰돌이 테스트 일부는 새 구조 테스트로 통합돼 총수가 54에서 53이 됐다.

**검증:** Debug·Release 빌드 성공, XCTest 53개 실제 실행·전부 통과(xcresult). 곰돌이형·하트형·숫자형을 인자로 각 6초 실행해 유지를 확인했다(저장 스타일 불변). 실제 메뉴 막대 GUI는 권한이 없어 확인하지 못했다. `dist`·설치 앱은 바꾸지 않았다.

## 33. 숫자형 위계 디자인 (2026-10-23)

**발견:** 요청의 "40/70·이름" 숫자형은 코드에 없었다. 기존 숫자형은 Codex 한 줄 텍스트다. 사용자 확인 후 새로 만들었다.

**구조:**
- `Models/NumericGauge.swift`(`NumericGaugeItem`, `NumericGauge.items`): `HeartGauge.visibleProviders`·`codexReading`·`externalReading`으로 보일 서비스와 stale을 정한다. 값은 Codex 창 / Claude `5시간 한도`·`7일 한도` / AGY 버킷 최저를 쓴다.
- `Views/MenuBarNumericRow.swift`(`MenuBarNumericImage`, `Layout`): Core Text로 그린다. 가로는 글리프 잉크 상자를 나란히 놓아 `100/100`과 `0/0`이 같은 간격이 되게 한다.
- `MenuBarNumericLabel`: 표시할 서비스가 없으면 기존 `MenuBarPresentation.text` 텍스트로 대체한다. 이 함수와 최소형·아이콘형은 그대로다.

**시안 비교(`Preview/Numeric/70`–`71`, 앱 코드 출력):** 7일을 15·20·25% 작게, 높이 차를 1.0·1.5·2.0pt로 비교했다.
- 15%는 위계가 약하다.
- 25%는 `100/100`의 7일이 작다.
- 1pt는 차이가 거의 안 보인다.
- 2pt는 7일이 아래첨자처럼 떨어져 보인다.
- **20%·1.5pt를 채택했다.**

**트러블슈팅:**
1. 열마다 잉크로 세로 중앙을 잡으니 숫자가 하나뿐인 AGY 열의 이름이 1pt 높아졌다. 그래서 세로 배치를 값과 무관한 글꼴 측정값으로 정해 모든 열이 같은 이름 기준선을 쓰게 했다.
2. 대문자 높이로 계산하니 숫자–이름 간격이 1.05pt로 줄었다. 이름의 `d`·`l`이 대문자보다 높고 둥근 숫자가 기준선 아래로 내려오기 때문이다. 그래서 실제 글리프("0", "Cdl")로 쟀다.
3. `/`는 기준선 아래로 내려와 가장 낮은 잉크가 됐다. 그래서 `/` 잉크를 숫자 영역 세로 중앙에 맞춰 간격을 1.75pt로 회복했다.

**측정:** 3개 행은 117×22pt(40/70·100/100·9), 94×22pt(9/100·0/0·54)다. 숫자 영역 2.8–13.1pt, 이름 14.9–19.3pt, 숫자–이름 1.75pt(AGY 2.46pt)이고, 가장자리 알파는 0이다.

**테스트(2개 추가):**
- 매핑(Codex·Claude 5h/7d, AGY 한 숫자, stale, 숨김, `—`)
- 비율 0.8·높이 차 1.5pt·이름 기준선 공유·숫자–이름 ≥1.5pt·상하 잘림 없음·가장자리 알파 0(100/100, 9/100, 0/0 포함)

XCTest 55개 실제 실행·전부 통과. 실제 메뉴 막대 GUI는 확인하지 못했다.

## 34. 숫자형 타이포그래피 조정 (2026-10-23)

**변경:** `MenuBarNumericImage.Layout`에 숫자·`/`·이름 굵기 필드를 추가했다. 이전 값은 `Layout.first`로 보존하고, `Layout.standard`를 다음으로 바꿨다: drop 2.0, separatorGap 1.2, 5h Semibold, 7d Medium, `/` Medium, 이름 Semibold. 세로 배치 계산(`vertical`)과 `/` 세로 중앙도 굵기별 글리프로 측정한다.

**비교(`Preview/Numeric/72`–`75`, `run-typography.sh`, 앱 코드 출력, 메뉴 막대 기본 13pt Regular 참고 글씨 포함):**
- 현재 Heavy는 참고 글씨보다 확연히 굵다.
- A(전부 Semibold)도 다소 굵다.
- B(전부 Medium)는 6pt 이름이 가늘다.
- C(5h Semibold·7d Medium)는 굵기와 크기 모두로 위계가 남고 균형이 가장 좋다.
- D(간격 1.5)는 너무 성기다.
- E(높이 차 2.5pt)는 계단·아래첨자처럼 보인다.
- 최종은 C에 이름만 Semibold로 바꾼 조합이다.

**측정(97/89·28/91·100/100·9/100·0/0, AGY 54·0 포함):**
- `/` 양옆 잉크 간격 1.20pt
- 숫자 잉크 2.6–13.4pt, 이름 15.1–19.5pt(모든 열 동일 기준선)
- 숫자–이름 1.75pt(AGY 2.70pt)
- 가장자리 알파 0
- 행 폭: 103에서 100pt, 115에서 110pt, 23에서 21pt

**테스트:** 숫자형 레이아웃 테스트를 새 값(drop 2.0·간격 1.2·굵기)과 `/` 양옆 잉크 간격 ≥1pt, 97/89·28/91·40/70 등 값 확대로 갱신했다. XCTest 55개 실제 실행·전부 통과했고, 숫자형 실행 6초 유지를 확인했다. 실제 메뉴 막대 GUI는 확인하지 못했다.

## 35. 숫자형 `/` 간격 1.7pt (2026-10-23)

`MenuBarNumericImage.Layout.standard.separatorGap`을 1.2에서 1.7로 바꿨다. 나머지 값과 다른 스타일은 그대로다. `Preview/Numeric/76`–`77`(앱 코드 출력, 1.2 대 1.7)에서 97/89·28/91·100/100·9/100·0/0의 `/` 양옆 잉크 간격이 1.70/1.70pt이고, 숫자 2.6–13.4pt·이름 15.1–19.5pt는 그대로이며, 숫자–이름 1.75pt와 가장자리 알파 0을 확인했다. 테스트는 간격이 정확히 1.7pt(±0.01)인지로 바꿨다. Debug·Release 빌드, XCTest 55개 실제 실행·전부 통과.

## 36. 숫자형 서비스 간격 16pt, `/` 1.2pt 복원 (2026-10-23)

**배경:** 35절의 `/` 간격 1.7pt는 요청을 잘못 해석한 결과였다. 사용자 정정에 따라 되돌렸다.

**변경:**
- `MenuBarNumericImage`의 고정 `spacing` 상수를 `Layout.columnSpacing`으로 옮겼다. 기본값은 12이고 `standard`는 16이다. 비교 시안이 같은 코드로 전후를 그릴 수 있게 하기 위해서다.
- `standard.separatorGap`은 1.2로 되돌렸다.
- 곰돌이·하트는 별도 상수 `MenuBarGaugeRow.spacing`(12)을 써서 영향이 없다. 테스트로 고정했다.

**측정(`Preview/Numeric/78`–`79`):** `/` 양옆 1.20/1.20pt, 숫자 2.6–13.4pt, 이름 15.1–19.5pt, 숫자–이름 1.75pt, 가장자리 알파 0. 행 폭은 102에서 108pt, 112에서 118pt이고, 0/0 한 개는 21pt다.

**테스트:** 간격 1.2pt·서비스 간격 16pt·곰돌이/하트 12pt를 확인한다. Debug·Release 빌드, XCTest 55개 실제 실행·전부 통과.

## 37. Codex 사용 한도 재설정 권한 (2026-10-23, 읽기 전용)

**조사:**
- `codex app-server generate-json-schema --out <임시>`로 받은 v2 스키마에서 다음을 확인했다.
  - `GetAccountRateLimitsResponse.rateLimitResetCredits`
  - `RateLimitResetCreditsSummary{availableCount, credits?}`
  - `RateLimitResetCredit{id, grantedAt, expiresAt?, status, resetType, title?, description?}`
  - 요청 인자 `GetAccountRateLimitsParams.excludeResetCreditDetails`: 백그라운드 조회에서 상세 생략 가능, 생략 시 상세 포함
  - 소모 요청 `account/rateLimitResetCredit/consume`(`idempotencyKey` 필요)
- 같은 `account/rateLimits/read`를 한 번 실제로 호출해 응답 키와 `rateLimitResetCredits` 구조만 출력했다(`availableCount` 2, 상세 2건 available·codexRateLimits·만료 6.6일/14.7일 후). 계정 ID·권한 ID는 출력하지 않았다.
- app-server는 CLI에서 "experimental"로 표시되며, 필드는 선택이다.

**구현:**
- `UsageSnapshot.resetCredits`(`RateLimitResetCredits`·`RateLimitResetCredit`)
  - `usableCount` = `availableCount` − (목록상 available이지만 이미 만료된 수), 최소 0
  - `usableCredits` = available이고 만료 전인 권한, 만료 이른 순(만료 없음은 마지막)
- `CodexRateLimitParser`가 `rateLimitResetCredits`를 디코딩한다. resetType이 `codexRateLimits`나 미지정이 아닌 행은 제외한다.
- 요청은 기존 그대로 인자 없는 `account/rateLimits/read`(상세 포함)다. 5분 주기에서도 상세를 받는다. 스키마는 백그라운드 조회에 `excludeResetCreditDetails`를 제안하지만, 만료 일시가 필요해 기존 동작을 유지했다.
- 소모 요청은 코드에 없다.
- `UsageMenuView.codexDetails`에 `resetCreditsSection`을 추가했다. 아코디언 `details()`는 펼침일 때만 그려지므로 접으면 숨는다. 문구는 `ResetCreditText`, 날짜는 ko_KR `yyyy년 M월 d일 (E) a h:mm`.

**테스트(3개 추가):**
- 파싱·만료 이른 순 정렬·한국어 날짜(서울 시간대)
- 만료·redeeming·비 Codex 행 제외와 목록 밖 남은 횟수 안내
- 0회·횟수만(상세 null)·필드 없음/null

XCTest 58개 실제 실행·전부 통과, Debug·Release 빌드 성공.

**오프라인 렌더(`Preview/CodexResetCredits`):** 앱 `UsageMenuView`에 가짜 응답(권한 2개)을 넣었다. 펼침은 340×316pt(재설정 영역 약 +45pt), 접힘은 340×110pt이고 재설정 정보가 보이지 않는다. 버튼·진행 막대는 `ImageRenderer`가 그리지 못해 노란 자리표시로 나온다. 실제 메뉴 막대 팝오버·작은 화면 스크롤은 확인하지 못했다.

## 38. Codex 재설정 권한 문구 (2026-10-23)

`ResetCreditText.detailLines`의 문구만 바꿨다. 정렬은 기존 `usableCredits`(기한 이른 순, 기한 없음 마지막)를 그대로 쓴다.
- 문구: "N회차 사용 기한: …", "N회차 사용 기한 없음", 목록 밖 "나머지 N회는 사용 기한 정보가 제공되지 않았습니다.", 상세 null "사용 기한 정보는 제공되지 않았습니다."
- 날짜는 `deadline`(ko_KR `M월 d일 a h:mm`, 다른 해는 `yyyy년 M월 d일 a h:mm`)으로 바꿨다. 기존 `expiry`(연도·요일 포함)는 제거했다.
- 파싱, `usableCount`, 조회, 메뉴 막대는 그대로다.

테스트 기대값을 새 문구로 갱신하고 다른 해 연도 표기 검사를 추가했다. 오프라인 렌더(`Preview/CodexResetCredits`)에서 "1회차/2회차 사용 기한"이 펼침에서만 보이는 것을 확인했다. Debug·Release 빌드, XCTest 58개 실제 실행·전부 통과.

## 39. 스타일 3종 정리와 v1.0.0 배포 준비 조사 (2026-10-23)

**스타일 정리:** `MenuBarDisplayStyle` = numeric, compact, bear. 아이콘형 분기·하트 라벨·`MenuBarHeartImage`·`HeartPalette.of` 제거. 저장값 "icon"/"heart"는 숫자형으로 읽고 한 번 되써서 정리(다른 키 불변, 테스트). `HeartGauge` 모델(표시·stale·숨김 규칙)은 숫자형·곰돌이형이 공유하므로 유지. `HeartGaugeView.swift`는 곰돌이 에셋 렌더러(`Render3D.HeartShape`)가 필요로 해 `Preview/Shared`로 이동, Preview 스크립트 경로 갱신, 에셋 파이프라인 컴파일 확인. 이전 README는 `Preview/README.before-v1.md`로 보존.

**배포 조사 결과:**
- 번들 ID `com.tokenly.app`(소유 도메인 아님 — 변경 권장), 버전 0.1(1), macOS 14.0, `LSUIElement`. ARCHS는 arm64·x86_64지만 일반 `build`는 활성 아키텍처만 → `-destination 'generic/platform=macOS'`로 universal 확인.
- `CODE_SIGNING_ALLOWED=NO`, Hardened Runtime 꺼짐 → 산출물은 링커 ad-hoc 서명뿐, `codesign --verify --strict` 실패. 키체인 코드 서명 인증서 0개 → 현재 환경에서 Developer ID 서명·공증 불가(notarytool 1.1.3은 있음). Apple Developer Program 가입 필요.
- 다른 Mac 위험: ① 미서명 다운로드 앱 Gatekeeper 차단 ② 로그인 항목(SMAppService)은 /Applications 설치 앱만 허용, 서명 안 된 앱에서 승인 요구 가능 ③ `/usr/bin/python3` 브리지는 Command Line Tools 없으면 실행 실패 ④ 설정 스크립트가 저장소 경로의 브리지를 가리킴(앱만 설치한 사용자 불가) ⑤ AGY 스크립트는 설정 권한 0600이 아니면 중단 ⑥ Codex CLI가 아는 경로 밖에 있으면 미검출 ⑦ app-server는 experimental.
- 보안 스캔: 키·토큰 패턴은 테스트용 가짜 값뿐, 이메일은 example.com. 개인 경로는 README·IMP-PLAN(정리 완료), `dist` 바이너리, `xcuserdata`. 저장소는 상위 `~/vibe` Git 저장소에 포함되어 있고 `.gitignore`·LICENSE 없음 → 별도 저장소와 `.gitignore`(dist, xcuserdata, .DS_Store, DerivedData) 필요. 곰돌이 에셋은 자체 렌더링이라 외부 라이선스 문제 없음.

## 40. GitHub 소스 공개 준비 (2026-10-23, Git 작업은 승인 대기)

**저장소 현황(읽기 전용 확인):** Git 루트는 `~/vibe`이지만 커밋이 없고, 추적 파일·원격 저장소도 없다. `myapp/`는 untracked다. Tokenly에는 옮겨야 할 Git 기록이 없으므로 분리는 "새 저장소 생성"이다.

**분리 방법 후보(승인 전 미실행):**
- A. `myapp/Tokenly`에서 `git init`: 경로를 바꾸지 않고 상위 저장소 파일도 바꾸지 않는다. 다만 상위에서 나중에 `git add myapp`을 하면 중첩 저장소(gitlink)가 된다.
- B. `~/vibe` 밖의 새 위치로 복사한 뒤 `git init`: 중첩 위험이 없지만 작업 위치가 바뀐다.

**공개 범위:** `.gitignore`(신규)를 반영한 공개 후보는 179개 파일, 약 8.2MB(`src`·`scripts`·`Doc`·`Preview`·README·설정 스크립트)다. `dist/`·`xcuserdata`·`.DS_Store`·`*.profraw`는 제외된다.

**보안 점검:**
- 키 형태 문자열은 테스트용 가짜 값, 이메일은 example.com, 테스트 경로는 `/Users/example`이다.
- 실제 개인 경로는 공개 후보에서 제거했다(`README.md`·`IMP-PLAN`·`Preview/README.before-v1.md`). 제외 대상(`dist` 바이너리, `xcuserdata`)에는 남아 있다.
- 비밀키·토큰·쿠키·계정 ID는 발견되지 않았다.

**문서:**
- `README.md`: 채용·개발자용으로 재작성. 동기, 기능, 렌더 이미지(캡처 아님 명시), 기술·구조, 연동 비교, 테스트, 제약, 계획을 담았다.
- `Doc/BLOG-NOTES.md`: 근거 파일·절 링크를 포함한 블로그 자료.
- `Preview/README.md`: 시안 목록과 스크립트 실행 가능 여부. 직접 컴파일로 확인했고, Heart3D의 4개 스크립트만 현재 API로 컴파일되지 않는다.

**검증:** Debug·Release 빌드 성공, XCTest 58개 실제 실행·전부 통과(앱 코드 변경 없음).

## 41. 지인 테스트 전달 조사 (2026-10-23, 조사만·파일 미작성)

**기존 산출물:** `dist/Tokenly.app`은 이른 시각의 오래된 빌드라 전달용으로 부적합하다(arm64 전용, `Resources` 없음 → 곰돌이 에셋·브리지 누락, 바이너리에 개인 경로 문자열 185개).

**일반 `build`의 문제:** `DEPLOYMENT_POSTPROCESSING=NO`라 심볼이 제거되지 않는다. universal Release 바이너리의 심볼 테이블에 개발자 사용자 경로 약 1,900개가 남고, 링커 ad-hoc 서명이라 `codesign --verify --deep --strict`가 실패한다.

**스크래치 검증:**
- `-destination 'generic/platform=macOS' DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES DEBUG_INFORMATION_FORMAT=dwarf-with-dsym`로 빌드하면 universal(x86_64·arm64), 개인 경로·사용자명 0, 1.6MB다.
- 번들 전체를 `codesign --force --deep --sign -`으로 다시 서명하면 strict 검증을 통과한다.
- `spctl`은 rejected(미공증)다. dSYM은 앱 밖에 생기므로 전달하지 않는다.

**동작 조건:** Tokenly 자체 로그인은 없다. 각 서비스는 지인 본인의 CLI 로그인을 쓴다.
- Codex: 지정 경로에 `codex`가 있고 로그인돼 있어야 한다.
- Claude: Claude Code 구독 사용자가 `statusLine`을 직접 편집해야 한다(앱에 명령 복사 버튼 없음).
- AGY: 앱의 "상태줄 명령 복사"를 쓴다.
- Claude·AGY 브리지는 `/usr/bin/python3`(Command Line Tools)가 필요하다.
- 재설정 권한 필드는 codex-cli 0.163.0-alpha 기준으로만 확인했다.

## 42. 독립 저장소 `~/Developer/Tokenly` (2026-10-23)

승인에 따라 원본 `~/vibe/myapp/Tokenly`를 `rsync`로 복사했다. `dist/`·`.DS_Store`·`xcuserdata/`·`*.profraw`는 제외했고 원본은 변경하지 않았다. 복사본은 원본과 181개 파일이 동일하고, Xcode 프로젝트에 절대 경로가 없다. 복사본에서 `git init -b main`을 했고, 상위 `~/vibe` 저장소는 변경 없음을 확인했다. 이후 변경은 복사본에서만 한다: MIT LICENSE(© 2026 jbbdyee), `CFBundleShortVersionString` 0.1 → 0.1.0, README 라이선스·Preview 안내, Preview 실행 불가 스크립트 목록 명시.
