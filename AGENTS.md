# Tokenly 공통 작업 규칙

## 프로젝트 기준 경로

- Git 저장소: `/Users/jbbdyee/Developer/Tokenly-Workspace/Tokenly`
- Xcode 프로젝트: `src/Tokenly.xcodeproj`; 앱 소스: `src/Tokenly/`; 테스트: `src/TokenlyTests/`; 문서: `Doc/`
- 백업·릴리스·실험용 `.noindex` 폴더는 앱 소스가 아니다. 별도 요청 없이 이동하거나 정리하지 않는다.

## 기능과 모듈 경계

- 기존 AI 토큰 모니터링의 Codex·Claude·AGY 조회, 메뉴 막대 표시, 설정, 상태줄 연결, 로그인 항목을 보존한다.
- System Monitor 코드는 `src/Tokenly/SystemMonitor/`에 둔다. 측정 모델(Snapshot), 시스템 값 수집(Sampler), 화면 상태와 갱신(Store)의 책임을 분리한다.
- System Monitor가 AI Provider·Store·설정·상태줄 연결 코드를 직접 변경하거나 의존하지 않게 한다. 공통 UI 연결은 승인된 단계에서 앱 진입점에 최소한으로 추가한다.
- 측정할 수 없는 값은 임의의 0이나 추정치로 채우지 않는다. 새 앱·Xcode 프로젝트를 만들거나 기존 AI 파일을 대량 이동하지 않는다.

## Xcode와 검증

- 이 프로젝트는 새 Swift 파일을 자동 등록하지 않는다. `src/Tokenly.xcodeproj/project.pbxproj`의 파일 참조, 그룹, 앱 타깃 Sources 등록을 함께 확인한다.
- 가능하면 `xcodebuild -project src/Tokenly.xcodeproj -scheme Tokenly -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath <저장소 밖 임시 경로> build`를 실행하고 Release도 확인한다.
- 기존 테스트는 같은 프로젝트·스킴의 `TokenlyTests`를 `xcodebuild test`로 실행한다. 새 동작에는 결과를 검증하는 테스트를 추가한다.
- 빌드 산출물과 테스트 로그는 저장소 밖의 임시 경로에 둔다. 실패 시 기존 환경 문제와 변경에 따른 문제를 구분해 기록한다.

## 인수인계와 Git

- 작업 전 브랜치, HEAD, 미커밋 변경을 확인하고 기존 변경을 보존한다.
- 작업 후 `Doc/HANDOFF.md`에 완료 사항, 결정, 검증 결과, 남은 작업과 주의사항을 갱신한다.
- 보고에는 변경 파일과 이유, 실행한 빌드·테스트와 결과, 확인하지 못한 사항을 포함한다.
- 사용자 승인 없이 커밋하거나 Push하지 않는다.
