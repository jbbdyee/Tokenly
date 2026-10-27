# Tokenly 작업 인수인계

최종 갱신: 2026-10-27 (2단계 CPU·RAM 측정, Claude)

## 현재 목표

기존 AI 토큰 모니터링을 유지하면서 같은 macOS 앱에 독립적인 System Monitor를 단계적으로 추가한다. 1단계(공통 문서·모듈 기반, Codex)와 2단계(CPU·RAM 측정 로직, Claude)가 완료되었다. UI·설정·메뉴 막대 연결은 아직 승인되지 않았다.

## 기준 상태

- 브랜치 `main`, HEAD `ea6ffb268da72a34b835b38f96ecef09bfedf908`. 1·2단계 변경은 모두 미커밋 상태다(커밋·Push 하지 않음).
- 2단계 시작 시 미커밋 변경: `project.pbxproj`(1단계 등록), 신규 `AGENTS.md`·`CLAUDE.md`·`Doc/HANDOFF.md`·`src/Tokenly/SystemMonitor/`. 모두 보존했고 그 위에 추가만 했다.

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

## 측정 방식과 계산 기준

### CPU
- `host_statistics(HOST_CPU_LOAD_INFO)`로 부팅 이후 누적 tick(모든 논리 CPU 합계, user/system/idle/nice)을 읽는다.
- 사용률 = (Δuser + Δnice + Δsystem) / (Δuser + Δnice + Δsystem + Δidle) × 100, 0~100으로 고정. user%에는 nice를 포함한다.
- 최초 샘플은 `.unavailable(.awaitingBaseline)`. 어느 카운터든 감소하면(재설정 또는 32비트 natural_t 랩어라운드) `.counterReset`으로 그 구간을 건너뛰고 새 기준으로 삼는다. Δ합계 0이면 `.noElapsedTicks`. 읽기 실패 시 `.readFailed`이고 기존 기준값은 유지한다.
- 값은 "직전 `sample()` 호출 이후" 평균이다. 따라서 Sampler 인스턴스 하나는 Store 하나에만 연결해야 한다.

### RAM
- 전체 용량: `ProcessInfo.processInfo.physicalMemory`(= `hw.memsize`). 페이지 크기: `host_page_size`(Apple Silicon 16 KiB). 페이지 수: `host_statistics64(HOST_VM_INFO64)`.
- used = App + Wired + Compressed
  - App = `internal_page_count` − `purgeable_count`
  - Wired = `wire_count`
  - Compressed = `compressor_page_count`(압축 데이터가 실제로 차지하는 물리 페이지)
  - Cached Files = `external_page_count` + `purgeable_count` — 회수 가능하므로 used에서 제외하고 별도 필드로 제공
- 활동 모니터의 "사용된 메모리" 구성과 같은 기준이지만 샘플 시점·반올림·GB/GiB 표기 차이로 수치가 약간 다를 수 있다. 스왑 사용량은 포함하지 않는다.
- total 0, page size 0, purgeable > internal, used > total, 곱셈·덧셈 오버플로는 `.inconsistentValues`로 처리한다(0으로 표시하지 않음).

### 자원 관리
- `mach_host_self()`는 호출마다 send right 참조를 늘리므로 초기화 시 한 번만 얻고 `deinit`에서 `mach_port_deallocate`로 해제한다.
- 두 통계 모두 스택 구조체에 채우므로 `vm_deallocate`가 필요한 커널 할당이 없다(`host_processor_info`는 사용하지 않음).

## 검증 결과 (2단계)

- Debug·Release 빌드: 성공 (`xcodebuild`, DerivedData `/private/tmp/tokenly-system-stage2-derived`). 신규 파일 관련 경고 없음.
- `xcodebuild test`(Debug, `platform=macOS`): **TEST SUCCEEDED**, 기존 112개 + 신규 13개 = 125개 전부 통과. 1단계에서 보고된 testmanagerd 제한은 이번 환경에서 발생하지 않았다.
- `plutil -lint project.pbxproj`: 통과.
- 실측 대조(16 GiB Apple Silicon): Wired·Compressor·App 페이지 수가 `vm_stat` 출력과 일치. CPU 1초 구간 약 8.9%.
- 오버헤드: 독립 실행 하네스(`swiftc -O`)에서 20만 회 샘플링 시 1회당 CPU 약 6.5 µs, `phys_footprint` 2.2 MB → 2.2 MB로 증가 없음. 1,000회 반복 후 host 포트 send right 참조 수 불변을 테스트로 확인.
- 기존 AI 소스 변경 여부: Git 변경 목록에 AI Provider·Store·설정·상태줄·UI 파일 없음.

## 설계 결정

- 기존 앱·Xcode 프로젝트 하나를 사용한다. AI 소스는 이동하지 않는다.
- 계산(SystemMetrics, 순수 값 타입) / 수집(MachSystemSampler, Mach 호출) / 상태(SystemMonitorStore)를 분리했다. 새 측정 항목은 `SystemSnapshot`에 `SystemMetric<…>` 필드를 추가하고 계산 타입 + Sampler 읽기 함수를 더하는 방식으로 확장한다. 항목별 Sampler 프로토콜 같은 추가 추상화는 아직 만들지 않았다.
- 한 항목의 읽기 실패가 다른 항목을 가리지 않도록 snapshot 전체가 아니라 항목별로 가용성을 가진다. 그래서 `MachSystemSampler.sample()`은 throw하지 않는다(Store의 `.failed`는 다른 Sampler용으로 유지).

## 기술적 제한

- CPU는 시스템 전체 합계만 제공한다(코어별·P/E 코어 구분 없음).
- 32비트 tick 카운터가 랩어라운드하면 해당 한 구간이 `.counterReset`으로 빠진다(코어 수에 따라 수 주 간격으로 발생 가능).
- 첫 갱신 직후 CPU는 항상 측정 불가이므로 UI는 "측정 중" 표시가 필요하다. 갱신 간격이 너무 짧으면 `.noElapsedTicks`가 나올 수 있다(tick 단위 약 10 ms).
- 메모리 압력(memory pressure), 스왑은 아직 수집하지 않는다.

## 남은 작업과 주의사항

- 다음 단계(주기적 갱신 타이머, System Monitor UI·설정·메뉴 막대 연결, 배터리·디스크·네트워크 등)는 사용자 승인 후 진행한다.
- 주기 갱신 추가 시 Store에 타이머를 두고 `MachSystemSampler`를 하나만 공유할 것(CPU 기준값 때문). 화면이 보이지 않을 때 샘플링을 멈추는 정책도 그 단계에서 정한다.
- 새 Swift 파일마다 `project.pbxproj` 파일 참조·그룹·Sources 등록을 확인한다.
- 커밋·Push 하지 않았다. 다음 작업자는 Git 상태를 확인하고 1·2단계 미커밋 변경을 보존한다.
