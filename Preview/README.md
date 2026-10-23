# Preview — 디자인 시안·측정 기록

앱에는 포함되지 않는 개발 기록입니다. 각 폴더의 `run*.sh`는 앱 소스를 읽기 전용으로 컴파일해 이미지를 만듭니다.

| 폴더 | 내용 | 스크립트 상태 |
|---|---|---|
| `Heart3D/` | 3D 하트·곰돌이 렌더링, **앱 곰돌이 에셋 생성(`run-bear-b.sh` → `assets-b/`)**, 외곽선·숫자·이름 통합 시안 | `run-bear-b.sh`·`run.sh`·`run-bear.sh` 실행 가능. `run-gauge-rows.sh`·`run-numbers.sh`·`run-outline.sh`·`run-name-outline.sh`는 이후 제거·변경된 앱 API(하트 렌더러, `BearNumber`, `MenuBarBearRow`)를 써서 **현재 실행되지 않음**(결과 이미지는 보존) |
| `Numeric/` | 숫자형 위계·굵기·간격 비교 | 실행 가능 |
| `CodexResetCredits/` | Codex 재설정 권한 팝오버 오프라인 렌더(가짜 응답, 네트워크 없음) | 실행 가능 |
| `ReadmeImages/` | README용 메뉴 막대 이미지(`Doc/images/`) | 실행 가능 |
| `HeartLegibility/`, `HeartStyles/` | 제거된 하트형의 가독성·스타일 시안 | `Shared/`의 레거시 코드로 실행 가능 |
| `Shared/` | `HeartGaugeView.swift`(곰돌이 에셋 렌더러가 쓰는 `HeartShape` 포함), 레거시 하트 메뉴 막대 코드 | — |
| `README.before-v1.md` | v1 정리 전 README 보존본 | — |

이미지는 대부분 Retina 2배율 실제 픽셀과 보간 없는 확대본입니다. 앱 렌더링 코드로 만든 이미지이며 실제 화면 캡처가 아닙니다.

## ⚠️ 현재 실행되지 않는 스크립트

아래 4개는 이후 앱에서 제거·변경된 API(하트 렌더러, `BearNumber`, `MenuBarBearRow`)를 사용해 **현재 코드로는 컴파일되지 않습니다.** 당시의 결과 이미지(`Heart3D/30`–`63`)는 기록으로 보존합니다.

- `Heart3D/run-gauge-rows.sh`
- `Heart3D/run-numbers.sh`
- `Heart3D/run-outline.sh`
- `Heart3D/run-name-outline.sh`
