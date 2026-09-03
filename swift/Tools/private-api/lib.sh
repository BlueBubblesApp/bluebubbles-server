#  lib.sh
#  Shared plumbing for the private-api tools. Sourced, never run.
#
#  Everything here exists because these tools are meant to be run by OTHER PEOPLE, on Macs
#  we do not have, to answer "what does this class look like on YOUR macOS". That turns a
#  handful of things we could otherwise hardcode into things that have to be detected:
#  the CPU architecture, whether a host app is Catalyst or native, where the dyld shared
#  cache lives on that release, and whether the toolchain can build for Catalyst at all.
#
#  Supported down to macOS 14 (Sonoma). See docs/private-api/macos-versions.md.

set -euo pipefail

PA_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PA_ROOT="$(cd "$PA_TOOLS_DIR/../.." && pwd)"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [ -t 2 ]; then
    PA_DIM=$'\033[2m'; PA_RED=$'\033[31m'; PA_YEL=$'\033[33m'; PA_OFF=$'\033[0m'
else
    PA_DIM=""; PA_RED=""; PA_YEL=""; PA_OFF=""
fi

pa_info()  { printf '%s\n' "$*" >&2; }
pa_step()  { printf '%s==>%s %s\n' "$PA_DIM" "$PA_OFF" "$*" >&2; }
pa_warn()  { printf '%swarning:%s %s\n' "$PA_YEL" "$PA_OFF" "$*" >&2; }
pa_die()   { printf '%serror:%s %s\n' "$PA_RED" "$PA_OFF" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# This machine
# ---------------------------------------------------------------------------

pa_macos_version() { sw_vers -productVersion; }
pa_macos_major()   { sw_vers -productVersion | cut -d. -f1; }
pa_macos_build()   { sw_vers -buildVersion; }

## The architecture clang should build for. `uname -m` reports the kernel's view, which is
## what we want: on Apple Silicon it is arm64, on Intel x86_64. Running these tools under
## Rosetta would report x86_64 on an Apple Silicon Mac, and the resulting binary would then
## introspect the x86_64 shared cache — a real answer, but not the one the machine runs.
pa_arch() { uname -m; }

## Refuses to go on when a release is older than anything we have notes for.
##
## Not a hard technical limit — the tools may well work further back — but a header dumped
## on a release nobody has looked at can be misread as authoritative, which is the exact
## failure docs/headers/README.md exists to prevent. Override deliberately if you are
## exploring.
pa_require_supported_macos() {
    local major minimum=14
    major="$(pa_macos_major)"
    if [ "$major" -lt "$minimum" ]; then
        if [ "${PA_ALLOW_OLD_MACOS:-0}" = "1" ]; then
            pa_warn "macOS $(pa_macos_version) is below the supported floor (macOS $minimum);"
            pa_warn "continuing because PA_ALLOW_OLD_MACOS=1. Results are unvalidated."
        else
            pa_die "macOS $(pa_macos_version) is older than the supported floor (macOS $minimum, Sonoma).
       Set PA_ALLOW_OLD_MACOS=1 to try anyway; see docs/private-api/macos-versions.md."
        fi
    fi
}

# ---------------------------------------------------------------------------
# Toolchain
# ---------------------------------------------------------------------------

pa_sdk_path() {
    local sdk
    sdk="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    [ -n "$sdk" ] && [ -d "$sdk" ] || pa_die "no macOS SDK found. Install the Xcode Command Line Tools:
       xcode-select --install"
    printf '%s\n' "$sdk"
}

## The Catalyst deployment target to build against.
##
## 13.1 is the first iOS version Catalyst ever supported, and every Catalyst-capable clang
## accepts it. Naming a recent one (17.0, 26.0) builds fine on a current Xcode and fails on
## an older one for no benefit — the deployment target does not affect what the ObjC runtime
## reports, which is all these tools read.
PA_CATALYST_IOS_VERSION="13.1"

## Builds one .m file. `platform` is `macos` or `catalyst`.
##
## WHY BOTH: a Catalyst process and a native macOS process see DIFFERENT COPIES of several
## private frameworks. See docs/private-api/macos-versions.md § Two copies of IMCore.
pa_compile() {
    local platform="$1" source="$2" output="$3"
    local sdk; sdk="$(pa_sdk_path)"
    case "$platform" in
        macos)
            clang -fobjc-arc -framework Foundation -o "$output" "$source" 2>/dev/null \
                || pa_die "could not build $(basename "$source") for macOS."
            ;;
        catalyst)
            clang -target "$(pa_arch)-apple-ios${PA_CATALYST_IOS_VERSION}-macabi" \
                  -isysroot "$sdk" -fobjc-arc -framework Foundation \
                  -o "$output" "$source" 2>/dev/null \
                || pa_die "could not build $(basename "$source") for Mac Catalyst.
       The macOS SDK at
         $sdk
       does not support -target $(pa_arch)-apple-ios${PA_CATALYST_IOS_VERSION}-macabi.
       Install full Xcode (the Command Line Tools alone are sometimes not enough) and run:
         sudo xcode-select -s /Applications/Xcode.app
       See docs/private-api/macos-versions.md § Toolchain."
            ;;
        *) pa_die "unknown platform '$platform' (expected macos or catalyst)" ;;
    esac
}

