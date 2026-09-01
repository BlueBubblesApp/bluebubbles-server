#!/bin/bash
#  dump-headers.sh
#  Writes docs/headers/macos-<version>/ from the classes on THIS machine.
#
#  This is the tool we ask other people to run. The output is checked in, one directory per
#  macOS release, because the diff between two of those directories is the answer to "what
#  did Apple move this time" — the question that costs the most time when a Private API
#  feature stops working.
#
#  WHAT IT READS: Objective-C class and method NAMES, from frameworks it loads into itself.
#  Nothing else. It does not open the Messages database, your notes, your location, or any
#  file in your home directory. See docs/private-api/collecting-headers.md § What this sends.
#
#  Usage:
#     ./dump-headers.sh                 dump every group in hosts.conf
#     ./dump-headers.sh Messages        dump only groups whose name starts with "Messages"
#     ./dump-headers.sh --list          show the groups and the platform each will use
#     ./dump-headers.sh --out DIR       write somewhere other than docs/headers/macos-<ver>
#     ./dump-headers.sh --quiet         only warnings and errors

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

manifest="$PA_TOOLS_DIR/hosts.conf"
output=""
list_only=0
quiet=0
filters=()

while [ $# -gt 0 ]; do
    case "$1" in
        --list) list_only=1; shift ;;
        --quiet) quiet=1; shift ;;
        --out) output="${2:?--out needs a directory}"; shift 2 ;;
        --manifest) manifest="${2:?--manifest needs a file}"; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's|^#[ ]\{0,2\}||'; exit 0 ;;
        -*) pa_die "unknown option $1 (try --help)" ;;
        *) filters+=("$1"); shift ;;
    esac
done

pa_require_supported_macos
[ -f "$manifest" ] || pa_die "no manifest at $manifest"
[ -n "$output" ] || output="$PA_ROOT/docs/headers/macos-$(pa_macos_version)"

build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

## Builds a dumper for `platform` on first use and caches it, so a manifest with five
## Catalyst groups compiles once rather than five times.
dumper_for() {
    local platform="$1" binary="$build/dump-$1"
    [ -x "$binary" ] || pa_compile "$platform" "$PA_TOOLS_DIR/dump-headers.m" "$binary" >&2
    printf '%s\n' "$binary"
}

## Which platform a group is dumped on, and why — the reason is printed so a surprising
## choice is visible rather than silent.
resolve_platform() {
    local bundle_id="$1" fallback="$2" app detected
    if [ -n "$bundle_id" ]; then
        app="$(pa_app_path "$bundle_id")"
        if [ -n "$app" ]; then
            detected="$(pa_app_platform "$app")"
            if [ -n "$detected" ]; then
                printf '%s\t%s\n' "$detected" "detected from $(basename "$app")"
                return
            fi
            printf '%s\t%s\n' "$fallback" "$(basename "$app") has no LC_BUILD_VERSION; using manifest default"
            return
        fi
        printf '%s\t%s\n' "$fallback" "$bundle_id is not installed; using manifest default"
        return
    fi
    printf '%s\t%s\n' "$fallback" "manifest default"
}

wanted() {
    [ ${#filters[@]} -eq 0 ] && return 0
    local f
    for f in "${filters[@]}"; do [[ "$1" == "$f"* ]] && return 0; done
    return 1
}

## Runs one group. Called when the next `group` line arrives and once at EOF, so a group is
## always complete before it is dumped.
run_group() {
    [ -n "$group" ] || return 0
    wanted "$group" || return 0

    local platform reason resolved
    resolved="$(resolve_platform "$app" "$platform_default")"
    platform="${resolved%%$'\t'*}"; reason="${resolved#*$'\t'}"

    if [ "$list_only" = 1 ]; then
        printf '%-22s %-9s %-3s classes  %s\n' \
            "$group" "$platform" "$(printf '%s' "$names" | wc -w | tr -d ' ')" "$reason"
        return 0
    fi

    [ "$quiet" = 1 ] || pa_step "$group — $platform ($reason)"
    [ -n "$names" ] || { pa_warn "$group has no classes; skipping"; return 0; }

    local binary; binary="$(dumper_for "$platform")"
    # Per-file lines go to stderr so stdout stays clean for piping; --quiet drops them but
    # keeps the dumper's own warnings, which are the ones that matter.
    # shellcheck disable=SC2086
    if [ "$quiet" = 1 ]; then
        BB_DUMP_FRAMEWORKS="$loads" "$binary" "$output" $names >/dev/null
    else
        BB_DUMP_FRAMEWORKS="$loads" "$binary" "$output" $names \
            | sed "s|$output/|  |" >&2
    fi
}

group=""; app=""; platform_default="macos"; loads=""; names=""
while IFS=$'\t' read -r line_group directive value; do
    if [ "$line_group" != "$group" ]; then
        run_group
        group="$line_group"; app=""; platform_default="macos"; loads=""; names=""
    fi
    case "$directive" in
        app)      app="$value" ;;
        platform) platform_default="$value" ;;
        load)     loads="${loads:+$loads:}$value" ;;
        class)    names="${names:+$names }$value" ;;
        protocol) names="${names:+$names }@$value" ;;
        end)      ;;   # marker so an empty group still reaches run_group
    esac
done < <(pa_parse_manifest "$manifest")
run_group

[ "$list_only" = 1 ] && exit 0
[ "$quiet" = 1 ] && exit 0

pa_info ""
pa_info "Headers written to $output"
pa_info "  macOS $(pa_macos_version) ($(pa_macos_build)), $(pa_arch)"
pa_info ""
pa_info "Each header records the framework it came from on its '// Image:' line."
