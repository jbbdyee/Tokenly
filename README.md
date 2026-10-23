# Tokenly

macOS 메뉴 막대에서 **Codex · Claude Code · Google Antigravity(AGY)** 의 남은 사용 한도를 한눈에 확인하는 SwiftUI 앱입니다.

> **현재 상태: v0.1.0 개발 버전(소스 공개 단계)**
> 일반 사용자용 설치 파일(서명·공증된 앱)은 아직 배포하지 않습니다. 직접 빌드해야 하며, 개발자 Mac 밖에서의 동작은 충분히 검증되지 않았습니다. 자세한 제약은 [현재 지원 범위와 제약](#현재-지원-범위와-제약)을 참고하세요.

## 개발 동기

여러 AI 코딩 도구를 함께 쓰면 각 서비스의 5시간·주간 한도를 확인하려고 매번 다른 화면이나 CLI를 열어야 했습니다. Tokenly는 이 확인을 메뉴 막대 한 곳으로 모으고, **공식적으로 제공되는 데이터만** 읽어 숫자로 보여 주는 것을 목표로 합니다. 확인되지 않은 값은 0%나 임의 값으로 채우지 않고 "데이터 없음·이전 데이터"로 구분합니다.

## 주요 기능

- 메뉴 막대 스타일 3종: **숫자형(기본)**, **최소형**, **곰돌이형**
- 서비스별 표시 선택, 연결되지 않은 서비스 숨김, 오래된 데이터는 반투명/회색으로 구분
- 팝오버 상세: 서비스별 5시간·7일(AGY는 버킷별) 잔여율과 초기화 시각, 마지막 수신 시각
- Codex 상세에서 ChatGPT **사용 한도 재설정 권한**의 남은 횟수와 회차별 사용 기한 표시(읽기 전용)
- 라이트·다크·시스템 테마, 로그인 시 자동 실행(앱이 `/Applications`에 있을 때)

## 화면

> 아래 이미지는 **앱의 실제 렌더링 코드로 생성한 이미지**이며, 메뉴 막대를 화면 캡처한 스크린샷이 아닙니다. 실제 스크린샷은 추후 추가합니다.

| 숫자형 (기본) | 최소형 | 곰돌이형 |
|---|---|---|
| ![숫자형](Doc/images/menubar-numeric.png) | ![최소형](Doc/images/menubar-compact.png) | ![곰돌이형](Doc/images/menubar-bear.png) |

- **숫자형:** 서비스마다 5시간 잔여율(크게·위)과 7일 잔여율(작게·아래), 그 아래 서비스 이름. AGY는 5시간/7일 창이 없어 가장 낮은 버킷 잔여율 하나만 표시합니다.
- **최소형:** Codex의 5시간·7일 잔여율을 한 줄로 표시합니다.
- **곰돌이형:** SceneKit으로 미리 렌더링한 3D 젤리 곰돌이가 잔여율만큼 차오르고, 안에 숫자, 아래 윤곽에 서비스 이름을 넣습니다.

## 사용 기술과 구조

- Swift 5 · SwiftUI `MenuBarExtra` · AppKit(`NSImage`, `NSStatusItem` 라벨) · Core Graphics · Core Text
- ServiceManagement(`SMAppService`, 로그인 항목) · Security(Keychain, 보류 중인 OpenAI API 연동용)
- SceneKit(3D 곰돌이 에셋 제작, **앱 런타임에는 사용하지 않음**) · Python 3 표준 라이브러리(상태줄 브리지)
- XCTest(호스트 앱 테스트)

```
Codex CLI ──(app-server JSON-RPC, 5분마다)──▶ CodexUsageProvider ─▶ UsageStore ─┐
Claude Code ─statusLine─▶ ClaudeStatusLineBridge.py ─▶ claude-quota.json ─┐      │
AGY CLI ─────statusLine─▶ AGYStatusLineBridge.py ────▶ agy-quota.json ────┴▶ ExternalProviderStore
                                                                                 │
                     HeartGauge / NumericGauge (표시·숨김·stale 규칙, 대표값) ◀──┘
                                  │
        MenuBarNumericRow · MenuBarGaugeRow(곰돌이) · 최소형 텍스트 ─▶ 메뉴 막대
        UsageMenuView ─▶ 팝오버 상세(Codex 재설정 권한 포함)
```

| 영역 | 주요 파일 |
|---|---|
| 앱 진입·메뉴 막대 라벨 | `src/Tokenly/TokenlyApp.swift` |
| Codex 조회 | `src/Tokenly/Providers/CodexUsageProvider.swift` |
| Claude·AGY 조회 | `src/Tokenly/Providers/ClaudeSubscriptionProvider.swift`, `AGYStatusLineProvider.swift`, `ExternalProviderStore.swift` |
| 상태줄 브리지 | `src/Tokenly/ClaudeStatusLineBridge.py`, `AGYStatusLineBridge.py` |
| 표시 규칙 | `src/Tokenly/Models/HeartGauge.swift`(이름은 초기 하트 시안에서 유래, 현재 숫자형·곰돌이형 공용), `NumericGauge.swift` |
| 렌더링 | `src/Tokenly/Views/MenuBarNumericRow.swift`, `MenuBarGaugeRow.swift`, `BearGaugeView.swift`, `UsageMenuView.swift` |
| 곰돌이 3D 에셋 제작 | `Preview/Heart3D/`(`HeartMesh.swift`, `BearModel.swift`, `BearExportB.swift`, `run-bear-b.sh`) → `src/Tokenly/Resources/BearGauge/` |

## 서비스별 연동 방식

| | Codex | Claude Code | Google Antigravity |
|---|---|---|---|
| 방식 | 공식 `codex app-server`의 읽기 전용 JSON-RPC `account/rateLimits/read` | Claude Code `statusLine` 명령이 넘기는 JSON | AGY CLI `statusLine` 명령이 넘기는 JSON |
| 갱신 | Tokenly가 **능동 조회**(5분 주기 + 새로고침) | CLI가 상태줄을 갱신할 때만(**이벤트 기반**) | CLI가 상태줄을 갱신할 때만(**이벤트 기반**) |
| 표시 값 | 5시간·7일 창, 재설정 권한 | 5시간·7일 한도 | 버킷별 잔여 비율(5시간/7일 아님) |
| 오래된 데이터 | 조회 실패 시 이전 값 표시 | 수신 후 15분 지나면 회색 | 수신 후 15분 지나면 회색 |

- **공식 조회 vs 이벤트 기반:** Codex는 앱이 언제든 공식 인터페이스에 물어볼 수 있습니다. Claude·AGY는 CLI가 실행되며 상태줄을 그릴 때만 새 값이 오므로, CLI를 쓰지 않는 동안에는 값이 멈춰 있고 Tokenly는 이를 "이전 데이터"로 표시합니다. Tokenly의 새로고침은 로컬 파일을 다시 읽을 뿐 서비스에 요청하지 않습니다.
- **Codex 재설정 권한:** Codex CLI가 생성하는 공식 프로토콜 스키마(`codex app-server generate-json-schema`)에 정의된 `rateLimitResetCredits`만 읽습니다. 권한을 소모하는 `account/rateLimitResetCredit/consume`은 호출하지 않습니다.
- 비공식 API, 웹 세션 쿠키, 인증 토큰 추출, 브라우저 자동화는 사용하지 않습니다.

## 개인정보와 로컬 데이터

- 브리지는 한도 수치·초기화 시각·수신 시각만 `~/Library/Application Support/Tokenly/`에 권한 0600으로 저장합니다. 세션·계정·경로·대화·인증정보와 원본 JSON은 저장하지 않습니다.
- Codex CLI 출력의 진단 메시지(stderr)는 버립니다. 수집한 데이터를 외부 서버로 보내지 않습니다.
- Claude·AGY 상태줄 설정 스크립트(`scripts/enable_claude_statusline.py`, `enable_agy_statusline.py`)는 기존 `statusLine`이 있으면 덮어쓰지 않고 중단하며, 변경 전 권한 0600 백업을 만듭니다.

## 빌드와 테스트

```sh
open src/Tokenly.xcodeproj          # Tokenly 스킴 실행(⌘R), 테스트(⌘U)
# 명령줄
xcodebuild -project src/Tokenly.xcodeproj -scheme Tokenly -configuration Release \
  -destination 'generic/platform=macOS' build     # universal(arm64 + x86_64)
xcodebuild -project src/Tokenly.xcodeproj -scheme Tokenly test
```

마지막 확인(2026-10-23, 개발자 Mac, Xcode 27.1):

| 항목 | 결과 |
|---|---|
| Debug·Release 빌드 | 성공 |
| XCTest | 58개 실제 실행, 전부 통과 |
| 숫자형·최소형·곰돌이형 실행 | 각 스타일로 실행해 종료 없이 유지되는 것만 자동 확인 |
| 메뉴 막대·팝오버 실제 화면 | 개발자 본인이 메뉴 막대 표시와 Codex 재설정 권한 표시를 확인. 자동화된 GUI 테스트는 없음 |

테스트는 Codex 응답 파싱, Claude·AGY 수신 파일 파싱과 만료, 표시·숨김·stale 규칙, 재설정 권한 계산, 스타일 저장·이전, 숫자형·곰돌이형의 크기·정렬·잘림(픽셀 단위) 등을 다룹니다(`src/TokenlyTests/TokenlyTests.swift`).

## 현재 지원 범위와 제약

- **설치 배포 없음:** Developer ID 서명·공증을 하지 않았습니다. 직접 빌드한 앱을 다른 Mac으로 옮기면 Gatekeeper가 막을 수 있습니다.
- **요구 사항:** macOS 14 이상. Codex 표시는 Codex CLI 설치·로그인이 필요하며 `PATH`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.npm-global/bin`에서 `codex`를 찾습니다.
- **Python 의존:** 상태줄 브리지는 `/usr/bin/python3`로 실행됩니다. Xcode Command Line Tools가 없는 Mac에서는 실행되지 않을 수 있습니다.
- **설정 스크립트 경로:** 현재 스크립트는 저장소 안의 브리지 경로를 상태줄에 등록합니다. 저장소를 옮기면 다시 설정해야 합니다.
- **Codex app-server**는 Codex CLI에서 experimental로 표시된 기능이라 CLI 업데이트에 따라 바뀔 수 있습니다.
- Gemini 자동 조회는 지원하지 않습니다. OpenAI API 사용량 연동 코드는 있으나 보류 상태입니다.

## 향후 계획

1. 실제 메뉴 막대 스크린샷 추가
2. 상태줄 설정 스크립트를 설치된 앱 번들 경로 기준으로 바꾸고 Python 의존을 줄이기
3. 번들 ID·버전 정리, Hardened Runtime, universal 빌드 스크립트
4. Apple Developer Program 가입 후 Developer ID 서명·공증과 GitHub Releases 배포

## 개발 기록

- `Doc/SPEC.md`(제품 사양), `Doc/IMP-PLAN.md`(구현 계획과 결정 기록), `Doc/TODO.md`(진행 상황)
- `Doc/BLOG-NOTES.md`: 기술 블로그용 정리(근거 파일 링크 포함)
- `Preview/`: 디자인 시안과 측정 스크립트·이미지(`Preview/README.md` 참고). 일부 과거 스크립트는 현재 코드로 실행되지 않으며 결과 이미지만 보존합니다.

## 개발 방식

설계·구현·테스트 작성과 디자인 시안 제작에 **Claude Code**와 **Codex**를 개발 보조 도구로 활용했습니다. 요구사항 결정, 시안 선택, 실제 메뉴 막대 확인은 개발자가 직접 했고, 각 결정과 검증 기록은 `Doc/IMP-PLAN.md`에 남겼습니다.

## 라이선스

[MIT](LICENSE) © 2026 jbbdyee
