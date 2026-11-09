#!/bin/bash
# Build, ad-hoc sign, verify and zip Tokenly for a GitHub Release.
#
#   scripts/release.sh                 development check (dirty tree allowed, marked as such)
#   scripts/release.sh --final 0.1.0   release mode: clean tree and matching version required
#   --replace                          disabled: existing output folders cannot be replaced
#   --print-output                     resolve and check the output folder, print it, change nothing
#   --print-node-archives              resolve and verify the Claude Node archives, print the folder, change nothing
#
# Claude Node archives (node-v24.22.1-darwin-{arm64,x64}.tar.gz, SHA-256 pinned below) are read from
# TOKENLY_CLAUDE_NODE_ARCHIVES, or by default from <release root>/claude-node-archives/v24.22.1/, where the
# release root is ~/Developer/Tokenly-Workspace/TokenlyRelease.noindex (not affected by TOKENLY_RELEASE_DIR).
#
# Output goes outside the repository (default ~/Developer/Tokenly-Workspace/TokenlyRelease.noindex/<version>[-dev]/,
# override with TOKENLY_RELEASE_DIR; `~`, relative paths, `..` and symlinks are resolved first).
# An existing output folder stops the script. --replace is disabled.
# Nothing is installed, committed, tagged or uploaded, and the LaunchServices registration of
# /Applications/Tokenly.app is never touched.
set -euo pipefail

BUNDLE_ID="io.github.jbbdyee.tokenly"
# Xcode registers every app it builds with LaunchServices, and unregistering or deleting such a copy makes
# macOS's app list drop every app with that bundle ID, including the installed /Applications/Tokenly.app
# (Doc/IMP-PLAN.md 52–53, 62). The Xcode product is therefore built under this temporary ID; only a final release's
# staged copy gets BUNDLE_ID, by replacing that one string in its Info.plist before signing.
BUILD_ID="$BUNDLE_ID.release-build"
# Development checks keep the temporary ID even in the staged ZIP, so LaunchServices cannot
# prefer a throwaway copy over the installed app. Only --final stages the real product ID.
PACKAGE_ID="$BUILD_ID"
CATEGORY="public.app-category.utilities"
MIN_MACOS="14.0"
REQUIRED_ARCHS="arm64 x86_64"
LSREGISTER="${TOKENLY_TEST_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
PRESERVE_LAUNCHSERVICES="${TOKENLY_PRESERVE_LAUNCHSERVICES:-0}"
case "$PRESERVE_LAUNCHSERVICES" in 0|1) ;; *) echo "TOKENLY_PRESERVE_LAUNCHSERVICES must be 0 or 1" >&2; exit 64 ;; esac
# Preserve generated intermediates when validating the release path without deleting temporary files.
KEEP_INTERMEDIATES="${TOKENLY_KEEP_INTERMEDIATES:-0}"
case "$KEEP_INTERMEDIATES" in 0|1) ;; *) echo "TOKENLY_KEEP_INTERMEDIATES must be 0 or 1" >&2; exit 64 ;; esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_REAL="$(cd -P "$ROOT" && pwd -P)"
INFO_PLIST="$ROOT/src/Tokenly/Info.plist"
RELEASE_ROOT_DEFAULT="$HOME/Developer/Tokenly-Workspace/TokenlyRelease.noindex"
NODE_VERSION='v24.22.1'
NODE_ARCHIVES_DEFAULT="$RELEASE_ROOT_DEFAULT/claude-node-archives/$NODE_VERSION"
node_archive_sha256() {
    case "$1" in
        arm64) echo '89c682593d76cd44233fa53b1563264e7de9cbb189cad169135c5b4fadfbc0a7' ;;
        x64) echo 'd132557e7ee2b85af08b0c8c34338e65c6430f2238d01f727728ef42dc83b035' ;;
    esac
}

mode="dev"
wanted_version=""
replace=0
print_only=0
print_node_archives=0
while [ $# -gt 0 ]; do
    case "$1" in
        --final)
            mode="final"; shift
            if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then wanted_version="$1"; shift; fi ;;
        --dev) mode="dev"; shift ;;
        --replace) replace=1; shift ;;
        --print-output) print_only=1; shift ;;
        --print-node-archives) print_node_archives=1; shift ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 64 ;;
    esac
done

fail() { echo "FAIL: $*" >&2; echo "FAIL: $*" >> "${LOG:-/dev/null}"; exit 1; }
ok() { echo "  ok  $*"; echo "ok   $*" >> "$LOG"; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }
[ "$replace" = 0 ] || fail "--replace is disabled because LaunchServices dump completeness cannot be verified; no existing output folder was changed"

