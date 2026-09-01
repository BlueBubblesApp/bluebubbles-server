#!/bin/bash
#  notifications.sh
#  Lists the NSNotification names a private framework posts.
#
#  These are the rung-1 events — the cheapest, most durable way to observe something, and
#  the first thing to look for before reaching for a swizzle. See docs/OBSERVATION_LADDER.md.
#
#  WHY GREP AND NOT dlsym: the names are `@"__kIMChatFooNotification"` STRING LITERALS in
#  the framework's __cstring, not exported symbols. `dlsym` reports them absent, which has
#  been read as "this notification does not exist" more than once in this project's history
#  and was wrong every time. Private frameworks have no binary on disk either — they live
#  only in the dyld shared cache — so the cache is what gets searched.
#
#  Usage:
#     ./notifications.sh                 every __kIM*Notification name
#     ./notifications.sh chat mute       only those matching a pattern
#     ./notifications.sh --pattern '__kFM[A-Za-z]*Notification'
#
#  This reads a system file and prints symbol names. It does not touch anything of yours.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

pattern='__kIM[A-Za-z]*Notification'
filters=()

while [ $# -gt 0 ]; do
    case "$1" in
        --pattern) pattern="${2:?--pattern needs a regex}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's|^#[ ]\{0,2\}||'; exit 0 ;;
        -*) pa_die "unknown option $1 (try --help)" ;;
        *) filters+=("$1"); shift ;;
    esac
done

# A read loop rather than `mapfile`: macOS ships bash 3.2 as /bin/bash and mapfile is a
# bash 4 builtin. Everything in this directory has to run on the stock shell, because the
# people we ask to run it will not have installed a newer one.
caches=()
while IFS= read -r cache_file; do
    caches+=("$cache_file")
done < <(pa_shared_cache_files || true)

if [ "${#caches[@]}" -eq 0 ]; then
    pa_die "no dyld shared cache found for $(pa_arch).
       Looked under /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld,
       /System/Cryptexes/OS/System/Library/dyld and /System/Library/dyld.
       See docs/private-api/macos-versions.md § Where the shared cache lives."
fi

pa_step "searching ${#caches[@]} cache file(s) for /$pattern/"

# LC_ALL=C because these are huge binary files and a UTF-8 locale makes grep an order of
# magnitude slower on them for no benefit — the names are ASCII.
names="$(LC_ALL=C grep -aoh -E "$pattern" "${caches[@]}" 2>/dev/null | sort -u || true)"

[ -n "$names" ] || pa_die "no matches. If this is unexpected, check the pattern."

if [ "${#filters[@]}" -gt 0 ]; then
    joined="$(IFS='|'; printf '%s' "${filters[*]}")"
    names="$(printf '%s\n' "$names" | grep -iE "$joined" || true)"
fi

printf '%s\n' "$names"
pa_info ""
pa_info "$(printf '%s\n' "$names" | grep -c . ) name(s). Observe them by name on"
pa_info "NSNotificationCenter.default — dlsym will NOT find them."
