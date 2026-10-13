#!/bin/bash
#  import-dump.sh
#  Move a dump produced in a VM into docs/headers/, and say what changed.
#
#  The copy itself is three commands. What is not three commands is being sure the headers
#  are filed under the release they were read on, which is the one mistake in this whole
#  pipeline that cannot be detected afterwards: a directory named macos-14.6.1 containing a
#  Sequoia dump reads as authoritative forever. So the release is taken from the dump's own
#  environment.txt, never from the folder it arrived in, and a disagreement between the two
#  stops the import.
#
#  Usage:
#     ./import-dump.sh                   every output/macos-* under the share root
#     ./import-dump.sh PATH ...          a dump directory, or a .tar.gz from collect.sh
#     ./import-dump.sh --root DIR        a share root other than $BB_VM_SHARE
#     ./import-dump.sh --dry-run         report what would change, write nothing
#
#  The share root is $BB_VM_SHARE, or ~/VM Shared when that is unset: see pa_share_root in
#  lib.sh. Naming a PATH skips it entirely, which is what to do for a dump someone sent.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

root="$(pa_share_root)"
dry_run=0
sources=()

while [ $# -gt 0 ]; do
    case "$1" in
        --root) root="${2:?--root needs a directory}"; shift 2 ;;
        --dry-run|-n) dry_run=1; shift ;;
        -h|--help) pa_usage "$0"; exit 0 ;;
        -*) pa_die "unknown option $1 (try --help)" ;;
        *) sources+=("$1"); shift ;;
    esac
done

if [ ${#sources[@]} -eq 0 ]; then
    while IFS= read -r found; do
        sources+=("$found")
    done < <(find "$root" -maxdepth 3 -type d -name 'macos-*' -path '*/output/*' 2>/dev/null | sort)
    [ ${#sources[@]} -gt 0 ] || pa_die "no dumps under $root.
       Expected <root>/<Release>/output/macos-<version>/, which is where
       dump-headers-vm.sh leaves them. Name a path to import one from elsewhere.
       $(pa_share_root_help)"
fi

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

## The macOS major a share folder is for, from its name. Empty when the path does not run
## through one, which is fine: environment.txt is the authority and this is a second opinion.
folder_major() {
    case "$1" in
        *"/Sonoma/"*|*"/sonoma/"*)   printf '14\n' ;;
        *"/Sequoia/"*|*"/sequoia/"*) printf '15\n' ;;
        *"/Tahoe/"*|*"/tahoe/"*)     printf '26\n' ;;
        *)                           printf '\n' ;;
    esac
}

imported=0
touched=()