# ---------------------------------------------------------------- 1. tree and version
version="$(plist "$INFO_PLIST" CFBundleShortVersionString)"
build="$(plist "$INFO_PLIST" CFBundleVersion)"
[ -n "$version" ] || fail "no CFBundleShortVersionString in $INFO_PLIST"
commit="$(git -C "$ROOT" rev-parse HEAD)"
dirty="$(git -C "$ROOT" status --porcelain)"
changelog_version="$(sed -nE 's/^## \[?([0-9]+\.[0-9]+\.[0-9]+)\]?.*/\1/p' "$ROOT/CHANGELOG.md" 2>/dev/null | head -1)"

if [ "$mode" = "final" ]; then
    PACKAGE_ID="$BUNDLE_ID"
    [ -n "$wanted_version" ] || fail "--final needs a version, e.g. --final $version"
    [ "$wanted_version" = "$version" ] || fail "requested $wanted_version but Info.plist says $version"
    [ -z "$dirty" ] || fail "working tree is not clean (commit or stash first)"
    [ "$changelog_version" = "$version" ] || fail "latest CHANGELOG.md entry is '${changelog_version:-none}', not $version"
    if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
        [ "$(git -C "$ROOT" rev-parse "v$version^{commit}")" = "$commit" ] || fail "tag v$version exists and is not HEAD"
    fi
fi

suffix=""; [ "$mode" = "dev" ] && suffix="-dev"
ZIP_NAME="Tokenly-$version-macOS-universal.zip"

