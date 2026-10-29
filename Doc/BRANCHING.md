# 브랜치 운영 규칙

개인 프로젝트 기준의 가벼운 규칙입니다. v0.2.0 발행(2026-10-29) 이후 개발부터 적용합니다.

```
feature/<주제>  ──(검증)──▶  test  ──(최종 확인)──▶  main  ──▶  태그 vX.Y.Z
```

| 브랜치 | 용도 | 들어오는 것 |
|---|---|---|
| `feature/<주제>` | 기능 하나·수정 하나의 개발 | 직접 커밋 |
| `test` | 여러 기능을 합쳐 전체 테스트와 실제 앱 확인 | `feature/*` 병합 |
| `main` | 검증된 안정 버전. 릴리즈 태그는 여기에만 | `test` 병합(긴급 수정은 아래 예외) |

## 브랜치 만들기

- 항상 최신 `test`에서 시작합니다: `git switch test && git pull --ff-only && git switch -c feature/<주제>`
- 이름은 소문자와 하이픈: `feature/disk-scale-label`, `feature/login-item-check`. 문서만 바꾸면 `docs/<주제>`도 씁니다.
- 한 브랜치에는 한 가지 목적만 담습니다.

## 병합

1. `feature/*` 작업이 끝나면 그 브랜치에서 전체 자동 테스트(`xcodebuild … test`)와 `git diff --check`를 통과시킵니다.
2. `test`로 병합합니다(`git switch test && git merge --no-ff feature/<주제>`). 병합 커밋으로 어떤 기능이 언제 들어왔는지 남깁니다.
3. `test`에서 다시 전체 테스트, Debug·Release 빌드, 필요하면 격리 앱이나 설치본으로 실제 화면을 확인합니다.
4. 확인이 끝나면 `main`을 앞으로만 옮깁니다(`git switch main && git merge --ff-only test`). `main`에 직접 커밋하지 않습니다.
5. 병합한 `feature/*`는 지워도 됩니다(`git branch -d`, 원격은 `git push origin --delete`).

## 충돌 해결

- 충돌은 `feature/*`에서 풉니다: 최신 `test`를 `feature/*`로 병합(`git merge test`)한 뒤 테스트를 다시 통과시키고 `test`로 병합합니다.
- 이미 공유한 브랜치(`test`, `main`)의 이력은 rebase·reset·force push로 고치지 않습니다. 되돌려야 하면 `git revert`로 새 커밋을 만듭니다.

## 릴리즈 태그

- 태그는 `main`의 커밋에만, `vX.Y.Z` 형식의 주석 태그(`git tag -a`)로 만듭니다.
- 순서: `Info.plist` 버전·빌드 번호와 `CHANGELOG.md` 갱신 → `main`에 반영 → 깨끗한 복제본에서 `scripts/release.sh --final X.Y.Z` → 산출물 검증 → 태그 생성·태그만 Push → GitHub Release(서명·공증 전에는 Pre-release, 먼저 초안으로 확인 후 게시).
- 발행한 태그는 옮기거나 지우지 않습니다. 발행 후 문서 수정은 새 커밋으로 하고, 다음 버전에 포함합니다.

## 긴급 수정

- 발행한 버전의 심각한 문제는 `main`에서 `fix/<주제>`를 만들어 고친 뒤 `main`과 `test`에 모두 병합합니다. 그 뒤 패치 버전(`vX.Y.Z+1`)을 발행합니다.

## GitHub 브랜치 보호 (2026-10-29 설정)

- `main`, `test`: force push와 브랜치 삭제를 막았습니다. 관리자에게도 적용됩니다.
- Pull Request·리뷰·상태 검사 필수는 설정하지 않았습니다. 혼자 개발하므로 위 병합 절차를 로컬에서 지키고, CI를 도입하면 상태 검사 필수를 추가하는 것을 권장합니다.
