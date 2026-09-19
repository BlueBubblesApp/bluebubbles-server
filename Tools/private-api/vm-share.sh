#!/bin/bash
#  vm-share.sh
#  Build the folder a macOS VM runs a header dump out of.
#
#  Sonoma and Sequoia dumps cannot be produced on this Mac: it is Tahoe, and a dump taken
#  here and filed as Sonoma is worse than no dump at all. They are produced in VMs, and a VM
#  reaches the tools through a shared folder. This writes that folder.
#
#  WHAT IT WRITES, per release:
#
#     <root>/<Release>/dump-headers-vm.sh   the runner, with its preflight
#     <root>/<Release>/private-api/         a snapshot of the tools and hosts.conf
#     <root>/<Release>/BUNDLE.txt           which commit that snapshot came from
#     <root>/<Release>/README.md            what to do, for a human in the VM
#     <root>/<Release>/output/              cleared; the dump lands here
#
#  WHY IT EXISTS: the share holds a COPY of hosts.conf, so it goes stale the moment a class
#  is added on the host, and the dump that follows is missing exactly the classes the dump
#  was requested for. That has happened. Re-run this before every dump; it is cheap, and
#  BUNDLE.txt lets the runner in the VM refuse a share it cannot vouch for.
#
#  Usage:
#     ./vm-share.sh                      refresh every release folder already under <root>
#     ./vm-share.sh Sonoma Sequoia       those, creating the folders if needed
#     ./vm-share.sh --root DIR           a share root other than $BB_VM_SHARE
#     ./vm-share.sh --list               what is under <root> now, and how stale it is
#
#  <root> is $BB_VM_SHARE, or ~/VM Shared when that is unset. It is whatever directory the
#  VM software on THIS Mac has been pointed at; there is nothing to detect and nothing
#  portable to hardcode, so it is configuration. See pa_share_root in lib.sh.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# The tools a VM needs. Deliberately not everything in this directory: compare-releases.py
# and trace.py are host-side analysis, and the limneos scripts are dead weight kept only for
# the history of a dump that is no longer used.
BUNDLED=(lib.sh collect.sh dump-headers.sh dump-headers.m hosts.conf probe.sh probe.m notifications.sh)

root="$(pa_share_root)"
list_only=0
releases=()

while [ $# -gt 0 ]; do
    case "$1" in
        --root) root="${2:?--root needs a directory}"; shift 2 ;;
        --list) list_only=1; shift ;;
        -h|--help) pa_usage "$0"; exit 0 ;;
        -*) pa_die "unknown option $1 (try --help)" ;;
        *) releases+=("$1"); shift ;;
    esac
done

## The macOS major each release folder is for. dump-headers-vm.sh derives the same mapping
## from the folder name; this one exists to reject a typo here rather than in the VM.
release_major() {
    case "$1" in
        Sonoma)  printf '14\n' ;;
        Sequoia) printf '15\n' ;;
        Tahoe)   printf '26\n' ;;
        *)       printf '\n' ;;
    esac
}

commit="$(git -C "$PA_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git -C "$PA_ROOT" diff --quiet -- "$PA_TOOLS_DIR" 2>/dev/null; then
    commit="$commit+dirty"
fi
hosts_sha="$(shasum -a 256 "$PA_TOOLS_DIR/hosts.conf" | awk '{print $1}')"
hosts_classes="$(grep -cE '^[[:space:]]*(class|protocol)[[:space:]]' "$PA_TOOLS_DIR/hosts.conf")"

# ---------------------------------------------------------------------------
# --list
# ---------------------------------------------------------------------------