# Absolute, symlink-free form of a location that may not exist yet. `~`, relative paths, `.`, `..`, repeated
# and trailing slashes are handled component by component; existing components are resolved physically, so a
# symlink cannot hide a location inside the repository. Fails on control characters, `~user`, an existing
# non-directory, or a dangling symlink.
resolve_path() {
    local input="$1" cur="/" part next exists=1
    local -a parts
    case "$input" in ""|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
    case "$input" in "~") input="$HOME" ;; "~/"*) input="$HOME/${input#\~/}" ;; "~"*) return 1 ;; esac
    case "$input" in /*) ;; *) input="$PWD/$input" ;; esac
    IFS=/ read -r -a parts <<< "$input"
    for part in "${parts[@]}"; do
        case "$part" in
            ""|.) continue ;;
            ..) cur="$(dirname "$cur")"
                if [ -d "$cur" ]; then cur="$(cd -P "$cur" && pwd -P)" || return 1; exists=1; fi ;;
            *)  if [ "$cur" = / ]; then next="/$part"; else next="$cur/$part"; fi
                if [ "$exists" = 1 ] && [ -e "$next" ]; then
                    [ -d "$next" ] || return 1
                    cur="$(cd -P "$next" && pwd -P)" || return 1
                else
                    [ ! -L "$next" ] || return 1
                    exists=0; cur="$next"
                fi ;;
        esac
    done
    printf '%s\n' "$cur"
}

# Removes the LaunchServices records of bundles under $OUT that carry the temporary BUILD_ID. A record with
# the real BUNDLE_ID is never unregistered (that would hide the installed app from the app list); it is only
# reported. Records outside $OUT are never touched.
ls_records_under_out() {  # prints "<bundle id>\t<path>" per registered bundle under $OUT
    local dump
    dump="$("$LSREGISTER" -dump 2>/dev/null)" || return 1
    printf '%s\n' "$dump" | awk -v out="$OUT" '
        function flush() { if (path != "" && (index(path, out "/") == 1 || index(path, "/private" out "/") == 1)) print id "\t" path; path = id = "" }
        /^-{20,}/ { flush(); next }
        /^path: / { p = $0; sub(/^path: +/, "", p); sub(/ \(0x[0-9a-f]+\)$/, "", p); path = p }
        /^identifier: / { i = $0; sub(/^identifier: +/, "", i); id = i }
        END { flush() }'
}
unregister_outputs() {
    [ "$PRESERVE_LAUNCHSERVICES" = 1 ] && return 0
    [ -x "$LSREGISTER" ] || return 0
    local records id path
    records="$(ls_records_under_out)" || return 0
    [ -n "$records" ] || return 0
    while IFS="$(printf '\t')" read -r id path; do
        case "$id" in
            "$BUILD_ID") "$LSREGISTER" -u "$path" 2>/dev/null && echo "  lsregister -u $path ($id)" >> "$LOG" ;;
            *) echo "  left registered (not the temporary id): $path ($id)" >> "$LOG" ;;
        esac
    done <<< "$records"
}

# Resolves the Claude Node archive folder and checks both pinned archives before the long build starts.
# Prints the resolved folder; reasons for a failure go to stderr.
resolve_node_archives() {
    local requested="${TOKENLY_CLAUDE_NODE_ARCHIVES:-$NODE_ARCHIVES_DEFAULT}" dir arch archive actual
    dir="$(resolve_path "$requested")" && [ -d "$dir" ] || {
        echo "Claude Node archive folder not found: $requested" >&2
        echo "  put node-$NODE_VERSION-darwin-arm64.tar.gz and -x64.tar.gz in $NODE_ARCHIVES_DEFAULT" >&2
        echo "  or set TOKENLY_CLAUDE_NODE_ARCHIVES to the folder that holds them" >&2
        return 1; }
    for arch in arm64 x64; do
        archive="$dir/node-$NODE_VERSION-darwin-$arch.tar.gz"
        [ -f "$archive" ] || { echo "Claude Node archive missing: $archive" >&2; return 1; }
        actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
        [ "$actual" = "$(node_archive_sha256 "$arch")" ] \
            || { echo "Claude Node checksum mismatch: $archive" >&2; return 1; }
    done
    printf '%s\n' "$dir"
}
NODE_ARCHIVES="$(resolve_node_archives)" || fail "Claude Node archives unusable (see above)"
[ "$print_node_archives" = 1 ] && { echo "node archives: $NODE_ARCHIVES"; exit 0; }

requested="${TOKENLY_RELEASE_DIR:-$RELEASE_ROOT_DEFAULT}"
base="$(resolve_path "$requested")" || fail "unusable output location: $requested"
[ "$base" != / ] || fail "unusable output location: $requested"
OUT="$base/$version$suffix"
case "$OUT/" in "$ROOT_REAL"/*|"$ROOT"/*) fail "output must be outside the repository: $requested → $OUT" ;; esac
case "$ROOT_REAL/" in "$OUT"/*) fail "output folder would contain the repository: $OUT" ;; esac
protected="$(resolve_path "$ROOT_REAL/../TokenlyRelease.noindex/final-build3")" \
    || fail "cannot resolve protected final-build3 folder"
case "$OUT" in "$protected"|"$protected"/*) fail "protected final-build3 output: $OUT" ;; esac

if [ -e "$OUT" ] || [ -L "$OUT" ]; then
    fail "output folder already exists: $OUT
      Nothing was changed. Choose a new location with TOKENLY_RELEASE_DIR; --replace is disabled."
fi
[ "$print_only" = 1 ] && { echo "output: $OUT"; exit 0; }
mkdir -p "$OUT"
LOG="$OUT/build-info.txt"
DD="$OUT/DerivedData"; STAGE="$OUT/stage"; CHECK="$OUT/unzipped"; SMOKE="$OUT/smoke-home"
APP="$STAGE/Tokenly.app"

# Gives the staged copy the real bundle ID (see BUILD_ID above). The built Info.plist is XML; exactly one
# <string>BUILD_ID</string> may occur, and nowhere else in the bundle.
set_release_bundle_id() {
    local app="$1" info="$1/Contents/Info.plist" head n hits
    head="$(head -c 5 "$info")" || fail "cannot read $info"
    [ "$head" = "<?xml" ] || fail "built Info.plist is not an XML property list"
    n="$(grep -c -F "<string>$BUILD_ID</string>" "$info" || true)"
    [ "$n" = 1 ] || fail "built Info.plist contains the temporary bundle id $n times (expected 1)"
    hits="$(grep -rl -F "$BUILD_ID" "$app" || true)"
    [ "$hits" = "$info" ] || fail "temporary bundle id found outside Info.plist: $hits"
    sed -i '' "s#<string>${BUILD_ID//./\\.}</string>#<string>$BUNDLE_ID</string>#" "$info"
    hits="$(grep -rl -F "$BUILD_ID" "$app" || true)"
    [ -z "$hits" ] || fail "temporary bundle id still present: $hits"
    [ "$(plist "$info" CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "staged bundle id is not $BUNDLE_ID"
    ok "bundle id: Xcode product built as $BUILD_ID (keeps the installed app in the app list), staged copy set to $BUNDLE_ID"
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
# The scheme xcodebuild creates on the fly gathers test coverage, which turns on coverage mapping for
# every build. An instrumented executable writes default.profraw into its working directory on exit,
# i.e. into the user's project whenever Claude Code runs the status line, so switch it off here.
# (-enableCodeCoverage NO is rejected for `build`.)
xcodebuild -project "$ROOT/src/Tokenly.xcodeproj" -scheme Tokenly -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DD" \
    ARCHS="$REQUIRED_ARCHS" ONLY_ACTIVE_ARCH=NO PRODUCT_BUNDLE_IDENTIFIER="$BUILD_ID" \
    CLANG_COVERAGE_MAPPING=NO ENABLE_CODE_COVERAGE=NO clean build > "$OUT/xcodebuild.log" 2>&1 \
    || { tail -20 "$OUT/xcodebuild.log" >&2; fail "xcodebuild failed (see $OUT/xcodebuild.log)"; }
ok "xcodebuild Release"
mkdir -p "$STAGE"
ditto --norsrc --noextattr --noacl "$DD/Build/Products/Release/Tokenly.app" "$APP"
unregister_outputs
if [ "$mode" = final ]; then set_release_bundle_id "$APP"; fi
# The unstripped Release executable keeps a debug map with absolute paths (source folders under the developer's
# home, DerivedData object files). Strip debug symbols only (`strip -S`; the symbol table stays, so crash
# reports still name functions): no personal paths ship, and the app no longer depends on the output folder.
strip -S "$APP/Contents/MacOS/Tokenly" 2>> "$LOG" || fail "strip -S failed"
ok "executable: debug symbols stripped (strip -S)"

# Bundle the pinned Claude usage helper and official universal Node runtime. No Claude CLI,
# credentials, or account response is copied, and this step never executes the helper.
package_claude_runtime() {
    local node_version="$NODE_VERSION" arch archive actual node resources package_work
    # Checked again here: the archives may change during the build that follows the early check.
    for arch in arm64 x64; do
        archive="$NODE_ARCHIVES/node-$node_version-darwin-$arch.tar.gz"
        [ -f "$archive" ] || fail "Claude Node archive missing: $archive"
        actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
        [ "$actual" = "$(node_archive_sha256 "$arch")" ] || fail "Claude Node checksum mismatch: $arch"
        mkdir -p "$OUT/claude-node-$arch"
        tar -xzf "$archive" -C "$OUT/claude-node-$arch" --strip-components=2 \
            "node-$node_version-darwin-$arch/bin/node" || fail "Claude Node extraction failed: $arch"
    done
    package_work="$(mktemp -d /private/tmp/tokenly-claude-release-package.XXXXXX)" \
        || fail "Claude SDK temporary packaging directory unavailable"
    TOKENLY_CLAUDE_PACKAGE_OUT="$package_work/payload" TOKENLY_CLAUDE_OMIT_OPTIONAL=1 \
        bash "$ROOT/scripts/package-claude-helper.sh" > "$OUT/claude-package-info.txt" \
        || fail "Claude SDK packaging failed"
    node="$APP/Contents/MacOS/TokenlyClaudeNode"
    resources="$APP/Contents/Resources/ClaudeUsageSDK"
    lipo -create "$OUT/claude-node-arm64/node" "$OUT/claude-node-x64/node" -output "$node" \
        || fail "Claude universal Node creation failed"
    chmod 755 "$node"
    mkdir -p "$resources"
    cp "$package_work/payload/claude-usage-helper.mjs" \
       "$package_work/payload/package.json" "$package_work/payload/package-lock.json" "$resources/"
    cp -R "$package_work/payload/node_modules" "$resources/node_modules"
    rm -rf -- "$package_work"
    "$node" --check "$resources/claude-usage-helper.mjs" >/dev/null || fail "Claude helper syntax invalid"
    "$node" --input-type=module -e 'import(process.argv[1]).then(m=>{if(typeof m.query!=="function")process.exit(23)})' \
        "$resources/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs" \
        || fail "Claude SDK import failed"
    ok "Claude Node archives: $NODE_ARCHIVES (SHA-256 pinned)"
    ok "Claude Node $node_version arm64/x64 and SDK 0.3.169 bundled; CLI and account excluded"
}
package_claude_runtime

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
    local loads
    for a in $REQUIRED_ARCHS; do
        loads="$(otool -l -arch "$a" "$exe")" || fail "$label: otool could not read $a"
        case "$loads" in *"sectname __llvm_prf"*) fail "$label: $a has LLVM profiling sections (coverage instrumentation)" ;; esac
    done
    ok "$label: no coverage instrumentation (no __llvm_prf sections in $REQUIRED_ARCHS)"
    local paths
    paths="$(LC_ALL=C grep -a -c -F -e "$HOME/" -e "$ROOT/" -e "/DerivedData/" "$exe" || true)"
    [ "$paths" = 0 ] || fail "$label: executable contains $paths absolute build path(s) (home, repository or DerivedData)"
    ok "$label: no absolute build paths in the executable"
    [ "$(plist "$info" CFBundleIdentifier)" = "$PACKAGE_ID" ] || fail "$label: bundle id is $(plist "$info" CFBundleIdentifier)"
    [ "$(plist "$info" CFBundleShortVersionString)" = "$version" ] || fail "$label: version mismatch"
    [ "$(plist "$info" LSUIElement)" = "true" ] || fail "$label: LSUIElement is not true"
    [ "$(plist "$info" LSApplicationCategoryType)" = "$CATEGORY" ] || fail "$label: category is not $CATEGORY"
    [ "$(plist "$info" LSMinimumSystemVersion)" = "$MIN_MACOS" ] || fail "$label: minimum macOS is not $MIN_MACOS"
    [ "$(plist "$info" CFBundleIconName)" = "AppIcon" ] || fail "$label: CFBundleIconName is not AppIcon"
    plutil -lint -s "$info" || fail "$label: Info.plist does not lint"
    ok "$label: Info.plist ($PACKAGE_ID $version, LSUIElement, utilities, macOS $MIN_MACOS+, AppIcon)"
    [ -s "$app/Contents/Resources/AppIcon.icns" ] && [ -s "$app/Contents/Resources/Assets.car" ] || fail "$label: AppIcon resources missing"
    for r in ClaudeStatusLineBridge.py AGYStatusLineBridge.py; do
        [ -s "$app/Contents/Resources/$r" ] || fail "$label: resource $r missing"
    done
    ok "$label: AppIcon.icns, Assets.car, compatibility bridges"
    local node="$app/Contents/MacOS/TokenlyClaudeNode"
    local sdk="$app/Contents/Resources/ClaudeUsageSDK"
    [ -x "$node" ] && [ -r "$sdk/claude-usage-helper.mjs" ] || fail "$label: Claude runtime missing"
    [ -r "$sdk/node_modules/@anthropic-ai/claude-agent-sdk/package.json" ] \
        || fail "$label: Claude SDK missing"
    [ "$(/usr/bin/plutil -extract version raw -o - "$sdk/node_modules/@anthropic-ai/claude-agent-sdk/package.json" 2>/dev/null)" = '0.3.169' ] \
        || fail "$label: Claude SDK version mismatch"
    archs="$(lipo -archs "$node")"
    for a in $REQUIRED_ARCHS; do
        case " $archs " in *" $a "*) ;; *) fail "$label: Claude Node missing $a" ;; esac
    done
    if otool -L "$node" | grep -Eq '/opt/homebrew|/usr/local|@rpath'; then
        fail "$label: Claude Node has external library dependency"
    fi
    ok "$label: Claude runtime and SDK bundle validated"
    if [ "$label" != "built" ]; then
        codesign --verify --deep --strict "$app" 2>> "$LOG" || fail "$label: codesign --verify failed"
        local sig; sig="$(codesign -dv "$app" 2>&1)" || fail "$label: codesign -dv failed"
        case $'\n'"$sig"$'\n' in *$'\n'"Identifier=$PACKAGE_ID"$'\n'*) ;; *) fail "$label: signing identifier is not $PACKAGE_ID" ;; esac
        case $'\n'"$sig"$'\n' in *$'\n'"Signature=adhoc"$'\n'*) ;; *) fail "$label: not ad-hoc signed" ;; esac
        ok "$label: ad-hoc signature valid, identifier $PACKAGE_ID"
    fi
}

# The executable's command-line modes must work from the package, using a throwaway home only.
smoke_test() {
    local app="$1" label="$2" exe="$1/Contents/MacOS/Tokenly" out
    if [ "$KEEP_INTERMEDIATES" = 1 ]; then
        SMOKE="$OUT/smoke-$label"
        [ ! -e "$SMOKE" ] || fail "$label: temporary home already exists"
    else
        rm -rf "$SMOKE"
    fi
    mkdir -p "$SMOKE/.claude"
    run() { env -i HOME="$SMOKE" TOKENLY_HOME="$SMOKE" PATH=/usr/bin:/bin LANG=en_US.UTF-8 "$@"; }
    run "$exe" --help > /dev/null || fail "$label: --help failed"
    run "$exe" --status > /dev/null || fail "$label: --status failed"
    run "$exe" --connect claude --dry-run > /dev/null || fail "$label: --connect --dry-run failed"
    out="$(echo '{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":4102444800}}}' | run "$exe" --statusline claude)" \
        || fail "$label: --statusline failed"
    [ -s "$SMOKE/Library/Application Support/Tokenly/claude-quota.json" ] || fail "$label: --statusline stored nothing"
    [ "$(stat -f %Lp "$SMOKE/Library/Application Support/Tokenly/claude-quota.json")" = "600" ] || fail "$label: quota file not 0600"
    [ ! -e "$SMOKE/.claude/settings.json" ] || fail "$label: a dry run wrote settings"
    [ "$KEEP_INTERMEDIATES" = 1 ] || rm -rf "$SMOKE"
    ok "$label: --help, --status, --connect --dry-run, --statusline (temporary home)"
}

smoke_test "$DD/Build/Products/Release/Tokenly.app" "temporary-id"
verify_app "$APP" "built"

# ---------------------------------------------------------------- 4. ad-hoc signing
codesign --force --sign - --identifier "$PACKAGE_ID.node" --timestamp=none \
    "$APP/Contents/MacOS/TokenlyClaudeNode" 2>> "$LOG" || fail "Claude Node signing failed"
codesign --force --deep --sign - --identifier "$PACKAGE_ID" --timestamp=none "$APP" 2>> "$LOG"
verify_app "$APP" "signed"

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
tree_hash() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1); }
[ "$(tree_hash "$APP")" = "$(tree_hash "$CHECK/Tokenly.app")" ] || fail "unzipped app differs from the signed app"
ok "unzipped app is byte-identical to the signed app (content $(tree_hash "$APP"))"
unregister_outputs
real_records="$(ls_records_under_out)" || real_records="(LaunchServices could not be read)"
real_records="$(printf '%s\n' "$real_records" | awk -F '\t' -v id="$BUNDLE_ID" '$1 == id || /could not be read/')"
[ -z "$real_records" ] && ok "LaunchServices: no copy under the output folder is registered with $BUNDLE_ID" \
    || echo "  warning: registered with $BUNDLE_ID under the output folder (left as is): $real_records" | tee -a "$LOG"

# ---------------------------------------------------------------- 7. checksum, notes, record
(cd "$OUT" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")
(cd "$OUT" && shasum -a 256 -c -s "$ZIP_NAME.sha256") || fail "checksum does not verify"
sha="$(cut -d' ' -f1 "$OUT/$ZIP_NAME.sha256")"
ok "sha256 $sha"

notes="$OUT/RELEASE-NOTES.md"
{
    echo "# Tokenly $version (개발자 미리보기)"
    echo
    if [ "$mode" = dev ]; then
        echo "> **개발 점검 전용:** 임시 번들 ID의 미커밋 빌드입니다. 설치·게시하지 마세요."
    else
        echo "**Apple 공증을 받지 않은 ad-hoc 서명 빌드입니다.** 첫 실행 때 macOS가 실행을 막습니다."
        echo "\`Tokenly.app\`을 응용 프로그램 폴더로 옮긴 뒤 한 번 열고, 시스템 설정 → 개인정보 보호 및 보안 → **그래도 열기**로 이 앱만 허용하세요(README의 \"설치\")."
        echo "Gatekeeper를 끄는 등 시스템 보안 설정을 바꿀 필요는 없습니다."
    fi
    echo
    echo "- macOS $MIN_MACOS 이상, Apple silicon·Intel 공용(universal)"
    echo "- 번들 ID \`$PACKAGE_ID\`"
    if [ "$mode" = final ]; then
        echo "- Claude 자동 조회에는 공식 Claude CLI 설치·로그인이 필요합니다. 상태줄 대체 경로는 기존 Claude 연결을 유지하며, AGY 상태줄은 필요할 때 \`Tokenly --connect agy\`로 연결합니다."
    fi
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

[ "$KEEP_INTERMEDIATES" = 1 ] || rm -rf "$DD"
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
    echo "command-line smoke used only the temporary build ID, never the staged release bundle ID"
} >> "$LOG"
echo
echo "done: $OUT/$ZIP_NAME"
echo "sha256: $sha"
