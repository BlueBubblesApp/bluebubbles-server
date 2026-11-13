#  helper-build.sh
#  Builds a dylib for the process it is injected INTO, and proves it. Sourced, never run.
#
#  A helper is loaded into somebody else's process, so it must carry the slices THAT process
#  runs, not the ones this server runs. On Apple Silicon, Messages.app and FaceTime.app run
#  `arm64e`, and dyld will not load an `arm64` dylib into an `arm64e` process. It reports
#  nothing when it declines: the insert is skipped, the app starts normally, and the Private
#  API is simply absent. No crash, no log line, no failed request. Measured:
#
#      lipo -archs /System/Applications/Messages.app/Contents/MacOS/Messages   # x86_64 arm64e
#      lipo -archs /System/Applications/FaceTime.app/Contents/MacOS/FaceTime   # x86_64 arm64e
#
#  So the dylibs take a SECOND `swift build` with different architectures from the app and the
#  CLI, which stay `arm64 + x86_64`. A plain `swift build` produces `arm64`; a helper taken
#  from it can never load. Do not "simplify" the second build away (CLAUDE.md rule 4).
#
#  ONE implementation, for every script that injects: `Packaging/build-app.sh`,
#  `Tools/dev-bundle.sh` and `Tools/observation-probe/run-probe.sh`. Three copies of a check
#  this quiet drift apart without anyone noticing, and a weaker copy fails exactly as silently
#  as no check at all. `ToolScriptTests` fails the build on a helper build, or on any `lipo`
#  slice check, in any other script; `bb_assert_slices` is the check for every Mach-O.
#
#  The slice check is the part that matters. A wrong-architecture helper produces an app that
#  installs, launches, serves and reports itself healthy, with reactions and typing indicators
#  quietly missing; nothing downstream would ever notice.

# No shebang: this file is sourced, never executed.
# shellcheck shell=bash

# The two helpers the app bundles. BOTH: `PrivateAPIGatedService` looks for
# `libBlueBubblesFaceTimeHelper.dylib` in `Contents/Frameworks/` by name, and a bundle that
# carried only the Messages helper had no FaceTime routes at all.
BB_HELPER_PRODUCTS=(BlueBubblesHelper BlueBubblesFaceTimeHelper)

# bb_injection_slices release|host
#
# Prints the slices to build, space-separated. `release` is every slice a shipped Messages or
# FaceTime runs, Apple Silicon and Intel; `host` is the one slice they run on THIS Mac, for a
# build that never leaves it (a dev bundle, the observation probe).
bb_injection_slices() {
    case "$1" in
        release) echo "arm64e x86_64" ;;
        host)
            case "$(uname -m)" in
                arm64) echo "arm64e" ;;
                x86_64) echo "x86_64" ;;
                *) echo "error: unsupported host architecture $(uname -m)" >&2; return 1 ;;
            esac
            ;;
        *) echo "error: bb_injection_slices takes release or host, not '$1'" >&2; return 2 ;;
    esac
}

# bb_assert_slices FILE SLICE...
#
# Fails, loudly and with one message, unless FILE exists and carries every SLICE. Matches
# whole slices: `arm64` is not `arm64e`, which is exactly the mistake being caught. On
# success sets BB_SLICES to what `lipo` reported, for the caller to print.
#
# THE slice check, for every Mach-O a script ships, not only the helpers: `build-app.sh`
# asserts the app binary and Sparkle with it directly, and the helpers go through
# `bb_assert_injectable_slices` below. `ToolScriptTests` fails the build on `lipo` in any
# other script, because a hand-written copy is where a weaker match (a substring, so that
# `arm64e` satisfies `arm64`) gets in.
bb_assert_slices() {
    local file="$1"
    shift
    local have required
    if [ ! -f "$file" ]; then
        echo "error: $file was not produced." >&2
        return 1
    fi
    have="$(lipo -archs "$file")" || return 1
    for required in "$@"; do
        case " $have " in
            *" $required "*) ;;
            *)
                echo "error: $(basename "$file") is missing the $required slice (has: $have; needs: $*)." >&2
                return 1
                ;;
        esac
    done
    # shellcheck disable=SC2034 # Read by the caller, which sources this file.
    BB_SLICES="$have"
}

