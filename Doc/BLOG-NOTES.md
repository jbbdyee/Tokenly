# Tokenly 기술 블로그 자료

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
