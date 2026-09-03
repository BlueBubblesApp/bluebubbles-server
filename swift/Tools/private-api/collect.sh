#!/bin/bash
#  collect.sh
#  One command for someone helping out from a macOS release we do not have.
#
#  Dumps the headers, writes down what this Mac is, and leaves a .tar.gz to send back.
#
#  WHAT GOES IN THE ARCHIVE — the whole list, so nobody has to take it on trust:
#     * Objective-C class, method, property and protocol NAMES from Apple's frameworks
#     * the macOS version, build, CPU architecture and Xcode version
#     * for each host app: its version, and whether it is a Catalyst or native binary
#
#  WHAT DOES NOT: nothing from your home directory. No messages, no contacts, no
#  attachments, no location, no account identifiers, no file contents of any kind. These
#  tools never open the Messages database. Read environment.txt before you send it — it is
#  plain text, and it is the only file here that is about your machine rather than Apple's.
#
#  Usage:
#     ./collect.sh                  dump everything, archive it
#     ./collect.sh --out DIR        put the archive somewhere specific
#     ./collect.sh --keep           leave the dumped headers in place as well

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

destination="$HOME/Desktop"
keep=0

while [ $# -gt 0 ]; do
    case "$1" in
        --out) destination="${2:?--out needs a directory}"; shift 2 ;;
        --keep) keep=1; shift ;;
        -h|--help) sed -n '2,23p' "$0" | sed 's|^#[ ]\{0,2\}||'; exit 0 ;;
        *) pa_die "unknown option $1 (try --help)" ;;
    esac
done

pa_require_supported_macos

version="$(pa_macos_version)"
label="macos-$version-$(pa_arch)"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
headers="$staging/$label"

pa_step "Dumping headers for macOS $version ($(pa_arch))"
"$PA_TOOLS_DIR/dump-headers.sh" --quiet --out "$headers"

xcode_version="$(xcodebuild -version 2>/dev/null | sed -n 1p || true)"
clang_version="$(clang --version 2>/dev/null | sed -n 1p || true)"
hardware="$(sysctl -n machdep.cpu.brand_string 2>/dev/null | sed -n 1p || true)"

{
    echo "# Collected by Tools/private-api/collect.sh"
    echo
    echo "macos_version   $(pa_macos_version)"
    echo "macos_build     $(pa_macos_build)"
    echo "architecture    $(pa_arch)"
    echo "hardware        ${hardware:-unknown}"
    # `cmd | head -1` under `set -o pipefail` reports FAILURE whenever head exits first and
    # the writer takes a SIGPIPE for it — which is a race, so `|| echo ...` fired sometimes
    # and appended a second line to a one-line field. Take the first line, then decide.
    echo "xcode           ${xcode_version:-command line tools only}"
    echo "clang           ${clang_version:-unknown}"
    echo "sdk             $(pa_sdk_path)"
    echo
    echo "# Host apps. 'platform' is what decides which copy of a shared framework the"
    echo "# dumper sees, so it is the single most useful line in this file."
    printf "# %-20s %-10s %-10s %s\n" "bundle-id" "installed" "platform" "version"
    seen=""
    while IFS=$'\t' read -r _group directive value; do
        [ "$directive" = "app" ] || continue
        case " $seen " in *" $value "*) continue ;; esac
        seen="${seen:-} $value"
        app="$(pa_app_path "$value")"
        if [ -n "$app" ]; then
            app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
                "$app/Contents/Info.plist" 2>/dev/null || echo '?')"
            printf "app %-22s %-10s %-10s %s\n" \
                "$value" "yes" "$(pa_app_platform "$app")" "$app_version"
        else
            printf "app %-22s %-10s %-10s %s\n" "$value" "no" "-" "-"
        fi
    done < <(pa_parse_manifest "$PA_TOOLS_DIR/hosts.conf")
    echo
    echo "# Classes reported NOT PRESENT on this release. This list is the point of the"
    echo "# whole exercise: it is what this macOS does not have that ours does."
    grep -l "is NOT PRESENT" "$headers"/*.h 2>/dev/null \
        | sed 's|.*/|missing |;s|\.h$||' || echo "missing (none)"
} > "$headers/environment.txt"

pa_step "Writing environment.txt"

mkdir -p "$destination"
archive="$destination/bluebubbles-headers-$label.tar.gz"
tar -czf "$archive" -C "$staging" "$label"

if [ "$keep" = 1 ]; then
    kept="$PA_ROOT/docs/headers/macos-$version"
    mkdir -p "$kept"
    cp "$headers"/*.h "$headers/environment.txt" "$kept"/
    pa_info "Headers also written to $kept"
fi

pa_info ""
pa_info "Done. $(ls "$headers" | grep -c '\.h$') headers, $(du -h "$archive" | cut -f1)."
pa_info ""
pa_info "  $archive"
pa_info ""
pa_info "Have a look inside before sending it — it is all plain text:"
pa_info "  tar -tzf \"$archive\"                 # list what is in it"
pa_info "  tar -xzf \"$archive\" -C /tmp && less /tmp/$label/environment.txt"
