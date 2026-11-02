## 확정된 v0.4.0 배포 정책 (2026-11-02)

사용자 결정으로 v0.3.0과 동일한 ad-hoc 서명 방식을 사용한다. 아래의 Developer ID·공증·M1 실기기·장시간 호출 검증은 미완료 사실과 향후 개선 항목이며 이번 배포 파일 준비의 차단 조건으로 취급하지 않는다. 릴리즈 노트에는 macOS 보안 경고, M1 미검증, 실험적 SDK 호출 제한·비용 불확실성, 외부 공식 Claude CLI 의존성·statusLine 대체를 명시한다. 설치본 교체·main 병합·Push·GitHub Release는 사용자의 최종 확인 전까지 진행하지 않는다.

## v0.4.0(6) 통합 후보 반영 (2026-11-02)

이전 점검의 버전 제안을 통합 브랜치에서 Info.plist 0.4.0(6)과 CHANGELOG 미배포 초안으로 반영했다. 공개 v0.3.0(5)과 설치 앱은 그대로다. 팝오버 중첩 방지 후보를 함께 포함하며 M1 실기기 수정 검증은 보류한다. 아래 LaunchServices·Node/SDK·서명 점검은 당시 읽기 전용 결과다. 릴리즈 전 필수 게이트는 여전히 미완료다. 이번 통합 후보의 전체 XCTest 457개와 Node 정책 11개는 통과했으나, Debug·Release 별도 빌드는 샌드박스 SwiftUI 매크로 서버 오류 뒤 한 번의 승인된 승격 실행에서 모두 성공했다.

# Claude 60초 갱신 배포 준비 점검 (2026-11-02)

이 문서는 릴리즈 초안이다. 현재 설치·공개 버전은 v0.3.0(5)이며 앱 버전, 설치본, 태그, Release를 변경하지 않았다. 이전 단계의 전체 XCTest 454개, Node 정책 테스트 11개, 일반 Debug·Release 및 개발 릴리즈 점검 결과를 재사용했다. 이번 점검에서 제품 코드를 변경하거나 실계정·모델 요청을 실행하지 않았다.

## LaunchServices 읽기 전용 조사

- `/Applications/Tokenly.app`의 Info.plist는 `io.github.jbbdyee.tokenly`, 0.3.0(5)이고 LaunchServices에도 정확히 그 경로가 등록돼 있다.
- 같은 제품 ID의 등록은 190개다. 이 중 `/private/tmp` 아래 157개와 그 밖의 이전 빌드·백업 경로 32개가 있으며 설치 경로는 1개다. 이전 릴리즈 점검의 임시 사본 경로 3개도 등록돼 있다. 이는 앱 선택이 모호해질 위험이지, 현재 설치본이 잘못 실행된다는 증거는 아니다.
- 샌드박스 내부의 `lsregister -dump`는 앱 항목이 없는 별도 DB를 보여 판정할 수 없었다. 읽기 전용 승격 조회에서 위 경로·건수를 확인했다.
- 정리하려면 먼저 설치본의 등록과 실행 경로를 다시 확인하고, **실제 남아 있는** 임시 사본만 목록화해야 한다. 사용자 승인 후 해당 경로만 개별 처리하고 설치본 등록을 다시 확인한다. 같은 ID를 한꺼번에 등록 해제하거나 LaunchServices 캐시를 초기화하지 않는다. 이번에는 삭제·등록 변경을 하지 않았다.

## 빌드 입력과 재현성