if [ "$list_only" = 1 ]; then
    [ -d "$root" ] || pa_die "no share root at $root.
       $(pa_share_root_help)"
    pa_info "share root: $root"
    pa_info "repository: commit $commit, hosts.conf names $hosts_classes classes"
    pa_info ""
    printf '%-12s %-10s %-18s %s\n' "FOLDER" "CLASSES" "BUILT FROM" "OUTPUT" >&2
    for dir in "$root"/*/; do
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        their_sha=""; their_commit="-"; their_classes="-"
        if [ -f "$dir/private-api/hosts.conf" ]; then
            their_sha="$(shasum -a 256 "$dir/private-api/hosts.conf" | awk '{print $1}')"
            their_classes="$(grep -cE '^[[:space:]]*(class|protocol)[[:space:]]' "$dir/private-api/hosts.conf" || true)"
        fi
        [ -f "$dir/BUNDLE.txt" ] && their_commit="$(awk '$1=="commit"{print $2}' "$dir/BUNDLE.txt")"
        # `ls` of a glob that matches nothing fails, and under `pipefail` that failure
        # propagates out of the assignment and `set -e` ends the listing early, one folder
        # in. `find` reports an empty result as success, which is what an empty output/ is.
        dumped=""
        [ -d "$dir/output" ] && dumped="$(find "$dir/output" -maxdepth 1 -type d -name 'macos-*' | head -1)"
        state="$their_commit"
        [ -n "$their_sha" ] && [ "$their_sha" != "$hosts_sha" ] && state="$their_commit (STALE)"
        printf '%-12s %-10s %-18s %s\n' \
            "$name" "$their_classes" "$state" "${dumped:+$(basename "$dumped")}" >&2
    done
    exit 0
fi

# ---------------------------------------------------------------------------
# Which folders to write
# ---------------------------------------------------------------------------

if [ ${#releases[@]} -eq 0 ]; then
    [ -d "$root" ] || pa_die "no share root at $root, and no release named.
       Name one to create it:  ./vm-share.sh Sonoma Sequoia
       $(pa_share_root_help)"
    for dir in "$root"/*/; do
        [ -d "$dir/private-api" ] || continue
        releases+=("$(basename "$dir")")
    done
    [ ${#releases[@]} -gt 0 ] || pa_die "no release folders under $root.
       Name one to create it:  ./vm-share.sh Sonoma Sequoia"
fi

for release in "${releases[@]}"; do
    major="$(release_major "$release")"
    [ -n "$major" ] || pa_die "'$release' is not a release I know (Sonoma, Sequoia, Tahoe).
       The folder name is what dump-headers-vm.sh checks the VM against, so a name it
       does not recognise turns that check off, which is the one guard against dumping
       the host and filing it as a VM."

    share="$root/$release"
    pa_step "$release (macOS $major) - $share"

    mkdir -p "$share/private-api"
    for file in "${BUNDLED[@]}"; do
        cp "$PA_TOOLS_DIR/$file" "$share/private-api/$file"
    done
    chmod +x "$share/private-api"/*.sh
    cp "$PA_TOOLS_DIR/dump-headers-vm.sh" "$share/dump-headers-vm.sh"
    chmod +x "$share/dump-headers-vm.sh"

    # A previous run's output is the most dangerous thing in this folder: it is a complete,
    # plausible dump of the wrong hosts.conf, and after an import nobody can tell from the
    # files alone which run produced it.
    if [ -d "$share/output" ]; then
        pa_warn "clearing a previous dump in $release/output/"
        rm -rf "$share/output"
    fi
    mkdir -p "$share/output"

    {
        echo "# Written by Tools/private-api/vm-share.sh. Do not edit."
        echo "#"
        echo "# dump-headers-vm.sh checks hosts_sha256 against the hosts.conf beside it and"
        echo "# refuses to run if they disagree, then copies this file into the dump so the"
        echo "# checked-in headers record which class list produced them."
        echo
        echo "release         $release"
        echo "macos_major     $major"
        echo "commit          $commit"
        echo "built           $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "built_on        macOS $(pa_macos_version) ($(pa_macos_build)), $(pa_arch)"
        echo "hosts_sha256    $hosts_sha"
        echo "hosts_classes   $hosts_classes"
    } > "$share/BUNDLE.txt"

    cat > "$share/README.md" <<README
# Header dump: macOS $release

Run this **inside the $release VM**, not on the host.

Open this folder however your VM mounts it, then:

\`\`\`bash
bash dump-headers-vm.sh --check     # preflight only, ~2 seconds
bash dump-headers-vm.sh             # the dump, ~5 minutes
\`\`\`

Nothing in the script cares where it was mounted; it works out the rest from its own location.
Where to look, if the folder is not obvious:

| Guest path | Seen with |
|---|---|
| \`/Volumes/My Shared Files/$release\` | Apple's Virtualization.framework: UTM, VirtualBuddy, Viable |
| \`~/Desktop/VirtualBuddyShared/$release\` | the same, with VirtualBuddy's guest additions running |
| \`/Volumes/VMware Shared Folders/$release\` | VMware Fusion |
| \`~/<name>\` or \`/Volumes/<name>\` | Parallels, depending on how the share was added |

\`--check\` verifies the machine is macOS $major, that clang can build for Mac Catalyst, and
that the four host apps are installed. Nothing is written until you run it without \`--check\`.

If \`--check\` reports no clang or no SDK:

\`\`\`bash
xcode-select --install
\`\`\`

The result lands in \`output/\` in this same folder, which is the host's
\`<share root>/$release/output\`, so there is nothing to copy back by hand. On the host:

\`\`\`bash
Tools/private-api/import-dump.sh
\`\`\`

## What this reads

Objective-C class, method, property and protocol **names**, out of Apple's frameworks, which
it loads into its own short-lived process. It never opens the Messages database, contacts,
attachments, or any file in a home directory, and it emits no file contents of any kind.

System Integrity Protection does **not** need to be disabled for this, and neither does
anything else: no root, no Full Disk Access, no installed copy of BlueBubbles.

## What is in this folder

| | |
|---|---|
| \`dump-headers-vm.sh\` | the runner, with the preflight |
| \`private-api/\` | a snapshot of the repository's tools, \`hosts.conf\` included |
| \`BUNDLE.txt\` | which commit that snapshot came from |
| \`output/\` | where the dump lands |

\`private-api/hosts.conf\` is the list of classes to dump: $hosts_classes of them, as of
commit \`$commit\`. **It is a copy.** Adding a class to the repository does not change this
folder; re-run \`Tools/private-api/vm-share.sh $release\` on the host first. The runner
checks the copy against \`BUNDLE.txt\` and stops if someone has edited it in place.

Written $(date -u '+%Y-%m-%d') by \`Tools/private-api/vm-share.sh\`.
README

    pa_info "  private-api/  ${#BUNDLED[@]} files, $hosts_classes classes, commit $commit"
    pa_info "  output/       cleared"
done

pa_info ""
pa_info "Next, in each VM: open the shared folder however that VM mounts it, then"
pa_info "  bash dump-headers-vm.sh"
pa_info "Each folder's README.md lists where the common VM apps put it."
pa_info ""
pa_info "Then, here:"
pa_info "  Tools/private-api/import-dump.sh"
