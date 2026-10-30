# Tokenly 작업 인수인계

## AGY print `/usage` 구조 확인 (2026-10-30, 추가 단일 실행)

- 시작 `main` HEAD `2278d5a`, 미추적 GPU 로그 2개 외 변경 없음. 공식 변경 기록의 모델 턴·쿼터 미소비 설명과 설정의 `disableSlashCommands` 부재(기본 false)를 확인하고, 승인된 CLI 명령을 임시 cwd에서 정확히 1회 실행했다. 종료 코드 0, 유효 JSON, 약 6.77초, stderr·추가 인증 요구 없음. `num_turns`와 `usage` 숫자 필드가 모두 0이라는 불리언 검사도 참이었다. 원본 JSON·실제 사용량·계정·토큰은 출력·저장하지 않았다.
- `command.data` 아래 항목 배열의 각 항목에 `buckets` 배열이 있고, 버킷은 `name`·`description`·`window`·`reset_time` 문자열과 `remaining_fraction` 숫자를 갖는다. 검사한 식별자에서 기존 statusLine 주간 버킷 두 종류와 weekly 표식은 확인, 5시간 표식은 미확인이다. statusLine은 `quota` 맵의 `remaining_fraction`·`reset_time`을 사용하므로 직접 JSON의 해당 필드를 변환하면 관찰된 주간 버킷의 메뉴 막대 잔여값을 구성할 후보가 있다. 5시간 한도나 모든 계정의 동일 구조는 보장되지 않는다.
- 다음 구현 단계는 별도 범위에서 버킷 선택·리셋 시각 파싱·계정별 구조 계약을 확인하고, 기존 statusLine을 유지한 채 직접 조회 Provider와 테스트를 설계하는 것이다. 초기 주기 후보는 5분, 중복 실행 방지·실패 시 마지막 성공 데이터 유지·5분 이상 재시도다. CLI 상태/인증 캐시 쓰기와 장시간 비용은 미측정이다. 이번에는 제품 코드·설치 앱·사용자 설정을 직접 변경하지 않았고 빌드·XCTest는 실행하지 않았다.

## AGY print `/usage` 단일 실행 검증 (2026-10-30)

- 이전 조사 문서 5개를 로컬 `main`에서 `c090954`로 커밋했다. GPU 실측 로그 2개는 미추적 상태로 보존했다. 설치 AGY CLI v1.4.10의 `--version`·`--help`에서 버전과 `-p`·JSON 출력 옵션을 확인했다.
- 공식 변경 기록은 `/usage` print 모드가 모델 턴·쿼터·대화 기록을 만들지 않는다고 설명한다. 사용자는 공식 CLI의 정상적 인증 캐시·상태 파일 쓰기 가능성을 포함한 단일 실행을 승인했다. 임시 cwd에서 명령을 정확히 1회 실행한 결과 종료 코드 0, JSON 객체, 약 6.65초, stderr 없음이었다. 추가 로그인이나 오류는 관찰되지 않았다. 원본 응답·계정·사용량·토큰은 기록하지 않았다.
- 비민감 구조는 `status`, `response`, `duration_seconds`, `num_turns`, `usage`(토큰 수치 필드), `data` 아래 배열 항목의 `name`·`buckets`까지 확인했다. 동적 키와 모든 값은 폐기해 5시간·7일 버킷, 잔여율·리셋 시각, 모델 턴 0을 실측으로 입증하지 못했다. 인증 캐시/설정/CLI 로그 쓰기와 대화 기록 영향도 미측정이다. 다음 개발은 실제 필드·버킷 매핑 계약을 별도 범위에서 확인한 뒤 결정한다. 제품 코드·설치 앱은 변경하지 않았고 빌드·XCTest는 실행하지 않았다.

`Doc/logs/`의 원본 성능 로그와 Workspace의 `.noindex` 보관소는 로컬 전용 자료다. 아래 절의 과거 미커밋·실행 PID·임시 경로는 당시 상태를 기록한 것이며 현재 Git·앱 상태는 별도 확인한다.

최종 갱신: 2026-10-30 (Codex 조건부 사용량 갱신 구현·검증, Codex)

## Claude Code·AGY 독립 조회 조사 (2026-10-30)

아래 AGY 미실행 기록은 위 단일 실행 **이전** 조사 상태다.

- 시작 `main` HEAD `85856cc`, GPU 실측 로그 2개는 미추적 보존. 기존 외부 Provider는 300초마다 Claude·AGY 상태줄 로컬 파일만 재읽어, 서비스가 새 이벤트를 보내지 않으면 서버 최신값을 독립 조회하지 못한다. 회색 오래된 데이터 표시와 제품 코드는 변경하지 않았다.
- 설치 CLI 도움말: Claude Code v2.1.292에는 개인 구독 한도 비대화형 명령이 보이지 않았다. 공식 `/usage`는 세션 화면, statusLine 한도는 첫 API 응답 뒤 조건부 제공된다. `claude -p`는 모델 질문 경로라 자동 폴링에 사용하지 않는다. 조직 Analytics/Admin API는 개인 Pro/Max 현재 5시간·7일 한도와 별개다.
- AGY CLI v1.4.10. 공식 v1.1.10 변경 기록에서 `agy -p "/usage" --output-format json` 형태의 read-only 구조화 응답을 지원하고 agent turn·쿼터·대화 기록을 만들지 않는다고 확인했다. 실제 계정에서 명령을 실행하지 않아 출력 스키마·버킷 매핑·로그/설정/인증 쓰기 영향은 미검증이다. 이는 이전 대화형 `/usage`만 가능하다는 문서 판단의 후속 갱신이다.
- 다음 순서: 사용자 인증 영향 범위를 먼저 검토하고 비민감 출력만 허용하는 별도 AGY 실측 → 결과가 안전하고 안정적일 때 기능 브랜치·테스트 설계. Claude는 공식 개인 구독 조회 경로가 확인될 때까지 상태줄 유지. 이번 조사에서는 버전·도움말과 공식 문서만 읽었고 모델 요청, 로그인·설정 변경, 제품 코드 수정, 새 빌드·XCTest, Push·릴리즈는 하지 않았다.

## `main` 병합 전 최종 점검 (2026-10-30)

- 점검 시작 HEAD `6f592f2`, 브랜치 `feature/usage-refresh-label-and-sources`. 로컬 `main`과 `feature/ui-color-harmony`는 모두 `192580f`를 가리키며 이 기능 브랜치는 해당 커밋의 직계 후손이다(앞선 브랜치에 없는 커밋 10개, 반대 방향 0개). 따라서 **현재 로컬 참조 기준** fast-forward가 가능하고 병합 충돌은 예상되지 않는다. 원격 `origin/main`은 별도로 뒤에 있으므로 병합 직전 대상 브랜치 위치를 다시 확인한다.
- `main...HEAD` 변경은 Codex 조건부 갱신 관련 앱 소스 5개, 테스트 1개, 문서 6개(`SPEC`, `TODO`, `IMP-PLAN`, `HANDOFF`, `README`, `BLOG-NOTES`)다. UI 색상 브랜치 변경은 `main`에 이미 포함됐으며, 본 브랜치의 추가 10개 커밋 중 제품 코드·테스트 변경은 앞의 구현·검증 커밋에만 있다. 이후 문서 커밋들은 앱 소스와 테스트를 바꾸지 않았다. `git diff --check main...HEAD` 통과.
- 이번 세션 새 검증: 전체 Debug XCTest 393개 통과·실패 0·건너뜀 0 (`/private/tmp/tokenly-merge-readiness-20261030/Tests.xcresult`). Debug·Release 빌드 모두 성공. 산출물·로그는 저장소 밖 임시 경로에 두었고 설치 앱은 교체하지 않았다. `xcresulttool` 요약의 일반 샌드박스 읽기는 권한 오류였지만 승인된 승격 읽기로 결과를 확인했다. 코드·설정·인증 변경 없음.
- 남은 실사용 제약: 정확한 초 단위 자동 조회 간격, 절전 복귀, Codex app-server 응답의 서버 캐시 정책은 미검증. Codex 앱 팝오버 의존성 의심은 추가 사용자 관찰에서 재현 결함으로 확정되지 않았다. 기능 병합 검토는 가능하나 이 제약을 완료로 표시하지 않는다. GPU 실측 로그 2개는 미추적 상태로 보존하고 병합 대상에서 제외한다.

## Codex 앱 팝오버 의존성 의심 재평가 (2026-10-30, 조사 중단)

- 사용자는 Codex 앱의 사용량 팝오버를 열지 않으면 Tokenly 값이 갱신되지 않는 듯했고, Codex 팝오버를 연 뒤 Tokenly에도 변경값이 반영됐다고 보고했다. Tokenly 수동 버튼은 정상이다. 과거 닫힌 상태의 메뉴 막대 값 변화는 실제 사용자 관찰로 유지하지만, **Codex 앱과 독립적으로 서버 최신값을 가져온다는 결론은 철회**한다. 조회 시점 차이와 캐시 영향은 모두 미확정이다.
- 코드상 타이머 조건 검사, CLI 자식 시작, initialize, RPC 응답 성공, 스냅샷 교체, 서버 최신성은 서로 다른 단계다. 공식 문서는 `account/rateLimits/read`가 rate limits를 가져온다고 설명하지만 매 호출의 캐시·네트워크 신선도를 보장한다고 적지 않는다. 조사 중단 전 개발 앱 CLI 자식 시작을 01:47:09·01:49:09 UTC에 관찰했으나 응답 성공은 측정하지 않았다.
- **새 사용자 반증:** Codex 앱 사용량 팝오버를 전혀 열지 않았는데도 Tokenly 메뉴 막대 잔여량이 새 값으로 자동 변경됐다. 실제 수치는 기록하지 않는다. 팝오버 의존성은 재현 결함으로 확정하지 않고 추가 진단을 중단한다. 조회 시점 차이는 가설이다. 제품 코드 변경 없음. 이 의심만으로 `main` 병합을 보류할 근거는 현재 없지만 정확한 간격·절전 복귀는 미검증으로 남는다.

## 백그라운드 화면 관찰 추가 (2026-10-30)

- 사용자가 별도 개발 앱의 팝오버를 닫은 상태에서 메뉴 막대 Codex 잔여량이 새 값으로 바뀐 것을 직접 확인했다. 마지막 성공 갱신 시각을 초 단위로 확인했고, 사용량이 같아도 시각은 새로 갱신되는 것을 봤다. 수동 버튼도 정상 동작했다. 실제 계정 수치나 초 단위 시각은 기록하지 않았다. 연속 성공 조회 사이의 초 단위 간격을 측정한 것은 아니다.
- 코드상 메뉴 막대 label은 팝오버와 별개로 `UsageStore.start()`를 시작하고, 메뉴 막대 값·갱신 시각은 성공 스냅샷에서 나온다. 사용자 관찰은 백그라운드 성공 스냅샷 반영의 직접 화면 증거이며, 과거 프로세스 재실행과 XCTest는 별도 근거다. 절전 복귀, 재열기 순간의 조건 적용, 정확한 자동 CLI 간격은 미검증. 제품 코드 변경 없음. 이번 문서 작업에서 새 테스트·빌드 없음.

## 개발 앱 팝오버 수동 확인 (2026-10-30)

- 추가 사용자 보고: 메뉴 막대 Codex 잔여량이 새 값으로 반영되고 수동 새로고침 버튼이 정상 작동했다. 실제 계정 수치는 기록하지 않는다. 아래의 수동 버튼 미검증 문구는 첫 화면 확인 당시 상태이며 현재는 사용자 수동 확인 완료다. 실패 전용 CLI의 300초 자동 재시도는 별도 실험에서 확인했다.
- 당시 백그라운드 범위: `TokenlyApp` 메뉴 막대 label의 `.onAppear`가 `UsageStore.start()`를 호출하고 타이머는 팝오버 표시와 독립적으로 실행된다. 과거 팝오버 조작 없이 관찰한 CLI 자식 2회는 백그라운드 프로세스 실행의 간접 근거였다. 그 시점에는 닫힌 상태의 성공 응답과 화면값을 함께 관찰하지 못했으나, 이후 위 사용자 화면 관찰이 추가됐다. 정확한 자동 조회 간격·절전 복귀는 여전히 미검증이다. 현재 추가 제품 코드 수정 필요성을 입증한 문제 없음.
- 사용자가 별도 개발 앱 팝오버 하단의 `Codex 1분 갱신`, 5시간·7일 사용량, `마지막 갱신 시간`의 10:24→10:25 변화를 직접 확인했다. 10:25 직후에는 변화가 없었고 약 20초 이상 지나 변경됐다고 보고했다. 화면 캡처와 초 단위 시각은 제공되지 않았다. 이는 사용자 화면 관찰이며 이전 세션의 프로세스 관찰과 구분한다.
- 코드 경로: `CodexUsageProvider.fetchSynchronously()`가 `account/rateLimits/read` 응답을 파싱할 때 `fetchedAt = Date()`로 스냅샷을 만들고, `UsageStore.refresh()`는 `provider.fetch()` 성공 시에만 스냅샷을 교체한다. 실패 시 마지막 성공 스냅샷을 유지한다. 따라서 **해당 개발 앱에서 시각이 실제로 변경된 것**은 새 Codex CLI 조회 성공의 근거다. 5시간·7일 값이 보였으므로 두 창을 포함한 응답이 파싱됐다. 서버 응답 원문·사용량 수치는 수집하지 않았다.
- 타이머는 앱 시작 기준 60초 간격으로 조건을 검사한다. 첫 조회가 타이머 등록 직전에 시작하고 성공 시각이 그보다 늦으면 첫 tick에서 성공 나이가 60초 미만이라 건너뛸 수 있다. 다음 tick은 약 120초 시점이다. 이전 관찰의 CLI 시작 120초 간격과 이번 사용자의 `10:25` 이후 지연 관찰은 이 구조와 양립한다. 정확한 최초·두 번째 조회 완료 시각이 없어 지연의 원인을 특정하거나 60초 경과 직후 실행 여부를 판정할 수 없다. 분 단위 표시는 초 단위 경과 측정에 사용할 수 없다.
- 이 첫 화면 관찰 시점에는 팝오버 닫기·재열기 조건과 수동 새로고침, 절전 복귀가 미검증이었다. 이후 수동 새로고침은 사용자가 정상 동작을 추가 확인했다. 기존 설치 앱·설정·인증은 조작하지 않았다. 제품 코드 변경 없음.

## 실계정 개발 앱 프로세스 검증 (2026-10-30, 조건부 승인 후)

- `feature/usage-refresh-label-and-sources`, 시작 HEAD `348e179`. 승인된 별도 앱 `/private/tmp/tokenly-real-codex-verify-20261030/Build/Products/Debug/Tokenly.app`(ID `io.github.jbbdyee.tokenly.realverify.20261030`)만 PID 55867로 실행했다. 런처는 공식 Codex CLI를 우선 PATH로 찾고 `CODEX_SQLITE_HOME=/private/tmp/tokenly-real-codex-verify-20261030/sqlite`를 지정했다. stdout/stderr는 `/dev/null`로 버려 계정·사용량·인증 응답을 남기지 않았다. 해당 임시 상태 경로에 파일 12개가 생성된 것은 확인했으나 내용은 읽지 않았다. 설치 앱 PID 66468은 실행 상태로 유지했다.
- 앱 시작 시각은 09:19:35 KST. 첫 CLI 실행은 프로세스 샘플링 시작 전에 끝나 직접 측정하지 못했다. 이후 개발 앱의 `codex` 자식 시작을 00:21:37·00:23:37 UTC에 2회 관찰했으며 간격은 120초다. 두 번째 관찰 자식 PID 56820은 0.25초 샘플링으로 약 0.92초 실행을 관찰했다(정확한 OS 실행 시간은 아님). 관찰한 두 프로세스는 겹치지 않았다. 60초 타이머의 검사와 CLI 실행은 같지 않다. `UsageStore`는 성공 직후 다음 tick의 나이가 60초 미만이면 건너뛰므로 120초 실행 간격은 구현과 양립한다. 이 실행 간격은 실패 후 타이머 300초 backoff가 적용되지 않은 상태임을 시사하지만 UI의 실제 사용량 성공값과 마지막 성공 시각은 직접 확인하지 못했다.
- 약 135초간 440개 `ps` 표본에서 개발 앱 CPU 순간값 0.0~5.6%, RSS 86,080~86,560 KiB였다. 이어진 약 80초 관찰에서 앱 CPU 0.0~8.8%, RSS 86,352~86,464 KiB였다. 이는 앱 전체 표본이며 실제 CLI의 CPU·RSS는 수집하지 못했다. 초기 CLI 소요 시간도 미측정이다. 장시간 안정성 결론으로 확대하지 않는다.
- macOS 컴퓨터 사용 도구는 `Sky Computer Use native pipe startup failed`로 연결되지 않았다. 따라서 팝오버 재열기·수동 새로고침·화면의 마지막 갱신 시각 및 실제 사용량, 절전 복귀는 미검증이다. 기존 XCTest는 조건 로직의 자동 테스트 증거로만 유지한다. 설정 변경 조작은 하지 않았으나 CLI 자동 토큰 갱신 여부와 UI 인증 오류 여부는 확인할 수 없었다. 개발 앱 PID 55867만 종료했고 설치 앱 PID 66468은 계속 실행 중이다. 제품 코드 변경 없음.

## 실사용 환경 기반 1분 갱신 검증 준비 (2026-10-30, 실행 승인 대기)