- `scripts/release.sh`는 [공식 Node v24.22.1 배포 아카이브](https://nodejs.org/en/download/archive/v24.22.1)의 macOS arm64/x64 파일명을 요구하고 두 SHA-256을 코드에 고정한다. 현지 `/private/tmp/tokenly-claude-portable-node-v24.22.1`의 두 파일은 고정 해시와 일치했다. 아카이브 원본의 재다운로드나 공식 체크섬 재조회는 이번에 하지 않았다.
- Claude Agent SDK는 `experiments/claude-usage-refresh/package.json`과 lockfile v3에 0.3.169로 고정돼 있고 npm 패키지 무결성 필드가 있다. `npm ci --omit=dev --omit=optional --ignore-scripts`로 helper를 패키징한다.
- 깨끗한 빌드 머신에는 Xcode/macOS SDK, `lipo`·`codesign`·`shasum`, 호스트 Node와 npm, 위 Node 아카이브 2개, 잠금 파일의 npm 패키지를 받을 수 있는 접근 또는 검증된 캐시가 필요하다. `TOKENLY_CLAUDE_NODE_ARCHIVES`로 아카이브 위치를 지정할 수 있다. 앱 실행 때는 번들 Node/SDK/helper를 사용하므로 Homebrew Node 경로를 요구하지 않지만, 공식 Claude CLI 설치·로그인은 별도 외부 의존성이다. CLI가 없거나 실행 불가하면 기존 statusLine 대체 경로가 유지돼야 한다.
- SDK 설치가 호스트 `npm` 명령과 레지스트리/캐시에 의존하며 아카이브를 스크립트가 자동 확보하지 않는다. 완전 오프라인 클린 빌드는 미검증이다. 개발 점검 ZIP의 아키텍처·SDK 버전·서명·압축 동일성은 이전 단계에서 확인했으며 다른 Mac 실행 검증은 아니다.

## 다음 버전과 CHANGELOG 초안

제안: **v0.4.0(6)**. Claude의 갱신 방식과 배포 의존성이 바뀌는 기능 릴리즈로, v0.3.0(5)을 유지한 채 검증 후 버전 파일과 CHANGELOG 본문을 변경한다. 제안일 뿐 아직 확정·릴리즈하지 않았다.

> ### 추가
> - Claude Code를 열지 않아도 공식 Claude Agent SDK의 실험적 usage API로 개인 구독의 5시간·7일 한도를 성공 후 60초 조건으로 조회한다. 인증은 기존 Claude CLI 로그인 상태를 SDK가 재사용한다.
> - Claude SDK 실행에 필요한 Node v24.22.1 universal 런타임과 SDK 0.3.169 helper를 앱에 포함한다. 공식 Claude CLI 설치와 로그인은 사용자 환경에 필요하다.
>
> ### 안정성
> - 단일 실행, 재시작 체크포인트, 실패 백오프 및 오류 시 자동 중단을 적용한다. 조회 실패·미지원 환경에서는 기존 성공 데이터와 Claude statusLine 대체 경로를 유지하며 오래된 값을 새 조회로 표시하지 않는다.
>
> ### 알려진 제한
> - SDK API가 실험적이며 공식 60초 최소 호출 간격, 장시간 호출 제한·비용·서버 데이터 신선도는 확인되지 않았다. 401/403/429의 실제 SDK 오류 형식도 확정되지 않았다. 다른 Mac, Intel, Developer ID 서명·공증, Gatekeeper와 설치본의 장시간 동작은 미검증이다.

## 서명·공증 준비 상태

- 현재 Xcode 프로젝트는 `CODE_SIGNING_ALLOWED=NO`이고 릴리즈 스크립트는 앱·내장 Node에 **ad-hoc** 서명한다. `notarytool`은 설치돼 있으나 키체인에서 유효한 Developer ID Application 서명 인증서는 0개였다(인증서 이름·비밀값 미출력).
- Developer ID 인증서와 배포 권한, Hardened Runtime 및 중첩 실행 파일 서명 순서, 공증 인증 수단, ZIP 공증·staple·Gatekeeper 검증 절차가 필요하다. 현재 스크립트의 ad-hoc 서명 검증만으로는 이 조건을 충족하지 않는다. 이번에는 실제 서명·공증 제출을 하지 않았다.

## 다른 Mac 실행 체크리스트

계정 조회는 별도 승인된 범위에서만 수행한다. 먼저 설치·실행 전에 다음을 순서대로 확인한다.

1. Apple Silicon과 **실제 Intel Mac** 각각에서 ZIP 체크섬, `lipo -archs Tokenly.app/Contents/MacOS/Tokenly` 및 `lipo -archs Tokenly.app/Contents/MacOS/TokenlyClaudeNode`가 두 아키텍처를 포함하는지 확인한다.
2. 번들 `Contents/Resources/ClaudeUsageSDK/claude-usage-helper.mjs`와 `node_modules/@anthropic-ai/claude-agent-sdk/package.json` 존재·버전 0.3.169, Node 실행권한, `codesign --verify --deep --strict Tokenly.app` 결과를 확인한다. Developer ID 빌드가 준비되면 `spctl --assess --verbose Tokenly.app`과 Gatekeeper 첫 실행도 확인한다.
3. 공식 Claude CLI가 설치·로그인된 경우에만 승인된 단발 조회로 5시간·7일 필드, 마지막 성공 시각, 60초 조건, 모델 메시지·양의 세션 비용 징후를 비민감 정보로 확인한다. 반복 조회와 장시간 운용은 별도 계획·승인 범위에 둔다.
4. CLI 미설치/실행 불가와 미로그인 상태를 각각 별도로 시험해 앱이 계속 실행되고 기존 statusLine 데이터가 있으면 대체 표시하며 인증 정보·원본 응답을 로그에 쓰지 않는지 확인한다. 재로그인이나 인증 초기화는 하지 않는다.
5. SDK 응답 실패·null·타임아웃·네트워크 끊김/복구를 모의 실행기로 확인해 마지막 성공값, stale 표시, 백오프·자동 중단, 재시작·절전 복귀 중복 차단을 확인한다. 실제 계정에서 오류를 유도하지 않는다.

배포 필수 게이트: Developer ID/Hardened Runtime/공증을 포함한 배포 절차, 클린 Apple Silicon·Intel Mac의 CLI/인증/대체 경로, 설치 후 사용자 화면과 반복 60초 호출의 제한·비용·신선도·안정성 검증. 이 게이트를 통과하기 전에는 v0.4.0을 배포 준비 완료로 표시하지 않는다.