for source in "${sources[@]}"; do
    [ -e "$source" ] || pa_die "no such path: $source"

    origin="$source"
    if [ -f "$source" ]; then
        case "$source" in
            *.tar.gz|*.tgz) ;;
            *) pa_die "$source is a file but not a .tar.gz. Point at the dump directory or
       the archive collect.sh wrote." ;;
        esac
        extract="$staging/$(basename "$source" .tar.gz)"
        mkdir -p "$extract"
        tar -xzf "$source" -C "$extract"
        source="$(find "$extract" -maxdepth 2 -name environment.txt -exec dirname {} \; | head -1)"
        [ -n "$source" ] || pa_die "$origin has no environment.txt in it; that is not a dump."
    fi

    [ -f "$source/environment.txt" ] || pa_die "$source has no environment.txt.
       Without it there is no record of which machine the headers came from, and a header
       directory that cannot name its own release is not worth checking in."

    count="$(find "$source" -maxdepth 1 -name '*.h' | wc -l | tr -d ' ')"
    [ "$count" -gt 0 ] || pa_die "$source has no .h files."

    version="$(awk '$1=="macos_version"{print $2}' "$source/environment.txt")"
    build="$(awk '$1=="macos_build"{print $2}' "$source/environment.txt")"
    arch="$(awk '$1=="architecture"{print $2}' "$source/environment.txt")"
    [ -n "$version" ] || pa_die "$source/environment.txt has no macos_version line."

    pa_step "macOS $version ($build, $arch), $count headers"
    pa_info "    from $origin"

    # Two cross-checks on the same claim, because the cost of getting it wrong is a wrong
    # answer that survives indefinitely, and neither source of truth is free of typos: the
    # directory name was written by the runner, the share folder name by a human.
    named="$(basename "$source")"
    case "$named" in
        macos-*)
            # TWO spellings are legitimate and both must pass, or this check refuses the very
            # archive collect.sh writes: collect.sh names its directory macos-<version>-<arch>,
            # and dump-headers-vm.sh renames that to macos-<version>, which is the spelling
            # docs/headers/ uses. Anything else is a directory whose name disagrees with its
            # own contents, which is the case worth stopping for.
            case "$named" in
                "macos-$version"|"macos-$version-$arch") ;;
                *) pa_die "the directory is called $named but its environment.txt says macOS
       $version${arch:+ on $arch}. One of the two is wrong, and filing the dump under either
       name would be a guess. Re-run the dump." ;;
            esac
            ;;
    esac
    expect_major="$(folder_major "$origin/")"
    if [ -n "$expect_major" ] && [ "$expect_major" != "${version%%.*}" ]; then
        pa_die "this dump arrived through a folder for macOS $expect_major but reports macOS
       $version. Either it was run on the wrong machine or it was copied into the wrong
       share. Neither is importable."
    fi

    target="$PA_ROOT/docs/headers/macos-$version"

    if [ -d "$target" ]; then
        before="$(mktemp -d)"
        cp "$target"/*.h "$before/" 2>/dev/null || true
        added=0; removed=0; changed=0
        for f in "$source"/*.h; do
            b="$(basename "$f")"
            if [ ! -f "$before/$b" ]; then added=$((added + 1))
            elif ! diff -q "$f" "$before/$b" >/dev/null; then changed=$((changed + 1))
            fi
        done
        for f in "$before"/*.h; do
            [ -e "$f" ] || continue
            [ -f "$source/$(basename "$f")" ] || removed=$((removed + 1))
        done
        rm -rf "$before"
        pa_info "    replacing macos-$version: $added new, $changed changed, $removed gone"
    else
        pa_warn "macos-$version is a NEW directory. The release moved."
        pa_warn "Nothing references it yet, and the directory it supersedes is still there:"
        for old in "$PA_ROOT"/docs/headers/macos-"${version%%.*}".*; do
            [ -d "$old" ] && [ "$old" != "$target" ] || continue
            refs="$(grep -rl "$(basename "$old")" "$PA_ROOT/docs" "$PA_ROOT/Tools" \
                    "$PA_ROOT/Sources" "$PA_ROOT/Helper" "$PA_ROOT/CLAUDE.local.md" \
                    2>/dev/null | grep -vc "^$PA_ROOT/docs/headers/macos-" || true)"
            pa_warn "  $(basename "$old")  (named in ${refs:-0} files, which now point at the old dump)"
        done
        pa_warn "Decide deliberately: delete the old directory and re-point those files, or"
        pa_warn "keep both. Do not leave two dumps of one release with nothing saying which"
        pa_warn "is current."
    fi

    if [ "$dry_run" = 1 ]; then
        pa_info "    --dry-run: nothing written"
        continue
    fi

    mkdir -p "$target"
    # Delete first. A header for a class dropped from hosts.conf has to disappear, and a
    # plain copy would leave it behind looking like a class this release still has.
    rm -f "$target"/*.h "$target/environment.txt" "$target/bundle.txt"
    cp "$source"/*.h "$target/"
    cp "$source/environment.txt" "$target/"
    [ -f "$source/bundle.txt" ] && cp "$source/bundle.txt" "$target/"

    pa_info "    -> docs/headers/macos-$version"
    imported=$((imported + 1))
    touched+=("macos-$version")
done

[ "$dry_run" = 1 ] && exit 0
[ "$imported" -gt 0 ] || exit 0

pa_info ""
pa_step "Imported $imported dump(s): ${touched[*]}"
pa_info ""
pa_info "The dumps are only the input. What reads them:"
pa_info "  Tools/private-api/compare-releases.py --matrix     regenerates docs/MACOS_COMPATIBILITY.md"
pa_info "  Tools/private-api/compare-releases.py docs/headers/macos-14.x docs/headers/macos-26.5.2"
pa_info ""
pa_info "Then review the diff before committing. A selector that appeared or vanished is a"
pa_info "finding; every header also carries the macOS version in its first line, so a dump"
pa_info "filed in the wrong directory shows up there."
pa_info ""
pa_info "  git -C \"$PA_ROOT\" status --short docs/headers"
