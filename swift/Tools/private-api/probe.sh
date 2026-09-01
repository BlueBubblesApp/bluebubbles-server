#!/bin/bash
#  probe.sh
#  Runs probe.m, having built it for the right platform and loaded the right frameworks.
#
#  Usage:
#     ./probe.sh [options] classes   [pattern ...]
#     ./probe.sh [options] selectors <pattern ...>
#     ./probe.sh [options] members   <Class ...>
#     ./probe.sh [options] protocols [pattern ...]
#
#  Options:
#     --host <bundle-id>   load the frameworks a hosts.conf group uses, and match that
#                          app's platform. Accepts a group name too: --host Messages
#     --load <path>        an extra framework to dlopen; repeatable, @sys/ and @ios/ expand
#     --platform macos|catalyst
#                          override the platform (default: catalyst, since the iOSSupport
#                          frameworks are unreachable from a native macOS process)
#
#  Examples:
#     ./probe.sh --host Messages selectors wallpaper background
#     ./probe.sh --host FindMy members FMIPCore.FMIPManager FMFCore.FMFManager
#     ./probe.sh --host Messages classes ChatKit

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

platform=""
host=""
extra_loads=()

while [ $# -gt 0 ]; do
    case "$1" in
        --host) host="${2:?--host needs a group name or bundle id}"; shift 2 ;;
        --load) extra_loads+=("$(pa_expand_path "${2:?--load needs a path}")"); shift 2 ;;
        --platform) platform="${2:?--platform needs macos or catalyst}"; shift 2 ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's|^#[ ]\{0,2\}||'; exit 0 ;;
        --) shift; break ;;
        -*) pa_die "unknown option $1 (try --help)" ;;
        *) break ;;
    esac
done

[ $# -ge 1 ] || pa_die "no command given (try --help)"

loads=()
if [ -n "$host" ]; then
    # Pull the `load` and `app` lines out of the matching hosts.conf group(s). Reusing the
    # manifest rather than retyping framework paths is the point: a probe that loads a
    # different set from the dumper answers a different question and looks like a bug.
    # Reuse the dumper's manifest rather than retyping framework paths: a probe that
    # loads a different set from the dumper answers a different question and looks like a
    # bug in whichever one you distrust first.
    while IFS=$'\t' read -r group directive value; do
        [[ "$group" == "$host"* ]] || continue
        case "$directive" in
            load) loads+=("$value") ;;
            app)
                [ -n "$platform" ] && continue
                app_path="$(pa_app_path "$value")"
                [ -n "$app_path" ] && platform="$(pa_app_platform "$app_path")"
                ;;
        esac
    done < <(pa_parse_manifest "$PA_TOOLS_DIR/hosts.conf")

    # A bundle id that matches no group is still usable: take its platform and let --load
    # supply the frameworks.
    if [ ${#loads[@]} -eq 0 ] && [ -z "$platform" ]; then
        app_path="$(pa_app_path "$host")"
        [ -n "$app_path" ] && platform="$(pa_app_platform "$app_path")"
    fi
    [ ${#loads[@]} -eq 0 ] && [ ${#extra_loads[@]} -eq 0 ] \
        && pa_warn "no frameworks matched --host $host; only already-loaded classes are visible"
fi

loads+=("${extra_loads[@]+"${extra_loads[@]}"}")

# Catalyst by default. A native macOS process cannot dlopen anything under /System/iOSSupport
# ("wrong platform to load into process"), and it silently sees a DIFFERENT copy of the
# frameworks that ship twice — so the default is the one that can see everything.
[ -n "$platform" ] || platform="catalyst"

build="$(mktemp -d)"; trap 'rm -rf "$build"' EXIT
pa_compile "$platform" "$PA_TOOLS_DIR/probe.m" "$build/probe"

joined=""
for path in ${loads[@]+"${loads[@]}"}; do joined="${joined:+$joined:}$path"; done

BB_PROBE_FRAMEWORKS="$joined" "$build/probe" "$@"