# bb_assert_injectable_slices FILE SLICE...
#
# `bb_assert_slices`, plus the sentence that says what a failure here MEANS: a helper that
# installs, launches and is never loaded.
bb_assert_injectable_slices() {
    if ! bb_assert_slices "$@"; then
        echo "error: dyld declines a mismatched insert WITHOUT an error, so this would be" >&2
        echo "error: a Private API that is simply never there. See Tools/helper-build.sh." >&2
        return 1
    fi
}

# bb_build_injected --slices release|host [--configuration debug|release] [--package-path DIR]
#                   [--product NAME]... [--quiet] [-- SWIFT_BUILD_ARGS...]
#
# The second build. Builds each product (default: BB_HELPER_PRODUCTS) for the injection
# slices, then asserts every `lib<product>.dylib` it produced carries them. Sets:
#
#   BB_INJECTED_SLICES   the slices built, space-separated
#   BB_INJECTED_BIN      the directory `swift build` wrote them to
#   BB_INJECTED_DYLIBS   an array of the dylibs' absolute paths, in product order
#
# Anything after `--` goes to every `swift build`; pass "${BB_SDK_STAMP_FLAGS[@]}" there when
# the dylibs ship (Tools/sdk-stamp.sh). `--quiet` sends the build's stdout to /dev/null; its
# errors still reach stderr.
#
# One `--product` per `swift build` invocation, on purpose: `swift build` honours only the
# last one and silently drops the rest, which surfaces as `lipo` failing on a binary that
# was never produced.
bb_build_injected() {
    local slices="" configuration="debug" quiet=0
    local package_args=() products=() extra=() arch_args=() slice product
    while [ $# -gt 0 ]; do
        case "$1" in
            --slices) slices="$(bb_injection_slices "$2")" || return 1; shift 2 ;;
            --configuration) configuration="$2"; shift 2 ;;
            --package-path) package_args=(--package-path "$2"); shift 2 ;;
            --product) products+=("$2"); shift 2 ;;
            --quiet) quiet=1; shift ;;
            --) shift; extra=("$@"); break ;;
            *) echo "error: bb_build_injected: unknown argument $1" >&2; return 2 ;;
        esac
    done
    if [ -z "$slices" ]; then
        echo "error: bb_build_injected needs --slices release or --slices host" >&2
        return 2
    fi
    if [ ${#products[@]} -eq 0 ]; then
        products=("${BB_HELPER_PRODUCTS[@]}")
    fi
    for slice in $slices; do
        arch_args+=(--arch "$slice")
    done

    # Every array is expanded with the `${a[@]+…}` guard: the system /bin/bash is 3.2, where
    # an empty array under `set -u` is an unbound-variable error.
    echo "==> Building ${products[*]} for $slices (the slices the target app runs)"
    for product in "${products[@]}"; do
        if [ "$quiet" -eq 1 ]; then
            swift build ${package_args[@]+"${package_args[@]}"} --configuration "$configuration" \
                "${arch_args[@]}" --product "$product" ${extra[@]+"${extra[@]}"} >/dev/null || return 1
        else
            swift build ${package_args[@]+"${package_args[@]}"} --configuration "$configuration" \
                "${arch_args[@]}" --product "$product" ${extra[@]+"${extra[@]}"} || return 1
        fi
    done
    BB_INJECTED_BIN="$(swift build ${package_args[@]+"${package_args[@]}"} \
        --configuration "$configuration" "${arch_args[@]}" --show-bin-path)" || return 1
    # shellcheck disable=SC2034 # Read by the caller, which sources this file.
    BB_INJECTED_SLICES="$slices"

    BB_INJECTED_DYLIBS=()
    for product in "${products[@]}"; do
        # shellcheck disable=SC2086 # $slices is a space-separated list by construction.
        bb_assert_injectable_slices "$BB_INJECTED_BIN/lib$product.dylib" $slices || return 1
        BB_INJECTED_DYLIBS+=("$BB_INJECTED_BIN/lib$product.dylib")
        echo "==> Built lib$product.dylib ($BB_SLICES)"
    done
}