- 브랜치 `feature/usage-refresh-label-and-sources`, 시작 HEAD `4ffd3f2`. GPU 실측 로그 2개는 미추적 상태로 보존. 기존 `/Applications/Tokenly.app`을 종료·교체하지 않았고 root 진단과 기존 EPERM 재현은 중단했다.
- Debug 개발 앱을 저장소 밖 `/private/tmp/tokenly-real-codex-verify-20261030/Build/Products/Debug/Tokenly.app`에 성공적으로 빌드했다. bundle ID는 `io.github.jbbdyee.tokenly.realverify.20261030`으로 설치본 `io.github.jbbdyee.tokenly`와 다르다. `/private/tmp/tokenly-real-codex-verify-20261030/launch-review.sh`는 **준비만** 했고 실행하지 않았다. 스크립트는 공식 CLI를 찾는 PATH와 공식 `CODEX_SQLITE_HOME`의 임시 DB 경로만 설정한다. 실제 `CODEX_HOME`·`HOME`은 유지한다.
- 코드상 앱 시작의 `ProviderDisplaySettings`와 시스템 위젯 선택은 `.standard` UserDefaults를 읽는데 번들 ID가 달라 도메인이 분리된다. 새 도메인의 기본값에서 Claude·AGY 표시는 꺼져 있어 상태줄 파일 재읽기는 시작되지 않는다. 설정 화면을 열면 상태줄 파일 존재 여부를 확인할 수 있고, 버튼을 조작하면 로그인 항목·연결·Keychain 값이 바뀔 수 있으므로 테스트 중 설정 화면은 열지 않는다. `UsageStore.start()`는 앱 표시 시 Codex CLI `app-server`를 시작한다.
- [공식 Codex 인증 문서](https://learn.chatgpt.com/docs/auth)에 따르면 CLI 로그인 캐시는 파일(`~/.codex/auth.json`) 또는 OS credential store에 있고, ChatGPT 로그인 토큰은 사용 중 자동 갱신될 수 있다. [공식 환경변수 문서](https://learn.chatgpt.com/docs/config-file/environment-variables)의 `CODEX_SQLITE_HOME`은 SQLite 상태만 임시 경로로 옮긴다. 따라서 실사용 환경에서 첫 조회를 실행하면 **기존 Codex 인증 캐시/Keychain이 CLI에 의해 갱신될 가능성은 남는다**. 인증 파일 복사·직접 읽기·로그 출력은 하지 않지만 불변성은 보장할 수 없다. 이 영향 때문에 앱을 아직 실행하지 않았다.
- 이번 세션 검증: 격리 Debug 빌드 성공, 별도 ID·경로 확인, 실행 스크립트 `/bin/sh -n` 통과. 실제 app-server initialize·사용량 성공 조회·60초 자동 갱신·팝오버·수동·절전 복귀 및 실제 CLI 비용은 **미검증**이다. 이전 XCTest 393개 통과와 실패 전용 CLI 300초 재시도는 별도 세션의 결과다. 제품 코드 변경 없음. 다음 단계는 이 인증 캐시 자동 갱신 가능성을 사용자에게 제시하고 실행 승인을 받은 뒤, 응답 내용을 기록하지 않고 개발 앱만 실행·관찰하는 것이다.

## 남은 EPERM 진단 경로 점검 (2026-10-30)

- 이번 세션 시작: `feature/usage-refresh-label-and-sources`, HEAD `79311f4`; GPU 원본 로그 2개 미추적 상태 보존. 동일한 실계정 `app-server` 실패 실행은 반복하지 않았다. CLI 버전은 여전히 `0.164.0-alpha.11.1`이다.
- Apple의 [파일 시스템 사용량 진단](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/FileSystem/Articles/FileSystemCalls.html)에 따르면 `fs_usage`는 파일 syscall·오류를 보여 주지만 root 권한이 필요하다. 현재 `fs_usage`는 종료 코드 1로 실행되지 않았고 passwordless `sudo -n`도 사용할 수 없었다. 보안 설정이나 sudo 구성을 바꾸지 않았다.
- Apple의 [샌드박스 위반 진단](https://developer.apple.com/documentation/security/discovering-and-diagnosing-app-sandbox-violations)에 따라 `log show --info --debug`에서 `Sandbox:` 이벤트를 검사했다. 처음 `codex` 문자열이 포함된 이벤트는 **Tokenly의 app-server가 아니라 `logd_helper`의 Codex 앱 자료 읽기 거부**였다. 진단 명령 자체의 검색 문자열도 로그에 나타나므로 필터 결과만으로 당사 프로세스 거부라고 판단하면 안 된다. 이번 app-server의 두 번째 EPERM에 대응하는 PID·syscall·경로는 통합 로그에서 확인하지 못했다.
- 설치본 `/Applications/Tokenly.app`은 bundle ID `io.github.jbbdyee.tokenly`, 버전 `0.2.0`/빌드 4이며 실행 중이다. 검사한 서명 출력에는 App Sandbox entitlement가 나타나지 않았다. 이전 격리 Debug 앱은 별도 bundle ID와 `/private/tmp` 경로, 추가 `sandbox-exec` 홈 접근 제한 및 임시 CLI를 사용했다. 설치본에는 그 자식 제한을 적용하지 않았다. 설치본의 Codex 사용량 조회 성공 여부는 프로세스 실행 상태와 코드만으로 판정할 수 없고, 사용자 설정·화면을 읽거나 앱을 조작하지 않았다.
- 현재 확인된 위치는 첫 번째 `~/.codex` SQLite 상태 DB 초기화뿐이다. `sqlite_home` 분리 후 남은 EPERM은 **경로·시스템 호출 미확정**. root 추적이나 추가 권한 없이 안전하게 확인할 수 있는 수단을 확보하지 못했으므로 실제 계정 조회·60초 갱신은 계속 미검증이다. 제품 코드·설치 앱·로그인 상태 변경 없음. 새 빌드·XCTest도 실행하지 않았다.

## Codex app-server 권한 오류 조사 (2026-10-30, CLI 0.164.0-alpha.11.1)

- 시작 상태: `feature/usage-refresh-label-and-sources`, HEAD `c62c874`; GPU 실측 로그 2개는 미추적 상태로 보존. 설치 앱·설정·Keychain·Codex 로그인 상태는 변경하지 않았다. CLI는 `/opt/homebrew/bin/codex`의 `0.164.0-alpha.11.1`로 앞선 기록의 `0.163.0-alpha.11`에서 달라졌다.
- 실제 홈 쓰기 전부 차단, `.codex` 읽기 허용, 기본 SQLite 위치인 조건에서 `app-server --listen stdio://`는 initialize 응답 전 종료 코드 1로 실패했다. 민감한 줄을 제거한 stderr는 `~/.codex` 아래 SQLite state runtime 초기화 실패를 가리켰다. 따라서 **첫 번째 확인된 실패 위치는 SQLite 상태 DB 초기화**다. 로그인 유효성이나 네트워크 요청에는 도달하지 않았다.
- [공식 설정 참조](https://learn.chatgpt.com/docs/config-file/config-reference)의 `sqlite_home`을 `/private/tmp/tokenly-codex-sqlite-20261030`으로 지정하면 이 구체적 오류는 없어졌지만, 다음 `Operation not permitted (os error 1)`로 여전히 initialize 전에 종료했다. `CODEX_HOME`을 실제 `.codex`로 명시하고 `HOME`·`TMPDIR`을 임시 경로로 바꾸면 `.codex` 정규화 단계가 거부됐다. 홈 상위 경로의 메타데이터 읽기만 허용해도 일반 EPERM이 남았다. **두 번째 실패의 정확한 syscall·경로는 미확정**이다. macOS 통합 로그는 Codex 거부 경로를 노출하지 않았고 `fs_usage`는 이 권한에서 실행되지 않았다.
- 대조군: 실제 홈 접근을 차단한 채 빈 임시 `CODEX_HOME`, 임시 `HOME`·`TMPDIR`, 임시 `sqlite_home`을 쓰면 app-server `initialize`가 성공했다. 이는 app-server 실행 자체와 임시 SQLite 경로가 동작함을 보여주지만, 인증이 없는 홈이라 실제 사용량 조회 증거는 아니다. `log_dir`은 공식적으로 별도 지정 가능하나 plaintext 로그 가능성을 고려해 이번에는 사용하지 않았다.
- 안전한 실계정 검증 환경은 **부분적으로만 준비**됐다. SQLite 쓰기는 임시 경로로 분리할 수 있지만 실제 `.codex`를 읽기 전용으로 사용하는 초기화는 성공하지 못했다. 인증 파일 복사·원본 수정·홈 쓰기 허용은 하지 않았다. 실제 사용량 최초 조회, 성공 후 60초 자동 재조회, 화면 시각·중복 요청은 미검증. 제품 코드 변경·새 빌드·XCTest 없음. 다음은 사용자 승인된 진단 환경에서 두 번째 EPERM의 경로를 비밀정보 없이 확인하는 일이다.

## 실제 Codex 인증 재사용 안전성 점검 (2026-10-30)

- 브랜치 `feature/usage-refresh-label-and-sources`, HEAD `4bebea2`. 앞선 세션의 문서 6개 미커밋 변경과 GPU 원본 로그 2개를 보존했다. `/Applications/Tokenly.app`은 변경하거나 종료하지 않았다.
- 설치된 공식 Codex CLI는 `/opt/homebrew/bin/codex`, 버전 `0.163.0-alpha.11`이다. 자식 `sandbox-exec`에서 실제 홈 쓰기를 전부 거부하고 `.codex` 읽기만 허용한 뒤 `app-server --listen stdio://`의 `initialize`를 시도했다. CLI는 응답 전에 약 14~16ms 만에 종료 코드 1로 끝났고, stderr는 메모리에서 권한 오류 여부만 판정한 뒤 버렸다. 인증 파일과 RPC 원문은 읽거나 출력·저장하지 않았다. 같은 제약에서 `codex --version`은 실행됐다. 따라서 인증 성공/실패 자체보다 app-server 초기화 단계의 쓰기 제한이 우선 장애다. 정확한 쓰기 대상은 확인하지 않았다.
- 이 제약을 풀면 기존 사용자 설정·로그인 상태의 쓰기 여부를 보장할 수 없어, 실제 인증을 사용하는 테스트 앱은 실행하지 않았다. 최초 성공 조회, 성공 후 60초 재조회, 마지막 성공 시각, 팝오버·수동·중복·절전 복귀 실제 동작과 실제 CLI 시간·CPU·메모리는 모두 미검증이다. 이전 실패 전용 임시 CLI의 300초 재시도 관찰과 XCTest 393개는 별도 증거다. 이번 세션에는 빌드·XCTest를 새로 실행하지 않았다.
- 제품 코드 수정은 필요하다고 판정하지 않는다. 후속 실제 앱 검증은 Codex CLI가 기존 홈에 무엇을 쓰는지 비밀정보 없이 확인하고, 허용 가능한 임시 경로 전환 방법이 확인된 후 진행한다. 사용자에게 기존 앱·설정·인증 변경을 요구하지 않는다.

## 격리 macOS 앱 실행 검증 (2026-10-30, 커밋 `4bebea2` 이후)

- `Debug` 앱을 저장소 밖 `/private/tmp/tokenly-live-isolated-20261030/Build/Products/Debug/Tokenly.app`에 빌드했다. 번들 ID는 `io.github.jbbdyee.tokenly.livecheck.20261030`이다. `sandbox-exec` 자식 프로세스가 실제 사용자 홈의 읽기·쓰기를 거부함을 실행 전에 확인했고, 실패 전용 임시 `codex`를 PATH 앞에 뒀다. `HOME`만 바꿔도 `NSHomeDirectory()`는 실제 홈을 가리키므로 이 차단이 필요하다. 실제 인증·Keychain·Claude/AGY 상태줄 및 설정 변경 없음. 설치 앱 PID 66468은 실행 상태로 유지했다.
- 테스트 앱 PID 48673은 실제 macOS 프로세스로 약 5분 51초 실행했다. 임시 CLI 시작은 2026-10-29 21:26:24 UTC와 21:31:24 UTC, 간격 300초였다. 첫 60초 tick에서는 CLI를 다시 실행하지 않았다. 로그의 21:27:56 UTC 실행(PID 48835)은 임시 CLI 자체 프로토콜을 단독 점검한 것으로 앱 실행 횟수에서 제외한다. 앱에서 시작된 CLI는 관찰 구간에 2회다. 실패 후 자동 재시도 제한의 실제 타이머 동작을 확인했지만 성공 뒤 60초 주기 조회는 확인하지 못했다.
- 1분 동안 10초 간격 6회 `ps` 표본에서 앱 CPU 순간값은 0.0~0.3%, RSS는 85,840~86,224 KiB였다. 이후 5분 25초 표본 RSS는 83,072 KiB였다. 단발 CPU 4.5% 표본도 있어 장시간 안정성이나 Codex 실제 CLI 비용으로 일반화하지 않는다. 임시 CLI는 완료 로그를 남기지 않아 실행 시간은 측정 불가다. 초기 조회·5분 재시도 외 추가 CLI 시작은 관찰되지 않았다.
- 컴퓨터 사용 도구가 이 메뉴 막대 전용 테스트 앱을 앱 목록에서 식별하지 못했다. 팝오버 열기·닫기·재열기, 수동 버튼, 화면의 마지막 성공값 유지, 절전 복귀는 실제 UI에서 미검증이다. 격리 환경에는 실제 Codex 인증이 없으므로 성공 조회와 실제 서버 사용량도 미검증이다. 관련 상태 전이는 이전 세션 XCTest 393개 통과 결과와 구분한다. 테스트 앱만 종료했고 설치 앱은 종료하지 않았다.
- 이번 세션은 격리 Debug 빌드 성공. XCTest 전체 및 Release는 새로 실행하지 않았으며 직전 세션 결과를 재사용하지 않는다. 제품 코드 변경 없음. GPU 로그 2개 미추적 상태 보존. 다음에는 사용자가 새 빌드의 팝오버를 직접 조작할 수 있는 별도 격리 UI 경로를 마련하고 성공/실패 화면과 절전 복귀를 확인한다.

## 현재 세션 재검증 및 Git 권한 (2026-10-30)

- Codex 60초 조건, 실패 후 자동 300초 재시도, 수동 즉시 조회, 이전 성공값 유지, 중복 방지와 팝오버·절전 복귀 연결을 코드와 기존 테스트로 재확인했다. 제품 코드 변경은 없으며 기존 `UsageStore`·UI·테스트·문서의 미커밋 작업을 보존했다.
- 샌드박스 내 `xcodebuild test`는 SwiftUI 매크로 서버의 malformed response로 컴파일 전에 중단됐고, `simctl`도 CoreSimulatorService 연결 거부와 로그 경로 권한 거부를 보고했다. 같은 소스를 승인된 승격 실행으로 다시 빌드·테스트했을 때 전체 393개 XCTest와 Debug·Release 빌드가 통과했다. 따라서 이번 재현에서 확인한 원인은 샌드박스의 Xcode 서비스 접근 제한이며 Xcode 설치 자체의 손상은 확인되지 않았다.
- `git diff --check`는 통과했다. `.git/index.lock`은 없고 `.git`에 대한 샌드박스 쓰기 권한이 없어 일반 실행에서 lock을 만들 수 없다. 승인된 승격 실행으로 이번 작업 파일만 스테이징·로컬 커밋한다. GPU 원본 로그 2개는 미추적 상태로 유지한다.

## Codex 1분 조건부 갱신과 공식 CLI 재조사 (2026-10-30)

- Codex 타이머를 300초에서 60초로 줄이고, 팝오버 열림·절전 복귀와 같은 `refreshIfStale()` 조건을 사용한다. 마지막 성공 조회와 최근 시도가 모두 60초 이상 전이어야 시작한다. 실패 상태에서 타이머는 최근 시도 후 300초까지 재시도하지 않아 CLI 연속 실행을 제한한다. 팝오버·복귀의 60초 제한과 수동 즉시 조회는 유지한다. 진행 중 요청은 건너뛰고 실패해도 기존 성공 데이터·시각을 보존한다. 설치 앱·설정은 변경하지 않았다.
- 설치된 `claude` 2.1.292와 `agy` 1.4.8의 도움말에는 구독 한도를 비대화형으로 출력하는 전용 옵션·명령이 확인되지 않았다. 공식 상태줄과 대화형 사용량 화면의 근거 및 구현 보류 이유는 `Doc/IMP-PLAN.md` 68절에 기록한다. Claude·AGY 조회 코드는 변경하지 않았다.
- 현재 브랜치에는 앞선 Codex 조건부 갱신 커밋 `8048a45`와 `마지막 갱신 시간` 문구 변경 미커밋 작업이 함께 있다. GPU 실측 로그 2개는 미추적 상태로 보존한다. RAM-02는 조사 종료 상태를 유지한다.
- 최종 자동 검증: 전체 393개 테스트 통과(이전 392개 + 타이머/팝오버 상호작용 테스트 1개), Debug·Release 빌드와 `git diff --check` 통과. 테스트 빌드의 `RAMPopoverTests.swift:47` 불필요한 `try` 경고는 기존 경고다. 실제 설치 앱의 화면·절전 복귀 동작과 CLI 장시간 비용은 미검증이다.

## 갱신 시각 문구와 Claude·AGY 소스 조사 (2026-10-30, feature/usage-refresh-label-and-sources)

- Codex 팝오버·설정의 `마지막 성공`을 `마지막 갱신 시간`으로 바꾼다. 기존 성공 조회 시각을 그대로 쓰며 실패해도 보존한다. 이는 서버 집계 시각이 아니다. Claude·AGY `마지막 수신`은 상태줄 이벤트 시각이므로 유지한다.
- Claude·AGY의 5분 타이머·수동 갱신은 로컬 상태줄 파일 재읽기다. 공식 문서상 Claude Code는 상태줄 JSON에 구독 한도를 조건부 제공한다. AGY `/usage`는 대화형 TUI로 백엔드 갱신이 가능하지만, 안정적인 비대화형 출력 계약은 확인하지 못했다. 개인 계정 인증 재사용이나 비공식 API 접근은 구현하지 않는다. 관련 근거는 `Doc/IMP-PLAN.md` 67절에 기록했다.
- Codex의 60초 조건부 조회와 300초 타이머는 앞선 `8048a45`에 구현됐다. 새 조회 경로의 실기기 팝오버·절전 복귀 검증은 아직 필요하다. RAM-02는 조사 종료·원인 미확정·제품 수정 보류 상태다. GPU 실측 로그 2개는 로컬에 남긴다.
- 전체 자동 테스트 392개 통과, Debug·Release 빌드 및 `git diff --check` 통과. 이번 변경은 문구와 문서에 한정되고, 실제 설치 앱의 화면 확인은 수행하지 않았다. 기존 `RAMPopoverTests.swift:47`의 불필요한 `try` 경고가 테스트 빌드에서 다시 표시됐다.

## Codex 사용량 확인 시 조건부 갱신 (2026-10-30, feature/codex-refresh-on-attention)

- 기존 300초 자동 조회와 수동 새로고침은 유지한다. AI 팝오버 열림 및 `NSWorkspace.didWakeNotification`에서 마지막 성공 조회가 60초 이상 오래됐고 최근 조회 시도도 60초 이상 전일 때 Codex 조회를 시도한다. 진행 중 요청은 중복하지 않으며 실패해도 기존 snapshot·마지막 성공 시각은 보존한다.
- `UsageStore`와 AI 팝오버 연결, 가짜 시계·절전 알림을 쓰는 테스트만 변경했다. `ExternalProviderStore`·Claude·AGY 상태줄 수신 경로는 변경하지 않았다. 설치본 v0.2.0과 사용자 설정은 그대로다.
- 자동 검증: 관련 `TokenlyTests` 61개, 전체 392개 통과(기존 388개 + 신규 4개). Debug·Release 빌드와 `git diff --check` 통과. 실제 앱 팝오버 재열기·절전 복귀 조작은 미검증이다. GPU 원본 로그 2개는 미추적 로컬 자료로 보존한다. RAM-02는 조사 종료·원인 미확정·제품 수정 보류 상태를 유지한다.

## feature/ui-color-harmony 접근성 마무리 점검 (2026-10-29, Codex)

- **격리 검증:** 기존 가짜 Provider Debug 창(`dev.local.tokenly.colorpreview.caution2`)을 다시 열어 AX 트리에서 AI 새로고침·설정·Codex/Claude/AGY 펼침 버튼, 3서비스 한도 막대 이름과 수치(0.35/0.30/0.42)를 확인했다. Tab·Space 입력 뒤 포커스 이동/버튼 활성화 증거는 얻지 못했다. 실제 VoiceOver는 실행하지 않았다. 격리 창은 메뉴 막대 및 시스템 팝오버를 재현하지 않으므로 그 동작은 코드 점검 범위다.
- **코드 점검:** 시스템 설정 5개는 기본 Switch Toggle에 접근성 레이블이 있고, 메뉴 막대 항목은 `SystemWidgetDisplay.accessibilityText`를 붙인다. CPU/RAM/GPU Aurora와 Disk I/O 그래프는 접근성에서 숨김 처리한다. 현재 수치는 별도 텍스트로 노출되지만 60초 추세의 음성 대체 정보는 없다. Claude/AGY 막대는 네이티브 값이 AX 트리에 보였으나 Codex와 달리 명시적 퍼센트 발화 문자열은 없다.
- **자동 검증:** `SystemMonitorWiringTests`·`SystemWidgetPresentationTests`·`MenuBarSystemImageTests`를 독립 실행해 71개 통과, 실패·건너뜀 0(`/private/tmp/tokenly-a11y-review-escalated.xcresult`). 이는 실제 키보드/VoiceOver 검증이 아니다. 기존 `RAMPopoverTests.swift:47`의 불필요한 `try` 컴파일 경고가 재발했다. 최초 샌드박스 실행은 SwiftUI 매크로 실행 차단으로 빌드 실패했고 정상 Xcode 권한에서 재실행했다.
- **판정:** 아래 사용자 수동 결과로 AI 사용량과 스위치의 VoiceOver 기본 읽기는 확인됐다. 일반 Tab 탐색은 원인 미확정·미검증으로 남기며 결함/정상 단정 금지. 그래프 추세 대체 정보·정확한 퍼센트 발화 형식은 후속 개선/검증 후보. 설치본·macOS 14/15와 RAM-02는 이 검증 범위 밖이다.
- **후속 격리 준비(수동 확인 전):** `/private/tmp/tokenly-a11y-fixture-src`를 별도 번들 ID `dev.local.tokenly.a11y-fixture`·UserDefaults `dev.local.tokenly.a11y-fixture.settings`로 빌드(`/private/tmp/tokenly-a11y-fixture-build/Build/Products/Debug/Tokenly.app`). 실제 AI View와 시스템 설정 View를 나란히 표시하되 Provider는 가짜 데이터다. AX 트리에 다섯 스위치 이름·OFF 및 AI 한도 이름·값이 보였고 격리 CPU 토글 클릭은 OFF→ON→OFF로 복원됐다. Tab·Space 자동 입력에는 포커스/동작 변화가 없었다. 한 창에 나란히 둔 시안의 AX 교차 순서는 실제 제품의 읽기 순서가 아니다. 이후 사용자 수동 결과는 다음 항목에 기록했고 제품 소스·설정은 바꾸지 않았다.
- **사용자 수동 검증 완료(범위 제한):** 격리 앱에서 VoiceOver가 AI 서비스 이름·사용량과 시스템 설정 스위치 이름·ON/OFF 상태를 읽었다. Control+F2는 macOS 상단 메뉴 막대로 포커스를 옮겼다. Tab 여러 번으로 Codex 버튼에 포커스가 이동하지 않았다. Apple의 Mac VoiceOver 문서상 키보드 탐색 설정이 영향을 줄 수 있으나 현재 설정은 확인하지 않았다. 일반 키보드 탐색은 원인 미확정·미검증으로 기록하며 결함이나 정상으로 단정하지 않는다. 사용량의 정확한 퍼센트 발화 형식, Space/Return 활성화, 설치본과 macOS 14/15는 검증되지 않았다. 사용자 수동 검증은 이 지점에서 종료하고 추가 조작은 요청하지 않는다.
- **브랜치 마무리:** 색상 코드·자동 테스트(기존 전체 388개, 이번 관련 71개)·Debug/Release 빌드·격리 AI 주의 막대의 다크/라이트 실제 화면 및 위 범위의 접근성 확인은 기록돼 있다. 사용자는 CPU·배터리 변경 색의 **화면 밖 렌더 검증을 수용**하고 실제 앱 화면 확인을 후속으로 분리했다. 실제 화면 확인 완료로 표시하지 않는다. 남은 Git 정리는 기존 미커밋 문서의 색상·접근성 기록과 RAM-02 조사 기록을 논리적으로 구분하고 로컬 전용 `Doc/logs/`를 제외하는 것이다. 병합·Push·릴리즈는 사용자 승인 후 결정한다. 일반 Tab 탐색 원인, 그래프 추세 설명, 설치본·macOS 14/15는 별도 후속 검증으로 유지한다. 이번에는 제품 코드·커밋·Push·릴리즈를 변경하지 않았다.

## feature/ui-color-harmony 검증과 외부 사용량 불일치 조사 (2026-10-29, Codex)

### RAM 전체 사용량 차이 추가 증거 (2026-10-29, Codex)

- **[사용자 제공 동일 캡처의 값]** 물리 메모리 24GB(양쪽), 활성 상태 보기 사용된 메모리 18.00GB / Tokenly 16.59GB, 앱 9.30/9.31GB, 와이어드 2.73/2.73GB, 압축 4.55/4.55GB. Tokenly 전체는 자체 세부 항목의 합 16.59GB다. 캡처 원본은 이 조사에서 직접 열어 보지 않았다.
- **[코드 확인]** Tokenly는 `HOST_VM_INFO64`의 `(internal − purgeable) + wire + compressor_page_count`를 사용량으로 계산한다. 화면의 세부 항목이 거의 일치하므로 단순한 세부 카운터 매핑 오류보다 전체 정의 차이를 우선 조사한다. 현재 문서의 "활성 상태 보기와 같은 구성" 설명은 검증되지 않았으며, 계산 로직은 변경하지 않았다.
- **[독립 진단의 한계]** 이 개발 Mac의 한 시점 `vm_stat`에서 물리 메모리 16GiB와 페이지 카운터를 대조하면 사용량 약 14.03GB, 캐시 약 2.43GB, free 약 0.09GB 외에 약 0.63GB의 미분류 차이가 남았다. 이 값은 제보된 24GB Mac의 1.41GB와 다른 환경·시점의 관찰이며, 활성 상태 보기의 계산식이나 누락 영역을 증명하지 않는다. `speculative_count`는 `free_count`에 이미 포함되므로 중복 합산하지 않는다.
- **[다음 검증]** 같은 Mac에서 동일 시점의 원시 `HOST_VM_INFO64` 카운터·페이지 크기·물리 메모리와 활성 상태 보기의 전체·Cached Files를 함께 비교한다. 값·시각·macOS 버전만 받고 인증·계정 정보는 수집하지 않는다. Apple의 전체 집계식 또는 재현 가능한 누락 영역이 확인된 뒤 수정안과 회귀 테스트를 결정한다.
- **[RAM-02 실측]** 저장소 밖 읽기 전용 Swift 진단 `/private/tmp/tokenly_ram02_diagnostic.swift`로 이 개발 Mac(macOS 27.0.1, 16GiB)의 `HOST_VM_INFO64`를 1초 간격 3회 수집했다. Tokenly 식 사용량 14.095/14.117/14.170GB(십진 바이트 환산), Cached Files 후보 2.368/2.345/2.286GB, `total−used−cached후보−free` 잔차 0.603/0.597/0.596GB. 원시 페이지 수·UTC 시각은 `BLOG-NOTES.md` §9.3에 있다. 이 개발 Mac은 제보 캡처의 24GB Mac이 아니며, 이번 3회와 같은 시점의 활성 상태 보기 수치는 확보하지 못했다. Apple 전체 집계식·1.41GB 원인은 여전히 미확정이다. 제품 계산식·UI·테스트는 변경하지 않았고 설치 앱·사용자 설정도 건드리지 않았다.
- **[RAM-02 추가 비교·실측]** 사용자가 같은 화면의 16GB Mac 비교값(활성 상태 보기 13.88GB / Tokenly 13.29GB, 세부 양쪽 4.97+2.94+5.37GB, Apple Cached Files 2.05GB·스왑 5.85GB)을 제공했다. 캡처 시각은 없어 뒤이은 원시 측정과 동일 시점으로 취급하지 않는다. 이 개발 Mac에서 `date -u`, `vm_stat`, `sysctl -n hw.memsize`와 `HOST_VM_INFO64` 3회를 읽기 전용으로 실행했다. 새 3회에서 Tokenly 식 사용량 13,885,734,912 / 13,907,001,344 / 13,954,596,864B, 캐시 후보 2,576,318,464 / 2,550,693,888 / 2,492,710,912B, 잔차 약 0.604GB(십진)였다. 원시 카운터와 시각은 `BLOG-NOTES.md` §9.3 참조. 0.59GB 화면 차이의 원인·Apple 산식·계산 오류 여부는 미확정. 제품 코드·UI·앱·설정·브랜치·릴리즈는 변경하지 않았다.
- **[RAM-02 동시 측정 준비]** 저장소 밖 `/private/tmp/tokenly_ram02_simultaneous.swift`를 만들고 `swiftc -typecheck` 통과. 5초 준비 시간과 12회/1초 집계 출력으로 양쪽 GUI를 나란히 둔 캡처를 돕는다. 새 실측은 실행하지 않았으며 사용자 캡처·출력 도착을 기다린다. 제품 코드·UI·계산식은 변경하지 않았다.
- **[RAM-02 12회 분석, 후속]** 사용자가 `/private/tmp/tokenly-ram02-simultaneous.txt`를 생성하고 화면값 Apple 14.12GB / Tokenly 13.49GB, 세부 양쪽 약 4.40/3.10/5.98GB, Apple Cached Files 1.85GB를 제공했다. 12회 원시 로그에서 Tokenly 식 13.461~13.606GiB, 캐시 후보 1.726~1.855GiB, 잔차 0.601~0.631십진 GB. 화면의 Tokenly 전체와 가까운 #10도 앱·압축 세부값은 화면과 크게 달라 캡처 시각의 원시 샘플로 확정할 수 없다. 세부 분석은 `BLOG-NOTES.md` §9.3. Apple 공식 산식·잔차 정체·계산 오류 여부는 미확정; 수정·커밋·Push 없음. 위의 '실행 대기'는 당시 준비 단계 기록이다.
- **[RAM-02 갱신 경로 조사]** RAM ON일 때 전체 측정은 팝오버와 독립적인 CPU/RAM 공용 1초 타이머(0.1초 tolerance)에서 실행한다. 팝오버 열림은 TOP 5 수집만 제어하며 즉시 RAM 새 측정을 트리거하지 않는다. `MachSystemSampler`의 `sampledAt`은 RAM 읽기 전에 생성되고 Store는 Task 완료 후 `memory`를 게시한다. 상세 팝오버는 이 값을 구독하지만 RAM 읽기/게시 시각은 UI 또는 Store 속성으로 남지 않는다. 새 게시 전 기존 값이 보일 수 있으나 실제 지연은 미측정. 원시 12개 세부값 범위가 사용자 화면 세부값과 달라 1초 위상·반올림만으로 불일치를 입증할 수 없다. 우선 기존 캡처의 터미널 UTC·샘플 번호를 확인한다. 자세한 근거·후속 격리 진단안은 `BLOG-NOTES.md` §9.3. 제품 수정·커밋·Push 없음.
- **[RAM-02 표시 시각 연결 준비]** 기존 캡처에 보이는 #11(06:12:45.570Z)·#12(06:12:46.572Z)의 원시 세부값도 화면 4.41/3.10/5.98GB와 일치하지 않는다. 캡처에 번호가 보인다고 해당 독립 스크립트 샘플이 앱 화면에 게시된 것은 아니다. 저장소 밖 격리 Debug 복사본에서만 `sampleID`로 타이머 callback/건너뜀, Mach RAM 읽기, 계산 완료, Store 게시, View 관찰, 화면 프레임을 연결하는 최소 진단을 설계했다. 건너뛴 tick과 게시·렌더 지연을 분리하고 세부 3값 모두로 프레임을 대조한다. 설치 앱·제품 RAM 코드/UI·설정·브랜치는 변경하지 않았고 추가 측정도 아직 하지 않았다. 격리 조건과 판정 기준은 `BLOG-NOTES.md` §9.3 참조. 실제 지연, Apple 산식, 원인은 미확정이며 사용자에게 실행 방법을 제시한 뒤 측정 결과를 기다린다.
- **[RAM-02 격리 Debug 빌드·자동 검증]** 저장소 밖 `/private/tmp/tokenly-ram02-timing-src/src` 복사본과 `/private/tmp/tokenly-ram02-timing-build/Build/Products/Debug/Tokenly.app`을 준비했다. 번들 ID `dev.local.tokenly.ram02timing`, 별도 UserDefaults suite·Keychain 서비스·`TOKENLY_HOME`, RAM 전용 앱 진입점으로 기존 AI/설정/상태줄 시작 경로를 분리했다. 임시 계측은 같은 `sampleID`로 tick/skip, Mach 읽기, 계산, Store 게시, View 관찰을 UTC 밀리초·단조 ns·원시/집계 바이트와 함께 전용 로컬 로그에 기록한다. 격리 Debug 빌드 성공, `SystemMonitorStoreTests` 11개 통과(가짜 ID/skip 검사 1개 추가), 가짜 로그 검증기 self-test 통과. 실제 Mach·화면 타이밍은 **아직 미측정**이며 사용자가 실행하기 전에서 멈췄다. 실행 스크립트 `/private/tmp/tokenly_ram02_run_timing.sh`, 분석기 `/private/tmp/tokenly_ram02_verify_timing.py`; 구체적 사용법과 한계는 `BLOG-NOTES.md` §9.3. 원본 Swift 소스·RAM 계산식/UI, 설치 앱·사용자 설정, 기존 미커밋 `Doc/logs/`는 보존했다. 커밋·Push·릴리즈 없음.
- **[RAM-02 진단 앱 표시 문제 후속]** 사용자 실행으로 초기 진단 앱 PID 94549는 Mach 읽기·Store 게시 중임을 확인했으나 메뉴 막대 아이콘 가시성은 확인할 수 없었다. 격리 복사본만 명시적 `NSStatusItem` 텍스트 `RAM-02`와 자동으로 열리는 별도 RAM 진단 창으로 보완했다. v3 Debug 빌드 PID 96645, 번들 ID `dev.local.tokenly.ram02timing`; `status_item_created button=1`, 창 `onscreen=1`(340×334, 화면 위쪽 가운데), 매초 `view_observed` 로그 및 최신 실행 구간의 ID·세부 바이트 검증기 통과. 사용자에게는 메뉴 막대 탐색 대신 제목 `RAM-02 진단 — 격리 앱`인 창을 안내한다. 초기 `MenuBarExtra`의 정확한 비가시 원인은 미확정이며 픽셀 표시 시각·Apple 전체값 차이도 미확정. 이전 격리 앱만 정상 종료했고 설치 앱 PID 66468·색상 미리보기 PID 81277과 원본 제품/설정/브랜치는 유지. 상세 기록은 `BLOG-NOTES.md` §9.3.
- **[RAM-02 녹화/로그 실측 대조]** 사용자 제공 26.283초 MOV(UTC 07:16:45 시작)와 격리 앱 전용 로그를 대조했다. 녹화 구간 sampleID 311~336 26개 모두 수집→계산→게시→View 관찰 완료, skip/Mach 실패/바이트 불일치 0건. 계산 완료→Store 게시 중앙값 0.920ms·최대 2.943ms, 게시→View 관찰 중앙값 6.096ms·최대 13.302ms, 읽기 시작→View 관찰 최대 20.962ms. 대표 프레임 다섯 개의 격리 앱 전체+앱/와이어드/압축 표시값은 ID 313/318/323/328/333의 로그 반올림값과 맞았다. 같은 프레임의 Apple 전체−Tokenly 전체는 0.56~0.63GB, Apple 전체−Apple 세부 세 항목 합은 표시값 기준 다섯 프레임 모두 약 0.59GB. **이 녹화에서는 Tokenly 수집·게시 지연만으로 전체 차이를 설명할 근거가 없다.** Apple 전체 산식·추가 범주·픽셀 표시 시각은 미확정이며 제품 RAM 계산식/UI 수정·고정 보정값 없음. 원본 MOV는 프로세스/사용자 정보가 보여 저장소에 복사하지 않았다. 자세한 표·한계는 `BLOG-NOTES.md` §9.3.
- **[RAM-02 최종 원인 검토·판정]** Apple 공식 활성 상태 보기 설명은 전체/세부 항목의 의미만 제시하고 전체 산식은 공개하지 않는다. 공개 XNU는 internal/external/purgeable/wired/compressor/free 등 별도·중첩 가능 카운터를 제공하고 speculative가 free에 포함됨을 명시한다. 따라서 12회 raw 잔차 0.601~0.631십진 GB를 녹화의 Apple−Tokenly 0.56~0.63 화면 표기 GB와 동일한 메모리 범주로 지정할 수 없다. Apple 자체 전체−세부 합계 0.59GB(대표 5프레임)는 소수 둘째 자리 반올림(최대 약 0.02 단위)이나 앱 간 GB/GiB 차이만으로 설명되지 않는다. 26개 sampleID에서 Tokenly 전달 지연/불일치가 없으므로 이 구간의 Tokenly 게시 지연도 주원인 근거가 없다. Apple의 각 값 취득 시각과 전체 산식, 잔차의 정체는 **미확정**. RAM-02 상태를 **전체 차이 재현·원인 미확정·제품 수정 보류**로 둔다. 새 측정·계산식/UI 변경·보정값·커밋·Push·릴리즈 없음. 후속에는 공식 산식 또는 동시 raw/Apple 값으로 재현되는 반례를 확보한 뒤 테스트와 표시 정의 변경을 별도 검토한다. 근거·블로그 표현은 `BLOG-NOTES.md` §9.3 참조.
- **[RAM-02 조사 종료, 사용자 결정]** 최종 상태는 **조사 종료·원인 미확정·제품 수정 보류**. 26개 sampleID와 화면 대표 5프레임은 Tokenly 수집→View 경로를 검증하지만 Apple 전체 산식이나 약 0.6GB 차이의 메모리 범주를 규명하지 않는다. 0.6GB 보정, RAM 계산식, 제품 UI 설명 모두 이번에는 변경하지 않는다. **재조사 조건:** Apple의 공식 전체 사용량 산식 확인 또는 Tokenly 계산의 재현 가능한 구체적 반례 확보. 이전 단계의 측정 제안은 당시 기록이며 현재 진행 과제가 아니다. 격리 앱은 `/private/tmp/tokenly-ram02-timing-build-v3/Build/Products/Debug/Tokenly.app`, 계측 소스는 `/private/tmp/tokenly-ram02-timing-src/`, 이벤트 로그는 `/private/tmp/tokenly-ram02-timing-data/events.log`, 26개 ID 표는 `/private/tmp/tokenly-ram02-video-timing.tsv`, 12회 raw 로그는 `/private/tmp/tokenly-ram02-simultaneous.txt`; 로컬 임시 자료로 두고 삭제하지 않았다. 블로그용 사실·가설·미확정 구분은 `BLOG-NOTES.md` §9.3에 기록했다.

- **작업 시작 상태:** `feature/ui-color-harmony` / `d92858b`. 기존 미커밋 변경 7파일(주의 앰버·테스트·문서)과 미추적 `Doc/logs/`를 보존했다. 설치본 `/Applications/Tokenly.app`과 별도 색상 미리보기 앱은 실행 중이었으며 종료·교체하지 않았다. 색상 미리보기 번들 ID `dev.local.tokenly.colorpreview`, 표시 이름 `Tokenly 색상 미리보기`, AI 메뉴 막대 라벨에 `미리보기` 표식이 있다. Keychain 서비스와 Claude·AGY 수신 파일 경로는 임시 위치로 분리돼 있다. 이 앱의 실제 팝오버를 자동 조작하거나 보지는 못했다.
- **색상 확인:** Codex·Claude·AGY 막대는 모두 `UsageMenuView.color(for:)`를 사용한다. 주의(잔여 21~50%)는 다크 `#F4D39A`, 라이트 `#B37914`; 여유(50% 초과)는 기존 민트→블루→라벤더 오버레이, 부족(20% 이하)은 시스템 빨강이다. 임계값·파서·측정 로직은 변경하지 않았다. 지정된 라이트 트랙 `#E8E8E8`에 대한 계산 대비는 두 앰버가 각각 약 1.17:1·3.03:1이다. 실제 창의 tint·재질·가독성은 미검증이며 macOS 14·15의 8pt 트랙 높이도 미검증이다.
- **[AI 주의 막대 격리 실제 화면 후속 검증]** 위의 “실제 창 미검증”은 당시 상태다. 별도 `/private/tmp/tokenly-colorpreview-caution-src/`의 가짜 Provider와 실제 `UsageMenuView`로 Codex 35%/40%, Claude 30%, AGY 42%를 재현했다. 번들 ID `dev.local.tokenly.colorpreview.caution2`, 독립 UserDefaults suite, 빌드 `/private/tmp/tokenly-colorpreview-caution-build-v2/Build/Products/Debug/Tokenly.app`. macOS 27.0.1의 **활성** 격리 창에서 다크·라이트 앰버 막대, 텍스트, 트랙 구분과 가독성을 화면으로 확인했다. 비활성 창에서 모든 기본 `ProgressView` tint가 회색이 된 것은 활성 상태 기준 표식으로 확인한 macOS 렌더링 동작이며 색상 매핑 오류로 판단하지 않는다. 설치본 팝오버·정량 픽셀 대비·macOS 14/15는 미검증. 제품 소스/설치본/설정, 기존 미커밋 문서와 GPU 로그를 보존했고 제품 수정·커밋·Push·릴리즈는 하지 않았다.
- **독립 자동 검증:** 전체 `/private/tmp/tokenly-color-harmony-verify.xcresult`에서 **388개 통과·실패/건너뜀 0**, Debug·Release 빌드 성공. 이전부터 있던 `RAMPopoverTests.swift:47` 불필요한 `try` 경고가 보였다. `git diff --check` 통과. 이번에는 코드 설명의 옛 '주의 주황 유지' 주석과 문서의 변경 전 픽셀 비교/대비 수치를 실제 변경 상태에 맞게 바로잡았다. 제품의 계산 코드는 수정하지 않았다.
- **외부 사용량 제보 — 확인된 구현:** Codex는 `account/rateLimits/read`의 `rateLimitsByLimitId["codex"]`를 우선하고 없으면 `rateLimits`를 사용한다. `primary`·`secondary`를 위치만으로 5시간·7일이라고 단정하지 않고 `windowDurationMins`(300·10080)로 분류하며 `100 − usedPercent`를 잔여로 표시한다. Claude는 상태줄 `five_hour`·`seven_day`의 `used_percentage`를 같은 방식으로 변환하며 수신 후 15분 초과·이미 지난 초기화 시각을 최신값에서 제외한다. AGY는 각 `quota` 버킷의 `remaining_fraction × 100`을 표시하고 메뉴 막대 대표값은 버킷의 **최솟값**이다. Claude·AGY 조회 실패 시 이전 데이터는 별도 상태로 표시된다. RAM은 `(internal − purgeable) + wired + compressor`를 사용량으로, `external + purgeable`을 Cached Files로 계산한다. 이 값은 메모리 압박·프로세스 footprint·스왑과 서로 다른 지표다.
- **원인 미확정:** 외부 제보에는 서비스·계정·비교 화면·시각·윈도우/버킷·두 값이 없다. Codex CLI 계정과 비교 계정 불일치, `codex` 버킷이 없을 때의 상위 `rateLimits` 대체, Claude/AGY 수신 지연·이전 데이터, AGY 대표 최저 버킷과 특정 버킷 비교, RAM 지표·측정 시각 차이는 **확인할 가설**이지 원인으로 확정하지 않았다. 실제 인증·계정 파일과 라이브 응답은 읽지 않았다. 증거가 모이기 전 계산식은 바꾸지 않는다.
- **최소 진단 정보:** 서비스명, 비교한 공식 화면 이름, 두 화면의 같은 시각(시간대 포함)·값·사용/잔여 단위·5시간/7일 또는 버킷명, Tokenly의 '마지막 수신/성공' 시각과 '이전 데이터' 여부, 같은 계정인지 사용자가 확인한 결과를 요청한다. 계정 이름 대신 일치/불일치만 받고 토큰·쿠키·인증 파일·원본 응답은 요청하지 않는다. RAM은 비교한 Activity Monitor 항목명과 시각을 추가로 받는다.
- **다음 단계:** 색상 미리보기 앱에서 실제 다크·라이트 주의 막대의 색·대비를 사용자 확인한다. 외부 사용량 제보의 위 최소 정보가 오면 민감정보를 제거한 재현 fixture로 조사하고, 결함이 확인되면 테스트를 먼저 만든다. 데이터 정확성 조사 기록은 색상 변경 커밋과 분리한다. `test`·`main` 병합, Push, 릴리즈는 진행하지 않았다.

## Stage 6-14 v0.2.0 발행 후 문서와 브랜치 운영 (2026-10-29, Claude)

- **발행 상태(6-13B):** 태그 `v0.2.0`(주석 태그) → `b9089c8`, GitHub Pre-release "Tokenly v0.2.0 — System Monitor"(2026-10-29), 첨부 `Tokenly-0.2.0-macOS-universal.zip`(3,040,070 B, SHA-256 `8b4c2c27802e873fe6b03a9b9c333ef70b6b6a2e4d01e38961bc16d6159b34a1`)과 `.sha256`. 깨끗한 복제본에서 `release.sh --final 0.2.0`, 전체 테스트 386개 통과, 공개 URL에서 받아 체크섬 확인. v0.1.0 태그·Release는 작업 전 기록과 동일.
- **문서:** CHANGELOG 0.2.0을 발행으로, README 다운로드·설치를 v0.2.0(이전 버전 v0.1.0 안내)으로, 0.1.0 업데이트 안내·시스템 모니터 비공개 값 제한·release 예시·`--final 0.2.0` 검증 행 추가. `Doc/BRANCHING.md` 신설(`feature/*` → `test` → `main`, 충돌·태그·긴급 수정 규칙). BLOG-NOTES 맨 앞에 블로그 준비 자료(근거 파일·테스트 수·캡처 후보). 태그 대상 커밋은 그대로이고 이 문서 변경은 v0.2.0 이후 커밋이다.
- **브랜치:** `test`를 이 문서 커밋 기준 `main`에서 만들어 Push. GitHub에서 `main`·`test` 모두 force push·삭제 금지(관리자 포함) 설정, PR·리뷰·상태 검사 필수는 설정 안 함(혼자 개발, CI 없음).
- **구분:** 구현 완료 = v0.2.0 기능 / 자동 검증 = 386개 테스트·릴리즈 검사 / 실제 확인 = 개발자 Mac 설치·업데이트와 사용자 직접 UI 조작 / 미검증 = Gatekeeper 첫 실행(다른 Mac), Intel·다른 기종 측정, 키보드·VoiceOver, 로그인 항목 재승인, AGY 새 수신 / 향후 = Developer ID 서명·공증, Disk 눈금 라벨 겹침, GPU 초기 그래프 표현.

## Stage 6-13A v0.2.0 최종 검토·커밋·Push (2026-10-29, Claude)

- **사용자 직접 확인:** 사용자가 설치된 `0.2.0 (4)`의 실제 UI를 직접 조작했고 이상이 없다고 보고했다. 어떤 항목을 각각 확인했는지는 별도 기록이 없으므로 "사용자 보고"로만 남긴다(자동 테스트·자동 UI 검증 결과가 아님).
- **검증 구분:** 자동 테스트 386개 통과 / 자동 UI 검증은 6-9C(격리 앱 메뉴 막대 표시·숨김·재실행 복원·`bear` 마이그레이션)와 6-12(설치본 메뉴 막대 표시·값 갱신) 범위만 / 사용자 직접 확인: 설치본 UI 조작 이상 없음 / **미검증 유지:** 키보드·VoiceOver 접근성, 로그인 항목 재승인·재로그인 자동 실행, AGY 신규 데이터 수신, OpenAI 키 저장 시 Keychain 재허용, 외부 배포(서명·공증).
- **반영:** 6-10~6-12 문서 변경과 `0.2.0 (4)` 버전·Codex 클라이언트 버전 동기화를 커밋 2개로 `main`에 Push(해시는 Git 기록 참조). 태그·GitHub Release는 만들지 않았다.

## Stage 6-12 v0.2.0 (4) 실제 설치와 업데이트 검증 (2026-10-29, Claude)

- **상태:** 설치 **완료**, 실행 검증 **완료**, 설정 보존 검증 **완료**, AI 서비스 검증 **부분 완료**(Claude 실시간 수신·Codex 조회 확인, AGY는 데이터 읽기만), 팝오버·스위치 클릭 등 실제 UI **미검증**, 외부 배포 **보류**. 새 앱은 실행 중으로 유지했다. 커밋·태그·Release 변경 없음.
- **사전 확인:** RC ZIP SHA-256(`d3986e8d…cc1e`) 일치, 앱 `0.2.0 (4)`·번들 ID·서명 유효, 격리(quarantine) 속성 없음(provenance만). 설치 전 앱 `0.1.0 (3)`.
- **백업(저장소 밖, 소유자만 읽기):** `TokenlyRelease.noindex/backup-0.1.0-installed-20261029-115433/` — `Tokenly.app`(설치본 `ditto` 복사, 내용 해시 동일·서명 유효), `settings.plist`(`defaults export`, 키 22개)와 `settings-read-before/after.txt`, `data/`(Tokenly 데이터 폴더 6개 파일, `diff -r` 동일), `status-before/after.txt`(`--status`), `replaced/Tokenly.app`(교체하며 **옮긴** 원래 0.1.0, 백업 복사본과 동일), `rc-0.2.0-from-zip/`(설치에 쓴 검증된 ZIP 해제본). Keychain 비밀값과 Codex·Claude·AGY 인증 파일은 복사하지 않았다.
- **종료:** PID 28707이 Tokenly Debug 빌드임을 확인한 뒤 AppleEvent 일반 종료, 약 1초 만에 종료, 다른 프로세스 영향 없음.
- **설치:** 검증된 ZIP을 새로 풀어 RC와 내용 동일 확인 → 기존 `/Applications/Tokenly.app`을 백업 폴더로 이동 → 새 앱 `ditto` 복사. 설치본 = RC 내용, 서명 유효, `0.2.0 (4)`.
- **실행:** `open`으로 실행, `/Applications/Tokenly.app/Contents/MacOS/Tokenly` 단일 프로세스, Gatekeeper 경고 없이 실행(로컬 생성 ZIP이라 격리 속성 없음), 새 크래시 리포트 없음, 60초 CPU 0.88% 코어.
- **설정:** 업데이트 전후 `defaults read`·export 비교 **완전히 동일**(키 22개, 추가·삭제·변경 0). 시스템 위젯 저장값(켜짐·꺼짐), 표시 방식, 배터리 테두리, 메뉴 막대 스타일, 화면 모드, AI 서비스 표시·펼침 그대로. 신규 기본값이 적용되지 않았다(저장된 키가 우선).
- **AI 서비스:** `--status` 전후 동일(Claude Code·AGY 모두 "연결됨", 상태 줄은 `/Applications/Tokenly.app` 경로를 그대로 사용해 재연결 불필요). 설치 후 Claude Code 세션의 상태 줄이 **새 실행 파일로** `claude-quota.json`을 갱신(권한 600 유지). Codex는 새로 실행한 앱의 메뉴 막대에 값이 표시됨(디스크 캐시가 없어 실시간 조회 결과). AGY는 기존 수신 데이터 표시만 확인(설치 후 AGY 세션 없음). OpenAI Admin 키는 Keychain에 없어 확인 대상 없음.
- **시스템 모니터:** 메뉴 막대에 저장된 켜짐·꺼짐 설정 그대로 표시(새 기본값 미적용). 1분 간격 캡처에서 RAM 값 변화(갱신 확인). 메뉴 막대 항목 순서는 새 프로세스에서 macOS가 다시 배치했다.
- **미검증:** 팝오버 열기·스위치 클릭·테마 전환·종료 버튼·키보드·VoiceOver(접근성 권한 없음), 로그인 항목의 재승인 필요 여부와 재로그인 자동 실행, AGY 실시간 수신, 실제 OpenAI 키 사용 시 Keychain 재허용 여부.
- **복구 방법:** Tokenly 종료 → `/Applications/Tokenly.app`(0.2.0)을 옆으로 옮김 → 백업의 `replaced/Tokenly.app` 또는 `Tokenly.app`을 `/Applications/Tokenly.app`으로 `ditto` → 실행. 설정은 현재 값과 비교해 달라졌을 때만 `defaults import io.github.jbbdyee.tokenly <백업>/settings.plist`.

## Stage 6-11 v0.2.0 (4) 준비와 개인 업데이트 사전 검증 (2026-10-29, Claude)

- **상태:** 버전 변경·CHANGELOG·RC 생성 **완료**, 자동 검증 **완료**, 실제 UI(최종 빌드) **미검증**, RC **준비 완료**, 개인 설치 **대기**(승인 필요), 외부 배포 **보류**(서명·공증 없음). 미커밋(커밋·태그·Release 생성 안 함). v0.1.0 태그·GitHub Release·기존 Release 폴더는 그대로.
- **버전 소스:** `src/Tokenly/Info.plist`의 `CFBundleShortVersionString`·`CFBundleVersion`만 실제 값이다(프로젝트 파일에 `MARKETING_VERSION` 등 없음, `release.sh`는 Info.plist를 읽음). `0.2.0`·`4`로 변경. 번들 ID·최소 macOS(14.0, `MACOSX_DEPLOYMENT_TARGET`)는 그대로. Codex `app-server`에 보내던 고정 `"0.1.0"`을 `CodexUsageProvider.clientVersion`(번들 버전)으로 바꾸고 테스트 1개 추가. 다른 `0.1.0` 문자열은 0.1.0 Python 브리지 형식을 가리키는 호환 코드라 그대로 둔다.
- **CHANGELOG:** `[0.2.0] - 미출시 (빌드 4)` 추가(System Monitor 위젯·팝오버·기본값 정책·설정 보존, 테마 옵션, 종료 경로, 스타일 정리, release.sh 보호, 385→386 테스트, 미검증 항목). `[0.1.0]` 머리말의 "미발행"을 실제 발행일(2026-10-26 Pre-release)로 고쳤다.
- **RC:** 깨끗한 로컬 clone(`2e7f832`)에 작업 트리 변경을 patch로 적용해 `scripts/release.sh`(개발 모드, 미커밋이라 final 불가)를 실행. 출력 `TokenlyRelease.noindex/rc-v0.2.0-build4/0.2.0-dev/`: `Tokenly-0.2.0-macOS-universal.zip`(3,040,068 B), `.sha256`, `RELEASE-NOTES.md`(개발 빌드 초안 표시, 0.2.0 변경 내용 포함), `build-info.txt`(commit `2e7f832` + dirty 7 paths), `stage/`·`unzipped/Tokenly.app`. SHA-256 `d3986e8d203e0abe9b1bbc5783b3b06c34d12b0c9787c39ecebc3071066bcc1e`.
- **RC 검증:** `0.2.0 (4)`, `io.github.jbbdyee.tokenly`, macOS 14.0+, universal `x86_64 arm64`, 리소스·아이콘 포함, 디버그 심볼·빌드 경로·커버리지 계측 없음, ad-hoc 서명 유효(팀 ID 없음), ZIP 해제본 = 서명본, CLI 스모크(임시 HOME) 통과, 출력 폴더에 실제 번들 ID LaunchServices 등록 없음. Gatekeeper **rejected**, 공증 티켓 없음. 기존 `0.1.0/`·`final-build3/0.1.0/`·`rc-20261029-2e7f832/` ZIP 체크섬 일치(보존).
- **자동 검증(저장소):** 전체 **386개** 통과(실패·건너뜀 0, 385 + 버전 테스트 1), Debug·Release 빌드 성공(둘 다 `0.2.0 (4)`), `git diff --check` 통과, Preferences Tokenly 파일 10개 그대로·테스트 임시 폴더 0개, 실제 설정·PID 28707 그대로.

### 개인 앱 업데이트 사전 조사 (읽기만 함)

- **실행 중:** PID 28707은 `/Applications` 설치본이 아니라 임시 폴더의 Debug 빌드(같은 번들 ID)다. `/Applications/Tokenly.app`은 `0.1.0 (3)`이며 실행 중이 아니다. 둘은 같은 설정 도메인·데이터 폴더를 쓴다.
- **유지되는 것:** 설정 도메인 `io.github.jbbdyee.tokenly`(시스템 위젯 키 5개가 이미 저장돼 있어 새 기본값이 적용되지 않음), `~/Library/Application Support/Tokenly/`(quota·연결 기록·백업), Codex CLI 인증(앱 밖). Claude Code·AGY 상태 줄 명령이 모두 `/Applications/Tokenly.app/Contents/MacOS/Tokenly`를 가리키므로 **같은 경로에 교체하면** 재연결이 필요 없다(교체 중 몇 초는 호출 실패 가능).
- **Keychain:** OpenAI Admin 키 항목(`io.github.jbbdyee.tokenly.openai.admin`)이 현재 없어 재허용 창 위험은 없다. 키를 저장해 둔 경우 ad-hoc 서명이 바뀌면 접근 허용을 다시 물을 수 있다.
- **위험:** 같은 번들 ID 앱 두 개(Debug 28707 + 새 앱) 동시 실행 시 메뉴 막대 항목 중복·설정 동시 쓰기. 로그인 항목은 같은 경로·번들 ID라 유지될 것으로 보이나 서명 변경으로 시스템 설정에서 재승인이 필요할 수 있다(미확인). 로컬에서 만든 ZIP이라 격리(quarantine) 속성이 없어 첫 실행 Gatekeeper 차단은 없을 것으로 보인다(미확인).

### 업데이트 절차 (다음 단계에서 승인 후)

1. 확인: RC ZIP 체크섬(`shasum -a 256 -c`), 실행 중인 Tokenly 프로세스 목록.
2. 백업: `ditto /Applications/Tokenly.app <TokenlyRelease.noindex>/backup-0.1.0-installed-<날짜>/Tokenly.app`, `defaults export io.github.jbbdyee.tokenly <백업 폴더>/settings.plist`, 데이터 폴더 `~/Library/Application Support/Tokenly`를 같은 백업 폴더로 `ditto`.
3. 종료: Tokenly(Debug 28707 포함)를 일반 종료(우클릭 `Tokenly 종료` 또는 AppleEvent quit). 강제 종료는 하지 않는다.
4. 교체: 기존 `/Applications/Tokenly.app`을 백업 폴더로 **옮긴 뒤**(덮어쓰기 금지) RC의 `unzipped/Tokenly.app`을 `ditto`로 `/Applications/Tokenly.app`에 복사.
5. 실행·확인: 버전 `0.2.0 (4)`, 설정 내보내기와 비교, Codex·Claude·AGY 표시, 시스템 위젯 5개, 로그인 항목 상태, `--status`.
6. 복구: Tokenly 종료 → 0.2.0 앱을 옆으로 옮김 → 백업한 0.1.0 앱을 `/Applications/Tokenly.app`으로 `ditto` → 실행. 설정이 손상된 경우에만 `defaults import`. 공개 ZIP(`final-build3/0.1.0/`, GitHub v0.1.0)도 그대로 있다.

## Stage 6-10 최신 코드 Release Candidate (2026-10-29, Claude)

- **기준:** `main` = `origin/main` = `2e7f832`. 작업 트리에는 미추적 `Doc/logs/`(GPU 원본 로그 2개, 보존)만 있다.
- **기존 Release(보존, 변경 없음):** 워크스페이스의 `TokenlyRelease.noindex/`(저장소 밖, Git 비추적). 발행된 v0.1.0 Pre-release(2026-10-26, 태그 `v0.1.0` = `85fe894`)의 ZIP은 `final-build3/0.1.0/`의 `0.1.0 (3)` 산출물(빌드 커밋 `5fa3e9b`)과 크기·체크섬이 같다. `0.1.0/`은 이전 `0.1.0 (1)` final. 그 밖의 `rc-*`·`install-staging-*`·`lsfix-*`·`pathtest` 등은 당시 검증 폴더. `0.1.0/`·`final-build3/0.1.0/` ZIP 체크섬을 다시 확인해 일치했다. `/Applications/Tokenly.app`은 `0.1.0 (3)`(ad-hoc)이며 건드리지 않았다.
- **방법:** 작업 트리가 미추적 로그 때문에 "dirty"이고 stash·clean은 금지라서, `2e7f832`를 저장소 밖 임시 폴더에 로컬 clone(깨끗한 트리)해 기존 `scripts/release.sh`를 **개발 모드**로 실행했다. `--final 0.1.0`은 태그 `v0.1.0`이 다른 커밋이라 쓸 수 없고 버전은 바꾸지 않았다. 출력은 새 폴더 `TokenlyRelease.noindex/rc-20261029-2e7f832/0.1.0-dev/`(기존 폴더가 있으면 스크립트가 멈추는 구조).
- **RC 산출물:** `Tokenly-0.1.0-macOS-universal.zip`(3,039,132 B, 스크립트 기본 이름 — 발행된 0.1.0과 이름이 같으므로 혼동 주의)과 같은 바이트의 `Tokenly-0.1.0-rc-20261029-2e7f832-macOS-universal.zip`, 각 `.sha256`, `RELEASE-NOTES.md`(개발 빌드 초안 표시), `build-info.txt`. SHA-256 `c468ebff992efae35f189440191db5515220c75effc5d3780973d91be015c18f`.
- **검증(스크립트 + 추가):** universal `x86_64 arm64`, 번들 ID `io.github.jbbdyee.tokenly`, `0.1.0 (3)`, macOS 14.0+, LSUIElement, AppIcon·Assets.car·브리지 스크립트 포함, 디버그 심볼 제거·절대 빌드 경로 없음·커버리지 계측 없음, ad-hoc 서명 유효(TeamIdentifier 없음), ZIP 해제본이 서명본과 바이트 동일, CLI 모드(`--help`·`--status`·`--connect --dry-run`·`--statusline`)를 임시 HOME에서 실행 성공, LaunchServices에 출력 폴더의 실제 번들 ID 등록 없음(빌드는 임시 ID로). `spctl` Gatekeeper 평가 **rejected**, 공증 티켓 없음 — 서명·공증 전에는 정상이다.
- **실행하지 않은 것:** RC의 GUI 실행. 실제 앱과 번들 ID가 같아 같은 UserDefaults·Keychain·데이터 폴더를 쓰므로, PID 28707(같은 번들 ID의 Debug 빌드)과 동시에 띄우면 메뉴 막대 항목이 겹치고 설정을 함께 쓴다. 정적 검사와 임시 HOME CLI 실행으로 대신했다.
- **설정·인증 보존 분석(코드 기준):** 설정 도메인 `io.github.jbbdyee.tokenly`, Keychain 서비스 `io.github.jbbdyee.tokenly.openai.admin`(OpenAI Admin 키), Codex는 로컬 CLI 인증을 그대로 사용, Claude·AGY는 상태 줄 브리지가 쓰는 `~/Library/Application Support/Tokenly/*-quota.json`을 읽는다. 업데이트해도 이 위치들은 그대로다. 시스템 위젯은 저장값이 없는 키만 새 기본값을 쓰므로, 시스템 모니터가 없던 0.1.0 사용자는 업데이트 후 CPU·RAM·Disk·Battery가 켜진 상태로 보이고 GPU는 꺼져 있다. ad-hoc 서명은 빌드마다 코드 해시가 달라 **Keychain 항목 접근 허용을 다시 묻는 창**이 뜰 수 있다(미확인).
- **자동 검증(저장소):** 전체 385개 통과(실패·건너뜀 0), Debug·Release 빌드 성공, `git diff --check` 통과, Preferences Tokenly 파일 10개 그대로·테스트 임시 폴더 0개, 실제 설정·PID 28707 그대로.
- **문서 불일치(수정 안 함, 결정 필요):** `CHANGELOG.md`의 0.1.0 항목이 아직 "미발행"이고 시스템 모니터 변경이 기록돼 있지 않다. RC와 발행본이 둘 다 `0.1.0 (3)`이다.

## Stage 6-9C 자동 검증 중심 최종 안정화 (2026-10-29, Claude)

- **격리 앱:** 6-9A 격리 도메인에는 macOS가 메뉴 막대 표시 기록(`NSStatusItem VisibleCC`)을 남겨 "신규 사용자"가 아니고, 그 plist는 보존 대상이라 지울 수 없다. 그래서 같은 격리 방식으로 새 사본을 만들었다(번들 ID `dev.local.tokenly.stage69c`, 별도 Keychain 서비스, AI 데이터 `/private/tmp/tokenly-stage6-9c-home`, 표시 이름 "Tokenly 6-9C 검증", AI 항목에만 "검증" 표식). 제품과 다른 줄은 9줄뿐이고 시스템 UI 코드는 동일. 이 앱의 설정 plist 1개가 새로 생겼다(Preferences의 Tokenly 파일 9 → 10). 마지막에 정상 종료해 지금은 실행 중이 아니다.
- **실제 메뉴 막대(격리 앱, 클릭 없이 저장값 + 재실행 + 화면 캡처):** 빈 설정 → CPU·RAM·Disk·Battery 표시, GPU 없음. 다섯 개 모두 OFF 저장 → 격리 앱 시스템 항목 없음. 하나씩만 ON 저장 → CPU·RAM·Disk·Battery·GPU 각각 단독 표시. CPU OFF·GPU ON 저장 → GPU 표시, 재실행해도 같음. 저장된 `bear` 스타일 → 앱이 실행하며 `numeric`으로 다시 저장(마이그레이션 확인). 메뉴 막대가 붐벼 왼쪽 항목이 macOS 넘침(`«`)으로 들어가므로, 전부 ON일 때 CPU가 안 보이는 것과 최소형 AI 표시는 화면으로 판정하지 못했다(단독 ON 검사로 대신). 종료는 AppleEvent quit으로 매번 정상 종료.
- **오프스크린(실제 팝오버 뷰 + 실제 측정 저장소, 메뉴 막대 화면 아님):** 5개 팝오버 다크·라이트 렌더. 잘림 없음. GPU 그래프: 시작 약 5초 뒤 점 4개가 x 301–317(가로 317 중 오른쪽 끝), 약 72초 뒤 60개가 x 5–317. 최근 60초 고정 가로축이 오른쪽부터 채워지는 **의도된 동작**이며 결함 아님(켠 직후 그래프가 거의 비어 보이는 것은 디자인 판단 대상). Battery 11pt 세부 행·라벨은 두 테마 렌더에서 읽을 수 있었으나 실제 화면·글자 크기 설정에서의 가독성은 미판정. CPU·RAM TOP 5가 "불러오는 중…"인 것은 화면 밖 창이라 팝오버가 숨겨진 것으로 보고 스캔을 멈춘 렌더 환경 탓(실제 앱에서는 이전에 확인됨). Disk 읽기 그래프의 "눈금 상한" 라벨이 현재 값이 눈금 위쪽일 때 오른쪽 위의 현재 점과 겹칠 수 있음(작은 배치 문제, 승인 전 수정 안 함).
- **발견·수정한 결함:** 없음. 코드 변경 없음.
- **자동 검증:** 전체 385개 통과(실패·건너뜀 0), Debug·Release 빌드 성공, `git diff --check` 통과. 테스트 후 Preferences의 Tokenly 파일 10개 그대로, 테스트 임시 폴더 0개. 실제 설정·PID 28707·GPU 원본 로그 2개 그대로.
- **미검증(전체 목록):** 설정 창 스위치 **클릭**과 그 직후 메뉴 막대 반영, 실제 팝오버 열기·닫기(좌클릭)와 실제 화면 렌더링, 우클릭 메뉴, 다크·라이트 실제 전환(설정 창·AI 팝오버 포함), 최소형 메뉴 막대 실제 표시, Cmd+Q·Token Friends 종료 버튼 클릭, GPU 그래프 실제 화면, Battery 실제 가독성·큰 글자 설정, Tab/Shift+Tab/Space/Return, VoiceOver 읽기 순서·ON/OFF 전달·포커스 표시. 원인: 이 환경에 접근성(UI 자동화) 권한이 없어 메뉴 막대 항목을 누를 수 없다. 권한 우회는 하지 않았다.

## Stage 6-9B 테스트 설정 파일 정리·재발 방지 (2026-10-29, Claude)

- **누적 원인:** System Monitor 테스트 5종(`tokenly.systemWidget.tests.<UUID>`, `cpupopover`, `appearance`, `wiring`, `rampopover`)이 일반 이름의 UserDefaults suite를 만들고 `removePersistentDomain`만 호출했다. cfprefsd는 그 뒤에도 빈 `<suite>.plist`를 사용자 Preferences 폴더에 남기므로 실행마다 suite 수만큼 파일이 쌓였다. AI 쪽 `TokenlyTests.swift`는 이미 `TestDefaults`(임시 폴더의 절대 경로 suite + 파일 삭제)를 쓰고 있어 남기지 않았다.
- **정리(휴지통 이동, 복구 가능):** Tokenly 관련 1,099개 중 **1,090개**: 테스트 5종 1,082개(전부 42바이트 빈 plist, 생성 코드 패턴과 일치)와 Claude가 저장소 밖 미리보기 스크립트로 만든 `tokenly.preview.*` 8개(빈 파일 7, 테스트 키 2개만 있는 1). 합계 45,840바이트. macOS `/usr/bin/trash`로 이동, 이동 전 경로·크기·SHA-256 목록을 저장소 밖에 기록, 휴지통의 1,090개 해시가 모두 일치, 원래 위치에 0개. 테스트·앱 프로세스가 쓰지 않는 도메인이라 cfprefsd 캐시 초기화는 하지 않았다.
- **보존(9개):** 실제 설정 `io.github.jbbdyee.tokenly`(작업 전후 비교 동일). 이전 지시("진단용 설정 도메인은 정리 전에 별도 승인")에 따라 10-27 진단 세션의 `io.github.jbbdyee.tokenly.diag`, `tokenlydiag`, `tokenly.harness.h1`·`h2`. 검증용 `io.github.jbbdyee.tokenly.stage66verify`, 격리 앱 `dev.local.tokenly.stage69`·`stage69a`(6-9A 수동 확인에 필요할 수 있음). 소유자를 확정 못 한 `com.tokenly.app`(오래된 백업 기록에만 등장). Keychain은 건드리지 않았다.
- **재발 방지(테스트 코드만):** 5개 파일 9곳을 `TestDefaults.suite(_:)`·`discard`로 전환(`SystemMonitorWiringTests` 3, `SystemWidgetControllerTests` 1, `RAMPopoverTests` 1, `CPUPopoverTests` 3 + 해당 정리부). `TestDefaults.discard`는 `TestDefaults` 폴더의 `TokenlyTests.` suite만 지우고 그 외(앱 도메인·일반 이름·`..` 경로)는 거부(`isTestSuite`, `assertionFailure`). 첫 사용 때 1시간 넘은 잔여 파일만 정리(강제 종료 대비, 동시 실행 중인 suite는 건드리지 않음). 정리는 모두 `defer`라 assertion 실패·throw 경로에서도 실행된다. 새 테스트 `testTestPreferenceSuitesStayOutOfUserPreferences` 1개. 검증 조건은 바꾸지 않았다.
- **재발 검증:** 정리 후 Preferences의 Tokenly 파일 9개·임시 폴더 0개 → 전체 테스트 1회차 **385개 통과**(실패·건너뜀 0) → 9개/0개(5초 뒤도 같음) → 2회차 385개 통과 → 9개/0개. 이전에는 실행마다 수십 개씩 늘었다. 실제 설정은 두 번 실행 뒤에도 동일. Debug·Release 빌드 성공, `git diff --check` 통과. 실행 중 앱 PID 28707 그대로.
- **남은 것:** 위 진단·검증·격리 도메인 7개와 `com.tokenly.app`의 정리는 별도 승인 후. 휴지통은 비우지 않았다(복구하려면 휴지통에서 되돌리기).

## Stage 6-9A 시스템 위젯 기본값 (2026-10-29, Codex 시작 · Claude 마무리)

- **이어받은 시점:** `main` / `85f27d5`. 미커밋: Codex의 `SystemWidgetController.swift`·`SystemWidgetControllerTests.swift`, 6-9 문서 3개, 미추적 `Doc/logs/`(GPU 원본 로그 2개, 보존). Codex 프로세스는 남아 있었지만 이어받기 전 4분 이상 저장소 쓰기·빌드가 없음을 확인했다.
- **정책(구현 완료):** 저장값이 없는 위젯만 `SystemWidget.initialInsertion`(GPU만 false)을 쓴다. 저장된 true/false가 우선하고, 기본값은 저장하지 않는다. → 신규 사용자 CPU·RAM·Disk·Battery ON / GPU OFF.
- **Codex 완료분:** 컨트롤러 기본값, 컨트롤러 테스트(신규 사용자, 모두 OFF 유지, 혼합 저장값 재실행, 일부 키만 있음, 바꾼 값 재실행 복원 + AI 설정 키 불변), 기존 상태 흐름 테스트는 "모두 OFF 저장" 기준으로 전환.
- **Claude 수정:** `CPUPopoverTests.swift`(`makeController`)·`RAMPopoverTests.swift`(`testRAMPopoverStartsAndStopsTheScanOnce`)에 모든 위젯 OFF 저장을 명시. 실패 2개(`testNoScanWhileTheCPUWidgetIsOffOrAfterRemoval`, `testRAMPopoverStartsAndStopsTheScanOnce`)는 "CPU/RAM widget off: no scan"에서 1 ≠ 0이었고, 빈 설정 도메인이 이제 CPU·RAM ON이라 생긴 **테스트 전제 문제**(제품 결함 아님). assertion은 그대로 두었다.
- **자동 검증:** 전체 384개 통과(실패·건너뜀 0, `/private/tmp/tokenly-69a-all.xcresult`), Debug·Release 빌드 성공, `git diff --check` 통과, 모든 Swift 파일이 pbxproj에 있음. 경고는 기존 `RAMPopoverTests.swift:47`뿐.
- **격리 앱:** `/private/tmp/tokenly-stage6-9a-isolated-src/`(제품 + 번들 ID `dev.local.tokenly.stage69a`, Keychain 서비스 `dev.local.tokenly.stage69a.openai.admin`, Claude/AGY/상태 줄 홈 `/private/tmp/tokenly-stage6-9a-home`, 표시 이름 "Tokenly 6-9A 검증", AI 메뉴 막대 항목에만 "검증" 표식). 제품 소스에는 표식 없음. Claude가 두 테스트 파일을 사본에 동기화하고 다시 빌드(`/private/tmp/tokenly-stage6-9a-isolated-build`), `HOME`·`TOKENLY_HOME`을 임시 폴더로 실행. 로그인 항목은 안정 설치 위치가 아니라 등록 불가, Codex CLI 탐색도 임시 `HOME`을 따른다.
- **실제 메뉴 막대(캡처로 확인):** 빈 도메인 → CPU·RAM·Disk·Battery 표시, GPU 없음, 설정 키 생성 없음. 재실행 → 같음. 격리 도메인에 CPU OFF·GPU ON 저장 후 재실행 → CPU 사라지고 GPU 표시. 확인 후 그 두 키를 지우고 격리 앱을 정상 종료(AppleEvent, 해당 번들 ID만). 원래 앱 PID 28707과 `io.github.jbbdyee.tokenly` 설정은 전후 동일(기존 사용자의 명시적 OFF 저장값도 그대로 — 기존 사용자 보존 사례).
- **미검증(사용자 확인 필요):** 설정 창 스위치 클릭 ON/OFF와 그 후 재실행 복원, 다섯 팝오버, 다크·라이트, GPU 그래프 초기/60초 이후, Battery 글씨 가독성, 키보드·VoiceOver. 메뉴 막대 항목을 누를 수단(접근성 권한)이 없다.
- **참고:** `~/Library/Preferences`에 테스트가 만든 `tokenly.*` 임시 plist가 1,000개 넘게 남아 있다(테스트의 `removePersistentDomain`이 빈 파일을 남김). 이번에 지우지 않았다.

## Stage 6-9 안정화 검증 (2026-10-29)

- **작업 전:** `main` / `85f27d5`; 미추적 GPU 원본 로그 2개 외 변경 없음. 기존 Debug 앱 PID 28707은 `/private/tmp/tokenly-switch-85-debug/Build/Products/Debug/Tokenly.app/Contents/MacOS/Tokenly`에서 실행 중이었다. 실제 사용자 설정 값은 문서에 남기지 않는다(작업 전후 비교로 동일함만 확인). 작업 전후 기존 앱 PID·실행 경로와 설정 도메인의 값이 같았다.
- **격리:** 저장소 밖 임시 소스 사본에서만 테스트용 번들 ID, Keychain 서비스, Claude/AGY 파일 루트와 표시 이름을 분리했다. `HOME`·`TOKENLY_HOME`도 임시 폴더를 사용했다. 별도 Debug 앱 `dev.local.tokenly.stage69`를 PID 43746으로 실행해 원래 앱과 동시 실행 및 별도 UserDefaults 도메인을 확인한 뒤, 해당 PID·실행 경로를 확인하고 테스트 앱만 정상 종료했다. 원본 제품 코드·인증 자료·사용자 설정은 수정하지 않았다. 격리 앱은 메뉴 막대 앱으로 UI 자동화 목록에 나타나지 않았고 직접 선택도 시간 초과됐으며 접근성 자동화 권한이 없어 클릭·렌더링·VoiceOver 검증은 수행하지 않았다.
- **코드·자동 검증:** `SystemWidgetControllerTests`는 위젯 독립 ON/OFF, 측정 작업 중지, 저장·복원을 검증하고 `TokenlyTests`는 폐기된 `bear` 스타일의 숫자형 이전을 검증한다. 이번 전체 `/private/tmp/tokenly-stage6-9-all.xcresult`에서 **380개 통과·실패/건너뜀 0**, 별도 Debug·Release 빌드 성공, `git diff --check` 통과. 테스트 컴파일의 `RAMPopoverTests.swift:47` 불필요한 `try`는 기존 경고다. 라이브 AI 서비스 조회, 실제 스위치 조작, 메뉴 클릭·종료, 다크·라이트 렌더링, 키보드·VoiceOver 읽기 순서는 이번 검증 결과가 아니다.
- **GPU·Battery 조사:** GPU 그래프는 최근 60초를 고정 가로축으로 쓰고 새 샘플을 오른쪽에 놓는다. 켠 직후 기록이 짧으면 오른쪽에 몰려 보일 수 있다는 것은 코드에서 도출한 설명이며 실제 문제 원인으로 확정하지 않았다. Battery 세부 행은 11pt, 도움말은 10pt다. 실제 화면·접근성 글자 크기 검증이 없어 가독성 결함이나 디자인 변경을 확정하지 않았다. 이번 단계의 Swift 제품 코드·자동 테스트 변경은 없다.
- **요구사항 확인 필요(당시):** ‘GPU 기본 OFF, 나머지 기본 ON’은 당시 §1.1(모두 최초 OFF)과 달라 동작을 유지했다. → 6-9A에서 확정·구현(위 절).
- **남은 수동 검증:** 별도 접근 가능한 테스트 빌드에서 다섯 스위치 클릭·재실행 복원, 메뉴 좌/우클릭·종료, 다섯 팝오버의 두 테마·값 경계·텍스트 잘림, GPU 60초 이내/이후 그래프, Battery 상세 가독성, Tab/Shift+Tab/Space/Return 및 VoiceOver 순서를 확인한다. 이 항목은 자동 테스트 통과와 구분한다.

## Stage 6-8C 바탕화면 Preview 선별 보존 (2026-10-29)

- 바탕화면의 Tokenly Preview 폴더 8개(총 288파일, 100,523,537바이트)를 분석했다. 현재 Xcode 제품·테스트 참조와 독립 Git 저장소는 없었다. 대표 시안·실제 화면 근거·측정 기록·재현용 탐침 코드 81개(30,861,957바이트)를 기존 Workspace 디자인 보관소 `../../TokenlyDesignArchive.noindex/Stage6-8C/`와 별도 로컬 연구 보관소 `../../TokenlyResearchArchive.noindex/Stage6-8C/`에 선별 복사했다. 전체 파일의 원본 경로·크기·SHA-256·선별 여부는 로컬 연구 보관소의 `manifest.json`에 기록한다. 보관 파일은 복사 후 해시와 열림을 확인했다.
- 나머지 207개는 중복 비교 이미지, 연속 화면 캡처, 실패·중간 시안 또는 재생성 가능한 자료로 분류했다. 원본 폴더는 복구 가능한 macOS 휴지통으로 이동했다. 휴지통을 비우지 않았으므로 실제 디스크 여유가 늘었다고 주장하지 않는다. 과거 절의 경로는 선별 보관된 대표 자료를 가리킨다. 모든 당시 파일이 현재 보관소에 남았다는 뜻은 아니다. 보관소는 제품 저장소 밖의 로컬 자료이며 GitHub 공개 대상이 아니다.
- 실행 중인 Tokenly PID 28707과 사용자 설정은 변경하지 않았다. 제품 코드·테스트도 수정하지 않았다. 전체 테스트는 `/private/tmp/tokenly-stage6-8c-all-escalated.xcresult`에서 **380개 통과·0 실패·0 건너뜀**을 확인했고, 별도 Debug·Release 빌드가 성공했다. 첫 샌드박스 테스트는 SwiftUI 매크로 서버 실행 권한 오류로 컴파일 단계에서 실패했으며, 같은 소스를 정상 권한으로 재실행해 통과했다. 기존 `RAMPopoverTests.swift:47`의 불필요한 `try` 경고가 유지된다. `git diff --check`와 Xcode 제품·테스트의 바탕화면 Preview 참조 부재를 확인했다.

## Stage 6-8B 안전 정리·배포 경로 검증 (2026-10-29)

- **작업 전:** `main` / `3c64a4e`, 기존 변경 경로 117개와 실행 중인 Debug Tokenly PID 28707을 확인했다. 사용자 설정은 읽기만 했고 앱을 종료·교체하지 않았다. 바탕화면의 Tokenly Preview 폴더 8개는 독립 Git 저장소가 아니지만 각각 고유한 시안 소스·실제 화면/측정 기록 또는 문서 참조가 있어 폴더 전체를 보존했다.
- **복구 가능한 정리:** 삭제 전 원래 경로·크기·파일 목록을 `/private/tmp/tokenly-stage6-8b-trash-before.tsv`와 `...-filelist-before.txt`에 기록했다. `.DS_Store` 5개(프로젝트 4·바탕화면 Tokenly CPU 폴더 1), 무시된 `src/default.profraw` 1개, 현재 프로세스에서 열지 않은 오래된 `/private/tmp` DerivedData 36개를 macOS 휴지통으로 이동했다. 검증 후 이번 단계·직전 단계의 재생성 가능한 빌드와 배포 ZIP의 중간 폴더 11개도 별도 목록(`...-trash-generated-before.tsv`, `...-filelist-before.txt`)을 만든 뒤 휴지통으로 옮겼다. 총 **53개 항목, 약 9.05 GB**의 원래 경로가 사라지고 휴지통 결과 경로가 존재함을 확인했다(`...-trash-after.tsv`, `...-trash-generated-after.tsv`). 이는 **휴지통으로 옮긴 논리적 크기**이며 휴지통을 비우지 않았으므로 실제 디스크 여유가 그만큼 늘었다는 뜻은 아니다. 개발용 ZIP·체크섬·검증 로그·전체 테스트 `.xcresult`, `Doc/screenshots/`, `Doc/logs/`, `Preview/`, 자동 테스트, Xcode 사용자별 상태, 현재 실행 앱의 빌드 경로는 보존했다. 프로젝트 밖의 다른 임시 빌드·실험 파일은 사용·증빙 여부를 일괄 확정할 수 없어 보존했다.
- **배포 스크립트:** `scripts/release.sh`의 필수 리소스 목록에서 폐기된 `BearGauge/bear-assets.json`만 제거하고 두 상태줄 브리지·AppIcon 검사는 유지했다. 검증 중 영구 삭제를 피하려고 `TOKENLY_KEEP_INTERMEDIATES=1` 옵션을 추가했다(기본 배포 절차는 그대로). 이 옵션으로 `/private/tmp/tokenly-stage6-8b-release-verify/0.1.0-dev/`에 개발용 universal Release ZIP을 생성했다. 빌드·ad-hoc 서명·두 아키텍처·번들 ID·리소스·명령줄 스모크·ZIP 재해제 후 바이트 동일·SHA-256 검사가 모두 통과했다. 실제 배포·업로드는 하지 않았다.
- **정리 후 검증:** 전체 `/private/tmp/tokenly-stage6-8b-all.xcresult`에서 380개 통과·0 실패·0 건너뜀, 별도 Debug·Release 빌드 성공. Xcode 프로젝트의 신규 Swift 참조와 곰돌이 제품 참조 제거, `git diff --check` 확인. 기존 `RAMPopoverTests.swift:47` 불필요한 `try` 경고 외 신규 경고는 관찰되지 않았다. 이번 검증은 기존 실행 앱의 실제 화면·상호작용 검증이 아니다.
- **후속 결정 필요:** 바탕화면 8개 폴더의 고유 시안·스크린샷·실측 로그, 저장소의 `Doc/screenshots/`·`Doc/logs/`·`Preview/`는 사용자 승인 없이는 이동하지 않는다. 과거 절에 나오는 바탕화면·임시 DerivedData 경로는 당시 자료 위치이며, 이동된 임시 경로를 현재 존재하는 산출물로 해석하지 않는다.

## Stage 6-8A Git 공개 사전 점검 (2026-10-28)

- **상태:** `main` / `3c64a4e`, 변경 경로 117개(수정 17·삭제 20·미추적 80). 아직 스테이징·커밋·Push하지 않았다. 곰돌이 전용 제품 파일 삭제는 기존 6-6B 승인 작업의 미커밋 결과이며, 제작 시안은 보존했다. 스위치 0.85배 변경이 포함된 Debug 앱 PID 28707은 실행 중이며 이번 점검에서 종료·교체하지 않았다.
- **최신 사용자 화면 확인:** 사용자가 최신 Debug 앱에서 CPU·RAM·GPU·Disk·Battery의 다크 계열 실제 화면을 보고 큰 카드 제거·플랫 차콜·큰 수치와 `%`·CPU/RAM/GPU 오로라·Disk 용량/I/O·Battery 게이지/세부 정보 디자인을 승인했다. 같은 앱의 시스템 설정에서 다섯 스위치의 축소 크기·정렬, CPU/RAM/Disk/Battery ON·GPU OFF 표시와 기존 안내 문구도 확인·승인했다. 이는 **사용자 시각 검증**이다. 이번 빌드에서 스위치 클릭·전환, VoiceOver·키보드, 변경 후 재실행 복원, 라이트 테마를 확인했다는 뜻은 아니다. 6-6B의 좌클릭·우클릭·⌘Q·설정 복원 검증은 당시 빌드의 기록으로 유지한다.
- **검증:** `/private/tmp/tokenly-stage6-8a-all.xcresult`에서 전체 380개 통과·실패/건너뜀 0, Debug·Release 빌드 성공(`/private/tmp/tokenly-stage6-8a-debug`, `/private/tmp/tokenly-stage6-8a-release`), `git diff --check` 통과. Xcode 프로젝트의 신규 앱 Swift 25개·테스트 Swift 14개 파일명 참조와 기존 Swift 참조의 실파일을 확인했다. 기존 `RAMPopoverTests.swift:47`의 불필요한 `try` 경고는 남아 있다. 실제 앱을 재검증한 결과는 아니다.
- **공개·커밋 준비:** 변경 파일의 기능별 분류와 공개 적합성은 이번 Stage 6-8A 보고를 따른다. 스테이징 전 스크린샷 전체 시각 검토, 개인 홈 경로와 실측 로그의 기기 식별 정보 공개 범위 결정, 문서·증빙 선택이 필요하다. 기존 Git 기록은 수정하지 않는다. GPU 그래프가 오른쪽에 몰려 보이는 현상과 Battery 세부 글자 크기는 **향후 검토 후보**이며 버그로 확정하지 않았다.
- **Stage 6-8A 당시 발견(6-8B에서 해결):** 당시 `scripts/release.sh`는 제품·번들에서 제거된 `BearGauge/bear-assets.json`을 필수 리소스로 검사했다. 일반 Xcode 빌드만으로 발견되지 않는 배포 경로 문제였고, 6-8B에서 검사 목록 수정과 개발용 ZIP 검증을 완료했다.

## 시스템 설정 스위치 크기 조정 (2026-10-28)

- **코드 적용:** 설정 → 시스템의 CPU·RAM·Disk·GPU·배터리 다섯 행에만 기본 SwiftUI `.toggleStyle(.switch)`를 유지하면서 스위치 표시를 `0.85`배로 축소했다. 라벨은 원래 크기이며, 스위치 영역은 54×24pt로 예약해 행 높이와 정렬을 유지한다. 라벨 영역 탭은 기존 `SystemWidgetController.binding(for:)` 값을 전환한다. VoiceOver에는 라벨을 가진 단일 Toggle을 노출하고 스위치의 키보드 조작은 기본 컨트롤에 맡긴다. 저장·복원과 측정 활성화 로직, 다른 설정 Toggle은 변경하지 않았다.
- **자동 검증:** `SystemWidgetControllerTests` 25개 통과·0 실패·0 건너뜀(`/private/tmp/tokenly-switch-85-tests-escalated.xcresult`). Debug·Release 빌드 성공(`/private/tmp/tokenly-switch-85-debug`, `/private/tmp/tokenly-switch-85-release`). 첫 테스트·빌드는 샌드박스의 SwiftUI 매크로 서버 오류로 중단돼 일반 실행 환경에서 재검증했다. 테스트 컴파일의 `RAMPopoverTests.swift:47` 불필요한 `try` 경고는 기존 경고다. 전체 380개 테스트는 이번 UI 크기 변경에서 재실행하지 않았다.
- **실제 화면 검증 필요:** 실행 중인 Tokenly 앱은 종료·교체하지 않았다. 다섯 스위치의 실제 크기·정렬·행 가장자리 클릭, ON/OFF 애니메이션, 다크·라이트 테마, VoiceOver·키보드 조작, 재실행 후 설정 복원은 새 빌드에서 사용자 수동 확인이 필요하다. 이전 사용자 확인은 크기 변경 전 앱에 대한 기록이다.

## Stage 6-7B-2 최신 Debug 앱 실행 확인 (2026-10-28)

- **정상 교체:** 사용자 승인을 받은 뒤 기존 Tokenly PID 20516의 실행 파일이 `/private/tmp/tokenly-stage6-7b-debug/Build/Products/Debug/Tokenly.app/Contents/MacOS/Tokenly`임을 다시 확인했다. 해당 PID·경로가 일치할 때만 `NSRunningApplication.terminate()`로 정상 종료를 요청했고, 프로세스가 사라진 것을 확인했다. 강제 종료나 다른 앱 종료는 없었다.
- **새 앱:** `/private/tmp/tokenly-stage6-7b2-debug/Build/Products/Debug/Tokenly.app`을 정상 실행했다. 번들 ID `io.github.jbbdyee.tokenly`, 버전 `0.1.0 (3)`, 새 PID **24475**. 실행 직후와 최종 재확인 시 동일 PID 한 개만 보여 `/Applications`의 Tokenly 설치본 중복 실행은 관찰되지 않았다. 앱은 실행 상태로 남겼다.
- **설정 보존:** 실행 전후 `defaults read io.github.jbbdyee.tokenly`에서 AI `numeric`, 외관 `system`, CPU·RAM·Disk·Battery ON/GPU OFF, 시스템 레이아웃 `split`, Battery 프레임 `rounded`가 같았다. GPU나 테마를 테스트 목적으로 변경하지 않았다. Git 변경 경로 수는 작업 전후 117개였고 `git diff --check`는 통과했다.
- **화면 검증 미완료:** UI 자동화 앱 목록에 메뉴 막대 전용 Tokenly가 없고 새 앱 경로로 직접 선택해도 시간 초과됐다. 접근성 권한 변경·클릭 우회를 하지 않았다. 따라서 새 RAM·GPU·Disk·Battery 화면의 카드 제거·차콜 배경·숫자/% 정렬·배지/도움말·Aurora 페이드·Disk I/O·Battery 세부 정보, 다크/라이트/시스템 테마, 메뉴 좌·우클릭 및 설정 재실행 복원은 **이번 앱에서 직접 확인하지 못했다**. 코드와 자동 테스트의 통과를 실제 화면 성공으로 기록하지 않는다. 사용자가 실행 중인 앱에서 수동 확인할 수 있다.

## Stage 6-7B-2 시스템 팝오버 디자인 통일 (2026-10-28)

- **사용자 결정:** 6-7B-1 CPU 플랫 디자인은 사용자가 실제 화면을 확인하고 승인했다. 라이트 테마와 세부 상호작용까지 확인했다고 확대하지 않는다. 6-5A 큰 카드 공통 컴포넌트 추출은 계속 보류하며, Stage 6-7A 비교 시안은 보존한다.
- **코드 적용 완료:** RAM·GPU·Disk·Battery 네 팝오버의 큰 핵심 영역에 있던 그라데이션 배경·둥근 클리핑·얇은 외곽선을 제거했다. 각 팝오버 전체의 `.regularMaterial`과 전역 `NSApp.appearance`는 유지했다. 네 지표가 모두 퍼센트 수치이므로 현재 CPU와 같은 큰 숫자 42pt·`%` 21pt·첫 기준선 정렬을 적용했다. 상태/오류 보조 문구와 오른쪽 정보 배치는 유지했다. RAM 구성 막대·압박 배지·TOP 5, GPU 실험적 안내, Disk APFS 설명·용량 막대·I/O 그래프, Battery 충전 배지·게이지·어댑터·건강도·온도·ⓘ는 그대로다. CPU·AI View, 측정·계산 Store, 메뉴 막대 Battery 프레임 설정은 수정하지 않았다.
- **오로라:** 큰 카드의 클리핑을 없앤 RAM·GPU는 기존 `AuroraGraph.fadesAreaEdges`를 켜서 면 채움과 glow만 좌우 페이드하고 그래프 높이 안에서 clip한다. 라인과 현재값 점은 페이드 대상이 아니다. Disk I/O 그래프 구현은 변경하지 않았다. 공유 그래프 코드에서는 'CPU 전용'이라는 주석만 실제 사용 범위에 맞게 바꿨고 수식·기본 OFF 동작은 그대로다.
- **자동 검증 완료:** 변경 순서대로 `RAMPopoverTests`, `GPUPopoverTests`, `DiskActivityTests`+`DiskUsageTests`, `BatteryPopoverTests`가 각각 통과했다. 전체 `/private/tmp/tokenly-stage6-7b2-all.xcresult` 기준 **380개 통과·0 실패·0 건너뜀**(이전과 동일, 테스트 소스 변경 없음). Debug `/private/tmp/tokenly-stage6-7b2-debug` 및 Release `/private/tmp/tokenly-stage6-7b2-release` 빌드 성공, `git diff --check` 통과. 기존 테스트 컴파일의 `RAMPopoverTests.swift:47` 불필요한 `try` 경고는 이 단계의 새 변경이 아니다. 테스트·빌드 산출물은 저장소 밖에 있다.
- **실제 화면 수동 검증 필요:** 실행 중인 Tokenly PID 20516은 이전 6-7B-1 Debug 앱이며 종료·교체하지 않았다. 최신 네 팝오버의 다크·라이트·시스템 테마, 큰 수치와 배지·보조 정보의 실제 간격, Aurora 양끝, Disk I/O 및 Battery 게이지, 메뉴 좌·우클릭과 설정 복원은 새 앱 화면에서 확인하지 못했다. 이전 실기기 검증 기록은 변경 전 버전에 대한 근거다. 최신 Debug 앱은 빌드만 준비했다. 앱 교체 전 PID·실행 경로 확인과 사용자 승인이 필요하다.

## Stage 6-7B-1 실제 앱 실행 확인 (2026-10-28)

- **사용자 승인 범위:** 이전 Debug Tokenly PID 4050의 정상 종료와 최신 빌드 실행을 승인받았다. 실행 직전 프로세스 재조회에서 PID 4050 및 다른 Tokenly 앱 프로세스가 없어서 종료 요청은 보내지 않았다. 강제 종료도 하지 않았다.
- **새 Debug 앱 실행:** `/private/tmp/tokenly-stage6-7b-debug/Build/Products/Debug/Tokenly.app`을 `open -a`로 실행했다. 번들 ID `io.github.jbbdyee.tokenly`, 버전 `0.1.0 (3)`, 실행 PID **20516**. 실행 직후와 재확인 시 동일 PID 한 개만 보였고 `/Applications` 설치본의 중복 실행은 관찰되지 않았다.
- **설정 보존:** 실행 전후 `defaults read io.github.jbbdyee.tokenly`에서 AI 스타일 `numeric`, 외관 `system`, CPU·RAM·Disk·Battery ON/GPU OFF, 시스템 레이아웃 `split`, Battery 프레임 `rounded`가 같았다. 설정값을 변경하거나 초기화하지 않았다. Git 변경 파일 수는 실행 전후 117개로 같았다.
- **실제 화면 미검증:** UI 자동화 목록에 메뉴 막대 전용 Tokenly 앱이 나타나지 않았고, 최신 앱 경로로 선택을 시도해도 시간 초과됐다. 따라서 안쪽 카드 제거, AI 팝오버와의 시각적 일치, 큰 수치/% 정렬, 오로라 라인·glow·양끝 페이드, TOP 5·배지·설정, 다크·라이트·시스템 테마, 좌클릭 팝오버·우클릭 종료는 이번 새 빌드에서 직접 확인하지 못했다. 코드·자동 테스트 결과를 실제 화면 검증으로 대체하지 않는다. 앱은 실행 상태로 남겼으며 사용자가 직접 확인·캡처할 수 있다.

## Stage 6-7B-1 CPU 플랫 차콜 적용 (2026-10-28)

- **디자인 승인·코드 적용 완료:** 사용자가 6-7A A안(플랫 차콜)을 승인했다. CPU 팝오버의 안쪽 둥근 카드 배경·클리핑·테두리를 제거하고 기존 전체 `.regularMaterial`과 앱 전역 `NSApp.appearance`를 유지했다. CPU 큰 숫자 44→42pt, `%` 20→21pt로 변경하고 기존 첫 기준선 정렬을 유지했다. 헤더·사용자/시스템·TOP 5·설정·접근성·측정 Store는 변경하지 않았다. RAM·GPU·Disk·Battery·AI 팝오버 디자인은 변경하지 않았다.
- **오로라:** `AuroraGraph`에 기본값 OFF인 `fadesAreaEdges` 옵션을 추가하고 CPU만 ON으로 사용한다. 좌우 5.5% 구간에서 glow와 면 채움의 알파를 0↔1로 부드럽게 바꾸며 라인과 현재값 점은 마스크하지 않는다. CPU 그래프 뷰만 경계에서 clip한다. 다른 지표의 그래프는 기본 옵션 그대로다. 정적 6-7A 미리보기와 실제 material·실시간 갱신은 다르므로 화면 확인이 필요하다.
- **자동 테스트 완료:** 첫 관련 테스트는 새 픽셀 검사 테스트가 실패했다. 테스트가 60초 창에서 제거되는 시점의 샘플과 투명 렌더의 빈 픽셀을 잘못 가정한 원인이다. 테스트를 보존 창 안의 샘플·페이드 함수 경계·기본 OFF 계약 검증으로 고쳤다. 이후 `CPUPopoverTests` 19개 통과, 전체 `/private/tmp/tokenly-stage6-7b-all.xcresult` 380개 통과(기존 379 + 신규 1), 0 실패·0 건너뜀. Debug `/private/tmp/tokenly-stage6-7b-debug`, Release `/private/tmp/tokenly-stage6-7b-release` 빌드 성공, `git diff --check` 통과. 첫 테스트 실행의 SwiftUI 매크로 서버 오류는 샌드박스 환경 문제였고 일반 실행 환경에서 재시험했다. 이전 `RAMPopoverTests.swift:47`의 불필요한 `try` 경고가 관련 테스트 컴파일에 다시 나타났다.
- **실제 앱 검증 필요:** 작업 중 실행 중인 앱은 이전 6-6B Debug 빌드 PID 4050 (`/private/tmp/tokenly-stage6-6b-debug/.../Tokenly`)이다. 종료·교체 승인이 없어 최신 앱을 실행하거나 기존 앱을 종료하지 않았다. 최신 CPU 팝오버의 다크·라이트·시스템 테마, 그래프 경계, TOP 5와 메뉴 클릭은 사용자 수동 검증 또는 앱 교체 승인 후 확인해야 한다. 기존 6-7A 시안은 보존한다.

## Stage 6-7A CPU 팝오버 디자인 비교 (2026-10-28)

- Stage 6-5A의 둥근 카드 공통화는 보류한다. 실제 앱 Swift 소스·설정·프로세스는 변경하지 않았다.
- `Preview/Stage6-7A-CPU/`에 현재형 근사, A 플랫 차콜, B 소프트 차콜을 다크·라이트 각 1장씩 340×345pt·2×로 렌더했다. 모든 수치·그래프는 세 안에 동일한 예시 데이터이며 실제 측정이 아니다. `render.swift`는 격리된 정적 SwiftUI 코드이고 제품 타깃에 포함되지 않는다.
- 기존 CPU View의 카드 그라데이션·둥근 클리핑·테두리는 `CPUPopoverView.swift`에, 라인·면 채움·glow는 `AuroraGraph.swift`에 있다. 카드 경계 제거 자체가 Aurora 알고리즘을 제거하지는 않는다. 실제 앱 적용 시 그래프 바깥 glow의 클리핑·배경 대비, 다크·라이트 material 차이, 접근성, TOP 5 갱신을 확인해야 한다.
- 추천은 A안이다. 카드 경계가 사라져 AI 팝오버와 시각적 위계가 가장 가까워지고 Aurora가 큰 영역에 자연스럽게 이어진다. B안은 대비를 약간 보강하지만 직사각형 핵심 영역 경계가 다시 보일 수 있다. 최종 선택과 제품 반영은 사용자 승인 전까지 보류한다.

## Stage 6-6C 사용자 수동 검증 기록 (2026-10-28)

- **근거:** 사용자가 Stage 6-6B 이후 최신 Debug 앱에서 직접 확인해 보고한 결과다. 아래 항목은 사용자 수동 검증 완료로 기록하며, Codex가 이번 단계에서 앱을 다시 조작하거나 테스트를 재실행한 결과는 아니다.
- **메뉴 막대:** CPU·RAM·Disk·Battery 좌클릭 팝오버 정상, AI 항목 좌클릭·우클릭 정상, 시스템 항목 우클릭 `Tokenly 종료` 메뉴 정상.
- **설정·표시:** 시스템 스위치 5개 정상, Battery `최대 용량` 명칭과 ⓘ 도움말 정상, 곰돌이형 선택지 제거 및 숫자형·최소형 정상, 다크·라이트·시스템 테마 정상, 설정 변경 후 재실행 시 복원 정상.
- **종료:** 토큰 친구들 창의 기존 종료 버튼, 우클릭 종료, 활성 앱에서 ⌘Q 종료가 모두 정상이라고 사용자가 확인했다.
- **범위:** GPU 좌클릭 팝오버, 각 팝오버의 모든 세부 정보, 측정값 정확도, 스위치 OFF 시 실제 샘플링 중지, 우클릭과 팝오버의 동시 표시 여부, 비활성 앱에서의 ⌘Q는 이번 사용자 보고에 포함되지 않았다. 이전 단계의 자동 테스트·빌드 결과와 사용자 수동 검증을 혼동하지 않는다. 아래 6-6B의 '수동 확인 필요'는 당시 상태를 보존한 기록이며 이 절이 현재 확인 범위를 갱신한다.
- **Stage 6-5A 사전 조사:** 시스템 팝오버 5개의 340pt 폭·material 배경, 카드 윤곽·헤더/설정 버튼·큰 수치와 일부 도움말 스타일은 반복된다. AI 팝오버는 같은 폭·배경을 쓰지만 provider 펼침/조회/오류 흐름이 달라 별도 유지가 안전하다. CPU Aurora Flow, RAM 메모리 분해, GPU 실험적 안내, Disk APFS·I/O, Battery 충전 정보와 각 Store의 주기는 그대로 둔다. 우선 정적 스타일 상수와 작은 표시 요소부터 추출하고, 상태·수집 생명주기 통합은 계획 범위에서 제외한다. 실제 리팩터링은 다음 단계 승인 후 진행한다.
- **Stage 6-5A 제안 순서(미구현):** (1) 시스템 5개 팝오버의 폭·material·카드 외형 등 상태 없는 스타일만 공통화하고 기존 스냅샷/접근성 테스트 및 Debug 빌드로 비교한다. (2) 공통 헤더의 제목·설정 버튼과 큰 숫자 서식을 필요 인자로 받는 작은 View로 추출하되 각 지표의 배지·보조 정보는 슬롯으로 유지하고 5개 화면을 라이트/다크에서 비교한다. (3) 반복되는 도움말·데이터 없음 표시만 검토해 선택적으로 추출하고 TOP 5의 열림/닫힘, GPU 실험 안내, Battery 15초 온도 신선도, Disk I/O를 회귀 테스트와 실제 화면으로 확인한다. 각 단계는 별도 검토 후 다음 단계로 진행하며 AI 팝오버와 측정 Store는 건드리지 않는 방향이다.

## Stage 6-6B 검증·정리 (2026-10-28)

- **작업 전:** `main` / `3c64a4e`, 다수의 기존 미커밋 변경 유지. 기존 Debug PID 94237은 원래 DerivedData 경로에서 실행 중이었다. 저장값은 AI `numeric`, 외관 `system`, 시스템 CPU·RAM·Disk·Battery ON/GPU OFF, 시스템 레이아웃 `split`, Battery 프레임 `rounded`.
- **앱 교체:** 사용자 승인에 따라 `NSRunningApplication.terminate()`로 PID 94237에 정상 종료 요청을 보냈고 종료를 확인했다. 최신 소스를 `/private/tmp/tokenly-stage6-6b-debug`에 Debug 빌드한 뒤 원래 번들 ID `io.github.jbbdyee.tokenly`로 실행했다. 새 PID 4050, 버전 0.1.0 (3), 실행 파일 `/private/tmp/tokenly-stage6-6b-debug/Build/Products/Debug/Tokenly.app/Contents/MacOS/Tokenly`. 17초 뒤 설치본 `/Applications/Tokenly.app`의 PID 4085가 추가로 나타났다(원인은 미확정). 설치본 PID 4085에만 정상 종료 요청을 보내고 5초 뒤 PID 4050 하나만 남은 것을 확인했다. 위 설정값 9개는 재확인 시에도 동일.
- **실제 UI 조작:** 메뉴 막대 전용 앱은 이번 UI 자동화 앱 목록에 나타나지 않았고 `getApp("Tokenly")`도 시간 초과됐다. 접근성 권한을 바꾸거나 별도 클릭 우회 도구를 사용하지 않았다. 따라서 좌·우클릭, `Tokenly 종료` 선택, 활성/비활성 ⌘Q, 기존 종료 버튼, 스위치 조작, Battery 상세 문구, 스타일 선택, 테마별 팝오버의 **이번 빌드 실제 화면 결과는 사용자 수동 검증 필요**다. 구현 완료나 이전 Battery 화면 확인 기록을 이번 조작 검증으로 대체하지 않는다. GPU는 원래 OFF 그대로 두었다.
- **승인 파일 정리:** Git 추적 중이며 앱·테스트·pbxproj에서 미참조인 `src/Tokenly/Views/BearGaugeView.swift`, `MenuBarGaugeRow.swift`, `src/Tokenly/Resources/BearGauge/`의 17개, 현재 README에서 미참조인 `Doc/images/menubar-bear.png`를 삭제했다. Git HEAD에서 복구할 수 있고 `Preview/Heart3D/`의 제작 자료는 유지했다. 무시된 루트 `default.profraw`는 0바이트라 삭제했다. 무시된 `src/default.profraw`는 60,768바이트의 과거 커버리지 증거라 보존했다. 승인 목록 밖 파일은 삭제하지 않았다.
- **정리 후 검증:** `/private/tmp/tokenly-stage6-6b-tests.xcresult`에서 전체 379개 통과·0 실패·0 건너뜀. 이전 379개와 동일하며 테스트 소스 삭제 없음. Debug 빌드(`/private/tmp/tokenly-stage6-6b-final-debug`)와 Release 빌드(`/private/tmp/tokenly-stage6-6b-final-release`) 모두 통과. 기존 `RAMPopoverTests.swift:47`의 불필요한 `try` 경고만 테스트 컴파일에서 관찰했다. Xcode 프로젝트 plist 유효, 곰돌이 파일 참조 없음, Release 번들 리소스 없음, `git diff --check` 통과.
- **남은 수동 확인:** 여섯 항목 각각 좌클릭 팝오버와 우클릭 종료 메뉴가 분리되는지, 세 종료 경로, 설정 스위치와 측정 중지·복원, Battery 상세 값과 ⓘ, 숫자형·최소형, 다크·라이트·시스템 테마. 테스트할 때 변경한 값은 위 기준값으로 복원한다. 접근성 권한을 임의 변경하지 않는다.
- **추가 관찰:** 설치본 PID 4085의 생성 원인은 확인하지 않았다. 로그인 항목/LaunchServices 등의 가능성을 사실로 기록하지 않는다. 다음 실제 앱 검증에서는 앱 교체 직후 프로세스 목록을 다시 확인하고 두 번 실행되지 않는지 먼저 살핀다.

## Stage 6-6 현재 상태 (2026-10-28)

- **기준:** `main` / `3c64a4e`, 작업 전 미커밋 변경 보존. 작업 시작 시 기존 Debug Tokenly PID 94237 실행 중; 종료·교체하지 않았다.
- **구현:** Battery 상세의 "최대 용량" 명칭과 기존 ⓘ 유지(배터리 보고 완충÷설계 용량, macOS 공식 값과 다를 수 있다는 도움말). 시스템 설정 5개 Toggle에 `.switch`를 지정하고 기존 `SystemWidgetController.binding(for:)`와 저장값을 유지했다. AI 메뉴 막대의 `bear` 선택·분기·전용 컴파일 소스/리소스를 타깃에서 제외하고 저장된 `bear`는 숫자형으로 이전한다. 전용 원본 파일은 사용자 삭제 승인 전까지 보존한다.
- **종료:** 기존 AI 팝오버 종료 버튼은 유지했다. Settings 장면에 앱 종료 명령(⌘Q)을 추가했다. AI 메뉴 막대 라벨의 첫 표시 때 로컬 오른쪽 마우스 이벤트 감시를 한 번 설치하고, 이 앱의 상태 막대 창에만 `Tokenly 종료` 메뉴를 표시한다. 이 방식은 전역 감시·접근성 권한이 필요 없지만, SwiftUI `MenuBarExtra`의 실제 이벤트 전달과 각 위젯에서의 동작은 새 앱 실기기 조작 확인이 필요하다.
- **자동 검증:** 샌드박스 SwiftUI 매크로 서버 오류로 첫 Debug 빌드는 실패했고, 저장소 밖 `/private/tmp/tokenly-stage6-6-debug`에서 재실행한 Debug 빌드는 통과했다. 전체 테스트는 `/private/tmp/tokenly-stage6-6-tests.xcresult`에서 379개 통과·0 실패·0 건너뜀. 이전 386개 대비 곰돌이 전용 테스트 7개를 제거했고, 기존 스타일 이전 테스트에 `bear`를 추가했다. Release 빌드도 `/private/tmp/tokenly-stage6-6-release`에서 통과했다. 기존 `RAMPopoverTests.swift:47`의 불필요한 `try` 경고는 이 단계의 변경 파일이 아니다.
- **실기기:** 이전 6-4f 보고 뒤 Battery 실제 화면 및 어댑터 분리·재연결은 사용자 확인 완료. 별도 번들 ID의 임시 앱(`/private/tmp/Tokenly-Stage6-6-Verify.app`)을 실행해 기존 PID 94237을 보존했으나 UI 자동화에서 메뉴 막대 전용 앱을 선택할 수 없어 스위치·우클릭·⌘Q·테마·재실행 설정 복원·팝오버 5개의 새 빌드 실제 화면 검증은 미완료다. 임시 프로세스 PID 97729만 종료했고 검증 앱 파일은 보존했다. 기존 앱을 교체할 때는 사용자 승인 필요.
- **문서:** 상세 기술 조사와 당시의 미완료 표기는 아래 기록에 보존했다. 현재 상태는 이 절과 `SYSTEM-MONITOR.md` 머리말을 우선한다. 오래된 곰돌이형 자료는 역사적 시안이며 현재 앱의 선택지가 아니다.
- **남은 작업:** 우클릭 종료가 상태 막대 창에서만 팝오버 없이 열리는지 실기기 확인, ⌘Q 활성 상태 확인, 각 테마/위젯 재실행 확인, 보존된 미사용 파일 삭제 여부 결정. 삭제·커밋·Push 없음.

### 삭제 후보 조사 (삭제하지 않음)

| 경로 | 현재 참조·용도 | 추천과 위험 |
|---|---|---|
| `src/Tokenly/Views/BearGaugeView.swift`, `MenuBarGaugeRow.swift` | 곰돌이 전용 렌더러. Stage 6-6에서 Xcode 타깃 제외; 서로만 참조 | 기능상 삭제 가능. 과거 렌더링 구현 근거가 사라지므로 승인 뒤 보존 방법 결정 |
| `src/Tokenly/Resources/BearGauge/`(manifest 1개·PNG 16개) | 곰돌이 전용 런타임 레이어. 타깃 리소스에서 제외 | 앱 기능상 삭제 가능. 재현 가능한 과거 시안의 원본 에셋 소실 위험 |
| `Doc/images/menubar-bear.png` | 과거 README 곰돌이 화면. 현 README에서 참조 제거 | 현재 제품 문서에서는 삭제 가능. 디자인 변경 전후 비교 근거 소실 위험 |
| `Preview/Heart3D/`(87개) | 3D 제작 소스·시안·생성 이미지. `Preview/README.md`와 기술 결정 기록에서 참조 | 유지 추천. 블로그·포트폴리오 근거이며 일부 구형 스크립트는 현재 API로 실행되지 않음 |
| `Preview/Heart3D/run-{gauge-rows,numbers,outline,name-outline}.sh` | 과거 시안 실행 스크립트. `Preview/README.md`에 현재 API와 호환되지 않는다고 기록 | 삭제 후보지만 원인 분석 재현 자료이므로 유지 추천. 단독 삭제 시 관련 결과의 제작 과정이 사라짐 |
| `Preview/README.before-v1.md` | 예전 README 보존본. 현재 런타임 참조 없음 | 보존 추천. 문서 변천 이력 |
| `default.profraw`, `src/default.profraw` | 과거 빌드 커버리지 산출물, `.gitignore`의 `*.profraw`로 제외 | 승인 뒤 삭제 가능. 후속 분석 원본이 필요할 수 있으므로 시각·용도를 먼저 확인 |
| `scripts/enable_claude_statusline.py`, `enable_agy_statusline.py` | 예전 설정 연결 스크립트. README·과거 계획에서 참조하지만 현재 설치 경로는 `Tokenly --connect` | 유지 또는 별도 승인 후 폐기. 복구·구버전 호환 경로를 검토해야 함 |
| `Doc/screenshots/`, `Doc/logs/` | UI 비교 이미지·실측 원본; 기술 문서에서 참조 | 유지. 블로그·검증 근거. 자동 테스트 소스도 유지 |
| `Doc/screenshots/stage6-2/preview-{light,dark}.png`, `stage6-2-final/preview-{light,dark}.png` | 초기/최종 렌더 비교. 각 대응 파일의 SHA-256이 달라 바이트 중복이 아니다 | 유지 추천. 디자인 변화 비교 근거 |

## 현재 목표

기존 AI 토큰 모니터링을 유지하면서 같은 macOS 앱에 독립적인 System Monitor를 단계적으로 추가한다. 요구사항·구현 현황·순서는 `Doc/SYSTEM-MONITOR.md`를 기준으로 한다. 3-1단계(Battery 실시간 상태, Store 주기 측정·60초 기록)와 3-2단계(조회 가능한 프로세스 CPU·RAM TOP 5 수집, Codex 리뷰 반영 안정화 포함), 4단계(Disk 시스템 볼륨 용량)를 완료했다. 5단계 GPU는 B안(실험적 지원)이 승인되어 측정 엔진(Sampler·Store)까지 구현했다. 팝오버 UI 연결은 6단계다.

## 기준 상태

- 브랜치 `main`. 1·2단계는 사용자 승인 후 로컬 커밋 `3c64a4e`(feat(system-monitor): System Monitor 기반과 CPU·RAM 측정 추가)로 기록했다. 부모는 `ea6ffb2`이며 Push는 하지 않았다.
- 3단계 이후 변경은 모두 **미커밋** 상태다.
  - 수정: `SystemMetrics.swift`, `SystemMonitorStore.swift`, `SystemMonitorTests.swift`, `project.pbxproj`, `AGENTS.md`, `Doc/HANDOFF.md`, `Doc/BLOG-NOTES.md`
  - 신규: `BatteryStatus.swift`, `BatterySampler.swift`, `SystemMetricHistory.swift`, `SystemMonitorScheduler.swift`, `BatterySamplerTests.swift`, `SystemMonitorStoreTests.swift`, `Doc/SYSTEM-MONITOR.md`
  - 3-2 신규: `ProcessTopMetrics.swift`, `ProcessTopSampler.swift`, `ProcessTopStore.swift`, `ProcessTopTests.swift`
  - 5 신규: `GPUUsage.swift`, `GPUSampler.swift`, `GPUTests.swift`. 5단계 수정: `SystemMetrics.swift`(`insufficientSamples` 사유), `SystemMonitorScheduler.swift`(`once(after:)`), `SystemMonitorStore.swift`, `SystemMonitorStoreTests.swift`, `ProcessTopTests.swift`(테스트 Scheduler에 `once` 스텁), `project.pbxproj`(ID `…055`~`…057`)
  - 4 신규: `DiskUsage.swift`, `DiskSampler.swift`, `DiskTests.swift`. 4단계 수정: `SystemMonitorStore.swift`, `SystemMonitorStoreTests.swift`, `project.pbxproj`(ID `…052`~`…054`)

## 완료 사항

### 1단계 (Codex)
- 루트 `AGENTS.md`(공통 규칙), `CLAUDE.md`(AGENTS.md·이 문서를 먼저 읽도록 안내).
- `SystemMonitor/SystemMonitorStore.swift`: `SystemSnapshot`, 비동기 `SystemSampler` 계약, `SystemMonitorStore`(idle/loading/ready/failed, 수동 갱신, 중복 갱신 방지).

### 2단계 (Claude)
- `SystemMonitor/SystemMetrics.swift` (신규, 순수 계산 — Mach 호출 없음)
  - `SystemMetric<Value>`: `.available(값)` / `.unavailable(사유)`. 사유: `awaitingBaseline`, `counterReset`, `noElapsedTicks`, `inconsistentValues`, `readFailed(kern_return_t)`. 측정 불가 값을 0으로 채우지 않기 위한 공통 표현이며 이후 Battery·Disk·Network에도 그대로 쓸 수 있다.
  - `CPUTickCounters`, `CPUUsage`(total/user/system %), `CPUUsageTracker`(직전 샘플 기준 계산).
  - `VMPageCounters`, `MemoryUsage`(total/used/app/wired/compressed/cachedFiles 바이트, `usedFraction`)와 `MemoryUsage.calculate`.
- `SystemMonitor/MachSystemSampler.swift` (신규): `actor MachSystemSampler: SystemSampler`. Mach 호출과 CPU 기준값 보관만 담당한다.
- `SystemMonitor/SystemMonitorStore.swift`: `SystemSnapshot`에 `cpu`, `memory` 필드만 추가. Store 로직은 변경하지 않았다.
- `src/TokenlyTests/SystemMonitorTests.swift` (신규): 13개 테스트.
- `project.pbxproj`: 위 3개 파일의 PBXFileReference·PBXBuildFile 등록, `SystemMonitor`·`TokenlyTests` 그룹, 앱/테스트 Sources 등록(ID `…039`~`…041`).

### 3단계 (Claude)
- `SystemMonitor/BatteryStatus.swift` (신규, 순수 파싱): `BatteryRegistryRead`(noService / failed / properties)와 `BatteryStatus.make(from:)`. IOKit 없이 사전으로 테스트할 수 있다.
- `SystemMonitor/BatterySampler.swift` (신규): `struct BatterySampler`. AppleSmartBattery IORegistry 항목을 읽기만 하며 상태가 없다. CPU·RAM Sampler와 독립적이다.
- `SystemMonitor/SystemMetrics.swift`: `SystemMetricUnavailableReason`에 `noBattery`, `unsupported` 케이스만 추가했다. CPU·RAM 계산 로직은 변경하지 않았다.
- `SystemMonitorTests.swift`: 포트 참조 테스트를 보완했다. `mach_host_self` 결과가 NULL이 아닌지, `mach_port_get_refs`·`mach_port_deallocate`가 `KERN_SUCCESS`를 반환하는지, Sampler 생성 시 참조가 정확히 +1 늘어나는지를 확인한다.
- `src/TokenlyTests/BatterySamplerTests.swift` (신규): 8개 테스트. `project.pbxproj`에 ID `…042`~`…044`로 등록했다.
- Battery는 아직 `SystemSnapshot`·`MachSystemSampler`·Store에 연결하지 않았다. CPU·RAM 코드를 바꾸지 않기 위해서다.

### 3-1단계 (Claude)
- `BatteryStatus.swift`
  - IOPowerSources 기반 `PowerSourcesRead`와 `BatteryPowerState`(잔량 %, 외부 전원 연결, 충전 중)를 추가했다.
  - 정수 파싱 함수를 파일 내부 함수 `registryInteger`로 옮겨 함께 쓴다. 기존 사이클·용량·건강도 동작은 그대로다.
- `BatterySampler.swift`: `BatterySampling` 프로토콜(Store 주입용)과 `samplePowerState()`·`readPowerSources()`를 추가했다.
- `SystemMetricHistory.swift` (신규): 60초·최대 60개 기록. 측정 불가는 `nil` 간격으로 남긴다.
- `SystemMonitorScheduler.swift` (신규): `SystemMonitorScheduling` 프로토콜과 실제 구현(Timer, IOPS 전원 알림). 취소할 수 있고, 해제되면 자동으로 취소된다.
- `SystemMonitorStore.swift`
  - `SystemSnapshot`·`SystemSampler`는 유지했다.
  - Store는 `setEnabled(_:_:)` 기반으로 다시 작성했다. 이전의 `state`·`refresh()` API는 제거했고, 앱에서 쓰는 곳은 없었다.
  - 테스트용으로 `pendingSample`과 `now` 주입을 제공한다.
- 테스트
  - `SystemMonitorStoreTests.swift` (신규): Store 10개, 기록 4개
  - `BatterySamplerTests.swift`: 실시간 상태 6개 추가
  - `SystemMonitorTests.swift`: Store 사용 테스트 1개를 새 API로 바꿨다.
- `project.pbxproj`에 ID `…045`~`…047`로 등록했다.
- CPU·RAM 계산 로직(`SystemMetrics.swift`의 CPU·RAM 부분, `MachSystemSampler.swift`)과 AI Monitor·메뉴 막대 UI는 변경하지 않았다.

## 측정 기준

CPU·RAM·Battery의 계산 기준과 출처, Battery 실시간 상태, Store 측정 정책, 자원 관리는 `Doc/SYSTEM-MONITOR.md` §4에 정리했다(중복 기재하지 않음).

## 검증 결과 (2단계)

- Debug·Release 빌드: 성공 (`xcodebuild`, DerivedData `/private/tmp/tokenly-system-stage2-derived`). 신규 파일 관련 경고 없음.
- `xcodebuild test`(Debug, `platform=macOS`): **TEST SUCCEEDED**, 기존 112개 + 신규 13개 = 125개 전부 통과. 1단계에서 보고된 testmanagerd 제한은 이번 환경에서 발생하지 않았다.
- `plutil -lint project.pbxproj`: 통과.
- 실측 대조(16 GiB Apple Silicon): Wired·Compressor·App 페이지 수가 `vm_stat` 출력과 일치. CPU 1초 구간 약 8.9%.
- 오버헤드: 독립 실행 하네스(`swiftc -O`)에서 20만 회 샘플링 시 1회당 CPU 약 6.5 µs, `phys_footprint` 2.2 MB → 2.2 MB로 증가 없음. 1,000회 반복 후 host 포트 send right 참조 수 불변을 테스트로 확인.
- 기존 AI 소스 변경 여부: Git 변경 목록에 AI Provider·Store·설정·상태줄·UI 파일 없음.

## 검증 결과 (3단계)

- Debug·Release 빌드: 성공 (DerivedData `/private/tmp/tokenly-system-stage3-derived`). 신규·수정 파일 관련 경고 없음.
- `xcodebuild test`(Debug, `platform=macOS`): **TEST SUCCEEDED**, 133개 전부 통과(기존 125 + Battery 8). 보완한 포트 참조 테스트도 통과.
- `plutil -lint project.pbxproj`: 통과.
- 실측(Mac16,12, AC 연결·완충): 사이클 114, 설계 4629 mAh, 최대 4635 mAh, 건강도 100.1%, 온도 unsupported.
- 부하·누수: 독립 실행 하네스로 2만 회씩 5라운드(총 10만 회) 반복. 1회당 약 165 µs. `phys_footprint`는 첫 라운드에서 0.2 MB 늘어난 뒤 2.70 MB로 유지되었다(초기 할당 안정화). Mach 포트 수 22 → 22로 변화 없음. `leaks --atExit`: 0 leaks.
- 배터리 없는 Mac과 읽기 실패 경로는 실기기로 재현하지 못했다. `BatteryRegistryRead` 주입 테스트로만 검증했다.
- 기존 AI 소스·CPU·RAM 계산 로직 변경 없음.

## 검증 결과 (3-1단계)

- Debug·Release 빌드: 성공 (DerivedData `/private/tmp/tokenly-system-stage31-derived`). System Monitor 파일 관련 경고 없음.
- `xcodebuild test`(Debug, `platform=macOS`): **TEST SUCCEEDED**, xcresult 기준 153개 통과, 실패·건너뜀 0(기존 AI 112 + System Monitor 41).
  - 첫 실행에서 `testFailureIsAGapNotZeroAndRecovers` 1개가 실패했다. 실패 샘플의 시각(실제 `Date()`)과 스크립트 시각(고정 날짜)이 섞여 기록이 "시계 역행"으로 초기화된 테스트 구성 문제였다.
  - Store에 `now` 시계를 주입하도록 고쳐 해결했다. 실제 앱에서는 둘 다 같은 시계를 쓴다.
- `plutil -lint project.pbxproj`: 통과.
- 실제 배터리(Mac16,12, 어댑터 연결·완충): 앱 결과는 잔량 100%, 외부 전원 연결, 충전 안 함이었고 `pmset -g batt`("AC Power", 100%, charged)와 일치했다.
  - 전원 분리, 충전 중, 전원 알림 수신은 이 환경에서 상태를 바꿀 수 없어 확인하지 못했다(사용자 확인 필요).
- 실제 Store(Live 타이머, CPU·RAM·Battery 모두 켬): 70초 실행 후 CPU·RAM 기록이 각각 60개(상한 유지)였다.
  - 프로세스 CPU 0.033초(0.048%)였다.
  - 모두 끈 뒤에는 현재값·기록이 지워졌고, 3초 동안 CPU 사용은 0.0004초였다.
- `leaks --atExit`(30초 실행): 0 leaks.
- 메모리 장기 점검 (모두 저장소 밖 독립 실행 하네스로 측정)
  - 첫 측정에서는 footprint가 10분간 2.18 → 3.15 MB로 계속 늘었다. autorelease pool을 비워도 같았다.
  - `heap` 비교 결과 늘어난 것은 libdispatch `_dispatch_source_set_handler` 할당(초당 약 4개)뿐이었다. `malloc_history`로 보니 모두 하네스의 `-[NSRunLoop runUntilDate:]` → `__CFRunLoopRun` 경로였다. 제한 시간을 둔 run loop에 다시 들어갈 때마다 CoreFoundation이 만드는 것으로 Store와는 무관하다. Store에서 나온 할당은 `PowerSourceObserver.init` 1건(최초 1회)이었다.
  - run loop에 한 번만 들어가도록(`CFRunLoopRun()`) 하네스를 고친 뒤 비교했다.
    - malloc 객체 수: 1분과 5분 30초 모두 1,302개로 같았다(바이트 +96).
    - `vmmap`(1분 → 4분 20초): 실제 사용 메모리(dirty + 압축)는 2,560 KB → 2,608 KB로 +48 KB였다. 나머지 footprint 변화는 쉬는 페이지가 압축된 것으로, 할당자·OS 수준의 소폭 변동이다.
  - 결론: Store의 힙 누적·누수는 확인되지 않았다. 실제 앱(AppKit 이벤트 루프)에서의 장시간 확인은 8단계 V7에서 한다.

## 3-2 사전 기술 검증 (구현 전)

- 저장소 밖 임시 하네스와 현재 앱 설정을 복제한 임시 `.app`으로 프로세스 조회를 측정했다. 셸 788개 중 371개 성공·417개 `EPERM`, 임시 앱 792개 중 375개 성공·417개 `EPERM`. 성공 PID는 확인 가능한 범위에서 현재 사용자 소유였다.
- 활동 모니터 전체 프로세스 목록의 `WindowServer`·`kernel_task`는 조회 목록에서 빠졌다. 따라서 전체 시스템의 정확한 CPU·RAM TOP 5는 현재 일반 사용자 권한으로 보장할 수 없다. 조회 가능한 프로세스 범위의 TOP 5와 범위 안내를 제안한다.
- `ri_phys_footprint`와 활동 모니터의 사용자 프로세스 메모리 값은 주요 PID에서 가까웠다. CPU 시간은 Mach tick이므로 `mach_timebase_info` 변환이 필요하며, 변환 뒤 단일 코어 부하가 약 100%로 측정됐다.
- 순회 비용은 약 2~8 ms. 당시 앱 소스·프로젝트·AI Monitor는 변경하지 않았다. 상세 수치와 검증 한계는 `Doc/SYSTEM-MONITOR.md` §3 V4에 기록했다. 이후 사용자 승인으로 아래 구현을 진행했다.

## 3-2 구현

- `ProcessTopMetrics.swift`: 접근 가능한 프로세스의 CPU·RAM 순위 계산, 최대 5개, Mach timebase 변환, PID 시작 시각 확인. UI 제목·권한 안내 문자열도 여기에 둔다.
- `ProcessTopSampler.swift`: `proc_listpids`·`proc_pid_rusage(RUSAGE_INFO_V2)`·BSD 프로세스 이름 조회. 실패 PID는 제외하고 권한 거부 수를 기록한다. actor가 CPU 기준값을 직렬화한다.
- `ProcessTopStore.swift`: 팝오버별 `setVisible("cpu"/"memory", Bool)` 준비. 하나라도 열리면 즉시 및 3초 간격 수집, 모두 닫히면 중단·초기화. 중복 읽기와 닫힌 뒤 늦은 결과 게시를 방지한다. 실제 UI 연결은 6단계.
- `ProcessTopTests.swift`: 시간 변환·멀티코어·PID 재사용·종료·카운터 감소·부분 조회·정렬·최대 5개·시작/중지/재시작·중복 작업을 검증한다.
- 임시 앱에 동일 Sampler 소스를 넣어 실행: 조회 성공 423·권한 거부 393, CPU 예시 Terminal 22.6%, RAM 예시 가상 컴퓨터 서비스 6028 MiB. 10회 전체 순회 1.7~3.5 ms. 전체 시스템 TOP 5를 보장하지 않는다.
- 최종 검증: Debug·Release 빌드 성공, `plutil -lint`·`git diff --check` 통과. Debug `xcodebuild test`는 xcresult 기준 162개 통과·실패 0·건너뜀 0(기존 153 + 신규 9). 첫 전체 실행에서 기존 `SystemMonitorTests.testMachSamplerReportsBaselineThenValidRanges`가 200 ms 후 CPU 값이 없어 한 번 실패했으나 재실행에서 통과했다. CPU·RAM 전체 사용률 계산 코드는 변경하지 않았다.

## 3-2 안정화 (Codex 리뷰 반영, Claude, 2026-10-27)

- **문제 A (Medium): 프로세스 목록 조회 실패와 빈 목록을 구분하지 못함**
  - 원인: `proc_listpids` 실패 시 빈 PID 목록으로 처리했다.
  - 수정
    - 원시 읽기와 Sampler 결과를 `SystemMetric`으로 바꿨다. 크기 조회나 목록 조회가 0 이하면 `.unavailable(.readFailed(errno))`("조회 불가"), 성공했지만 0개면 `.available` + `readableCount == 0`("목록 없음")이다.
    - 조회 실패 때 CPU 기준값은 유지한다.
    - 테스트에서 실패를 주입할 수 있도록 `LiveProcessReader.read(listPIDs:)`에 조회 함수를 받게 했다.
  - 권한 거부와 개별 PID 실패를 제외하는 정책, TOP 5 계산(`ProcessTopCalculator`)은 변경하지 않았다.
- **문제 B (Medium): 팝오버를 닫아도 진행 중인 수집이 계속됨**
  - 원인: 중지할 때 타이머만 취소했다. 또 이전 Task가 끝나면서 `sampling`·`pendingSample`을 무조건 초기화해, 재시작한 뒤의 새 수집 상태를 지울 수 있었다.
  - 수정
    - 중지 시 Task도 취소한다.
    - Sampler는 읽기 전후에, 순회는 PID 64개마다 `Task.checkCancellation()`을 확인한다.
    - 완료 처리는 같은 세대일 때만 상태를 바꾼다. `sampling` 플래그는 없애고 `pendingSample`을 기준으로 삼았다.
    - 다시 열면 즉시 새 수집을 시작한다.
  - Codex 테스트 `testReopenDuringOldScanStartsFreshBaselineWithoutOverlap`은 "이전 수집이 끝날 때까지 새 수집을 미룸"을 검증하던 것이라, 이번 요구사항에 맞춰 `testReopenStartsImmediatelyEvenIfTheOldScanIgnoresCancellation`으로 교체했다.
- **문제 C (Low): CPU 실기기 테스트 간헐 실패** (`XCTUnwrap failed: expected non-nil value of type "CPUUsage"`)
  - 원인을 단정하지 않고 실측했다.
    - 200 ms 간격 150회 중 65회가 `noElapsedTicks`였고, 그때 원시 tick 차이는 네 값 모두 0이었다.
    - 5 ms 간격 관찰에서 카운터가 최대 993 ms 동안 멈췄다.
    - 900 ms 간격에서는 60회 중 2회, 1000 ms 간격에서는 30회 중 0회였다.
  - 따라서 원래 실패는 이 현상과 일치한다. 다만 원래 실패한 실행의 사유는 기록이 없어 직접 확인하지 못했다.
  - 테스트 수정
    - 대기를 1.1초로 늘렸다.
    - 설계상 구간을 건너뛰는 `noElapsedTicks`·`counterReset`에 한해서만 최대 3회 다시 시도한다.
    - 그 밖의 사유(`readFailed`, `awaitingBaseline` 등)는 즉시 실패시키고 사유를 출력한다. 재시도가 있었으면 `MACH_CPU_SKIPPED_INTERVALS`로 사유를 남긴다.
  - CPU 계산 코드는 변경하지 않았다.
- **추가한 회귀 테스트 8개**
  - Sampler: 조회 실패와 목록 없음 구분, 실패 뒤 기준값 유지, 조회 함수 주입으로 errno 확인, 읽기 전·중 취소, 실제 순회 취소
  - Store: 닫으면 Task 취소, 취소를 무시한 이전 수집이 있어도 즉시 재시작하며 늦은 결과가 게시되지 않음, 조회 불가 게시 후 복구
- **검증**
  - Debug·Release 빌드 성공, `plutil -lint` 통과
  - `xcodebuild test` xcresult 기준 169개 통과, 실패·건너뜀 0
  - CPU 실기기 테스트와 `ProcessTopStoreTests`를 `-test-iterations 10`으로 반복 실행해 60회 모두 통과
  - AI Monitor 파일 변경 없음
- **진행 중 오류**
  - 첫 테스트 빌드가 컴파일 오류로 실패했다(`'await' in an autoclosure that does not support concurrency`). `XCTUnwrap(try await …)` 형태 때문이었다.
  - `await` 결과를 먼저 변수에 받는 방식으로 고쳤다.
- **남은 위험**: 1초 Store 측정에서도 타이머 간격이 1초보다 짧아지면 CPU 값이 빈 구간이 생길 수 있다. UI 단계에서 표시 정책을 정해야 한다.

## 4단계 Disk (Claude, 2026-10-27)

- **구현**
  - `DiskUsage.swift`: `DiskCapacityRead`와 `DiskUsage.make`. 전체·사용 가능·사용·사용률을 계산하고, 중요한 용도 기준 가용 값은 별도 필드에 둔다.
  - `DiskSampler.swift`: `DiskSampling` 프로토콜과 공개 API `URL.resourceValues(forKeys:)`로 `/`를 읽는 구현. 매번 새 URL로 읽고, nonisolated async라 메인 스레드 밖에서 실행된다.
  - `SystemMonitorStore`
    - `.disk` 지표와 `disk` 값, `diskInterval = 60`, `pendingDiskSample`을 추가했다.
    - 켤 때 즉시 한 번, 이후 60초마다 읽는다. 끄면 타이머를 멈추고 진행 중 Task에 취소를 요청하고 값을 지운다. 이미 시작된 동기 API 호출은 끝까지 실행될 수 있고, 그 결과는 세대 검사로 버린다(즉시 중단은 보장하지 않음).
    - CPU·RAM과 같은 세대 방식으로 중복 측정과 늦은 결과를 막는다.
  - CPU·RAM·Battery·ProcessTop 코드는 변경하지 않았다. Store에는 init의 `disk:` 인자(기본값 있음)와 Disk 분기만 추가했다.
- **측정 기준:** 사용 가능 = `volumeAvailableCapacity`(보수적 기준), 사용 = 전체 − 사용 가능. 근거·검증 기록·표시 규칙(10진 GB, 정수 % 반올림)은 `Doc/SYSTEM-MONITOR.md` §3 V6와 §4 "Disk (4)"에 있다.
- **검증**
  - Debug·Release 빌드 성공, `plutil -lint` 통과.
  - `xcodebuild test` xcresult 기준 181개 통과, 실패·건너뜀 0(기존 169 + `DiskUsageTests` 6 + `SystemMonitorStoreDiskTests` 6).
  - 실측(Mac16,12): 전체 245.11 GB, 사용 가능 51.85 GB(시스템 정보 Free와 일치), 사용 78.8%, 중요한 용도 기준 가용 65.55 GB.
  - AI Monitor 파일 변경 없음.
- **4단계 마무리 (Codex 리뷰·GUI 비교 반영)**
  - 시스템 설정 > 저장 공간(사용자 확인): 전체 245.11 GB, 사용 중 179.45 GB, 남은 공간 65.66 GB였다. 중요한 용도 기준 가용(65.55 GB)과 가깝다. 측정 시점이 달라 완전 일치는 주장하지 않는다. Finder 캡처에는 사용 가능 수치가 없어 Finder 비교는 미완료다.
  - 표현 수정(Codex 리뷰)
    - 중요한 용도 기준 값과 보수적 값의 차이를 "정확한 purgeable 총량"이라고 쓰던 표현을 고쳤다(`DiskUsage.swift` 주석, SYSTEM-MONITOR V6·§4).
    - "끄면 진행 중 호출이 즉시 중단된다"는 표현을 "취소 요청과 늦은 결과 폐기만 보장한다"로 고쳤다.
    - 계산 로직은 변경하지 않았다.
  - 6단계 UI 후보로 "시스템 설정 기준 사용 가능 공간"(중요한 용도 기준)과 "보수적 가용 공간"(기본)을 구분해 기록했다. 메뉴 막대 사용률 기준(78.8% 대 73.3%)은 미확정이다(SYSTEM-MONITOR §4 "Disk (4)").
  - 후속 보강 테스트: Disk 읽기 도중 비활성화·재시작 경쟁 상태.
- **후속 보강 과제(이번 범위 제외):** 3-2 재검증에서 남은 Low 항목인 "긴 PID 순회 도중 취소" 테스트.

## 5단계 GPU 기술 검증 (Claude, 2026-10-27)

- 범위: 측정 가능성 검증만 했다. 저장소 코드는 변경하지 않았고, 검증 코드는 세션 임시 폴더의 하네스로만 작성했다.
- 결과 요약 (상세는 `Doc/SYSTEM-MONITOR.md` §3 V5 검증 기록)
  - 공개 API로는 시스템 전체 GPU 사용률을 얻을 수 없다. Metal은 이 M4에서 `timestamp` 카운터 세트만 지원하고, `powermetrics`는 root가 필요하다.
  - IORegistry `IOAccelerator` → `PerformanceStatistics` → `Device Utilization %`(문서화되지 않은 키)는 Metal 부하 테스트에서 실제 셰이더 실행 비율과 강하게 연동됐다(99.0% 대 99.2%, 53.4% 대 47.7%). 관찰 범위는 0~100, 일반 권한으로 읽혔고 1회 약 40 µs다.
  - 값이 순간값에 가까워 1초 1회 읽기는 평균 오차 42.7%p였다. 약 100 ms 간격 평균은 11.5%p였다.
  - Renderer·Tiler 키는 컴퓨트 부하를 절반 이하로만 반영해 쓰지 않는다.
- 판단 B 제안: 문서화되지 않은 방식이라 실험적 지원만 가능하다. 대안 C는 미지원 처리. 사용자 결정을 기다린다.
- 부하 테스트: 짧은 Metal 컴퓨트 부하를 두 번 실행했다(약 26초, 14초). 자동으로 종료되고 파일을 쓰지 않는다.
- 미검증: 다른 Apple Silicon 세대와 macOS 버전, App Sandbox 환경, 활동 모니터 GPU 기록과의 비교.

## 5단계 GPU 엔진 구현 (Claude, 2026-10-27)

- **구현**
  - `GPUUsage.swift`
    - `GPURegistryRead`, `GPUReading`: 읽기 판정. 서비스 없음·여러 개·통계 없음·키 없음·타입 오류·범위 밖·읽기 실패를 구분한다.
    - `GPUSampleSchedule`: 시드 기반 슬롯 내 무작위 읽기 시각
    - `GPUUtilizationWindow`: 1초 창, 유효 5개 이상일 때만 평균
  - `GPUSampler.swift`: 매 읽기마다 IOAccelerator 서비스를 재탐색하고 해제한다. arm64가 아니면 `notAppleSilicon`. `supportStatus()`로 지원 여부를 확인할 수 있다.
  - `SystemMonitorStore`
    - `.gpu`, `gpu`(실험적 추정 사용률), `gpuHistory`를 추가했다.
    - one-shot 타이머로 슬롯마다 1회 읽고, 1초 창이 닫힐 때 1회 게시한다.
    - 긴 공백이나 잠자기 뒤에는 열린 창을 버린다. 끄면 대기 중 읽기 취소와 세대 증가 후 값·기록·부분 창을 지운다.
  - `SystemMonitorScheduling`에 `once(after:)`를 추가했다. 실제 구현은 Timer 1회, 허용 오차 5 ms다.
    - 테스트 Scheduler 두 개에도 추가했다. `ProcessTopTests`의 `ProcessTimer`에는 호출되면 실패하는 스텁만 넣었다(프로세스 수집은 one-shot을 쓰지 않음).
  - CPU·RAM·Battery·Disk·ProcessTop 측정 로직과 AI Monitor·UI는 변경하지 않았다.
- **검증**
  - Debug·Release(Intel 포함) 빌드 성공, `plutil -lint` 통과.
  - `xcodebuild test` xcresult 기준 204개 통과, 실패·건너뜀 0(기존 181 + GPU 23).
  - 실기기 읽기: 이 Mac에서 `utilization` 0~100, 서비스 1개.
- **실제 앱 비용 (저장소 밖 측정 프로그램, 실제 Store·타이머·IOKit):** GPU를 켜면 프로세스 CPU 약 0.5%였다. 스케줄링만 하면 0.19%, GPU를 끄면 ≈0%였다. `top` idle wakeups는 약 3~4/s(정정값, 아래)였다.
  - 단일 읽기는 연속 반복 시 수십 µs(실행마다 19~45 µs)지만, 100 ms 간격으로 따로 읽으면 약 290~350 µs다.
  - 배터리 영향은 측정하지 않았다(추정만).
  - 완화 대안 세 가지는 SYSTEM-MONITOR §4 "GPU (5)"에 있다. 결정이 필요하다.
- **남은 위험**
  - 문서화되지 않은 키다. macOS 14·15, 다른 Apple Silicon, App Sandbox, 잠자기 실제 복귀는 미검증이다.
  - 1초 값은 1초에 10번만 읽는 데서 오는 잡음이 있다(주기 부하 시뮬레이션에서 1초 값 20~90%, 1분 평균 51%).

## GPU 비용 로그 보존과 idle wakeups 정정 (Claude, 2026-10-27)

- `Doc/logs/2026-10-27-gpu-cost.txt`에 원본 출력을 보존했다.
  - 단일 읽기 비용 재측정(16:08, 기존 `gpucost3`·`gpucost4` 그대로 재실행, GPU 부하 없음)
  - 기존 실제 Store 비용 로그(`gpucost`·`gpucost2`, 15:52~15:56)
  - 실행 환경, 측정 조건, 단위, 측정 프로그램 소스(재현용)
- 재측정 결과
  - 100 ms 간격 읽기 346 µs(이전 350), 현재 방식 288 µs(이전 301): 이전과 비슷했다.
  - 연속 읽기 19 µs(이전 45): 크게 달랐고 원인은 확인하지 않았다.
- **idle wakeups 정정:** 이전 기록 29.3/s, 10.2/s, 9.8/s는 `top` IDLEW 누적 카운터의 평균을 4초로 나눈 잘못된 계산이었다.
  - 첫·마지막 기록의 차이로 다시 계산했다: GPU 끔 0/s, GPU 켬 60초 약 4.3/s, 가짜 Sampler 30초 약 2.8/s, 실제 Sampler 30초 약 3.4/s.
  - 짧은 구간의 대략값이며, 시스템 전체 깨어남 횟수와 같지 않다.
  - SYSTEM-MONITOR §4 "GPU (5)"와 BLOG-NOTES에도 반영했다.
- 코드는 변경하지 않았다.

## 5단계 GPU 안정화·최적화 (Codex 리뷰 반영, Claude, 2026-10-27)

- **Medium: 오래된 창 게시**
  - 원인: 창이 끝난 뒤 1초 미만이면 무조건 게시해, 창 시작 1.9초 뒤 재개 시 약 1초 전 데이터를 현재값으로 게시했다.
  - 수정
    - `GPUUtilizationWindow.isFresh(closingAt:)`: 닫는 읽기 지연 ≤ 0.25초, 그리고 마지막 유효 읽기 나이 ≤ 0.75초일 때만 게시한다.
    - 아니면 폐기하고, 현재값을 `.unavailable(.insufficientSamples)`로 바꾸고 새 창을 시작한다.
  - 기준의 근거는 SYSTEM-MONITOR §4 "GPU (5)"에 있다. 마지막 유효 읽기 기준은 처음 0.5초로 했다가, 끝 몇 번이 실패한 정상 창까지 버려서 0.75초로 완화했다.
- **Medium: 실기기 테스트의 호환성 가정**
  - arm64이면 반드시 읽힌다고 가정하던 것을 고쳤다.
  - 검증 환경(Mac16,12 + macOS 27.0.1)만 지원을 필수로 하고, 다른 기기는 미지원 판정을 허용한다. 지원 여부와 값의 유효성을 따로 검사한다.
- **Low: 샘플 시각:** IOKit 읽기 시작 시각으로 명시했다. 창 경계에서 시작한 읽기가 다음 창에 속함을 테스트했다.
- **최적화 B안 (서비스 핸들 재사용)**
  - `GPUSampler`를 class로 바꿨다. IOKit 호출은 `GPURegistryAccess`로 분리했다.
  - 유효한 사용률을 준 서비스만 캐시한다. 비정상 결과가 나오면 즉시 다시 찾는다.
  - 10초마다, 그리고 2초 넘게 읽지 않았으면 재검증한다. 실패 시 5초 동안 재시도하지 않는다.
  - `reset()`(끌 때)과 deinit에서 핸들을 해제한다.
  - `GPUSampling`에 `reset()`을 추가했다(기본 구현은 비어 있음). Store는 끌 때 이를 호출한다.
  - 초당 10회 읽기, 슬롯 분산, 1초 평균, 최소 유효 5개는 유지했다.
- **변경 파일:** `GPUUsage.swift`, `GPUSampler.swift`, `SystemMonitorStore.swift`(GPU 부분만), `SystemMetrics.swift`(`insufficientSamples` 설명), `GPUTests.swift`, `SystemMonitorStoreTests.swift`
  - CPU·RAM·Battery·Disk·ProcessTop, AI Monitor, UI는 변경하지 않았다.
- **검증**
  - Debug·Release 빌드 성공.
  - `xcodebuild test` xcresult 기준 219개 통과, 실패·건너뜀 0(기존 204 + 15).
  - 진행 중 오류와 해결
    - 테스트 컴파일 오류: `GPUReading`이 `Hashable`이 아닌데 `Set`을 썼다. `allSatisfy`로 바꿨다.
    - 테스트 기대값 오류 1건: 계속 늦는 타이머에서도 창이 제때 닫히면 빈칸(`nil`)이 기록되는 것이 맞다. "기록이 비어 있음"에서 "유효값이 게시되지 않음"으로 고쳤다.
    - 직접 작성한 잠자기 테스트의 기대값 오류: 첫 읽기에서 이미 새 서비스를 찾는다. 실행 전에 발견해 수정했다.
- **성능:** 같은 측정 프로그램으로 30초씩 번갈아 2회 비교했다(`Doc/logs/2026-10-27-gpu-cache-optimization.txt`).
  - 프로세스 CPU 평균 0.446% → 0.373%(약 16% 감소). 가짜 Sampler 대비 IOKit 몫은 약 26% 감소.
  - 실행 간 편차가 커서 감소 크기는 대략값이다. idle wakeups는 결론 내리지 않았다. 배터리는 측정하지 않았다.
- **남은 위험**
  - (최종 안정화에서 해소) 이상값 하나로 최대 5초 측정 불가가 될 수 있었다.
  - 서비스가 바뀌면 최대 10초 동안 이전 핸들이 응답할 수 있다.
  - 실제 서비스 소실·잠자기 복귀는 가짜 레지스트리로만 검증했다.
  - 문서화되지 않은 키와 미검증 기종·macOS의 위험은 그대로다.

## 5단계 GPU 최종 안정화 (Codex 최종 리뷰 반영, Claude, 2026-10-27)

- **Medium: 오류별 재시도 정책**
  - 원인: `fail()`이 실패 종류와 관계없이 5초 재시도 제한을 걸었다. 그래서 일시적 IOKit 오류나 이상값 한 번에도 GPU가 곧 정상이어도 최대 5초 동안 측정 불가였다.
  - 수정 (`GPUSampler`, 규칙과 간격은 코드 주석과 SYSTEM-MONITOR §4 "GPU (5)" 표에 있다)
    - 값 이상(`invalidType`, `outOfRange`): 응답하는 서비스이므로 핸들을 유지하고 대기 없이 다음 슬롯에 다시 읽는다. 처음 찾을 때 나와도 캐시한다.
    - 서비스 소실: 핸들 해제 후 즉시 다시 찾는다.
    - 일시 실패(`readFailed`): 0.25 → 0.5 → 1 → 2초 상한. 성공이나 `reset()`이면 처음부터 다시 센다.
    - 지원 불가(서비스 없음·여러 개·통계 없음·키 없음): 5초.
  - 10초 재검증, 2초 공백 재검증, 핸들 소유권 규칙은 그대로다.
- **Low: 동시 접근**
  - `GPUSampling`과 `GPUSampler`에 `@MainActor`를 붙였다. 락은 추가하지 않았다.
  - Store init의 `gpu:` 기본 인자는 비격리 문맥에서 평가되어 컴파일 오류가 났다. `(any GPUSampling)? = nil`로 바꾸고 init 안에서 `GPUSampler()`를 만든다(`scheduler`와 같은 방식).
  - `deinit`은 핸들 해제만 직접 한다(마지막 참조가 사라질 때만 실행되어 경합이 없다). 빌드 경고는 없었다.
- **테스트**
  - 추가 5개: 처음 찾을 때의 값 이상, 일시 실패 1회 후 0.25초 회복, 연속 일시 실패 대기 0.25/0.5/1/2/2초, 서비스·키가 계속 없을 때 5초마다만 탐색, `reset()`으로 대기와 횟수 초기화
  - 교체 1개: `testBadValueFromTheCachedServiceDropsTheCache` → `testSingleBadValueRecoversOnTheNextRead`. 기존 테스트는 "이상값 하나에 캐시를 버리고 5초 대기"를 검증했는데, 이것이 바로 고쳐야 할 Medium 동작이라 기대값을 바꿨다.
  - 시간 경계 테스트는 2진수로 정확한 간격(1/8초, 1/16초)을 써서 부동소수점 누적 오차를 피했다.
  - 테스트 클래스 `GPUSamplerCacheTests`와 실기기 테스트에 `@MainActor`를 붙였다.
- **검증**
  - Debug·Release 빌드 성공, 경고 없음.
  - `xcodebuild test` xcresult 기준 224개 통과, 실패·건너뜀 0.
  - GPU 관련 3개 클래스 34개를 `-test-iterations 5`로 반복해 170회 모두 통과했다.
  - AI Monitor·UI·다른 지표 변경 없음. 측정 로그 두 파일은 수정하지 않았다.
- **변경 파일:** `GPUSampler.swift`, `SystemMonitorStore.swift`(GPU 기본 인자 한 곳), `GPUTests.swift`
- **남은 위험**
  - 서비스가 바뀌어도 최대 10초 동안 이전 핸들이 응답할 수 있다.
  - 값 이상이 계속되면 초당 10회 읽기가 계속된다(비용은 정상과 같다).
  - 문서화되지 않은 키와 미검증 기종·macOS·App Sandbox 위험은 그대로다.
  - 실제 서비스 소실·IOKit 오류는 가짜 레지스트리로만 검증했다.

## 6단계 UI 명세 (2026-10-27, 구현 승인 대기)

- 기준 문서는 `Doc/SYSTEM-MONITOR.md` §7 하나다(이전 제안과 결정 필요 목록은 대체됨). 코드 변경은 없다.
- **사용자 확정 디자인**
  - CPU·RAM·Disk·GPU는 AI 숫자형과 같은 2단(`24%` 아래 `CPU`), 아이콘 없음
  - Battery는 한 줄 `82%`, 실제 충전 중에만 `⚡82%`(초록 번개). 배터리 외곽 아이콘 없음(2026-10-27 최종 확정. 그 이전 B안 "숫자 왼쪽 아이콘"을 대체)
  - `%`는 숫자와 같은 기준선
  - 이미지 안쪽 폭은 `100%` 기준 고정
  - Disk는 중요한 용도 기준, 값이 없으면 `—`
  - 토글·영속 저장은 6단계에 포함(7단계를 합침)
  - TOP 5 CPU는 코어 하나 기준(100% 초과 허용)
- **Codex 설계 리뷰(조건부 승인) 반영**
  - High: 위젯 상태 동기화 계약(§7.2). `SystemWidgetController`가 단일 소유자이고, 토글·`isInserted`·UserDefaults·`setEnabled`가 같은 setter를 거친다. 앱 시작 시 컨트롤러 init에서 적용한다. `isInserted == true`가 화면 노출을 보장하지 않는다는 점을 명시했다.
  - Medium: 확정 디자인 기록(§7.1), 팝오버 수명주기(§7.7: `ProcessTopStore` 하나, `"cpu"`/`"memory"` 키, `onAppear`/`onDisappear`를 가정하지 않고 6-4에서 검증 후 대안), 그래프 실패 구간(§7.8: 연속 유효 구간마다 별도 선).
  - Low: 일시 실패와 지원 불가 구분, Battery 4상태, 실제 충전 중일 때만 번개(§7.4·§7.6).
  - 추가 주의사항: Disk는 표시 계층에서 계산하고 `usedFraction` 금지, TOP 5에 AI 0~100 포맷터 금지, 픽셀 비교 테스트의 보장 범위, 재렌더링 비용 측정, AI 조회 경로 유지.
- 다음 작업: 6-3은 구현했고, 사용자 실기기 확인(토글 동작·위젯 표시) 뒤 간격·정렬·번개 정책을 보완했다(아래, 보완분 GUI 재확인 대기). 6-4(팝오버·그래프)는 별도 승인 후 진행하며, **M1을 먼저 해결**해야 한다.

## 6-4f: Battery 상세 팝오버 구현 (Claude, 2026-10-28)

상태: **구현 완료 · 자동 테스트 386개 통과 · Debug·Release 빌드 성공 · 오프스크린 확인 · 실제 앱 검증 대기**(실행 중인 PID 90019는 이전 빌드, 교체 승인 필요). 사양 SYSTEM-MONITOR §7.7-5.

- **신규:** `SystemMonitor/UI/BatteryPopoverView.swift`(상태·시간·전원·사이클·최대 용량·온도 표시 규칙과 화면), `TokenlyTests/BatteryPopoverTests.swift`(9개). pbxproj ID 079·080.
- **수정:** `BatteryStatus.swift`(`BatteryRegistryRead.properties`에 팩 자식 `BatteryData`, 온도 ÷100·범위, 오래된 "온도 키 없음" 주석 교체, `BatteryPowerState`에 `timeToEmpty`·`timeToFull`·`adapterWatts`와 파서, `BatteryTimeEstimate`), `BatterySampler.swift`(어댑터 W, 팩 자식 읽기), `SystemMonitorStore.swift`(`batteryReadDate`), `UI/SystemMonitorMenuBarScenes.swift`(Battery `.window` 팝오버), `BatterySamplerTests.swift`(실기기 온도 기대값). 수집 주기·메뉴 막대 Battery 표시는 그대로.
- **성능(측정 프로그램):** Battery 1회 읽기 0.372 ms(전원 + 어댑터 + 레지스트리 + 팩), 60초마다 + 전원 변경 시. 실제 앱 측정은 대기.
- **오프스크린:** `../../TokenlyDesignArchive.noindex/Stage6-8C/Battery/implementation-check/` 실측(완충 100%, 30W, 114회, 100%, 29°C)과 예시 2종(충전 중, 부족 + 온도 확인 불가), 다크·라이트.

## 6-4f 준비: Battery 팝오버 데이터 조사·디자인 미리보기 (Claude, 2026-10-28)

상태: 조사·미리보기 후 추천 구성 + 온도(배지 없음)로 승인되어 위와 같이 구현됨. 조사 내용은 SYSTEM-MONITOR §7.7-5 조사 기록.

- 현재 수집: 잔량·연결·충전·완충(공개 IOPowerSources), 사이클·설계/완충 mAh·비율(레지스트리). 추가 가능(공개): 남은 시간·완충까지 시간(분, -1 계산 중), 어댑터 W, 저전력 모드. 표시 안 함: 온도(키 없음), 전력 W(공개 전압 없음), 배터리 상태 문구(공개 키 미게시, `system_profiler`만).
- 이 Mac: 100%, AC 30W, 완충, 사이클 114, 4631/4629 mAh = 100%(시스템 정보 99% — 같은 값 아님).
- 미리보기: `../../TokenlyDesignArchive.noindex/Stage6-8C/Battery/`(추천 구성 + 상태별, 다크·라이트). 결정 대기: 최대 용량 줄, 어댑터 W, 저전력 모드, 부족 기준, 시간 표시.
- **온도 추가 조사(같은 날): 실험적 수집 가능, 정확도 미검증.** 공개 API 없음(`kIOPSTemperatureKey` 미게시). `AppleSmartBattery`의 자식 `AppleSmartBatteryPack` → `BatteryData.Temperature`(문서화 안 된 정수, ÷100 = °C; 2939 ↔ 비공개 HID "gas gauge battery" 29.40 °C로 단위 확인, 약 60초마다 갱신, 0.039 ms). 비공개 HID SPI는 대조용만(50 ms). SMC는 이 macOS 27·M4에서 키 읽기가 모두 `kIOReturnBadArgument`. 충전 상태에 따른 변화와 실제 온도 대비 정확도는 미확인. 제안: 기존 Battery 작업에 읽기 하나 추가(새 루프 없음), 정수 °C, "실험적" 배지 + ⓘ, 120초 넘은 값은 숨김. 미리보기 `battery-popover-temperature{,-missing}-{dark,light}.png`(기존 파일 보존). 탐침 `temperature-probe.swift`(같은 폴더).
- 6-4e 마무리: 사용자가 실제 Disk 팝오버를 확인 → **실제 앱 검증 완료**. 작은 속도 표기 "<0.1 MB/s"(읽기·쓰기 공통 `DiskPopoverPresentation.rate`), 경계 테스트 `testSpeedBoundaries` 추가. Disk 관련 테스트 21개만 재실행해 통과(전체 테스트는 다시 돌리지 않음, 총 377개), Debug·Release 빌드 성공. 실행 중인 앱(PID 90019)은 이 표기 변경 이전 빌드이며 교체하지 않았다.

## 6-4e: Disk 상세 팝오버 구현 (Claude, 2026-10-28)

상태: **구현 완료 · 자동 테스트 통과 · Debug·Release 빌드 성공 · 실제 앱 검증 완료**(팝오버 조작은 사용자가 확인, 2026-10-28). 사양은 SYSTEM-MONITOR §7.7-4.

- **신규:** `SystemMonitor/DiskActivity.swift`(카운터·추적기·장치 정보·눈금), `SystemMonitor/DiskActivitySampler.swift`(IOKit, actor), `SystemMonitor/UI/DiskPopoverView.swift`(용량 분해·표시·화면), `TokenlyTests/DiskActivityTests.swift`(14개). pbxproj ID 075~078.
- **수정:** `SystemMonitorStore.swift`(Disk가 켜져 있는 동안 1초 활동 작업, `diskActivity`·`diskDevice`·읽기/쓰기 기록, 끌 때 정리; 용량 60초·계산은 그대로), `UI/SystemMonitorMenuBarScenes.swift`(Disk만 `.window` 팝오버), `SystemMonitorStoreTests.swift`(Disk 켜짐 시 타이머가 60초 + 1초 두 개라는 기대값 3곳, 하네스에 활동 대역). CPU·RAM·GPU 화면·색, Disk 용량 측정 로직은 바꾸지 않았다.
- **테스트(14):** 메뉴 막대 % 일치, 세 영역 합 = 전체(바이트), 모순값 거부·꽉 찬 디스크, 10진 단위·속도 표기, 도움말 문구·장치 줄 생략 규칙, 실제 경과 시간 나눗셈·실제 0, 실패 후 재기준, 누적값 감소·장치 변경·잠자기·경과 0/역행·100 GB/s 초과, 눈금 상한 단계·최소 1, 기록 60초·공백 분리·0으로 안 그림, 저장소 수명주기(켤 때 1회, 1초 틱, 기준값은 점 없음, 실패는 공백, 끄면 폴링 중단·정리), 중복 읽기 방지·늦은 결과 폐기, 장치 선택 실패 ≠ 유휴, 이 Mac 실제 드라이버(`/`에서 찾음, `/dev`는 거부).
- **오프스크린(실제 메뉴 막대 아님):** 앱의 실제 `DiskPopoverView` + 실제 저장소 약 33초 — `../../TokenlyDesignArchive.noindex/Stage6-8C/Disk/implementation-check/disk-popover-offscreen-live-{dark,light}.png`, 장치 미발견 대역 `…-no-drive-dark.png`("확인 불가", "측정 데이터 없음"). 340 × 394pt. 구성 합계 일치, 메뉴 막대 76%와 같음, "Macintosh HD · APFS · 내장 SSD".
- **성능(저장소 밖 측정 프로그램):** 활동 읽기 0.067 ms/회, Disk 작업 켬 30초에 CPU 약 0.28% 코어.
- **실제 앱(사용자 승인 후 교체, 14:47~):** 이전 빌드 PID 84054를 일반 종료 요청으로 끄고(1초 안에 종료, 다른 프로세스 무관) `/private/tmp/tokenly-dd-Debug`의 새 Debug 빌드 실행. 지금 실행 중인 것은 PID 90019(같은 빌드). 설정은 시작 전과 같다(스크래치패드 `settings-before-disk.txt`와 비교).
  - 완료: 메뉴 막대 Disk 76% 표시(실제 팝오버 코드 오프스크린 값과 같음), Disk 꺼짐/켜짐 저장값으로 재실행 시 복원(`defaults`로 잠시 바꿨다가 원래 값 복원), 실제 앱 CPU 60초: Disk 꺼짐 0.85% → 켜짐 1.25% 코어(첫 측정 1.35%). 이전 빌드 3.03%는 Xcode 디버거 아래라 비교 제외.
  - 사용자 직접 확인 필요: 팝오버 열기와 내용(용량·막대·줄무늬·장치 줄), 읽기·쓰기 실시간 변화·60초 기록, 도움말 호버·클릭, 톱니바퀴, 테마 3종, 설정 창 토글 OFF/ON. 손쉬운 사용 권한이 없어 메뉴 막대 항목을 누를 수 없다.
- **다음:** 실제 앱 확인(승인 후), 이후 Battery 상세 팝오버(별도 지시).

## 6-4e 준비: Disk 팝오버 데이터 조사·디자인 미리보기 (Claude, 2026-10-28)

상태: 조사·미리보기 완료 후 B안 + P1으로 승인되어 위와 같이 구현됨. 조사 내용은 SYSTEM-MONITOR §7.7-4 조사 기록.

- **현재 수집:** 용량만(전체, 지금 비어 있음, 중요한 용도 기준 사용 가능; 켤 때 + 60초마다). 읽기·쓰기 속도는 수집하지 않는다.
- **추가 가능(공개 API):** 읽기·쓰기 누적 바이트(`IOBlockStorageDriver` `Statistics`, 공개 헤더 키, 1회 약 1 ms, 권한 불필요), 볼륨 이름, 장치 모델, SSD 여부, 내장 여부. **불가/비추천:** SMART 상태(외부 도구·비공개 플러그인), 일련번호(개인 정보).
- **주의:** 디스크 이미지도 `IOBlockStorageDriver`를 가지므로 합산하면 안 된다. `/` 컨테이너의 물리 장치 하나만.
- **미리보기:** `../../TokenlyDesignArchive.noindex/Stage6-8C/Disk/` — A안·B안(추천)·색 비교(P1/P2), 각 다크·라이트, 예시와 이 Mac 실측을 보드 제목에 구분, 모두 "합성 미리보기(실제 앱 화면 아님)" 표기. 탐침·미리보기 코드는 저장소 밖.
- **결정 대기:** A/B, 색 P1/P2, I/O 수집 시점(팝오버 열림 동안만 vs 위젯 ON 동안), 장치 줄 표시 여부.
- GPU 팝오버(6-4d)는 사용자가 실제 앱에서 정상 동작을 확인했다 → **실제 앱 검증 완료**로 갱신.

## 6-4d: GPU 상세 팝오버 구현 (Claude, 2026-10-28)

상태: **구현 완료 · 자동 테스트 통과 · 오프스크린 확인 · 실제 앱 검증 완료**(사용자 확인, 2026-10-28). 보류: 프로세스별 GPU 사용, 온도, VRAM, `powermetrics`. 사양은 SYSTEM-MONITOR §7.7-3.

- **신규:** `SystemMonitor/UI/GPUPopoverView.swift`, `TokenlyTests/GPUPopoverTests.swift`(pbxproj ID 073·074).
- **수정:** `GPUUsage.swift`(`GPUDeviceInfo`, `import Metal`), `UI/AuroraGraph.swift`(`AuroraPalette.Scheme`·`palette` 인자, 기본값 `standard`라 CPU·RAM 그대로), `UI/SystemWidgetPresentation.swift`(`gpuHeadline`, 도움말 문구), `UI/SystemMonitorMenuBarScenes.swift`(GPU만 `.window` 팝오버). GPU 측정 엔진은 바꾸지 않았다.
- **테스트:** 362개 통과(355 + 7): 0%·실패·측정 전 구분, 메뉴 막대 값과 일치, 실패 창·공백이 그래프에서 끊기고 0이 아님, GPU 색 HEX와 CPU·RAM 색 불변, 코어 수 허용 범위(0·음수·5000·8.5·문자열·데이터 거부), 이름 대체 순서, 이 Mac 실측(이름 = Metal 이름, 한 번 읽어 재사용). Debug·Release 빌드 성공, 새 경고 없음.
- **오프스크린(실제 메뉴 막대 아님):** 실제 `GPUPopoverView`를 앱 측정 경로로 약 20초 실측해 렌더링(다크·라이트), 그리고 GPU 읽기가 항상 실패하는 저장소로 실패 상태(다크) — `../../TokenlyDesignArchive.noindex/Stage6-8C/GPU/implementation-check/`. 340 × 194pt, "Apple M4 · GPU 코어 8개", 실패 시 "— 확인 불가"와 "측정 데이터 없음"(기록 19점 모두 `nil`).
- **실제 앱:** 새 빌드(PID 84054, GPU 팝오버 포함 확인)는 사용자가 실행했지만, 수동 확인 절차는 사용자 결정으로 생략. 이후 사용자가 실제 앱에서 정상 동작을 확인했다(6-4e 요청에서 전달). Claude가 따로 기록하지 않은 세부 항목: 실제 메뉴 막대에서 팝오버 열기, 배지 도움말·톱니바퀴 동작, 테마 반복 전환에서의 GPU 팝오버, GPU 위젯 ON/OFF 재실행 복원, 팝오버 열림 전후 CPU 부하. 설정값은 시작 전과 같음(GPU 위젯 꺼짐, 비교 확인). 미완성 `real-app-check/` 기록은 쓰지 않았으며 Stage 6-8C에서 선별 보존 대상에서 제외해 원본과 함께 휴지통으로 이동했다.

## 6-4c 마무리 + 6-4d GPU 팝오버 준비 (Claude, 2026-10-28)

- **RAM 압박 배지 색 — 구현 완료·테스트 통과·실제 앱 확인:** 상태별 색(SYSTEM-MONITOR §7.7-2). 테스트 1개 추가(다크 확정값, 네 상태 서로 다름, 다크·라이트 모두 글자 대비 ≥ 4.5:1, 알 수 없음은 회색, 문구 매핑). 사용자가 새 빌드에서 확인("이상 없음", 실제 상태 "주의" = 앰버).
- **RAM 위젯 ON/OFF·재실행 복원 — 실제 앱 검증 완료 (13:58~14:00, 사용자가 Xcode로 종료·재실행):** 1초 기록기가 설정값(`systemWidget.*.inserted`)·Tokenly PID·메뉴 막대 캡처를 남김(`../../TokenlyDesignArchive.noindex/Stage6-8C/RAM/onoff-relaunch-check/`).
  - RAM OFF(13:59:21) → 재실행(PID 81732)에도 OFF 유지, 메뉴 막대에 RAM 없음(CPU·Disk·Battery는 그대로).
  - RAM ON(13:59:42) → 재실행(PID 82045)에도 ON 유지, RAM 다시 표시.
  - 다른 위젯 값(CPU·Disk·Battery ON, GPU OFF)은 내내 그대로. 끝난 뒤 설정 전체가 시작 전과 같음(비교 확인).
  - RAM OFF 시 수집·압박 정리는 자동 테스트로 확인(`testPressureFailureLeavesUsageIntactAndIsCleared` 등).
- **GPU 팝오버 — 디자인 검토 단계, 실제 기능 미구현:** 데이터 조사와 미리보기(SYSTEM-MONITOR §7.7-3). 앱 코드 변경 없음.
- **테스트·빌드:** 355개 통과(354 + 1), Debug·Release 빌드 성공, 새 경고 없음.

## 6-4c: RAM 상세 팝오버 구현 (Claude, 2026-10-28)

상태: **구현 완료 · 자동 테스트 통과 · 실제 앱 검증 완료.** 보류·미착수: GPU·Disk·Battery 팝오버, 6-5. 사양은 SYSTEM-MONITOR §7.7-2.

- **신규:** `SystemMonitor/UI/RAMPopoverView.swift`(팝오버, `MemoryCompositionBar`), `TokenlyTests/RAMPopoverTests.swift`. `project.pbxproj` 등록(ID 071·072).
- **수정:**
  - `SystemMetrics.swift`: `MemoryPressure`(매핑·sysctl 읽기).
  - `SystemMonitorStore.swift`: `memoryPressure` 게시, RAM 샘플마다 읽기, RAM OFF 시 지움, 읽기 함수 주입(`memoryPressure:` 인자, 기본 실제 읽기).
  - `ProcessTopMetrics.swift`: `ProcessMemoryEntry.startTicks`, `ProcessNames`(31자 이름 보완 규칙).
  - `ProcessTopSampler.swift`: 꽉 찬 이름만 `proc_pidpath`로 보완(`LiveProcessReader.executableName`).
  - `SystemWidgetPresentation.swift`: `memoryComposition`, `memoryPressureText`, `memoryTopRows`, 도움말 문구.
  - `SystemMonitorMenuBarScenes.swift`: RAM만 `.window` 팝오버.
  - `CPUPopoverView.swift`: 디자인·지표 변경 없이 이름 툴팁 1줄과 아이콘 캐시가 CPU·RAM 두 목록을 함께 유지하도록(공유 캐시가 서로 지우지 않게).
- **검산:** 이 Mac 실측 사용 14.08 GB, 네 칸 합 = 17,179,869,184 바이트 = 전체. 테스트: 고정 페이지 수(이 Mac의 `vm_stat`)로 계산기 → 네 칸 합 = 전체, 실측 샘플로도 같음.
- **테스트:** 354개 통과(339 + 15). 추가: 구성 합·사용률 일치·불일치 값 거부·실측 합, 압박 매핑(1/2/4, 그 밖은 추정 안 함, 공개 Dispatch 값과 같음)·문구(실패·nil = "확인 불가")·이 Mac 실측 읽기·읽기 실패가 사용량에 영향 없음·RAM OFF 시 지움·CPU만 켜면 읽지 않음, TOP 5 정렬·5개·형식·시작 시각 보존, 이름 보완(31자만·접두 일치만·실패 시 원래 이름·짧은 이름은 조회 안 함)·이 프로세스 실행 파일 이름, RAM 팝오버 수집 시작·중지·반복·CPU와 공유, 확정 HEX 4색. Debug·Release 빌드 성공, 새 경고 없음.
- **오프스크린(실제 메뉴 막대 아님):** 실제 `RAMPopoverView`를 실측으로 렌더링 — `../../TokenlyDesignArchive.noindex/Stage6-8C/RAM/implementation-check/`. 미리보기와 같은 340 × 394pt.
- **실제 앱 검증 (Xcode 재실행 빌드 PID 69815, 12:38~12:45):** 판정기(창을 `screencapture -l`로 찍어 배경·글자 판정)와 `/usr/bin/log stream` 기록, 결과 `../../TokenlyDesignArchive.noindex/Stage6-8C/RAM/real-app-check/`.
  - 사용자 수행: RAM 팝오버 확인, 두 ⓘ, 긴 이름 툴팁, 톱니바퀴, 설정 창 연 채 다크·라이트·다크·라이트·시스템·다크, RAM·CPU·AI 팝오버를 다크·라이트에서 각각, RAM 팝오버 빠른 반복. 사용자 확인 "이상 없음".
  - 판정: 창이 보인 130회 중 129회 일치, 1회는 설정 창이 닫히며 흐려지는 프레임(내용은 정상)이었다.
  - 로그: RAM 팝오버 열기·닫기마다 `memory` 키가 `appear`·`window` 두 신호로 켜지고 `disappear`·`window`로 꺼짐, CPU·RAM 사이 전환도 각각 짝을 이룸.
  - 스크린샷: RAM 다크(TOP 5 도움말 펼침)·라이트, 압박 "주의"(실측), 전체 이름 "com.apple.Virtuali…ion.VirtualMachine"(가운데 생략).
- **미검증:** 메뉴 막대 위젯 ON/OFF 후 재실행 복원은 이번에 실제로 하지 않았다(자동 테스트로만, 선택 단계였음). 압박 "정상"·"높음"과 "확인 불가"는 실제 화면에서 보지 못했다(테스트로만).

### (이전) 6-4c 디자인 미리보기 기록

- 미리보기만 만들었다(앱 코드·테스트·설정 변경 없음): `../../TokenlyDesignArchive.noindex/Stage6-8C/RAM/ram-popover-example-{dark,light}.png`(예시 데이터), `ram-popover-live-data-{dark,light}.png`(이 Mac 실측을 한 번 읽음), `measurements.txt`, `preview-script.swift`. 앱의 `AuroraGraph`·`ProcessIconView`·포맷터를 그대로 썼다.
- 사양·데이터 검토는 SYSTEM-MONITOR §7.7-2. 요점: 앱·와이어드·압축은 겹치지 않고 합이 사용, 네 번째 칸은 "사용 가능(전체 − 사용, 캐시 포함)". 메모리 압박은 아직 수집하지 않음(공개 sysctl로 추가 가능). TOP 5 값은 phys_footprint.
- 다음: 사용자 승인 후 구현(압박 레벨 수집 추가 여부 포함).

## 6-4b: CPU 상세 팝오버 구현 — B1 Aurora Flow (Claude, 2026-10-28)

상태: **구현 완료 · 자동 테스트 검증 완료 · 실제 앱 확인 완료(라이트·다크·시스템 반복 전환 포함).** RAM·GPU·Disk·Battery 팝오버와 6-5는 시작하지 않았다. 사양은 SYSTEM-MONITOR §7.7-1.

- **테마 반복 전환 오류 근본 수정 (2026-10-28):**
  - 증상(사용자): 앱 외관 다크 → 라이트 → 다크 후 설정 창이 어두운 배경에 검은 글자. 앞선 CPU 팝오버 수정(창별 `NSWindow.appearance`)으로는 해결되지 않음.
  - 근거(저장소 밖 재현 앱: SwiftUI `Settings` 장면 + 메뉴 막대 항목, 창을 `screencapture -l`로 찍어 배경·글자 밝기로 판정, 5가지 순서 × 창 유지/다시 열기):
    - A `.preferredColorScheme`(설정 창·AI 팝오버의 기존 방식): 다크↔라이트는 맞지만 **라이트 → 시스템에서 배경 0.25 / 글자 0.02**(창은 시스템 다크로 돌아가고 SwiftUI 색 체계는 라이트에 남음).
    - B 창별 `NSWindow.appearance`(앞선 CPU 수정 방식): SwiftUI가 창 외관을 다시 덮어써 거의 모든 단계에서 창 다크·글자 라이트.
    - C `NSApp.appearance`만 사용: 30단계 모두 일치, 메뉴 막대 라벨은 메뉴 막대를 계속 따름.
    - 사용자의 "다크"가 "시스템 설정 따르기 + 시스템 다크"였거나, A·B가 섞인 상태(설정 창 A, CPU 팝오버 B)가 원인으로 보인다. 앞선 수정이 듣지 않은 이유는 B가 SwiftUI 관리 창에서 유지되지 않기 때문이다.
  - 수정: `TokenlyApp.swift` — `.preferredColorScheme` 2곳(AI 팝오버, 설정 창) 제거, `AppAppearanceApplier`(설정의 `$appearance`를 구독해 시작 시와 변경 시 `NSApp.appearance` 적용)와 `AppAppearance.windowAppearance` 추가. `CPUPopoverView.swift` — 창별 외관 패치와 쓰지 않게 된 `displaySettings` 인자 제거. `SystemMonitorMenuBarScenes.swift`·`SystemMonitorWiringTests.swift` — 그 인자 제거. AI Monitor 변경은 `.preferredColorScheme` 1줄 제거뿐(사용자 지시: 같은 원인이면 최소 범위로 함께 수정).
  - 테스트: 339개 통과(창별 외관 테스트 1개를 앱 전체 방식 테스트 2개로 교체: 적용기가 시작 값과 5가지 순서를 따름, `NSApp.appearance`만으로 호스팅된 SwiftUI 뷰의 색 체계가 창 외관과 항상 일치). Debug·Release 빌드 성공, 새 경고 없음.
  - **실제 앱 확인 (Xcode 재실행 빌드 PID 65653, 12:02~12:05):** 저장소 밖 판정기가 1초마다 Tokenly의 설정 창·팝오버를 `screencapture -l`로 찍어 배경과 반대 밝기의 글자 픽셀 비율로 판정(재현 앱 A의 오류 상태를 MISMATCH로 잡는 것을 먼저 확인). 사용자가 설정 창을 연 채 다크↔라이트 4회, 다크 → 시스템 → 라이트 → 시스템, 닫고 CPU·AI 팝오버, 라이트·다크 각각에서 다시 열기를 수행. 창이 보인 81회 중 80회 일치, 1회는 창이 닫히는 순간의 빈 프레임(내용 없음)이었다. 스크린샷으로 설정 창(다크·라이트·시스템), CPU 팝오버(라이트·다크), AI 팝오버(라이트·다크) 확인. 결과: `../../TokenlyDesignArchive.noindex/Stage6-8C/CPU/theme-check-real/`. 사용자 확인: "이상 없음".
  - 앞선 기록 중 "창별 `NSWindow.appearance`로 해결" 부분(아래 "앱 외관 전환 오류")은 이 수정으로 대체되었다.

- **앱 외관 전환 오류 (사용자 보고, 2026-10-28):** 설정 > 테마 > 앱 외관을 라이트로 바꾸면 설정 창만 밝아지고 CPU 팝오버는 그대로였고, 다시 다크로 돌아오자 팝오버가 어두운 배경에 검은 글자가 됐다. 원인: `.preferredColorScheme`이 메뉴 막대 팝오버 창의 외관(머티리얼)을 바꾸지 못하고 SwiftUI 글자색만 따로 바뀜. 수정: `.preferredColorScheme`을 빼고 `WindowVisibilityReporter`가 창의 `NSWindow.appearance`를 설정값으로 지정(`AppAppearance.windowAppearance`). 테스트 2개 추가(매핑, 창 외관이 라이트→다크→시스템을 따라감), 전체 338개 통과, Debug·Release 빌드 성공. 오프스크린 전환 확인: 다크(배경 밝기 0.18, 숫자 0.93) ↔ 라이트(배경 0.96, 숫자 어두움) 반복이 일관됨. **실제 앱 재확인 대기.**
  - 참고: AI 팝오버(`TokenlyApp.swift`의 `UsageMenuView`)도 같은 `.preferredColorScheme` 방식이라 같은 문제가 있을 수 있다. AI Monitor는 이번 범위가 아니라 고치지 않았다(승인 필요).

- **실제 앱 2차 확인 (2026-10-28 11:24~11:29, 설정 버튼 수정을 포함해 사용자가 다시 빌드한 Debug 빌드 PID 58006):** 같은 기록기에 앞쪽 창 소유자와 `/usr/bin/log stream`(subsystem `io.github.jbbdyee.tokenly`) 기록을 더했다. 결과: `../../TokenlyDesignArchive.noindex/Stage6-8C/CPU/real-app-check-2/`(당시 스크린샷 20장, 현재 대표 2장과 연구 보관소의 `samples.txt`·`popover-log.txt`만 선별 보존).
  - 톱니바퀴: 두 번(11:26:36, 11:27:47) 모두 팝오버가 닫히고 설정 창이 맨 앞(앞쪽 일반 창 = Tokenly). 사용자도 "설정 창 앞에 뜸"으로 확인. **수정 확인.**
  - 수명주기: 팝오버를 7번 열고 닫았다. 매번 `appear`·`window` 두 신호로 `scan on`, `disappear`·`window` 두 신호로 `scan off`가 짝을 이뤘고, 닫힌 동안 `scan on`은 없었다(로그). 스캔 중복 여부는 자동 테스트로 확인(수집 쪽이 멱등).
  - 성능(1초 `ps`, 참고값): Tokenly CPU 평균 팝오버 열림 3.3%(69초), 팝오버·설정 모두 닫힘 1.9%(136초), 닫은 뒤 26초 구간 1.5%. 열려 있는 동안 약 +1.4%p(그래프 다시 그리기 + 3초 프로세스 조회).
  - 계속 확인됨: 값 갱신, 그래프, TOP 5·아이콘(Xcode 실제 아이콘, 보조·시스템 프로세스 기본 아이콘), RAM·Disk·Battery·AI 항목 유지.
  - 미확인: 라이트 모드(관찰 내내 시스템이 다크 모드; 오프스크린 렌더링으로만 확인), 설정 토글 회귀(자동 테스트로만).

- **실제 앱 1차 확인 (2026-10-28 11:15~11:20, 사용자가 Xcode로 실행한 Debug 빌드 PID 53604, CPU 팝오버 코드 포함 확인; 앱은 종료·교체하지 않음):**
  - 방법: 이 세션에는 손쉬운 사용 권한이 없어 자동 클릭이 불가능했다. 저장소 밖 기록기로 1초마다 Tokenly 팝오버 창 상태(창 목록)·프로세스 CPU를 기록하고, 팝오버가 화면에 있을 때 스크린샷을 찍었다. 사용자가 직접 클릭했다. 결과: `../../TokenlyDesignArchive.noindex/Stage6-8C/CPU/real-app-check/`(당시 스크린샷 12장, 현재 대표 1장과 연구 보관소의 `samples.txt`만 선별 보존).
  - 확인됨: 팝오버가 세 번 열림(11:15:58, 11:16:28, 11:17:29), 현재값·사용자·시스템 갱신(21% → 15% 등), B1 그래프가 실측으로 그려짐, TOP 5·아이콘(Chrome 보조 프로세스는 기본 아이콘, MenuBarAgent는 앱 아이콘), "측정 중…" → TOP 5, ⓘ 도움말 펼침(창 높이 335 → 409pt), 메뉴 막대의 RAM·Disk·Battery(라운드)·AI 항목이 함께 표시됨.
  - **발견한 오류:** 톱니바퀴로 연 설정 창이 팝오버 뒤에 떴다(사용자 보고). 원인: 팝오버 창이 일반 창보다 높은 층. 수정: 팝오버를 닫고 설정 창을 띄운다(`CPUPopoverView.openSettingsInFront`). 테스트 336개 통과, Debug·Release 빌드 성공. **실제 앱 재확인 필요**(Xcode에서 다시 빌드·실행).
  - 성능(대략): 1초 `ps` 샘플 기준 Tokenly CPU 평균 열림 2.7%(77회) / 닫힘 2.0%(119회). 짧은 관찰이라 참고값이다.
  - 확인 못 함: 닫은 뒤 TOP 5 수집 중지(로그 기록이 zsh 내장 `log` 명령과 충돌해 실패, 다음 확인 때 `/usr/bin/log`), 다크/라이트 전환(관찰 중 다크만), 반복 열기·닫기에서의 중복 수집(자동 테스트로만), 설정 토글 회귀(자동 테스트로만).

- **신규 파일 (`SystemMonitor/UI/`):** `AuroraGraph.swift`(단조 3차 곡선 `AuroraCurve`, B1 색 `AuroraPalette`, 배치 `AuroraGraphLayout`, 그래프 뷰), `CPUPopoverView.swift`(팝오버, `SystemPopoverVisibility`, `WindowVisibilityReporter`, `ProcessIconView`), `ProcessIconProvider.swift`. 테스트 `CPUPopoverTests.swift`. 모두 `project.pbxproj`에 등록(ID 067~070).
- **수정:** `SystemMonitorMenuBarScenes.swift`(CPU만 `.window` 팝오버, 장면에 설정 창·외관 설정·아이콘 캐시 전달), `TokenlyApp.swift`(`ProcessIconProvider` 하나 추가, 장면 인자 3개), `SystemWidgetPresentation.swift`(`cpuLoad`, `cpuTopRows`), `ProcessTopMetrics.swift`(`ProcessCPUEntry.startTicks`, 기본값 0), `SystemMonitorWiringTests.swift`(장면 인자, 별도 설정 suite).
- **데이터:** 헤더·그래프 모두 앱의 `SystemMonitorStore`(실측), TOP 5는 `ProcessTopStore`. 가상 데이터 없음. 측정값 수정·평활화 없음.
- **테스트:** 336개 통과(321 + 15), 실패·건너뜀 0. 추가: 부하 경계 39.9/40/79.9/80과 nil·NaN·표현, 마지막 점 = 현재값·오른쪽 끝, 0~100 고정 축·자동 확대 없음, 결측·20초 공백 분리와 0% 구분, 끝이 결측이면 현재 점 없음, 빈 기록, 곡선이 이웃 범위를 벗어나지 않음(무작위 60점 + 극단값)·평평한 데이터 유지, 높이→색 일관성·B1 값, TOP 5 정렬·5개 제한·100% 초과, 계산기가 시작 시각 보존, 아이콘 캐시(1회 조회·재사용 PID 재조회·정리)·앱 묶음만 아이콘, 열기·닫기 수집 시작·중지, 두 신호 반복 시 중복 없음, 위젯 OFF·제거 시 수집 없음. 기존 메뉴 막대 해시·설정 테스트 그대로 통과.
- **빌드:** Debug·Release clean build 성공. 경고는 기존 `BearGaugeView.swift:198`, AppIntents 안내뿐(새 경고 없음).
- **화면 확인(오프스크린, 실제 메뉴 막대 아님):** 앱의 `CPUPopoverView`를 실측 데이터(약 30초)로 화면 밖 렌더링 — `../../TokenlyDesignArchive.noindex/Stage6-8C/CPU/implementation-check/cpu-popover-offscreen-live-{light,dark}.png`. 헤더 값과 그래프 마지막 점 일치, Terminal은 실제 아이콘, Chrome 보조 프로세스는 기본 아이콘. 렌더링 중 창이 화면에 없자 창 가시성 신호가 수집을 멈추는 것도 관찰했다(설계대로).
- **실기기 확인 필요:** CPU 위젯 클릭 시 팝오버가 열리는지, 다른 위젯·AI 항목·토글이 그대로인지(장면 재구성 — 6-3 토글 버그 경로), 톱니바퀴로 설정 창이 앞으로 오는지, ⓘ 도움말, 라이트·다크·앱 외관 설정 반영, 열고 닫을 때 로그(`log stream --level debug --predicate 'subsystem == "io.github.jbbdyee.tokenly" && category == "SystemPopover"'`)와 닫힌 뒤 3초 수집이 멈추는지, 팝오버를 연 상태의 CPU 비용.
- **알려진 제약:** 프로세스 이름은 수집 단계에서 잘린다(`pbi_name` 최대 31자). UI 폭 때문이 아니다. 보완안은 SYSTEM-MONITOR §7.7-1(미구현, 승인 필요).

## 6-4a: M1 그래프 시간 공백 연결 오류 수정 (Claude, 2026-10-28)

상태: **구현 완료 · 자동 테스트 검증 완료.** 그래프 UI가 아직 없어 화면 확인은 6-4c에서 한다. 6-4b~f·6-5는 시작하지 않았다.

- **원인:** `SystemWidgetPresentation.segments`가 `nil` 점에서만 선을 나눴다. 그런데 기록에는 `nil` 없이 시간만 비는 경우가 있다: 잠자기·타이머 정지 중의 CPU·RAM(점 자체가 없음), GPU 오래된 창 폐기(현재값만 측정 불가로 바꾸고 기록에 점을 추가하지 않음, `SystemMonitorStore.readGPU`). 그 앞뒤 점이 한 선으로 이어졌다.
- **수정(`SystemWidgetPresentation.swift`만):** `chartMaxGap = 2.5`, `segments(_ history:, maxGap: = chartMaxGap)`. 유효 점을 붙이기 전에 직전 유효 점과의 간격이 `maxGap`을 **초과**하면 현재 구간을 닫는다(같으면 연결). `nil`에서 닫는 기존 동작, 1점 구간, 모두 `nil`이면 빈 배열은 그대로. 기존 호출부는 인자 없이 그대로 동작한다. 측정 엔진·타이머·기록 보관·GPU 실패 처리는 바꾸지 않았다.
- **테스트:** 321개 통과(315 + 6), 실패·건너뜀 0. 추가(고정 시각): 20초 공백 분리, 2.4/2.5/2.6초 경계와 명시 기준, `nil`+긴 공백 결합·1점 구간, 1초 흔들림·한 번 건너뜀 연결·모두 `nil`, 원본 기록 불변, CPU·RAM·GPU 공통(같은 `SystemMetricHistory` 타입). 기존 5개는 그대로 통과.
- **빌드:** Debug·Release 성공, 새 경고 없음. 메뉴 막대 렌더링 테스트(통일형 고정 해시 포함) 그대로 통과.

## 6-3 최종 미세 조정: 숫자–% 간격·Battery 테두리 높이 (Claude, 2026-10-28)

상태: **구현 완료 · 자동 테스트 검증 완료 · 실제 메뉴 막대 확인 대기.** 6-4·6-5는 시작하지 않았다.

- **승인:** 숫자–% 간격 1.2 → 1.7pt(+0.5), Battery 라운드 테두리 높이 15.75 → 17.5pt. 근거 미리보기 `../../TokenlyDesignArchive.noindex/Stage6-8C/Spacing/`(17.5pt 비교: `final-applied-17.5/`, 16.75·17.75와 나란히).
- **변경(`MenuBarSystemImage.swift`만):** 시스템 전용 `percentGap = 1.7`을 새로 두고, 숫자–% 간격 세 곳(두 자리 폭 계산, 2단 열 배치, Battery 배치)이 AI `layout.separatorGap`(1.2, AI `/` 간격) 대신 이것을 쓴다. `BatteryFrame.paddingY` 1.75 → 2.625(높이 = 번개 11.5 + 2×2.625 + 선 0.75 = 17.5). AI 렌더러·측정·판정·설정 코드는 그대로.
- **검증(변경 전 저장한 기대 픽셀 대비)**
  - 앱 출력 = 승인값으로 그린 기대 이미지: 구분형 144/144, 통일형 144/144, Battery 미니멀 28/28, 라운드 28/28(4위젯 × 9값 또는 Battery 7상태, 2×·3×, 라이트·다크). AI(Codex·Claude·AGY)는 변경 전과 4/4 동일.
  - 이미지 폭 변화 없음: 시스템 25/31pt, Battery `82%` 25, `⚡82%` 33, 라운드 `⚡100%` 45pt(정수 올림이 0.5pt를 흡수).
  - 2× 빈 픽셀 열(24·82·99%): 1 → 2~3px. 10%·100%는 2×에서 반올림으로 그대로 2px, 3×에서는 1~2px 넓어짐. 번개–숫자 간격(2px@2×)은 그대로.
  - 테두리 17.5pt: 선 바깥 1.875–20.125pt(22pt 위아래 여백 1.875), 좌우 위치·폭 동일, 내용과 겹침 없음, 잘림 없음.
- **테스트:** 315개 통과(312 + 3), 실패·건너뜀 0. 추가: `percentGap` 1.7·AI 1.2 유지·두 방식에서 % 시작이 숫자 잉크 + 1.7pt·묶음 가로 중앙·폭 유지, 2× 픽셀 간격(≥ 2열, 미니멀=라운드), 테두리 17.5pt(1.875–20.125pt·중앙). 수정: 테두리 값(2.625/17.5), 테스트 보조 함수의 간격, 통일형 고정 해시 10개 재기록(승인된 간격 변경 때문; `—`·측정 전과 2× GPU 100%는 픽셀이 같아 해시 유지).
- **빌드:** Debug·Release 성공, 새 경고 없음(AppIntents 안내는 기존).
- **실기기 확인 필요:** `24%`·`82%`·`10%`·`100%`의 숫자–% 간격, 라운드 테두리 17.5pt가 AI·구분형 옆에서 자연스러운지(위아래 여백 1.875pt), 미니멀형 간격, 테마 전환·재시작 후 유지.

## 6-3 메뉴 막대 디자인 최종 반영 (Claude, 2026-10-28)

상태: **구현 완료 · 테스트 검증 완료 · 실제 메뉴 막대 확인 대기.** 6-4·6-5는 시작하지 않았다.

- **승인안:** Battery B(얇은 라운드 테두리, 선택 옵션) · AGY B(숫자만 0.5pt 위) · 시스템 구분형 C(추가 1pt 위, 총 2pt). 근거 미리보기: `Doc/screenshots/stage6-3-battery-agy-options/`, `../../TokenlyDesignArchive.noindex/Stage6-8C/System-Alignment/`(저장소 밖).
- **수정 파일**
  - `Views/MenuBarNumericRow.swift`(이번에 사용자 승인으로 수정): `Layout.singleNumberLift`(기본 0, `standard` 0.5), 7일 칸 없는 열(AGY)의 숫자 기준선에만 적용. 공통 규칙(`vertical`, 열 폭, 이름, 두 숫자 열)은 그대로.
  - `SystemMonitor/UI/MenuBarSystemImage.swift`: `splitLift` 1 → 2, `BatteryFrame`·`framed(_:)`·`BatteryFrameStyle`, `render`/`size`/`make`에 `frame` 인자(기본 `.minimal`).
  - `SystemWidgetController.swift`: `batteryFrame`, `batteryFrameDefaultsKey`(`systemWidget.batteryFrame`), `batteryFrameBinding()`, `setBatteryFrame(_:)`.
  - `SystemMonitorMenuBarScenes.swift`: 캐시 키에 테두리, `SystemWidgetLabel.frame`, 장면이 `controller.batteryFrame` 전달.
  - `SystemMonitorSettingsView.swift`: `BatteryFramePicker`. `Views/TokenlySettingsView.swift` 테마 탭에 한 줄.
  - 테스트 `MenuBarSystemImageTests`·`SystemWidgetControllerTests`·`SystemMonitorWiringTests`.
- **픽셀 검증(변경 전 기록 대비)**
  - 앱 출력 = 승인 미리보기: 구분형 128/128, AI(AGY B) 4/4, Battery 라운드 20/20.
  - 변경 없음 확인: 통일형·Battery 미니멀 196개 해시 동일, Codex·Claude 열과 AGY 이름 행 4/4 동일(2×·3×, 라이트·다크).
- **테스트:** 312개 통과(303 + 9), 실패·건너뜀 0. 추가: 테두리 값, 테두리가 미니멀 내용을 픽셀 그대로 보존(폭 +6pt), 테두리 높이 고정·내용과 간격·22pt 안·불투명도(측정 전 흐림), 테두리 무채색·번개 초록 유지, AGY 숫자만 0.5pt 이동(Codex·Claude·AGY 이름 픽셀 동일), 배터리 스타일 기본값·저장·복원·모르는 값·레이아웃과 독립, ON/OFF·측정 무영향, 캐시가 Battery만 다시 그림. 수정: 구분형 기준선 17.40/5.88·픽셀 2pt·잉크 1.33–17.67·무게중심 10.76, AGY 비교 테스트는 `singleNumberLift = 0` 레이아웃과 비교.
- **빌드:** Debug·Release 성공, 새 경고 없음(AppIntents 안내는 기존).
- **설정 창:** 테마 탭 내용 높이 249pt(창 440×300). 화면 밖 렌더링으로 확인, 실제 창은 미확인.
- **README:** 시스템 모니터가 아직 공개 버전에 없으므로 바꾸지 않았다.
- **실기기 확인 필요:** 구분형 2pt 올림이 AI 옆에서 자연스러운지(위 여백 1.33pt), AGY 숫자 위치, 라운드 테두리 전환 즉시 반영·재시작 후 유지, 테두리 상태에서 `⚡82%`·`⚡100%`·`—`, 테마 탭이 창 안에 다 보이는지, 미니멀형이 이전과 같은지.

## 6-3 후속: 구분형 세로 위치 확정 — 1pt 올림 (Claude, 2026-10-28)

- **경과:** 구분형이 어색하다는 피드백 → 이름 크기 키우기(A 6 / B 7 / C 6.5pt) 미리보기 → 사용자가 크기 변경 불채택 → 세로 위치(0 / 0.5 / 1pt 위로)와 가로 중심 분석 → **C안(1pt 위로) 확정, 가로 보정 없음.** 미리보기·분석 단계에서는 앱 코드를 바꾸지 않았다.
- **변경:** `MenuBarSystemImage.swift` — `splitLift = 1`을 추가하고 `baselines(.split)`에서 두 기준선을 함께 1pt 위로(이름 7.88 → 6.88pt, 숫자 19.40 → 18.40pt). 이름 6pt·숫자 12pt·`%` 0.75배·행 간격·가로 정렬·폭·여백은 그대로.
- **검증**
  - 통일형·Battery: 표시 방식 도입 전 기록한 196개 조합 해시와 변경 후가 모두 같다(통일형 해시 10개는 테스트에도 있음).
  - 구분형: 앱 출력이 미리보기 C안과 128개 조합(4위젯 × 8값 × 명암 × 2·3배)에서 픽셀이 같다.
  - 테스트 수정: 구분형 기준선(1pt 올림, 18.40/6.88), 픽셀(위·아래 1pt 이동, 행 간격 동일). 추가: `testSplitBlockIsRaisedByOnePoint`(3× 잉크 2.33–18.67pt, 세로 무게중심 평균 11.76pt). 경계·흐림·색 테스트는 그대로 통과.
  - `xcodebuild test` **303개 통과**, 실패·건너뜀 0. Debug·Release 빌드 성공, 새 경고 없음(AppIntents 안내는 기존).
- **미리보기 보존(새 폴더):** `Doc/screenshots/stage6-3-split-final/unified-vs-split-{light,dark}@{2,3}x.png`(위 통일형, 아래 구분형 최종, Preview "실제 크기"로 메뉴 막대 크기), `options-abc/`(A·B·C 비교, 확대, 측정값 `metrics.txt`). 배경화면이 들어간 합성 이미지는 개인 화면 일부라 보존하지 않았다. 기존 스크린샷은 건드리지 않았다.
- **실기기 확인 필요:** 구분형으로 바꿨을 때 AI 위젯 옆에서 처져 보이지 않는지, 통일형으로 되돌리면 이전과 같은지, Battery가 그대로인지.

## 6-3 후속: 시스템 위젯 표시 방식 선택 (Claude, 2026-10-28)

- **배경:** 사용자가 6-3 최종 디자인(Battery 중앙 정렬·번개·`%` 비율·간격)을 실기기에서 확정했다. AI와 시스템 위젯의 정보 구조를 구분하는 선택지를 추가했다.
- **설정:** 테마 탭 "시스템 위젯 표시 방식" — 통일형(숫자 위 / 이름 아래, **기본값**) / 구분형(이름 위 / 숫자 아래). 기존 "앱 외관" 선택 아래에 붙였고 기존 항목은 그대로다. UserDefaults `systemWidget.layout`(`unified`/`split`). 기존 사용자는 값이 없으므로 통일형이다. 기본값 변경은 실사용 후 결정한다.
- **구현**
  - `MenuBarSystemImage.swift`: `SystemWidgetLayout`, `baselines(_:)`, `nameCapInk`, `runs`/`render`/`make`에 `style` 인자(기본 `.unified`). 구분형은 통일형과 같은 상자(3.60~19.40pt)를 위아래로 뒤집어 행 사이 간격이 같다. Battery는 `applied(to:)`로 항상 통일형.
  - `SystemWidgetController.swift`: `layout`, `layoutDefaultsKey`, `layoutBinding()`, `setLayout(_:)`(저장·게시만).
  - `SystemMonitorMenuBarScenes.swift`: 캐시 키에 방식 추가(Battery는 고정), `SystemWidgetLabel.style`, 장면이 `controller.layout` 전달.
  - `SystemMonitorSettingsView.swift`: `SystemWidgetLayoutPicker`(라디오). `TokenlySettingsView.swift` 테마 탭에 한 줄 추가.
- **영향 없음:** AI 렌더러·AI 캐시·AI 경로, Battery 이미지(두 방식 픽셀 동일 테스트), 측정 엔진, ON/OFF, 간격·여백.
- **통일형 픽셀 동일성:** 변경 전 렌더러로 196개 조합(5위젯 × 7값 × 번개 × 명암 × 2·3배)의 해시를 기록하고 변경 후 비교해 모두 같았다. 그중 10개를 테스트에 넣었다(macOS 27.0.1에서만, 다른 OS는 건너뜀).
- **테스트:** 302개 통과(288 + 14). 추가: 통일형 해시, 구분형 기준선 대칭, 구분형 run 순서·`%` 0.75배·기준선·가로 위치 동일, 구분형 픽셀(이름이 위, 같은 상자·간격), 0·9·24·99·100%·`—`·측정 전 경계(2×·3×, 명암), 구분형 흐림·색, Battery 두 방식 동일, 기본값·저장·재시작 복원·모르는 값, 방식 변경이 ON/OFF·측정·타이머·TOP 5에 영향 없음, 캐시가 2단 위젯만 다시 그림, 라벨이 컨트롤러 방식을 받음.
- **빌드:** Debug·Release 성공, 새 경고 없음(AppIntents 안내는 기존).
- **미리보기:** 저장소 밖 `preview65/compare-light.png`·`compare-dark.png`(위 통일형, 아래 구분형). 기존 스크린샷·미리보기는 건드리지 않았다.
- **실기기 확인 필요:** 테마 탭에서 전환 즉시 메뉴 막대 반영, 재시작 후 유지, 구분형이 AI 옆에서 구분돼 보이는지, 전환 중 위젯이 꺼지거나 위치가 바뀌지 않는지(장면 재계산 시 `isInserted`), 설정 창 테마 탭 높이(440×300) 안에 다 들어오는지.

## 6-3 메뉴 막대 최종 디자인 미세 조정 (Claude, 2026-10-27)

- **배경:** 실기기 확인 뒤 사용자가 최종 디자인을 확정했다. 시스템 위젯 간격·이미지 여백·99↔100% 폭 정책은 현재 상태로 확정(변경 금지).
- 앞선 요청이 중단돼 렌더러에 일부 변경(`percentRatio`, `BatteryStyle`, 명암별 초록)이 들어가 있었다. 상태를 확인하고 이어서 완성했다. 그때 시도한 "2단 위젯보다 1.5pt만 내림" 안은 사용자 최종 결정(전체 높이 중앙)으로 대체했다.
- **Battery 세로 중앙 (최종 확정):** 숫자 `0` 잉크 중심을 22pt 이미지 중심(11pt)에 둔다. 기준선 `centredBaseline` 15.23pt, 숫자 윗선은 위에서 6.60pt. 번개 중심도 11pt라 숫자만, 번개 + 숫자 모두 그룹이 중앙이다. 다른 위젯 윗줄 숫자에 맞추라는 이전 요구는 취소됐다.
- **번개:** 10pt Medium → **11.5pt Bold**(폭 6.2 → 7.0pt), 숫자 잉크까지 1 → **1.25pt**. 숫자의 실제(스냅 후) 잉크 위치에서 거꾸로 배치해, 값에 따라 1~3px로 흔들리던 빈 간격을 고정했다. 충전 표시 이미지 폭이 1pt 늘었다(`⚡82%` 33pt, `⚡100%` 39pt). 번개가 없는 상태와 2단 위젯 폭은 그대로다.
- **번개 색:** 라이트 sRGB 0.09/0.62/0.24(흰 배경 대비 약 3.5:1, 이전 0.20/0.78/0.35는 약 2.2:1), 다크 0.24/0.84/0.40(검정 대비 약 11:1).
- **`%`:** 숫자의 0.8배 → **0.75배**(시스템 전용 `percentRatio`, Battery 포함). AI `secondaryRatio` 0.8과 AI 렌더러는 그대로다. 두 자리 칸 폭이 23.51 → 23.06pt로 줄었지만 이미지 폭(올림)은 변하지 않았다(CPU 25pt, `100%` 31pt).
- **수정 파일:** `UI/MenuBarSystemImage.swift`, `TokenlyTests/MenuBarSystemImageTests.swift`, 문서. 측정 엔진·판정 정책·컨트롤러·설정·장면·AI 파일은 바꾸지 않았다.
- **테스트 추가·수정:** Battery 세로 중앙(0·9·24·99·100% × 번개 3종 × 명암 × 2×·3×), 번개 크기, 번개 색 대비, Battery `%`와 CPU `%` 픽셀 높이·기준선 일치, `%` 0.75배 글꼴 크기, 경계 테스트 값 확대(2단 위젯도 0·9·24·99·100%). AGY 정렬 테스트에서 Battery를 빼고 CPU·RAM·Disk·GPU로 바꿨다.
- **검증:** `xcodebuild test` **288개 통과**, 실패 0. Debug·Release 빌드 성공, 새 경고 없음(증분 빌드라 기존 `BearGaugeView.swift:198` 경고는 다시 출력되지 않았다. AppIntents 안내는 기존).
- **미리보기:** 저장소 밖 `preview64/`(라이트·다크), 실제 메뉴 막대 캡처 위 합성 `compose64b/after.png`(이전 모습은 같은 캡처의 실제 위젯). 기존 스크린샷은 건드리지 않았다.
- **실기기 확인 필요:** Battery가 옆 2단 위젯·시스템 아이콘·시계 사이에서 중앙으로 자연스러운지, 밝은·어두운 배경화면에서 번개 초록 식별, `⚡100%`(어댑터·완충)와 `⚡NN%`(충전 중), `%` 크기 인상.

## 6-3 실기기 확인 뒤 디자인·배터리 정책 보완 (Claude, 2026-10-27)

- **사용자 실기기 확인 결과:** 토글 동작과 위젯 표시는 정상. 시스템 위젯 사이 간격이 AI 숫자형보다 넓고, Battery 숫자가 다른 위젯보다 낮아 보였다. 번개 정책에 "외부 전원 + 완충 `⚡100%`"를 추가하기로 했다.
- **간격 (측정과 제약)**
  - 메뉴 막대 아이템 사이 16pt(좌우 각 8pt)는 macOS가 정한다. 하네스에서 30pt 이미지가 46pt 아이템 창이 되는 것을 확인했다. 앱이 바꿀 공개 수단은 시스템 전체 설정 `NSStatusItemSpacing`뿐이라 **쓰지 않았다**(다른 앱 아이템까지 바뀜, 비공개 API 금지).
  - 앱이 줄일 수 있는 것: 이미지 좌우 여백(1 → 0.5pt), `100%` 기준 고정 폭에서 생기던 빈 공간(평소 값 기준 좌우 각 약 3.5pt).
  - 변경: 열 폭을 가장 넓은 두 자리 값(`10%`~`99%`, 23.51pt) 기준으로 고정하고 `100%`일 때만 넓힌다(29.58pt). CPU 이미지 32 → 25pt, `24%`의 좌우 빈 공간 4.7 → 1.2pt, 시스템 아이템 사이 잉크 간격 약 25 → 18pt(AI 약 16~19pt).
  - **확정 결정 #4 변경 사항(되돌릴 수 있음):** 99%↔100%를 오갈 때 폭이 약 6pt 바뀐다. 원래대로 하려면 `MenuBarSystemImage.digitSlotWidth`가 항상 `hundredWidth`를 반환하게 한다.
  - AI 렌더러(`MenuBarNumericRow.swift`)는 바꾸지 않았다. AGY 픽셀 동일성 테스트는 AI 여백 1pt 경로(`aiPadding: true`)로 계속 통과한다. (이후 2026-10-28 최종 반영에서 AGY 숫자 0.5pt 올림을 위해 승인 하에 수정, 위 절 참고.)
- **세로 정렬**
  - Battery 숫자를 22pt 행 가운데(기준선 15.32pt)에서 2단 위젯·AGY와 같은 `singleBaseline`(12.23pt)으로 옮겼다. **→ 다음 절(최종 미세 조정)에서 사용자 결정으로 취소, 세로 중앙으로 변경.**
  - CPU·RAM·Disk·GPU·Battery·AGY 숫자의 윗선(3.60pt)·기준선이 같다. Codex·Claude의 큰 숫자는 AI 설계상 1pt 위(기준선 11.23pt, 보조 숫자 자리 때문)이며 AI 렌더러를 바꾸지 않으므로 그대로 둔다.
- **배터리 번개 정책**
  - 엔진: `BatteryPowerState.isAtFullCapacity`를 추가했다. IOPowerSources `Current Capacity == Max Capacity`를 반올림 전 정수로 비교한다(4,627/4,629는 `100%`로 보이지만 완충 아님). 잔량을 읽을 수 없으면 같은 사유로 `unavailable`.
  - 표시: `SystemWidgetDisplay.bolt`(`.none`/`.charging`/`.fullOnExternalPower`). 충전 중이면 `.charging`, 아니고 외부 전원 + 완충이 모두 `.available(true)`이면 `.fullOnExternalPower`. 잔량이 없으면 번개 없이 `—`. 모르는 상태는 번개를 붙이지 않는다. 이미지는 두 경우 같고, VoiceOver만 "충전 중"/"전원 연결됨"으로 다르다.
  - Battery 폭은 번개가 있을 때만 번개 칸을 포함한다(평소 `82%` 25pt, `⚡82%` 32pt). 전원 연결·분리 때 한 번 폭이 바뀐다.
- **수정 파일:** `BatteryStatus.swift`, `UI/SystemWidgetPresentation.swift`, `UI/MenuBarSystemImage.swift`, 테스트 `BatterySamplerTests`·`SystemWidgetPresentationTests`·`MenuBarSystemImageTests`·`SystemMonitorWiringTests`(이름 변경 반영), 문서. `TokenlyApp.swift`, 장면·설정·컨트롤러, AI 파일은 바꾸지 않았다.
- **테스트 추가:** 원시 완충 판정 1, 번개 정책 조합 12가지 + 잔량 없음 1, 렌더러(여백·두 자리 폭, 빈 공간 상한 2×·3×, 숫자 윗선·기준선·이름 아랫선 AGY 일치 2×·3×, 번개 세로 중심) 4. 렌더러 경계 테스트는 0.5pt 여백에서 가장자리 열의 안티에일리어싱을 허용하고, 글자가 잘리면(가장자리에 진한 잉크) 실패하도록 바꿨다.
- **검증:** `xcodebuild test` **284개 통과**, 실패·건너뜀 0. Debug·Release 빌드 성공(경고는 기존 `BearGaugeView.swift:198`, AppIntents 안내뿐). 저장소 밖 미리보기(아이템 사이 16pt 가정)에서 숫자 윗선 정렬과 간격을 눈으로 확인했다.
- **GUI 미검증(사용자 확인 필요):** 실제 메뉴 막대에서 AI와 시스템 위젯 간격, 숫자 윗선 정렬, 어댑터 연결·완충 시 `⚡100%`, 충전 중 `⚡NN%`, 어댑터 분리 시 번개가 사라지는지와 폭 변화.
- 진단용 설정 도메인은 그대로 두었다(정리는 별도 승인).

## 6-3 GUI 오류 수정: 시스템 위젯 토글이 즉시 꺼짐 (Claude, 2026-10-27)

- **증상 (사용자 실기기):** 설정 > 시스템의 토글을 켜면 잠깐 켜졌다가 바로 꺼지고, 메뉴 막대에 위젯이 나타나지 않는다. Stats 종료나 재빌드와 무관했다.
  - 사용자 설정값에는 `systemWidget.cpu/memory.inserted = 0`과 `NSStatusItem VisibleCC Item-1~5 = 0`이 남아 있었다. 진단에서는 읽기만 했고 지우지 않았다.
- **원인 (저장소 밖 재현으로 확인)**
  - `SystemMonitorMenuBarScenes`가 컨트롤러를 관찰하지 않는 `let`으로 받았다.
  - 토글로 앱 body가 다시 계산되어도, SwiftUI는 입력(같은 참조)이 같은 이 scene의 body를 다시 계산하지 않았다. 그래서 `MenuBarExtra`가 이전의 `isInserted == false`를 상태 막대 아이템에 `isVisible = false`로 적용했다.
  - 그 KVO 되쓰기(`MenuBarExtraController.observeValue` → `Binding.setter`)가 약 10 ms 뒤 `setInserted(_, false)`를 불러 위젯이 꺼졌다.
  - 배제한 것: AppKit 숨김 기록, 메뉴 막대 공간, 컨트롤러 재생성, 지원 판정, 재확인 호출(모두 재현 실험으로 배제했다).
- **수정:** `SystemMonitorMenuBarScenes.swift`의 `let controller`를 `@ObservedObject var controller`로 바꿨다(이유 주석 추가). 그 밖의 구조, `TokenlyApp.swift`, `SystemWidgetController.swift`, AI 파일은 변경하지 않았다.
- **회귀 방지**
  - 테스트 `SystemMonitorWiringTests.testMenuBarScenesObserveTheController`: `Mirror`로 `_controller`가 `ObservedObject` 래퍼인지 확인한다(실제 메뉴 막대 경로는 XCTest에서 돌릴 수 없다).
  - 재현 절차(저장소 밖 하네스)
    1. 저장소 앱 소스(`TokenlyMain.swift` 제외)와 `@main` 하네스를 `swiftc -parse-as-library`로 함께 빌드한다.
    2. 하네스는 실제 `SystemWidgetController`(별도 UserDefaults suite)와 `SystemMonitorMenuBarScenes`를 쓴다. AI 대신 단순 `MenuBarExtra`를 앞에 둔다.
    3. 1초 뒤 `setInserted(.cpu, true)`, 0.5초 뒤 RAM을 바인딩으로 켜고, 3초 뒤 바인딩으로 끈다.
    4. 매초 `isInserted`·`enabledMetrics`·앱 body 계산 횟수를 출력하고, 6.5초 뒤 판정한다.
    - 하네스 소스는 세션 임시 폴더 `h2/Harness.swift`에 있다(사라질 수 있음, 보존은 별도 승인).
  - 결과(수정 후 저장소 코드): **PASS**. CPU ON이 6.5초 유지됐고 값이 매초 갱신됐다(12% → 8% → 7% …). RAM을 끄면 측정이 멈췄다. 앱 body 계산은 전체 4회(시작, 켜기 2회, 끄기 1회)뿐이고 1초 Store 갱신으로는 다시 계산되지 않았다.
  - 같은 하네스로 수정 전 코드에서는 약 0.01초 뒤 OFF로 돌아갔다(진단 시 재현).
- **검증:** Debug·Release 빌드 성공(경고는 기존 2개뿐: `BearGaugeView.swift:198`, AppIntents 안내). `xcodebuild test` 277개 통과, 실패·건너뜀 0(기존 276 + 1).
- **상태: 사용자 GUI 재검증 대기**
  - 설정에서 토글을 켠 뒤 5초 이상 유지되고 메뉴 막대에 위젯이 보이는지
  - `defaults read io.github.jbbdyee.tokenly | grep -E "systemWidget|VisibleCC"`로 켠 위젯의 `inserted = 1`과 해당 `VisibleCC Item-N = 1`
  - Xcode 콘솔의 SwiftUI 경고
- 진단용 설정 도메인 11개(`io.github.jbbdyee.tokenly.diag`, `tokenlydiag`, `diag2_*`, `diag2obs_*`, `h1`, `h1_patched`, `check`, `tokenly.harness.h1`)와 `tokenly.harness.h2`는 지시에 따라 그대로 두었다. 정리는 별도 승인 후 한다.

## 6-3 메뉴 막대 연결·설정 탭 (Claude, 2026-10-27)

- **신규 (`SystemMonitor/UI/`)**
  - `SystemMonitorMenuBarScenes.swift`
    - `SystemWidgetImageCache`: 위젯별로 `(표시값, 명암, 배율)`이 바뀔 때만 렌더링한다.
    - `SystemWidgetLabel`: Store를 관찰하는 유일한 뷰다.
    - `SystemWidgetMenu`: 6-4 전까지의 임시 메뉴(값과 `SettingsLink`)다.
    - `SystemMonitorMenuBarScenes`: `MenuBarExtra(isInserted: controller.binding(for:))` 5개다.
  - `SystemMonitorSettingsView.swift`
    - 토글 5개, 미지원이면 비활성화와 사유, GPU 실험적 안내, 가려짐 안내
    - 탭이 나타날 때마다 `recheckUnsupportedWidgets()`를 부른다(미지원 위젯만 확인하고, 모두 지원이면 작업 없음).
- **수정**
  - `SystemWidgetController`
    - `store`·`processTop`을 읽기 전용으로 공개했다.
    - `SystemWidgetSupport.reasonText`를 추가했다.
  - `SystemWidgetPresentation`: `accessibilityText`를 추가했다.
  - `MenuBarSystemImage`: 배율을 받는 `make(_:dark:scale:)`를 추가했다.
  - AI 파일 최소 수정
    - `TokenlyApp.swift`: `@StateObject systemWidgets`, 이미지 캐시, 장면 한 줄, 설정에 컨트롤러 전달
    - `TokenlySettingsView.swift`: `@ObservedObject systemWidgets` 하나와 "시스템" 탭 하나
- **구조 결정:** `SystemMonitorStore`를 앱의 `@StateObject`로 두지 않는다. 1초 게시마다 앱 body와 AI 라벨이 다시 계산되기 때문이다. 앱은 컨트롤러만 관찰하고, Store는 라벨만 관찰한다.
- **위젯 활성화 계약 (L1):**
  - 위젯 켜기·끄기와 측정 시작·중지는 **`SystemWidgetController.setInserted`(또는 `binding(for:)`)로만** 바꾼다.
  - UI·장면·설정 코드는 `SystemMonitorStore.setEnabled`를 직접 부르지 않는다(6-3 UI 파일에 호출 없음).
  - GPU 값은 Store가 게시한 값만 쓰고, UI는 GPU Sampler를 부르지 않는다.
- **테스트 (`SystemMonitorWiringTests` 8개, 전체 276개 통과, 실패 0)**
  - 같은 값이면 이미지를 다시 만들지 않는다(같은 인스턴스).
  - CPU 값이 3번 바뀌어도 다른 4개 위젯은 1번만 렌더링한다.
  - 명암·배율·충전 상태가 바뀌면 다시 렌더링하고, 이미지는 non-template이다.
  - Store → 라벨 값(24%·71%, 끄면 측정 전)
  - 컨트롤러가 받은 Store·스캐너를 보관한다.
  - 실제 지원 확인: CPU·RAM·Disk는 지원, 검증 환경에서는 GPU·Battery도 지원
  - 미지원 사유 문구, 접근성 문구
- **빌드:** Debug·Release 성공. 경고 2개는 기존 것이다(`BearGaugeView.swift:198` 미변경 파일, AppIntents 메타데이터 안내).
- **실제 macOS 확인: 전부 미검증**
  - Claude는 화면을 보거나 조작할 수 없다. 같은 번들 ID로 두 번째 Tokenly를 실행하면 실제 UserDefaults를 공유하고 AI 조회가 실행되므로 앱을 직접 실행하지 않았다.
  - 약한 근거 하나: 테스트 호스트(Tokenly.app)가 새 장면을 포함해 실행되었고 테스트 중 크래시가 없었다.
- **사용자 GUI 확인 체크리스트**
  1. 처음 실행 시 시스템 위젯이 하나도 없는지(기본 OFF)
  2. 설정 > 시스템에서 각 토글을 켜면 해당 위젯이 나타나고 끄면 사라지는지
  3. 앱을 재시작해도 켠 위젯이 유지되는지
  4. ⌘-드래그로 위젯을 메뉴 막대 밖으로 빼면 설정 토글도 꺼지는지, 측정이 멈추는지(활동 모니터에서 Tokenly CPU)
  5. 메뉴 막대가 가득 차서 가려진 위젯은 토글이 켜진 채로 남는지. 공개 API로 구분할 수 없어 안내만 한다.
  6. 라이트·다크 메뉴 막대에서 AI 숫자형과 어울리는지, 아이템 간격
  7. 실제 충전 중 초록 번개가 색으로 보이는지(V2)
  8. Battery 한 줄 숫자의 세로 위치와 좌우 여백
  9. "투명도 줄이기"·"대비 증가"·큰 텍스트 설정에서 잘림·색 문제
  10. 설정 > 시스템 탭이 440×300 창 안에 잘리지 않는지
  11. 위젯을 클릭하면 임시 메뉴(현재 값, "시스템 모니터 설정…")가 열리고 설정으로 이동하는지
  12. 바인딩 setter가 뷰 갱신 중에 불려 "Publishing changes from within view updates" 경고가 나는지(Xcode 콘솔)
- **M1:** **해결 (2026-10-28, 6-4a).** 아래 표와 "6-4a" 절 참고.

## Battery 최종 디자인과 M2 (Claude, 2026-10-27)

- **Battery 최종 디자인 (사용자 확정)**
  - 충전 중이 아니면 `82%`, 실제 충전 중이면 `⚡82%`(초록 번개)
  - 외부 전원 연결·충전 안 함, 충전 상태 모름은 번개 없이 숫자, 잔량을 모르면 `—`, 배터리 없음은 기존 미지원 정책
  - 배터리 외곽·잔량 단계 아이콘은 쓰지 않는다.
- **변경**
  - `SystemWidgetPresentation`: `BatteryGlyph`·`batteryLevel`을 없애고 `SystemWidgetDisplay.showsChargingBolt`로 바꿨다(잔량이 있고 실제 충전 중일 때만 true).
  - `MenuBarSystemImage` Battery
    - 폭을 `⚡100%`로 고정하고 내용을 가운데 정렬한다.
    - 번개는 심볼 잉크만 잘라 그리고(잉크 높이 10pt), 숫자까지 간격은 1pt다.
    - CPU·RAM·Disk·GPU 렌더링은 변경하지 않았다(AGY 픽셀 동일성 테스트 통과).
- **M2:** `SystemWidgetController.recheckUnsupportedWidgets()`
  - `support`를 `@Published`로 바꾸고 확인 함수를 보관한다(`@escaping`).
  - 미지원 위젯만 다시 확인하고, 판정이 바뀌면 `support`를 갱신하며, 유효 상태가 바뀔 때만 `store.setEnabled`를 부른다.
  - 다른 영구 사유로 바뀌면 사유만 갱신하고 꺼진 상태를 유지한다.
- **테스트 (전체 268개 통과, 실패 0)**
  - 렌더러: 숫자만·가운데·외곽 없음, 번개는 숫자 왼쪽이고 간격이 일정·가까움, 충전 상태가 바뀌어도 폭 유지, 22pt·좌우 경계를 2×·3×에서 확인, 번개와 숫자 각각의 경계, `bolt.fill` 존재
  - 표시 로직: Battery 표시·번개 조건 갱신(잔량 단계 테스트 삭제)
  - 컨트롤러 6개
    - 시작 시 위젯마다 한 번 확인(L4)
    - 미지원 → 재확인 → 복구와 측정 시작, 저장값 보존
    - 사용자가 끈 위젯은 재확인 후에도 측정하지 않음
    - 미지원만 다시 확인
    - 반복 재확인 시 게시·작업·중복 활성화 없음
    - 다른 영구 사유로 바뀌면 꺼진 상태 유지
- **진행 중 오류와 해결**
  - 컴파일 오류 `assigning non-escaping parameter 'supportProbe' to an '@escaping' closure`: 확인 함수를 보관하게 되어 `@escaping`을 붙였다.
  - 테스트 실패 1: 번개의 반투명 가장자리가 "초록이 아닌 잉크"로 잡혀 숫자의 시작으로 오인됐다 → 숫자를 "검은 잉크"로 판별하도록 바꿨다.
  - 테스트 실패 2: 번개와 숫자 간격이 7px(3.5pt)였다 → 원인은 심볼 이미지의 여백이었다. 잉크만 잘라 그리도록 렌더러를 고쳤고, 간격은 "잉크 없는 열의 수"로 다시 정의했다(실측 3px = 1pt + 픽셀 맞춤).
  - 테스트 실패 3: `57%` 잉크 폭이 기대값보다 2.2px 컸다(허용 2px). 바깥 양 끝의 반투명 열과 숫자·`%`를 따로 픽셀에 맞추는 오차라서 허용을 3px로 바꿨다. 외곽 아이콘이 있다면 약 40px가 늘어나므로 여전히 검출된다.
- **미리보기:** 세션 임시 폴더 `preview62b/preview-{light,dark}.png`. `Doc/screenshots/stage6-2/`의 기존 두 장은 이전(아이콘) 디자인이며 덮어쓰지 않았다.
- **실기기 확인 필요 (6-3)**
  - 실제 메뉴 막대에서의 초록 번개(V2)
  - 한 줄 Battery 숫자가 2단 위젯 숫자보다 낮게 보이는 높이 차이가 어색한지
  - 고정 폭 가운데 정렬 때문에 생기는 좌우 여백

## 6-1 리뷰 미해결 항목 (6-1 자체 리뷰, 2026-10-27 — 단계별로 유지)

| ID | 내용 | 처리 시점 |
|---|---|---|
| ~~M1~~ **해결 (2026-10-28, 6-4a)** | `SystemWidgetPresentation.segments`가 `nil` 점에서만 선을 나눈다. 그런데 Store는 시간 공백을 `nil` 없이 남기는 경우가 있다: GPU 오래된 창 폐기(`SystemMonitorStore.swift:252-253`), 잠자기·타이머 지연 중의 CPU·RAM. 저장소 밖 재현에서 1초×5 → 20초 공백 → 1초×3이 구간 1개로 이어졌다 | `segments(_:maxGap:)`가 이웃한 유효 점 간격이 2.5초(`chartMaxGap`)를 넘으면 끊는다(정확히 2.5초는 연결). 2초 대신 2.5초: 한 번 건너뛴 틱(약 2초)이 타이머 흔들림으로 2초를 조금 넘어 깜빡이며 끊기는 것을 피함. 회귀 테스트 6개. 표시 계층만 수정 |
| ~~M2~~ **해결 (2026-10-27)** | 지원 여부를 앱 시작 시 한 번만 확인했다. 로그인 직후 일시적인 판정이 세션 내내 남을 수 있었다 | `recheckUnsupportedWidgets()` 추가. 미지원 위젯만 다시 확인(별도 Sampler, 메인 액터)하고, 지원으로 바뀌면 저장값대로 Store를 켠다. 저장값은 보존하고 반복 호출 시 작업이 없다. 테스트 6개. **설정 화면이 열릴 때 호출하는 연결은 6-3에서 한다** |
| ~~L1~~ **처리 (6-3)** | 컨트롤러는 자신만 `store.setEnabled`를 부른다고 가정한다(public API) | 계약 명시(아래 "위젯 활성화 계약"). UI 코드는 `setEnabled`를 부르지 않는다(6-3 UI 파일에 호출 없음) |
| ~~L2~~ **처리 (6-3)** | `processTop`을 빠뜨리면 CPU·RAM을 꺼도 TOP 5가 해제되지 않는다 | `TokenlyApp` init에서 `ProcessTopStore()`를 만들어 전달한다. 테스트 인자 호환을 위해 선택 인자는 유지 |
| ~~L3~~ **처리 (6-3)** | 실제 지원 확인과 `display(_:store:)` 테스트가 없었다 | `testRealSupportProbe`(검증 환경에서 GPU·Battery 지원), `testLabelValuesComeFromTheStore` 추가 |
| ~~L4~~ **해결** | "지원 여부는 init에서 위젯마다 한 번" 호출 횟수 테스트가 없었다 | M2와 함께 `testStartupProbesEachWidgetOnce` 추가 |
| ~~L5~~ **처리 (6-3)** | 바인딩이 `[unowned self]`다 | 컨트롤러는 `TokenlyApp`의 `@StateObject`로 앱 수명 동안 하나다. 바인딩은 앱 장면과 설정 뷰 안에서만 만들어지고 쓰인다 |

## 6-2 구현 (Claude, 2026-10-27)

- **신규 파일**
  - `src/Tokenly/SystemMonitor/UI/MenuBarSystemImage.swift`(ID `…062`)
  - `src/TokenlyTests/MenuBarSystemImageTests.swift`(ID `…063`)
- **재사용 (`MenuBarNumericRow.swift` 수정 없음)**
  - 그대로 호출: `MenuBarNumericImage.font`·`line`·`ink`·`vertical`·`Run`, `Layout.standard`(12pt Semibold, 0.8배 Medium, 간격 1.2pt, 이름 6pt Semibold, 이름까지 1.75pt), `height` 22, `sidePadding` 1, `staleAlpha` 0.5
  - 새로 쓴 부분: `column`·`render`의 처리 방식(잉크 상자 가운데 배치, sRGB, 배율, 폰트 스무딩 끔, 픽셀 스냅, 검정·흰색, `isTemplate = false`)을 따르는 짧은 코드. 기존 `column`·`render`는 AI 전용 `NumericGaugeItem`을 받아 그대로 호출할 수 없기 때문이다.
- **구성**
  - 2단 위젯: AGY 단일 숫자 열 + `%`(같은 기준선). 열 폭은 `max(100% 잉크, 이름 잉크)`로 고정
  - Battery: 첫 구현은 "아이콘 칸 + 숫자"였다. 이후 최종 디자인으로 바뀌었다(아래 "Battery 최종 디자인과 M2").
- **구현 중 발견·수정 (미리보기에서)**
  - Battery 숫자를 가운데 정렬하면 아이콘과의 간격이 값에 따라 벌어졌다 → 아이콘 뒤 고정 간격
  - 번개가 칸 가운데라 숫자와 멀었다 → 칸 오른쪽 정렬
  - 두 가지 모두 회귀 테스트 `testBatteryNumberFollowsTheIconAtAFixedGap`으로 고정했다.
- **테스트 11개**
  1. AGY 열 픽셀 동일성: 라이트·다크 × 정상·흐림 4조합, 바이트 단위로 같음
  2. 0·9·24·99·100%·측정 전·불가에서 폭 고정(Battery 포함)
  3. `%` 기준선이 숫자와 같고 글꼴 크기가 12 / 9.6 / 6pt
  4. 숫자·이름 가운데 정렬(오차 0.01pt)
  5. 측정 전 숫자 최대 알파 128±3(이름은 흐리지 않음), 측정 불가는 흐리지 않음
  6. 라이트는 검정, 다크는 흰색, 색 픽셀 없음
  7. (최종 디자인으로 교체됨) 잔량 5단계 아이콘 테스트는 삭제했다
  8. 초록 픽셀은 실제 충전 중에만(연결·충전 안 함, 상태 모름, 측정 전에는 0)
  9. 22pt와 좌우 경계에 잉크가 닿지 않음(2단 4종과 Battery 4아이콘 × 100%·`—` × 라이트·다크)
  10. Battery 숫자 간격 고정
  11. 심볼 존재
- **픽셀 비교가 보장하는 범위:** 숫자·이름의 글꼴, 굵기, 기준선, 스냅, 색 처리가 AI와 같다는 것. 보장하지 않는 것: `%` 배치의 미감, 고정 폭 가운데 정렬, Battery 배치, 실제 메뉴 막대(틴트, 아이템 간격, 순서).
- **검증**
  - Debug·Release 빌드 성공(경고 없음).
  - `xcodebuild test` xcresult 기준 262개 통과(기존 251 + 11).
  - AI 파일·`TokenlyApp.swift`·`TokenlySettingsView.swift`·`MenuBarNumericRow.swift` 변경 없음.
- **미리보기:** 저장소 밖 하네스로 AI 숫자형과 시스템 위젯을 나란히 렌더링했다(세션 임시 폴더 `preview62/preview-{light,dark}.png`, 사라질 수 있음).
- **실기기 확인 필요 (6-3)**
  - 실제 메뉴 막대에서 초록 번개가 색을 유지하는지(V2), "투명도 줄이기"·"대비 증가"
  - 독립 아이템 사이 간격
  - 충전 중에 배터리 외곽 없이 번개만 보이는 모양이 충분히 알아보기 쉬운지
  - Battery 고정 폭 때문에 오른쪽에 생기는 여백이 어색하지 않은지
  - macOS 14에서의 심볼


## 6-1 구현 (Claude, 2026-10-27)

- **신규 파일 (`src/Tokenly/SystemMonitor/UI/`, Xcode에 `UI` 그룹 ID `…009`로 추가)**
  - `SystemWidgetController.swift`
    - `SystemWidget`(5개, 이름·지표·TOP 5 키·UserDefaults 키)
    - `SystemWidgetSupport`(영구 판정만 미지원. GPU `readFailed`·이상값과 Battery 읽기 실패는 지원으로 본다)
    - `SystemWidgetController`(`@MainActor`)
      - 저장값 `stored`와 유효 상태 `isInserted = 저장값 && 지원됨`을 둔다.
      - `binding(for:)`은 토글과 `isInserted` 공용이다.
      - 단일 setter `setInserted`: 미지원이면 무시하고 저장값을 보존한다. 같은 값이면 반환한다. 그 외에는 UserDefaults 저장 → 게시 → `store.setEnabled` → CPU·RAM 끔이면 `processTop.setVisible(key, false)`.
      - init에서 저장값을 읽고, 지원 여부를 한 번 확인하고, 켜진 위젯의 측정을 시작한다.
  - `SystemWidgetPresentation.swift`
    - `SystemWidgetDisplay`(loading/unavailable/percent, 텍스트 `24%`/`—`, 흐림 여부, Battery 번개 여부. 처음엔 Battery 아이콘이었다가 최종 디자인에서 바뀜)
    - Disk: `diskUsedPercent`는 중요한 용도 기준이고 `usedFraction`은 쓰지 않는다. 값이 없으면 `nil` → `—`.
    - Battery: `BatteryDisplayState` 4상태. 번개는 `isCharging == .available(true)`이고 잔량이 있을 때만이다(최종 디자인에서 `BatteryGlyph`를 `showsChargingBolt`로 대체).
    - TOP 5 포맷: CPU는 소수 1자리이고 100% 초과 허용, RAM은 `ByteCountFormatter.memory`.
    - 그래프: `segments`로 연속 유효 구간을 나눈다.
- **테스트 27개**
  - `SystemWidgetControllerTests` 11개: 실제 `SystemMonitorStore`·`ProcessTopStore`, 기록용 Scheduler, 별도 UserDefaults suite 사용
    - 첫 실행 OFF, 켜기 시작·끄기 중지(타이머 취소), 바인딩이 토글과 같은 경로, 재시작 복원, 제거 후 다시 켜기
    - 같은 값이면 게시·작업·저장 없음
    - 미지원 시 저장값 보존과 지원되는 Mac에서 복귀
    - 영구 판정만 미지원, 시작 시 GPU 일시 실패는 지원
    - CPU·RAM 끄면 TOP 5 해제, 다른 위젯은 TOP 5에 영향 없음
  - `SystemWidgetPresentationTests` 16개
    - 정수 %·범위, 측정 전 흐린 `—`, 측정 불가 `—`(GPU 실패는 0% 아님)
    - Disk 중요한 용도 기준(보수적 80% 대신 73%)·대체 없음·경계
    - Battery 4상태·표시·번개 조건·아이콘 단계
    - TOP 5 CPU 123.4%
    - 그래프 구간 5가지
- **검증**
  - Debug·Release 빌드 성공(경고 없음).
  - `xcodebuild test` xcresult 기준 251개 통과, 실패·건너뜀 0(기존 224 + 27).
  - 새 테스트 27개를 `-test-iterations 5`로 반복해 135회 모두 통과했다.
  - `TokenlyApp.swift`·`TokenlySettingsView.swift`·`MenuBarNumericRow.swift`와 AI 파일 변경 없음.
- **진행 중 오류**
  - 테스트 컴파일 오류: 배열 리터럴 `[SystemWidgetPresentation.cpu(nil), .memory(nil), …]`의 생략형 멤버가 원소 타입(`SystemWidgetDisplay`)에서 찾아졌다. 타입을 명시해 해결했다.
  - 테스트 이름에 보이지 않는 문자(U+200B)가 들어간 것을 빌드 전에 발견해 제거했다.
- **남은 확인 (6-3 이후)**
  - 실제 `MenuBarExtra(isInserted:)`에서 ⌘-드래그 제거 시 바인딩 setter가 불리는지
  - 뷰 갱신 중 게시 경고가 나는지
  - 가려진 위젯 구분(공개 API 없음)


## 6단계 UI 연결 시 지켜야 할 GPU 제약

- `GPUSampler`와 `GPUSampling`은 `@MainActor`다. 인스턴스를 백그라운드 Task, 다른 actor, `Task.detached`에서 부르지 않는다.
- 한 Sampler는 상태(캐시 핸들, 재시도 시각)를 가지므로 Store 하나에만 둔다.
- 지원 여부 확인(`supportStatus()`)에는 Store의 Sampler를 재사용하지 말고 **별도 인스턴스**를 메인 액터에서 만들어 쓴다. Store의 재시도·재검증 상태를 건드리지 않기 위해서다. `SystemWidgetController` init에서 한 번만 확인하고 반복 호출하지 않는다(SYSTEM-MONITOR §7.6). 일시 실패(`readFailed`)는 지원 불가로 저장하지 않는다.
- GPU 위젯 표시 설정은 `SystemWidgetController`를 거쳐 `SystemMonitorStore.setEnabled(.gpu, _:)`로만 연결한다(§7.2). 끌 때 Store가 `reset()`으로 핸들을 해제한다.
- 화면 값(`gpu`, `gpuHistory`)은 1초에 한 번 갱신된다. UI에서 더 자주 Sampler를 직접 읽지 않는다.

## 설계 결정

- 기존 앱·Xcode 프로젝트 하나를 사용한다. AI 소스는 이동하지 않는다.
- 계산(SystemMetrics, 순수 값 타입) / 수집(MachSystemSampler, Mach 호출) / 상태(SystemMonitorStore)를 분리했다. 새 측정 항목은 `SystemSnapshot`에 `SystemMetric<…>` 필드를 추가하고 계산 타입 + Sampler 읽기 함수를 더하는 방식으로 확장한다. 항목별 Sampler 프로토콜 같은 추가 추상화는 아직 만들지 않았다.
- Battery는 독립 `BatterySampler`로 두고 `SystemSnapshot`에는 아직 넣지 않았다. 연결할 때는 `SystemSnapshot`에 `battery: SystemMetric<BatteryStatus>`를 추가하고, `MachSystemSampler`와 `BatterySampler`를 묶는 Sampler 하나가 Store에 제공하는 방식을 권장한다(Store는 Sampler 하나만 받음).
- (3-1) Battery는 `SystemSnapshot`에 넣지 않고 Store가 `BatterySampling`으로 따로 읽는다. CPU·RAM(1초)과 주기·트리거가 달라 한 Sampler로 묶지 않았다(이전 권장안 변경).
- (3-1) 측정 불가 표현은 `nil`(측정 안 함)과 `SystemMetric.unavailable(사유)`(측정했으나 값 없음)로 구분한다. Sampler가 예외를 던지면 `readFailed(KERN_FAILURE)`로 기록한다.
- 한 항목의 읽기 실패가 다른 항목을 가리지 않도록 snapshot 전체가 아니라 항목별로 가용성을 가진다. 그래서 `MachSystemSampler.sample()`은 throw하지 않는다(Store의 `.failed`는 다른 Sampler용으로 유지).

## 기획 정리 (2026-10-27, Claude)

- `Doc/SYSTEM-MONITOR.md` 신규 작성: 확정 요구사항, 구현 완료·미구현, 기술 검증 V1~V7, 구현 순서 3-1~8과 완료 기준, 테스트 방법.
- 기존 `SPEC.md`·`TODO.md`·`IMP-PLAN.md`는 AI Monitor 문서이며 System Monitor 기획과 겹치거나 충돌하는 내용이 없어 수정하지 않았다.
- `AGENTS.md`에 System Monitor 기준 문서 경로 한 줄을 추가했다.
- 점검 중 확인한 사실은 다음과 같다(상세는 SYSTEM-MONITOR §3).
  - 작업 셸에서 `proc_pid_rusage`는 812개 프로세스 중 420개에서 EPERM이었다.
  - 이 Mac의 `IOAccelerator` → `PerformanceStatistics`에서 `Device Utilization %`를 읽을 수 있었다(문서화되지 않은 키, 미검증).
- 코드 변경 없음. 빌드·테스트는 다시 실행하지 않았다(3단계 결과 그대로).

## 기록 원칙 추가 (2026-10-27)

- 사용자 요청으로 블로그·포트폴리오 기록 원칙을 `AGENTS.md` "역할과 기록"에 추가했다(사실·추정 구분, 📸 캡처 추천, 단계별 보고 항목, 민감정보 비공개, Claude 구현·Codex 검증 역할).
- `Doc/BLOG-NOTES.md`에 §9 "System Monitor 개발 기록"을 추가해 1~3-1단계의 기술 근거·오류 분석·재현 명령을 정리했다. 측정 원본 로그는 세션 임시 폴더에만 있어 수치를 문서에 옮겨 두었다.

## 기술적 제한

- CPU는 시스템 전체 합계만 제공한다(코어별 상세는 기획에서도 제외).
- 32비트 tick 카운터가 랩어라운드하면 해당 한 구간이 `.counterReset`으로 빠진다.
- 첫 샘플 직후 CPU는 항상 측정 불가다. UI는 `—` 또는 "측정 중"을 표시해야 한다.
- Battery 건강도는 시스템 정보의 "최대 용량"과 다를 수 있어 추정치로 표시한다. 온도는 지원하지 않는다.
- Battery 레지스트리 1회 읽기는 약 165 µs라서 긴 주기나 이벤트 방식으로 읽는다.

## 남은 작업과 주의사항

- 다음 작업: 6단계는 `Doc/SYSTEM-MONITOR.md` §7 명세대로 6-1부터 진행한다. 위 "6단계 UI 연결 시 지켜야 할 GPU 제약"을 따른다. GPU 추가 비용 완화(대안 2·3)는 필요 시 결정한다. 모두 사용자 승인 후 진행한다. 프로세스 순위의 팝오버 연결은 6단계다. Network는 확정 기획에 없다.
- 사용자 확인이 필요한 항목
  - 어댑터 분리·재연결과 충전 중 상태를 `pmset -g batt`와 대조하고, 전원 알림 반영 속도를 확인한다(V3).
  - Finder 창 하단 상태 막대나 "정보 가져오기"의 사용 가능 수치를 같은 시점의 Disk 값과 대조한다(V6, 시스템 설정 비교는 완료).
- 후속 보강 테스트
  - 긴 PID 순회 도중 취소(3-2 재검증 Low)
  - Disk 읽기 도중 비활성화·재시작 경쟁 상태(4단계 Codex 리뷰)
- UI 연결 단계에서 위젯 표시 설정을 `SystemMonitorStore.setEnabled`에 연결한다. Store는 앱 수명 동안 하나만 둔다.
- 새 Swift 파일마다 `project.pbxproj` 파일 참조·그룹·Sources 등록을 확인한다.
- 3단계·3-1·3-2·4단계 변경과 기획 문서는 커밋·Push 하지 않았다. 다음 작업자는 Git 상태를 확인하고 미커밋 변경을 보존한다.
