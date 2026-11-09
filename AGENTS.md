# Tokenly 공통 작업 규칙

## 프로젝트 기준 경로

- Git 저장소: 이 `AGENTS.md`가 있는 디렉터리(프로젝트 루트)
- Xcode 프로젝트: `src/Tokenly.xcodeproj`; 앱 소스: `src/Tokenly/`; 테스트: `src/TokenlyTests/`; 문서: `Doc/`(README 이미지는 `Doc/images/`)
- 앱 번들에 들어가는 Claude 사용량 helper(Node): `src/ClaudeUsageHelper/`. 릴리스·패키징 스크립트: `scripts/`(`release.sh`, `package-claude-helper.sh`, `build-popover-fixture.sh`).
- 시안·일회성 실험 스크립트·단계별 스크린샷은 저장소에 두지 않는다(2026-11-09 정리, 이전 자료는 Git 이력 `4fb4a59`). 실험 산출물은 저장소 밖 임시 경로에 만든다.
- 백업·릴리스용 `.noindex` 폴더는 앱 소스가 아니다. 별도 요청 없이 이동하거나 정리하지 않는다. `TokenlyRelease.noindex/claude-node-archives/`는 `release.sh`가 읽으므로 지우지 않는다.

## 기능과 모듈 경계

- 기존 AI 토큰 모니터링의 Codex·Claude·AGY 조회, 메뉴 막대 표시, 설정, 상태줄 연결, 로그인 항목을 보존한다.
- System Monitor의 요구사항·구현 현황·구현 순서는 `Doc/SYSTEM-MONITOR.md`를 기준으로 한다.
- System Monitor 코드는 `src/Tokenly/SystemMonitor/`에 둔다. 측정 모델(Snapshot), 시스템 값 수집(Sampler), 화면 상태와 갱신(Store)의 책임을 분리한다.
- System Monitor가 AI Provider·Store·설정·상태줄 연결 코드를 직접 변경하거나 의존하지 않게 한다. 공통 UI 연결은 승인된 단계에서 앱 진입점에 최소한으로 추가한다.
- 측정할 수 없는 값은 임의의 0이나 추정치로 채우지 않는다. 새 앱·Xcode 프로젝트를 만들거나 기존 AI 파일을 대량 이동하지 않는다.

## Xcode와 검증

- 이 프로젝트는 새 Swift 파일을 자동 등록하지 않는다. `src/Tokenly.xcodeproj/project.pbxproj`의 파일 참조, 그룹, 앱 타깃 Sources 등록을 함께 확인한다.
- 가능하면 `xcodebuild -project src/Tokenly.xcodeproj -scheme Tokenly -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath <저장소 밖 임시 경로> build`를 실행하고 Release도 확인한다.
- 기존 테스트는 같은 프로젝트·스킴의 `TokenlyTests`를 `xcodebuild test`로 실행한다. 새 동작에는 결과를 검증하는 테스트를 추가한다.
- 빌드 산출물과 테스트 로그는 저장소 밖의 임시 경로에 둔다. 실패 시 기존 환경 문제와 변경에 따른 문제를 구분해 기록한다.

## 역할과 기록

- 역할: Claude가 구현하고 Codex가 독립 검증·리뷰를 맡는다. 승인된 작업 범위를 임의로 넓히지 않는다.
- v0.3.0까지의 기술 블로그 원문은 Git 커밋 `81afae9`의 `Doc/BLOG-NOTES.md`에 보존했다(블로그 작성 완료로 저장소 밖 사본·#4 자료는 2026-11-09 삭제). 이후 기술적 제약, 예상과 다른 결과, 오류 분석·해결 과정은 `Doc/HANDOFF.md`에 기록한다. 확인된 사실과 추정을 구분하고 재현하기 어려운 수치와 방법을 남긴다. 블로그 글 자체는 별도 요청이 있을 때만 쓴다.
- 블로그에 쓸 만한 화면이나 로그는 보고서에 `📸 캡처 추천`으로 표시한다. 화면, 실행 명령, 시점, 설명할 핵심을 함께 적는다. 이미 끝난 작업은 기존 기록을 우선 쓰고 캡처만을 위해 다시 실행하지 않는다. API 키, 토큰, 사용자 정보, 일련번호, 사용자 이름이 들어간 경로는 공개하지 않는다.
- 단계별 보고에는 구현·테스트 결과, 발견한 문제와 해결 과정, 남은 제약, 블로그 핵심, 캡처 추천, 문서 업데이트 내역, 다음 작업 제안을 포함한다.

## 인수인계와 Git

- 작업 전 브랜치, HEAD, 미커밋 변경을 확인하고 기존 변경을 보존한다.
- 작업 후 `Doc/HANDOFF.md`에 완료 사항, 결정, 검증 결과, 남은 작업과 주의사항을 갱신한다.
- 보고에는 변경 파일과 이유, 실행한 빌드·테스트와 결과, 확인하지 못한 사항을 포함한다.
- 사용자 승인 없이 커밋하거나 Push하지 않는다.
