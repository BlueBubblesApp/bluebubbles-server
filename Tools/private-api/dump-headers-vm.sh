#!/bin/bash
#  dump-headers-vm.sh
#  Produce a BlueBubbles private-API header dump inside a macOS VM.
#
#  Run this INSIDE the VM, from the shared folder. It copies the tools to the VM's own disk
#  (a shared folder is often mounted without the execute bit, and clang is slow over one),
#  runs the dump, and leaves the result back in the shared folder ready to be moved into
#  docs/headers/ by `import-dump.sh` on the host.
#
#  WHICH RELEASE IT EXPECTS is taken from the NAME OF THE FOLDER this script sits in:
#  .../Sonoma/ wants macOS 14, .../Sequoia/ 15, .../Tahoe/ 26, so the same file works in
#  every VM share and there is no second copy to drift. Running it on the wrong machine is
#  the mistake it is guarding against: the host would silently produce a dump of the host.
#
#  IT IS NOT RUN FROM THE REPOSITORY. `vm-share.sh` copies it, and a snapshot of
#  Tools/private-api/, into a share folder; this script then runs from that copy. The
#  BUNDLE.txt `vm-share.sh` writes records which commit the copy came from, and the
#  preflight below refuses a share whose hosts.conf no longer matches it, because a stale
#  share dumps an old class list and the missing classes are indistinguishable from classes
#  the release does not have.
#
#  READ-ONLY. It introspects Apple's frameworks for class and method NAMES. It never opens
#  the Messages database, contacts, attachments, or any file in your home directory.
#
#  SIP does NOT need to be disabled for this, and neither does anything else. See the
#  preflight for the full list of what it actually requires.
#
#  Usage:
#     bash dump-headers-vm.sh              preflight, then dump everything
#     bash dump-headers-vm.sh --check      preflight only, dump nothing
#     bash dump-headers-vm.sh --force      run even if this is not the expected release

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_SRC="$HERE/private-api"
OUT="$HERE/output"

dim=""; red=""; yel=""; grn=""; off=""
if [ -t 2 ]; then
    dim=$'\033[2m'; red=$'\033[31m'; yel=$'\033[33m'; grn=$'\033[32m'; off=$'\033[0m'
fi
step() { printf '%s==>%s %s\n' "$dim" "$off" "$*" >&2; }
ok()   { printf '%s  ok%s   %s\n' "$grn" "$off" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$yel" "$off" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$red" "$off" "$*" >&2; exit 1; }

check_only=0
force=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check) check_only=1; shift ;;
        --force) force=1; shift ;;
        # Read until the comments stop, never a line range: this header has grown twice
        # and a numbered range truncates the help without saying so.
        -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^#[ ]?[ ]?/, ""); print; next } { exit }' \
                       "$0"; exit 0 ;;
        *) die "unknown option $1 (try --help)" ;;
    esac
done

# Running this out of a checkout does nothing useful: the release check would key off the
# folder name `private-api`, and on the host the answer is Tahoe, which dump-headers.sh
# already produces correctly.
if [ -f "$HERE/lib.sh" ] && [ -f "$HERE/hosts.conf" ]; then
    die "this is the repository copy, which is a template, not a runner.
       On this Mac:        Tools/private-api/dump-headers.sh
       To build a share:   Tools/private-api/vm-share.sh Sonoma Sequoia
       Then run the copy the share folder gets, from inside the VM."
fi

# ---------------------------------------------------------------------------
# Which release this folder is for.
# ---------------------------------------------------------------------------

folder="$(basename "$HERE")"
case "$folder" in
    Sonoma|sonoma)   expect_major=14; expect_name="Sonoma" ;;
    Sequoia|sequoia) expect_major=15; expect_name="Sequoia" ;;
    Tahoe|tahoe)     expect_major=26; expect_name="Tahoe" ;;
    *)               expect_major=""; expect_name="" ;;
esac

# ---------------------------------------------------------------------------
# Preflight. Every one of these has bitten someone; none of them is theoretical.
# ---------------------------------------------------------------------------

step "Checking this machine"

version="$(sw_vers -productVersion)"
major="${version%%.*}"
build="$(sw_vers -buildVersion)"
arch="$(uname -m)"

printf '       macOS %s (%s), %s\n' "$version" "$build" "$arch" >&2

if [ -z "$expect_major" ]; then
    warn "folder '$folder' names no release I know, so the release check is skipped."
    warn "Name the folder Sonoma, Sequoia or Tahoe to get it back."
elif [ "$major" != "$expect_major" ]; then
    if [ "$force" = 1 ]; then
        warn "this is macOS $version, not $expect_name ($expect_major). Continuing because --force."
    else
        die "this is macOS $version, but this folder is for $expect_name (macOS $expect_major).
       Are you running it on the host by mistake?
       Pass --force to dump this release anyway."
    fi
else
    ok "macOS $major is $expect_name, which is what this folder is for"
fi

