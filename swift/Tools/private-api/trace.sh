#!/bin/bash
#  trace.sh
#  Reads what a private method actually does, without its source.
#
#  A header dump tells you a method exists and takes two `id`s. This tells you what those
#  `id`s are, by disassembling the method and resolving each `objc_msgSend$foo` stub back
#  to a selector name. It is how `-[IMChat setTranscriptBackgroundAndSendToChat:transferID:]`
#  turned from "two anonymous objects" into a documented daemon call.
#
#  It is READ-ONLY. lldb loads the frameworks into a stub process, stops at main, and
#  disassembles. No Apple method is ever called; nothing on your account is touched.
#
#  Usage:
#     ./trace.sh --host Messages IMChat setTranscriptBackgroundAndSendToChat:transferID:
#     ./trace.sh --host Messages --consts IMChat transcriptBackgroundGUID
#     ./trace.sh --host FindMy +FMFSession sharedInstance
#
#  Options:
#     --host <group>       load the frameworks that hosts.conf group uses (see probe.sh)
#     --load <path>        an extra framework to dlopen; repeatable
#     --platform macos|catalyst
#     --consts             report NSString constants instead of the call graph
#     --limit <n>          instructions to walk (default 400)
#
#  Prefix a class with + to trace a class method: `+FMFSession sharedInstance`.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v lldb >/dev/null 2>&1 || pa_die "lldb not found. Install the Xcode Command Line Tools:
       xcode-select --install"

platform=""; host=""; mode="sels"; limit="400"
extra_loads=()

while [ $# -gt 0 ]; do
    case "$1" in
        --host) host="${2:?--host needs a group name}"; shift 2 ;;
        --load) extra_loads+=("$(pa_expand_path "${2:?--load needs a path}")"); shift 2 ;;
        --platform) platform="${2:?--platform needs macos or catalyst}"; shift 2 ;;
        --consts) mode="consts"; shift ;;
        --limit) limit="${2:?--limit needs a number}"; shift 2 ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's|^#[ ]\{0,2\}||'; exit 0 ;;
        --) shift; break ;;
        -*) pa_die "unknown option $1 (try --help)" ;;
        *) break ;;
    esac
done

[ $# -ge 2 ] || pa_die "need a class and a selector (try --help)"
class_name="$1"; selector="$2"

loads=()
if [ -n "$host" ]; then
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
fi
loads+=("${extra_loads[@]+"${extra_loads[@]}"}")
[ -n "$platform" ] || platform="catalyst"

build="$(mktemp -d)"; trap 'rm -rf "$build"' EXIT

# A do-nothing host process for lldb to stop inside. It has to be built for the same
# platform as the frameworks: a native macOS process cannot dlopen anything under
# /System/iOSSupport, and lldb reports that as a plain "no implementation found", which
# reads like the method is missing rather than the framework.
cat > "$build/stub.m" <<'STUB'
#import <Foundation/Foundation.h>
int main(void) { @autoreleasepool { return 0; } }
STUB
pa_compile "$platform" "$build/stub.m" "$build/stub"

commands="$build/commands"
{
    echo "breakpoint set --name main"
    echo "run"
    for path in ${loads[@]+"${loads[@]}"}; do
        printf 'expression (void*)dlopen("%s", 1)\n' "$path"
    done
    printf 'command script import "%s"\n' "$PA_TOOLS_DIR/trace.py"
    printf '%s %s %s %s\n' "$mode" "$class_name" "$selector" "$limit"
    echo "quit"
} > "$commands"

pa_step "$mode $class_name $selector  ($platform, ${#loads[@]} framework(s))"

# lldb narrates every setup step — the breakpoint, the launch, the dlopen return values.
# The interesting output starts at the echo of our own command, so that is the anchor.
# `|| true` throughout: a filter that matches nothing must not take the script down under
# `set -e`, and "no output" is a legitimate answer here (a method can genuinely make no
# calls, which is itself a finding — see +[FMFSession sharedInstance]).
output="$(lldb --batch --source "$commands" "$build/stub" 2>&1 || true)"

printf '%s\n' "$output" \
    | sed -n "/^(lldb) $mode /,\$p" \
    | grep -vE '^\(lldb\)' \
    | sed '/^$/d' || true

if ! printf '%s' "$output" | grep -q "^(lldb) $mode "; then
    pa_warn "lldb did not reach the trace command. Its output was:"
    printf '%s\n' "$output" | tail -20 >&2
    exit 1
fi
