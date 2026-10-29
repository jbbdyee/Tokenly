# Preview — 디자인 시안·측정 기록

앱에는 포함되지 않는 개발 기록입니다. 각 폴더의 `run*.sh`는 앱 소스를 읽기 전용으로 컴파일해 이미지를 만듭니다.

바탕화면의 Tokenly 팝오버·간격 Preview 폴더 8개는 Stage 6-8C에서 대표 시안·실제 화면·측정 기록만 Workspace 로컬 보관소로 옮기고 원본을 휴지통으로 이동했다. 이 저장소의 `Preview/` 자료도 앱 빌드 산출물로 취급해 삭제하지 않는다. 현재 사용 여부와 과거 시안 여부는 아래 표를 따른다.

| 폴더 | 내용 | 스크립트 상태 |
|---|---|---|
| `Heart3D/` | 3D 하트·곰돌이 렌더링, **과거 앱 곰돌이 에셋 생성(`run-bear-b.sh` → `assets-b/`)**, 외곽선·숫자·이름 통합 시안. 현재 제품의 곰돌이형 코드·에셋은 Stage 6-6B에서 삭제 | `run-bear-b.sh`·`run.sh`·`run-bear.sh`는 시안 제작용. `run-gauge-rows.sh`·`run-numbers.sh`·`run-outline.sh`·`run-name-outline.sh`는 제거·변경된 앱 API를 써서 **현재 실행되지 않음**(결과 이미지는 보존) |
| `Numeric/` | 숫자형 위계·굵기·간격 비교 | 실행 가능 |
| `CodexResetCredits/` | Codex 재설정 권한 팝오버 오프라인 렌더(가짜 응답, 네트워크 없음) | 실행 가능 |
| `ReadmeImages/` | README용 메뉴 막대 이미지(`Doc/images/`) | 실행 가능 |
| `AppIconConcepts/` | **앱에 쓰는 원본 추출본 `D-original-extracted/`**(`icon-*.png`가 `src/Tokenly/Assets.xcassets/AppIcon.appiconset/`과 바이트 동일, 추출 결과 `original-crop-343.png`·`native-396.png`)과 비교 시트(`sheetx`) 입력인 Swift 렌더 후보 `D-final-candidate/`(`source/render.sh`로 보드 없이 다시 렌더 가능). 다른 시안(A–C, D 초기안·보정본)과 비교 시트·리샘플링 비교 이미지는 `run.sh`로 다시 만들 수 있는 검토용 결과라 저장소에 포함하지 않음 | `source/`에 생성 스크립트 보존(콘셉트 보드 원본 필요, 저장소에 없음). `D-original-extracted/source/run.sh`는 앱 아이콘 원본 파일을 다시 쓰므로 주의 |
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