# Rosetta produces a real but wrong-world dump: uname reports x86_64 on Apple Silicon and
# the dumper then reads the x86_64 shared cache, which is not what the machine runs.
if [ "$arch" = "x86_64" ] && [ "$(sysctl -in sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then
    die "running under Rosetta. Open a native arm64 Terminal and run this again."
fi

[ -d "$TOOLS_SRC" ] || die "no private-api/ next to this script (expected $TOOLS_SRC)"
ok "tools present"

# ---------------------------------------------------------------------------
# Is this share current?
#
# The share is a COPY of Tools/private-api/, so it goes stale the moment hosts.conf gains a
# class on the host. That failure is silent and expensive: the dump completes, the new class
# has no header, and a later reader cannot tell "nobody looked" from "the release does not
# have it". BUNDLE.txt records the commit and the hosts.conf digest the copy was made from,
# so both halves of that can be checked here rather than discovered months later.
# ---------------------------------------------------------------------------

bundle="$HERE/BUNDLE.txt"
bundle_commit="unknown"
if [ -f "$bundle" ]; then
    bundle_commit="$(awk '$1=="commit"{print $2}' "$bundle")"
    want_digest="$(awk '$1=="hosts_sha256"{print $2}' "$bundle")"
    want_classes="$(awk '$1=="hosts_classes"{print $2}' "$bundle")"
    have_digest="$(shasum -a 256 "$TOOLS_SRC/hosts.conf" | awk '{print $1}')"
    have_classes="$(grep -cE '^[[:space:]]*(class|protocol)[[:space:]]' "$TOOLS_SRC/hosts.conf")"

    if [ -n "$want_digest" ] && [ "$want_digest" != "$have_digest" ]; then
        die "private-api/hosts.conf does not match the BUNDLE.txt next to it.
       Someone edited the share by hand. Rebuild it on the host:
         Tools/private-api/vm-share.sh $folder"
    fi
    ok "bundle from commit $bundle_commit, $have_classes classes${want_classes:+ (expected $want_classes)}"
    expected_headers="$have_classes"
else
    warn "no BUNDLE.txt: this share was not built by vm-share.sh, so there is no record of"
    warn "which commit its hosts.conf came from. Rebuild it on the host to get one:"
    warn "  Tools/private-api/vm-share.sh $folder"
    expected_headers="$(grep -cE '^[[:space:]]*(class|protocol)[[:space:]]' "$TOOLS_SRC/hosts.conf")"
fi

command -v clang >/dev/null 2>&1 || die "no clang. Install the Command Line Tools:
       xcode-select --install"

sdk="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
[ -n "$sdk" ] && [ -d "$sdk" ] || die "no macOS SDK found. Install the Command Line Tools:
       xcode-select --install"
ok "SDK $sdk"

# The one that actually decides whether this works. Messages.app is a Catalyst app, so the
# dumper has to be built for Catalyst to see the IMCore that Messages really runs. The
# Command Line Tools alone are sometimes enough and sometimes not.
probe_dir="$(mktemp -d)"
probe_src="$probe_dir/catalyst-probe.m"
probe_bin="$probe_dir/catalyst-probe"
printf '#import <Foundation/Foundation.h>\nint main(void){return 0;}\n' > "$probe_src"
if clang -target "$arch-apple-ios13.1-macabi" -isysroot "$sdk" -fobjc-arc \
         -framework Foundation -o "$probe_bin" "$probe_src" 2>/dev/null; then
    ok "toolchain can build for Mac Catalyst"
else
    rm -rf "$probe_dir"
    die "this toolchain cannot build for Mac Catalyst, so the dump would miss the IMCore
       that Messages actually runs. Install full Xcode in the VM and point at it:
         sudo xcode-select -s /Applications/Xcode.app"
fi
rm -rf "$probe_dir"

# Not fatal: a missing app is recorded as a finding. But a dump with no Messages installed
# is worth almost nothing, so say so before spending five minutes on it.
for app in \
    "/System/Applications/Messages.app" \
    "/System/Applications/FaceTime.app" \
    "/System/Applications/FindMy.app" \
    "/System/Applications/Notes.app"
do
    if [ -d "$app" ]; then
        ok "$(basename "$app") installed"
    else
        warn "$(basename "$app") is not installed; its groups will dump as NOT PRESENT"
    fi
done

if [ "$check_only" = 1 ]; then
    printf '\n%sPreflight passed. Run without --check to produce the dump.%s\n' "$dim" "$off" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Run off the VM's own disk, not the share.
# ---------------------------------------------------------------------------

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Tools/private-api"
cp "$TOOLS_SRC"/* "$work/Tools/private-api/"
chmod +x "$work/Tools/private-api"/*.sh

# collect.sh signs off with the path of its archive and how to inspect it. That path is
# inside $work and about to be deleted, so its tail is dropped and the real locations are
# printed at the end instead. Progress lines and every warning are kept.
step "Dumping (this takes a few minutes)"
set +e
"$work/Tools/private-api/collect.sh" --out "$work/archive" 2>&1 \
    | grep -E '^(==>|warning:|error:)' >&2
status="${PIPESTATUS[0]}"
set -e
[ "$status" = 0 ] || die "collect.sh failed (exit $status). The full output above is the
       useful part of a bug report: a tool that fails on a release is worth knowing about."

# A glob rather than `ls`, which shellcheck objects to and is right to: `ls` output is
# text, and a name carrying a newline or a glob character comes back as something other
# than the file. An unmatched glob stays literal under bash's default, so the `-f` below
# is what tells "no archive" from one, and globs sort the way `ls` did: same first entry.
archives=("$work/archive"/bluebubbles-headers-*.tar.gz)
archive="${archives[0]}"
[ -f "$archive" ] || die "collect.sh produced no archive"

# ---------------------------------------------------------------------------
# Hand back both shapes: the archive to keep, and a directory named the way the repository
# names them (macos-<version>, no arch suffix) so it can be moved straight in.
#
# EVERY STEP HERE IS ASSEMBLED ON LOCAL DISK FIRST and only then copied across, because a
# shared folder is not a filesystem that supports the usual moves. virtiofs on a macOS guest
# refuses `rmdir` outright: an earlier version opened with `rm -rf "$OUT"` and died with
# "Operation not permitted" AFTER a five-minute dump had succeeded, throwing the result away
# at the last step. So: no directory is removed on the share, no `mv` crosses onto it, and a
# share that cannot be written falls back to the Desktop rather than losing the dump.
# ---------------------------------------------------------------------------

staged="$work/staged"
mkdir -p "$staged"
tar -xzf "$archive" -C "$staged"
extractions=("$staged"/macos-*-"$arch")
extracted="${extractions[0]}"
[ -d "$extracted" ] || die "the archive did not contain the directory collect.sh writes"
# Provenance travels WITH the dump, because the question asked of a checked-in header six
# months from now is "which hosts.conf was this", and by then the share has been rebuilt.
[ -f "$bundle" ] && cp "$bundle" "$extracted/bundle.txt"

headers=("$extracted"/*.h)
[ -e "${headers[0]}" ] || headers=()
count="${#headers[@]}"
missing="$(grep -c '^missing ' "$extracted/environment.txt" 2>/dev/null || echo 0)"

## Copies the finished dump to `dest`, or returns 1.
##
## `environment.txt` is written LAST and removed again if anything fails, which is what makes
## a partial copy safe rather than merely unlikely. import-dump.sh refuses a directory with no
## environment.txt, so a delivery that dies halfway leaves something the host will reject
## rather than a plausible-looking dump missing an arbitrary third of its headers. Clearing a
## previous run is best-effort: where unlink works it stops a stale header surviving into the
## new dump, and where it does not, the copy still lands on top.
deliver() {
    local dest="$1" dir="$1/macos-$version"
    mkdir -p "$dir" 2>/dev/null || return 1
    rm -f "$dir/environment.txt" 2>/dev/null || true
    rm -f "$dir"/*.h "$dir"/*.txt 2>/dev/null || true
    rm -f "$dest"/bluebubbles-headers-*.tar.gz 2>/dev/null || true

    if cp "$extracted"/*.h "$dir/" 2>/dev/null \
        && { [ ! -f "$extracted/bundle.txt" ] || cp "$extracted/bundle.txt" "$dir/" 2>/dev/null; } \
        && cp "$archive" "$dest/" 2>/dev/null \
        && cp "$extracted/environment.txt" "$dir/" 2>/dev/null
    then
        return 0
    fi
    rm -f "$dir/environment.txt" 2>/dev/null || true
    return 1
}

if deliver "$OUT"; then
    out_dir="$OUT/macos-$version"
    out_archive="$OUT/$(basename "$archive")"
    on_share=1
else
    fallback="$HOME/Desktop/bluebubbles-headers"
    warn "could not write into the shared folder at"
    warn "  $OUT"
    warn "The dump itself is fine; only the delivery failed. Writing it to the Desktop"
    warn "instead, to be copied across by hand."
    deliver "$fallback" || die "could not write to $fallback either. The dump is complete
       but there is nowhere to put it. Free some space, or copy it out of $extracted
       before this shell exits: that directory is deleted on exit."
    out_dir="$fallback/macos-$version"
    out_archive="$fallback/$(basename "$archive")"
    on_share=0
fi

printf '\n' >&2
if [ "$count" = "$expected_headers" ]; then
    ok "$count headers, one per class in hosts.conf. $missing absent on this release."
else
    warn "$count headers, but hosts.conf names $expected_headers classes."
    warn "A class named twice in hosts.conf explains a small shortfall; anything larger"
    warn "means groups were skipped, and the dump is not complete."
fi
printf '\n' >&2
printf '  %s\n' "$out_dir" >&2
printf '  %s\n' "$out_archive" >&2
printf '\n' >&2
if [ "$on_share" = 1 ]; then
    printf '%sBoth are in the shared folder. On the host:%s\n' "$dim" "$off" >&2
    printf '%s  Tools/private-api/import-dump.sh%s\n' "$dim" "$off" >&2
else
    printf '%sNeither is in the shared folder. Copy the directory across yourself, then%s\n' "$dim" "$off" >&2
    printf '%son the host:  Tools/private-api/import-dump.sh PATH%s\n' "$dim" "$off" >&2
fi
