# Stage 6-7A CPU 팝오버 정적 디자인 비교

실제 앱 소스·설정·측정값을 바꾸지 않는 격리된 SwiftUI 렌더입니다. 모든 화면은 **340×345pt, 2×(680×690px)**이며 `24%`, 사용자 `17%`, 시스템 `7%`, 프로세스 목록과 그래프는 디자인 비교용 **동일한 예시 데이터**입니다. 실제 CPU 측정 결과가 아닙니다.

| 테마 | 현재형 근사 | A 플랫 차콜 | B 소프트 차콜 |
|---|---|---|---|
| 다크 | [현재](cpu-current-dark.png) | [A](cpu-flat-dark.png) | [B](cpu-soft-dark.png) |
| 라이트 | [현재](cpu-current-light.png) | [A](cpu-flat-light.png) | [B](cpu-soft-light.png) |

`render.swift`는 `CPUPopoverView.swift`의 헤더·숫자·TOP 5 배치와 `AuroraGraph.swift`의 색·면 채움·빛 번짐 원칙을 참고한 **별도 정적 시안**입니다. 현재형도 실제 앱 화면 캡처나 픽셀 동일 렌더가 아닙니다. 실제 앱의 `.regularMaterial`, 프로세스 아이콘, Aurora의 단조 3차 보간·시간 공백·실시간 갱신·접근성 동작은 이 미리보기에 들어 있지 않습니다. 시안에서 아이콘은 중립 플레이스홀더입니다. 실제 그래프 애니메이션의 유지 여부는 제품 UI 변경 뒤 별도 실기기 확인이 필요합니다. 현재 `AuroraGraph` 자체에는 시간 기반 애니메이션이 없으며, Store 기록 갱신에 따라 다시 그려집니다.

재현: 저장소 루트에서 `CLANG_MODULE_CACHE_PATH=/private/tmp/tokenly-stage6-7a-module-cache swiftc -parse-as-library Preview/Stage6-7A-CPU/render.swift -o /private/tmp/tokenly-stage6-7a-render` 후 `/private/tmp/tokenly-stage6-7a-render Preview/Stage6-7A-CPU`. 기존 이미지에 덮어쓸 수 있으므로 재생성할 때만 실행합니다.