# ---------------------------------------------------------------------------
# Host apps
# ---------------------------------------------------------------------------

## Where an app bundle lives, by bundle identifier. Empty output when it is not installed.
##
## The fixed paths are tried first and Spotlight second, because `mdfind` returns nothing on
## a Mac with indexing disabled — which is a completely reasonable configuration for a
## machine running a chat server, and one that made an earlier version of this report every
## app as missing.
pa_app_path() {
    local bundle_id="$1" path
    for path in "/System/Applications" "/Applications" "/System/Applications/Utilities"; do
        local candidate
        for candidate in "$path"/*.app; do
            [ -e "$candidate/Contents/Info.plist" ] || continue
            local found
            found="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
                "$candidate/Contents/Info.plist" 2>/dev/null || true)"
            [ "$found" = "$bundle_id" ] && { printf '%s\n' "$candidate"; return 0; }
        done
    done
    mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2>/dev/null | head -1
}

## `catalyst`, `macos`, or empty when the app is not installed / cannot be read.
##
## LC_BUILD_VERSION's platform field: 1 = macOS, 6 = MACCATALYST. This is the single most
## important thing these tools detect. Messages.app, FaceTime.app and FindMy.app are all
## Catalyst on macOS 26; Notes.app is native. Whether that was true on YOUR macOS is exactly
## the sort of thing that changes between releases, so it is measured, never assumed.
pa_app_platform() {
    local app="$1" executable name platform
    [ -d "$app" ] || return 0
    name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
        "$app/Contents/Info.plist" 2>/dev/null || true)"
    [ -n "$name" ] || return 0
    executable="$app/Contents/MacOS/$name"
    [ -f "$executable" ] || return 0
    platform="$(otool -l "$executable" 2>/dev/null \
        | awk '/LC_BUILD_VERSION/{f=1} f&&/^ *platform/{print $2; exit}')"
    case "$platform" in
        6|MACCATALYST) printf 'catalyst\n' ;;
        1|MACOS)       printf 'macos\n' ;;
        *)             ;;   # LC_VERSION_MIN_MACOSX-era binary, or unreadable
    esac
}

# ---------------------------------------------------------------------------
# dyld shared cache
# ---------------------------------------------------------------------------

## Prints every file making up this machine's native shared cache, one per line.
##
## Private frameworks have no binary on disk — they live only in the cache — so anything
## that greps for a string literal has to grep this. Its location MOVED: macOS 13 introduced
## the Cryptex, and by 26 /System/Library/dyld is empty on a stock install. Both roots are
## checked, and the split files (.01, .02, …) all matter because a given string may be in
## any of them.
pa_shared_cache_files() {
    local arch roots root prefix f found=0
    case "$(pa_arch)" in
        arm64*) arch="arm64e" ;;
        x86_64) arch="x86_64h" ;;
        *)      arch="$(pa_arch)" ;;
    esac
    roots=(
        "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld"
        "/System/Cryptexes/OS/System/Library/dyld"
        "/System/Library/dyld"
    )
    for root in "${roots[@]}"; do
        [ -d "$root" ] || continue
        for prefix in "$arch" "$(pa_arch)"; do
            for f in "$root/dyld_shared_cache_${prefix}" "$root/dyld_shared_cache_${prefix}".[0-9]*; do
                # .map/.atlas are indexes, not image data, and are pure noise to grep.
                case "$f" in *.map|*.atlas) continue ;; esac
                [ -f "$f" ] || continue
                printf '%s\n' "$f"; found=1
            done
            [ "$found" = 1 ] && return 0
        done
    done
    return 1
}

# ---------------------------------------------------------------------------
# Framework path shorthand, used by hosts.conf
# ---------------------------------------------------------------------------

PA_SYS_FRAMEWORKS="/System/Library/PrivateFrameworks"
PA_IOS_FRAMEWORKS="/System/iOSSupport/System/Library/PrivateFrameworks"
# The PUBLIC Catalyst frameworks — Messages.framework (MSMessage) lives here, not under
# PrivateFrameworks, and a private-only prefix silently fails to load it.
PA_IOS_PUBLIC_FRAMEWORKS="/System/iOSSupport/System/Library/Frameworks"

## Expands @sys/…, @ios/… and @iosfw/… in a framework path.
pa_expand_path() {
    local path="$1"
    path="${path/#@sys\//$PA_SYS_FRAMEWORKS/}"
    path="${path/#@iosfw\//$PA_IOS_PUBLIC_FRAMEWORKS/}"
    path="${path/#@ios\//$PA_IOS_FRAMEWORKS/}"
    printf '%s\n' "$path"
}

# ---------------------------------------------------------------------------
# hosts.conf
# ---------------------------------------------------------------------------

pa_trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

## Normalises hosts.conf into TSV: <group> <TAB> <directive> <TAB> <value>.
##
## ONE parser, because there were two and they disagreed: the manifest aligns its values
## with runs of spaces for readability, and a `${line#load }` prefix-strip left them in, so
## `@sys/` stopped matching and every framework silently failed to load. The probe then
## reported every class as ABSENT — which is indistinguishable from a genuine finding, and
## is the worst possible failure mode for a tool whose entire job is telling you what is
## present.
##
## `load` values are expanded here so no caller has to remember to.
pa_parse_manifest() {
    local manifest="$1" group="" line directive value
    [ -f "$manifest" ] || pa_die "no manifest at $manifest"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="$(pa_trim "$line")"
        [ -n "$line" ] || continue
        directive="${line%%[[:space:]]*}"
        value="$(pa_trim "${line#"$directive"}")"
        case "$directive" in
            group) group="$value" ;;
            app|platform|class|protocol)
                [ -n "$group" ] || pa_die "$manifest: '$directive' before any 'group' line"
                printf '%s\t%s\t%s\n' "$group" "$directive" "$value"
                ;;
            load)
                [ -n "$group" ] || pa_die "$manifest: 'load' before any 'group' line"
                printf '%s\t%s\t%s\n' "$group" "$directive" "$(pa_expand_path "$value")"
                ;;
            *) pa_die "$manifest: unknown directive '$directive'" ;;
        esac
    done < "$manifest"
    # A group with no members still has to reach the caller, or filtering by its name looks
    # like a typo rather than an empty group.
    [ -n "$group" ] && printf '%s\t%s\t\n' "$group" "end"
}
