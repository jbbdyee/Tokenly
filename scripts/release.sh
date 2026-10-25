#!/bin/bash
# Build, ad-hoc sign, verify and zip Tokenly for a GitHub Release.
#
#   scripts/release.sh                 development check (dirty tree allowed, marked as such)
#   scripts/release.sh --final 0.1.0   release mode: clean tree and matching version required
#
# Output goes outside the repository (default ~/Developer/TokenlyRelease.noindex/<version>[-dev]/,
# override with TOKENLY_RELEASE_DIR). Nothing is installed, committed, tagged or uploaded, and the
# LaunchServices registration of /Applications/Tokenly.app is never touched.
set -euo pipefail

BUNDLE_ID="io.github.jbbdyee.tokenly"
CATEGORY="public.app-category.utilities"
MIN_MACOS="14.0"
REQUIRED_ARCHS="arm64 x86_64"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFO_PLIST="$ROOT/src/Tokenly/Info.plist"

mode="dev"
wanted_version=""
while [ $# -gt 0 ]; do
    case "$1" in
        --final)
            mode="final"; shift
            if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then wanted_version="$1"; shift; fi ;;
        --dev) mode="dev"; shift ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 64 ;;
    esac
done

fail() { echo "FAIL: $*" >&2; echo "FAIL: $*" >> "${LOG:-/dev/null}"; exit 1; }
ok() { echo "  ok  $*"; echo "ok   $*" >> "$LOG"; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

# ---------------------------------------------------------------- 1. tree and version
version="$(plist "$INFO_PLIST" CFBundleShortVersionString)"
build="$(plist "$INFO_PLIST" CFBundleVersion)"
[ -n "$version" ] || fail "no CFBundleShortVersionString in $INFO_PLIST"
commit="$(git -C "$ROOT" rev-parse HEAD)"
dirty="$(git -C "$ROOT" status --porcelain)"
changelog_version="$(sed -nE 's/^## \[?([0-9]+\.[0-9]+\.[0-9]+)\]?.*/\1/p' "$ROOT/CHANGELOG.md" 2>/dev/null | head -1)"

if [ "$mode" = "final" ]; then
    [ -n "$wanted_version" ] || fail "--final needs a version, e.g. --final $version"
    [ "$wanted_version" = "$version" ] || fail "requested $wanted_version but Info.plist says $version"
    [ -z "$dirty" ] || fail "working tree is not clean (commit or stash first)"
    [ "$changelog_version" = "$version" ] || fail "latest CHANGELOG.md entry is '${changelog_version:-none}', not $version"
    if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
        [ "$(git -C "$ROOT" rev-parse "v$version^{commit}")" = "$commit" ] || fail "tag v$version exists and is not HEAD"
    fi
fi

suffix=""; [ "$mode" = "dev" ] && suffix="-dev"
OUT="${TOKENLY_RELEASE_DIR:-$HOME/Developer/TokenlyRelease.noindex}/$version$suffix"
case "$OUT/" in "$ROOT"/*) fail "output must be outside the repository: $OUT" ;; esac
ZIP_NAME="Tokenly-$version-macOS-universal.zip"
rm -rf "$OUT"; mkdir -p "$OUT"
LOG="$OUT/build-info.txt"
DD="$OUT/DerivedData"; STAGE="$OUT/stage"; CHECK="$OUT/unzipped"; SMOKE="$OUT/smoke-home"
APP="$STAGE/Tokenly.app"

# Every app bundle the script produces lives under $OUT; only those registrations are removed.
unregister_outputs() {
    [ -x "$LSREGISTER" ] || return 0
    "$LSREGISTER" -dump 2>/dev/null | sed -nE 's/^path: +(.*\.app) \(0x[0-9a-f]+\)$/\1/p' | sort -u |
    while IFS= read -r path; do
        case "$path" in
            "$OUT"/*|/private"$OUT"/*) "$LSREGISTER" -u "$path" 2>/dev/null && echo "  lsregister -u $path" >> "$LOG" ;;
        esac
    done
}
trap unregister_outputs EXIT

{
    echo "Tokenly release build"
    echo "mode:            $mode$([ "$mode" = dev ] && echo ' (development check — not for publication)')"
    echo "version:         $version ($build)"
    echo "commit:          $commit"
    echo "working tree:    $([ -z "$dirty" ] && echo clean || echo "dirty ($(echo "$dirty" | wc -l | tr -d ' ') paths)")"
    echo "changelog top:   ${changelog_version:-none}"
    echo "started:         $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "macOS:           $(sw_vers -productVersion) ($(sw_vers -buildVersion)) $(uname -m)"
    echo "xcode:           $(xcodebuild -version | tr '\n' ' ')"
    echo "swift:           $(xcrun swift --version 2>/dev/null | head -1)"
    echo "sdk:             $(xcrun --sdk macosx --show-sdk-version)"
    echo
    echo "checks:"
} > "$LOG"
echo "Tokenly $version · $mode → $OUT"
ok "version $version, CHANGELOG ${changelog_version:-none}, tree $([ -z "$dirty" ] && echo clean || echo dirty)"

# ---------------------------------------------------------------- 2. universal Release build
echo "building…"
xcodebuild -project "$ROOT/src/Tokenly.xcodeproj" -scheme Tokenly -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DD" \
    ARCHS="$REQUIRED_ARCHS" ONLY_ACTIVE_ARCH=NO clean build > "$OUT/xcodebuild.log" 2>&1 \
    || { tail -20 "$OUT/xcodebuild.log" >&2; fail "xcodebuild failed (see $OUT/xcodebuild.log)"; }
ok "xcodebuild Release"
mkdir -p "$STAGE"
ditto --norsrc --noextattr --noacl "$DD/Build/Products/Release/Tokenly.app" "$APP"
unregister_outputs

# ---------------------------------------------------------------- 3. bundle checks (staged and unzipped)
verify_app() {
    local app="$1" label="$2" exe archs a
    local info="$app/Contents/Info.plist"
    exe="$app/Contents/MacOS/$(plist "$info" CFBundleExecutable)"
    [ -x "$exe" ] || fail "$label: executable missing"
    archs="$(lipo -archs "$exe")"
    for a in $REQUIRED_ARCHS; do
        case " $archs " in *" $a "*) ;; *) fail "$label: missing $a (has: $archs)" ;; esac
    done
    ok "$label: architectures $archs"
    [ "$(plist "$info" CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "$label: bundle id is $(plist "$info" CFBundleIdentifier)"
    [ "$(plist "$info" CFBundleShortVersionString)" = "$version" ] || fail "$label: version mismatch"
    [ "$(plist "$info" LSUIElement)" = "true" ] || fail "$label: LSUIElement is not true"
    [ "$(plist "$info" LSApplicationCategoryType)" = "$CATEGORY" ] || fail "$label: category is not $CATEGORY"
    [ "$(plist "$info" LSMinimumSystemVersion)" = "$MIN_MACOS" ] || fail "$label: minimum macOS is not $MIN_MACOS"
    [ "$(plist "$info" CFBundleIconName)" = "AppIcon" ] || fail "$label: CFBundleIconName is not AppIcon"
    plutil -lint -s "$info" || fail "$label: Info.plist does not lint"
    ok "$label: Info.plist ($BUNDLE_ID $version, LSUIElement, utilities, macOS $MIN_MACOS+, AppIcon)"
    [ -s "$app/Contents/Resources/AppIcon.icns" ] && [ -s "$app/Contents/Resources/Assets.car" ] || fail "$label: AppIcon resources missing"
    for r in ClaudeStatusLineBridge.py AGYStatusLineBridge.py BearGauge/bear-assets.json; do
        [ -s "$app/Contents/Resources/$r" ] || fail "$label: resource $r missing"
    done
    ok "$label: AppIcon.icns, Assets.car, compatibility bridges, bear assets"
    if [ "$label" != "built" ]; then
        codesign --verify --deep --strict "$app" 2>> "$LOG" || fail "$label: codesign --verify failed"
        local sig; sig="$(codesign -dv "$app" 2>&1)"
        echo "$sig" | grep -qx "Identifier=$BUNDLE_ID" || fail "$label: signing identifier is not $BUNDLE_ID"
        echo "$sig" | grep -qx "Signature=adhoc" || fail "$label: not ad-hoc signed"
        ok "$label: ad-hoc signature valid, identifier $BUNDLE_ID"
    fi
}

# The executable's command-line modes must work from the package, using a throwaway home only.
smoke_test() {
    local app="$1" label="$2" exe="$1/Contents/MacOS/Tokenly" out
    rm -rf "$SMOKE"; mkdir -p "$SMOKE/.claude"
    run() { env -i HOME="$SMOKE" TOKENLY_HOME="$SMOKE" PATH=/usr/bin:/bin LANG=en_US.UTF-8 "$@"; }
    run "$exe" --help > /dev/null || fail "$label: --help failed"
    run "$exe" --status > /dev/null || fail "$label: --status failed"
    run "$exe" --connect claude --dry-run > /dev/null || fail "$label: --connect --dry-run failed"
    out="$(echo '{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":4102444800}}}' | run "$exe" --statusline claude)" \
        || fail "$label: --statusline failed"
    [ -s "$SMOKE/Library/Application Support/Tokenly/claude-quota.json" ] || fail "$label: --statusline stored nothing"
    [ "$(stat -f %Lp "$SMOKE/Library/Application Support/Tokenly/claude-quota.json")" = "600" ] || fail "$label: quota file not 0600"
    [ ! -e "$SMOKE/.claude/settings.json" ] || fail "$label: a dry run wrote settings"
    rm -rf "$SMOKE"
    ok "$label: --help, --status, --connect --dry-run, --statusline (temporary home)"
}

verify_app "$APP" "built"

# ---------------------------------------------------------------- 4. ad-hoc signing
codesign --force --deep --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP" 2>> "$LOG"
verify_app "$APP" "signed"
smoke_test "$APP" "signed"

# ---------------------------------------------------------------- 5. ZIP (fixed timestamps for reproducibility)
epoch="$(git -C "$ROOT" log -1 --format=%ct HEAD)"
stamp="$(date -r "$epoch" +%Y%m%d%H%M.%S)"
find "$APP" -exec touch -h -t "$stamp" {} +
(cd "$STAGE" && ditto -c -k --keepParent --norsrc --noextattr --noacl --noqtn Tokenly.app "$OUT/$ZIP_NAME")
ok "zip $ZIP_NAME ($(stat -f %z "$OUT/$ZIP_NAME") bytes, timestamps $(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ))"

# ---------------------------------------------------------------- 6. unzip and verify again
mkdir -p "$CHECK"
ditto -x -k "$OUT/$ZIP_NAME" "$CHECK"
[ "$(ls "$CHECK")" = "Tokenly.app" ] || fail "zip root is not just Tokenly.app: $(ls "$CHECK" | tr '\n' ' ')"
unregister_outputs
verify_app "$CHECK/Tokenly.app" "unzipped"
smoke_test "$CHECK/Tokenly.app" "unzipped"
tree_hash() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1); }
[ "$(tree_hash "$APP")" = "$(tree_hash "$CHECK/Tokenly.app")" ] || fail "unzipped app differs from the signed app"
ok "unzipped app is byte-identical to the signed app (content $(tree_hash "$APP"))"
unregister_outputs

# ---------------------------------------------------------------- 7. checksum, notes, record
(cd "$OUT" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")
(cd "$OUT" && shasum -a 256 -c -s "$ZIP_NAME.sha256") || fail "checksum does not verify"
sha="$(cut -d' ' -f1 "$OUT/$ZIP_NAME.sha256")"
ok "sha256 $sha"

notes="$OUT/RELEASE-NOTES.md"
{
    echo "# Tokenly $version (개발자 미리보기)"
    echo
    [ "$mode" = dev ] && { echo "> **초안:** 미커밋 변경이 있는 작업 트리의 개발 빌드입니다. 게시 전에 \`scripts/release.sh --final $version\`으로 다시 만드세요."; echo; }
    echo "**Apple 공증을 받지 않은 ad-hoc 서명 빌드입니다.** 첫 실행 때 macOS가 실행을 막습니다."
    echo "\`Tokenly.app\`을 응용 프로그램 폴더로 옮긴 뒤 한 번 열고, 시스템 설정 → 개인정보 보호 및 보안 → **그래도 열기**로 이 앱만 허용하세요(README의 \"설치\")."
    echo "Gatekeeper를 끄는 등 시스템 보안 설정을 바꿀 필요는 없습니다."
    echo
    echo "- macOS $MIN_MACOS 이상, Apple silicon·Intel 공용(universal)"
    echo "- 번들 ID \`$BUNDLE_ID\`"
    echo "- Claude Code·AGY는 설치 후 \`/Applications/Tokenly.app/Contents/MacOS/Tokenly --connect claude\`(또는 \`agy\`)로 연결합니다."
    echo
    echo "## 변경 내용"
    awk -v v="$version" '
        $0 ~ "^## \\[?" v "\\]?" {on=1; next}
        on && /^## / {exit}
        on {sub(/^### /, "#### "); print}' "$ROOT/CHANGELOG.md" 2>/dev/null
    echo
    echo "## 체크섬 (SHA-256)"
    echo
    echo '```'
    echo "$sha  $ZIP_NAME"
    echo '```'
    echo
    echo "받은 뒤 확인: \`shasum -a 256 -c $ZIP_NAME.sha256\`"
} > "$notes"
ok "release notes draft $(basename "$notes")"

rm -rf "$DD"
{
    echo
    echo "artifacts:"
    echo "  $OUT/$ZIP_NAME"
    echo "  $OUT/$ZIP_NAME.sha256"
    echo "  $notes"
    echo "sha256:          $sha"
    echo "app content:     $(tree_hash "$APP")"
    echo "finished:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "not verified here: Gatekeeper first launch of the downloaded zip, real Claude Code / AGY calls"
} >> "$LOG"
echo
echo "done: $OUT/$ZIP_NAME"
echo "sha256: $sha"
