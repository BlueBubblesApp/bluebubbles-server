#!/bin/bash
#
# Assembles a throwaway BlueBubbles.app from the CURRENT debug build, for testing anything
# that needs a real app bundle.
#
# Why this exists: **TCC keys permission grants on a bundle identifier and a code signature.**
# A bare `swift run` binary has neither, so macOS has nothing to attribute a grant to: it
# never prompts, `CNContactStore.authorizationStatus` answers `.denied`, and the Permissions
# page reports a denial that no amount of clicking in System Settings can fix. Contacts, Full
# Disk Access, Automation and notifications are all only testable from a bundle.
#
# This is NOT `Packaging/build-app.sh`. That one builds a universal release bundle for
# distribution and takes minutes; this one is single-architecture and is only good for running
# on this machine. It IS signed the way a release is, through the same `bb_sign_app`
# (Tools/app-signing.sh): hardened runtime, the entitlements, inside-out, and the provisioning
# profile when the identity can carry it. See the signing step below.
#
# IT BUILDS THE APP FIRST, and it did not always. It used to assemble the bundle from whatever
# `swift build` had last produced, so the ordinary loop -- edit, re-run this, look at the
# app -- showed you the PREVIOUS build with nothing saying so. That is close to undetectable:
# the script still compiles the arm64e helpers below, so it churns through a build and prints
# "Built" while quietly copying a stale binary. `--no-build` restores the old behaviour for
# the rare case where bundling a specific earlier build is the point.
#
# It uses the SHIPPING bundle identifier deliberately, because TCC grants follow the
# identifier: a dev bundle under its own identifier would be a separate app as far as macOS is
# concerned, and granting it would prove nothing about the real one. The consequence is worth
# knowing: permissions granted to this bundle are granted to anything else carrying that
# identifier, including an installed Electron BlueBubbles.
#
# Usage:
#   Tools/dev-bundle.sh [--output DIR] [--run] [--no-build]

set -euo pipefail

# `.env` from the CURRENT DIRECTORY, before the `cd` below: the file is chosen by
# where you stand, not by where this script lives or where it is about to go. A
# name already in the environment wins, so a `VAR=… ` prefix still overrides the
# file. See Tools/dotenv.sh.
source "$(cd "$(dirname "$0")" && pwd)/dotenv.sh"
bb_load_dotenv
# The SDK stamp `swift build` writes is wrong on Xcode 27; see Tools/sdk-stamp.sh.
source "$(cd "$(dirname "$0")" && pwd)/sdk-stamp.sh"
# The second build for the injected helpers, and its slice check; see Tools/helper-build.sh.
source "$(cd "$(dirname "$0")" && pwd)/helper-build.sh"
# The release's signing, shared; see Tools/app-signing.sh.
source "$(cd "$(dirname "$0")" && pwd)/app-signing.sh"

cd "$(dirname "$0")/.."
ROOT="$PWD"

OUTPUT="$ROOT/.build/dev"
RUN=0
BUILD=1

while [ $# -gt 0 ]; do
    case "$1" in
        --output) OUTPUT="$2"; shift 2 ;;
        --run) RUN=1; shift ;;
        --no-build) BUILD=0; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

APP="$OUTPUT/BlueBubbles.app"

# The app, BEFORE anything is copied. `swift build --show-bin-path` below only PRINTS a path;
# it compiles nothing, whatever is pending. That is what made the stale-bundle failure so
# quiet, and it is why this builds rather than checking for staleness: being told to run a
# command is worse than the command having been run.
bb_sdk_stamp_flags
if [ "$BUILD" -eq 1 ]; then
    echo "==> Building"
    swift build "${BB_SDK_STAMP_FLAGS[@]}"
fi

BIN_PATH="$(swift build --show-bin-path)"
BINARY="$BIN_PATH/BlueBubblesApp"

if [ ! -f "$BINARY" ]; then
    echo "error: $BINARY does not exist. Run 'swift build' first." >&2
    exit 1
fi

echo "==> Assembling $APP from $BIN_PATH"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/BlueBubbles"
chmod +x "$APP/Contents/MacOS/BlueBubbles"
bb_assert_sdk_stamp "$APP/Contents/MacOS/BlueBubbles"

# Same nested-bundle layout the release uses, so a path that works here works there.
#
# The nested bundle is what lets the CLI carry its own `embedded.provisionprofile`, so it
# reaches the data-protection keychain when the signing below can claim
# `keychain-access-groups`. The layout would be mirrored even if it could not: a dev bundle
# that put the binary somewhere else would mean every path in the docs, the launch-agent
# plist and any script is only correct for one of the two.
if [ -f "$BIN_PATH/bluebubbles-server" ]; then
    CLI_APP="$APP/Contents/Helpers/bluebubbles-server.app"
    mkdir -p "$CLI_APP/Contents/MacOS"
    cp "$BIN_PATH/bluebubbles-server" "$CLI_APP/Contents/MacOS/bluebubbles-server"
    chmod +x "$CLI_APP/Contents/MacOS/bluebubbles-server"
    bb_assert_sdk_stamp "$CLI_APP/Contents/MacOS/bluebubbles-server"
    cat > "$CLI_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.BlueBubbles.BlueBubbles-Server.cli</string>
    <key>CFBundleExecutable</key>
    <string>bluebubbles-server</string>
    <key>CFBundleName</key>
    <string>BlueBubbles Server</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSBackgroundOnly</key>
    <true/>
</dict>
</plist>
PLIST
fi

# The launcher, in the same place the release puts it, so `SMAppService.loginItem` can find it
# and the login-item path is exercisable here rather than only in a signed release.
if [ -f "$BIN_PATH/BlueBubblesLauncher" ]; then
    LAUNCHER_APP="$APP/Contents/Library/LoginItems/BlueBubblesLauncher.app"
    mkdir -p "$LAUNCHER_APP/Contents/MacOS"
    cp "$BIN_PATH/BlueBubblesLauncher" "$LAUNCHER_APP/Contents/MacOS/BlueBubblesLauncher"
    chmod +x "$LAUNCHER_APP/Contents/MacOS/BlueBubblesLauncher"
    bb_assert_sdk_stamp "$LAUNCHER_APP/Contents/MacOS/BlueBubblesLauncher"
    cat > "$LAUNCHER_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.BlueBubbles.BlueBubbles-Server.Launcher</string>
    <key>CFBundleExecutable</key>
    <string>BlueBubblesLauncher</string>
    <key>CFBundleName</key>
    <string>BlueBubbles</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST
fi

# --- The injected helpers -------------------------------------------------------------------
#
# Built HERE, and for a DIFFERENT architecture from everything above: a helper must carry the
# slice of the app it is injected INTO, and on Apple Silicon that is `arm64e`, which a plain
# `swift build` never produces. A dev bundle assembled from the ordinary build output has a
# helper dyld declines without a word, so the Private API is permanently absent in exactly the
# configuration a contributor develops in. `bb_build_injected` asserts the slice with `lipo`;
# the reasoning is in Tools/helper-build.sh.
#
# Single-slice on purpose (`--slices host`): this bundle only ever runs on this Mac.
# `Packaging/build-app.sh` builds the released pair `arm64e + x86_64`.
bb_build_injected --slices host --quiet -- "${BB_SDK_STAMP_FLAGS[@]}"

mkdir -p "$APP/Contents/Frameworks"
# Both of them; see BB_HELPER_PRODUCTS.
for built in "${BB_INJECTED_DYLIBS[@]}"; do
    cp "$built" "$APP/Contents/Frameworks/"
    bb_assert_sdk_stamp "$APP/Contents/Frameworks/$(basename "$built")"
    echo "==> Bundled $(basename "$built") ($BB_INJECTED_SLICES)"
done

# Sparkle, from beside the binary, for the same reason `build-app.sh` gives. A dev bundle
# never starts the updater (its `SUPublicEDKey` is blank; see `UpdaterPolicy`), but the app
# links the framework and will not load without it.
SPARKLE="$BIN_PATH/Sparkle.framework"
[ -d "$SPARKLE" ] || { echo "error: no Sparkle.framework at $SPARKLE; run 'swift build' first." >&2; exit 1; }
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
cp -R "$SPARKLE" "$APP/Contents/Frameworks/"
echo "==> Bundled Sparkle.framework"

# Dependencies find these through `Bundle.main.resourceURL` at runtime, so an app assembled
# without them starts, serves requests, and then aborts on the first address it formats:
# PhoneNumberKit calls `fatalError("unable to find bundle")`, which is not catchable.
# Test bundles are excluded: they carry recorded fixtures and have no business in an app.
BUNDLE_COUNT=0
for resource in "$BIN_PATH"/*.bundle; do
    [ -e "$resource" ] || continue
    case "$(basename "$resource")" in
        *Tests.bundle) continue ;;
    esac
    cp -R "$resource" "$APP/Contents/Resources/"
    # The nested CLI is a bundle of its own: `Bundle.main` there is
    # `Helpers/bluebubbles-server.app`, so it looks in ITS Resources and never in the app's.
    # Without its own copy, the headless binary CONTRIBUTING.md documents started, served,
    # and aborted on the first phone number it parsed. The app's UI bundle is not its business.
    if [ -n "${CLI_APP:-}" ] && [ "$(basename "$resource")" != "BlueBubbles_BlueBubblesApp.bundle" ]; then
        mkdir -p "$CLI_APP/Contents/Resources"
        cp -R "$resource" "$CLI_APP/Contents/Resources/"
    fi
    BUNDLE_COUNT=$((BUNDLE_COUNT + 1))
done
if [ "$BUNDLE_COUNT" -eq 0 ]; then
    echo "error: no resource bundles were copied; the app would abort at runtime." >&2
    exit 1
fi
if [ -n "${CLI_APP:-}" ] && [ ! -d "$CLI_APP/Contents/Resources/PhoneNumberKit_PhoneNumberKit.bundle" ]; then
    echo "error: the CLI bundle has no PhoneNumberKit resources; it would abort at runtime." >&2
    exit 1
fi
echo "==> Copied $BUNDLE_COUNT resource bundle(s)"

VERSION="$(tr -d '[:space:]' < Packaging/VERSION)"
sed -e "s|__VERSION__|$VERSION|g" \
    -e "s|__BUILD__|0|g" \
    -e "s|__SPARKLE_PUBLIC_KEY__||g" \
    Packaging/Info.plist > "$APP/Contents/Info.plist"

# Signed the way a release is, and this is not optional, but understand what it does and does
# not buy.
#
# The SIGNATURE is the release's: `bb_sign_app` is the function `Packaging/sign-app.sh` calls,
# with the hardened runtime, the entitlements on the same items and the same inside-out order,
# so a dev bundle exercises what a user's copy does rather than a `--deep` approximation of it.
# Two differences, both forced: no secure timestamp (it needs Apple's server and only
# notarization reads it), and `keychain-access-groups` only when the identity can carry it.
# Ad-hoc, or any identity outside the provisioning profile's team, cannot: claiming that
# restricted entitlement without a profile that authorises it gets the process killed at
# launch, so it is dropped from a copy of the entitlements and secrets use the legacy keychain.
# The script says which it did.
#
# TCC records a grant as (bundle identifier, code requirement). An UNSIGNED bundle cannot be
# granted anything durable at all. An AD-HOC signed one can be granted, and then loses the
# grant on the next rebuild: ad-hoc signing has no stable certificate, so the recorded
# requirement pins the exact binary and a rebuilt one no longer satisfies it. The symptom is
# confusing enough to be worth naming: `TCC.db` still says `auth_value = 2` (allowed) while
# `CNContactStore.authorizationStatus` answers `.denied`, and System Settings still lists the
# app with its switch on.
#
# When that happens, clear the recorded decision and grant it once more:
#
#     tccutil reset AddressBook com.BlueBubbles.BlueBubbles-Server
#     open .build/dev/BlueBubbles.app
#
# To stop it happening on every rebuild, sign with a STABLE identity instead: a Developer ID
# certificate, or a self-signed code-signing certificate made once (Keychain Access ›
# Certificate Assistant › Create a Certificate, type "Code Signing", self-signed) and trusted:
#
#     DEV_SIGNING_IDENTITY="My Dev Cert" Tools/dev-bundle.sh
#
# The certificate satisfies the recorded requirement across rebuilds, so the grant sticks. A
# Developer ID identity named as "Name (TEAMID)", from the profile's team, also gets the
# data-protection keychain, which makes the SIGNATURE the release's in every respect but the
# timestamp.
SIGNING_IDENTITY="${DEV_SIGNING_IDENTITY:--}"
echo "==> Signing with identity: $SIGNING_IDENTITY"
bb_sign_app --app "$APP" --identity "$SIGNING_IDENTITY" --purpose development

echo "==> Built $APP"
echo
echo "    Permissions are granted to bundle id:"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" | sed 's/^/      /'
echo
echo "    If macOS does not prompt, or reports denied after a rebuild, clear the recorded"
echo "    decision and launch again:"
echo "      tccutil reset AddressBook com.BlueBubbles.BlueBubbles-Server"
echo "      open $APP"
echo
echo "    Launch with 'open', not by running the binary from a shell: TCC attributes a"
echo "    shell-spawned process to the TERMINAL, so it never sees this bundle's grant."

if [ "$RUN" -eq 1 ]; then
    # Refuse rather than launch into a copy that is already running.
    #
    # `open` reports success once LaunchServices has started the process. The second instance
    # then exits on the single-instance lock with a message on ITS stdout, which `open`
    # discards, so the visible result of `--run` against a running server was nothing at all:
    # the old window stayed up, looking like a build that had not taken.
    #
    # The LOCK is tested, not the pid file, because that is what the server does: an `flock`
    # is released by the kernel when the holder dies, so a pid left in the file may name a
    # process that is gone or an id since recycled. The pid is read only to NAME the holder,
    # exactly as `SingleInstanceLock.AlreadyRunning` uses it.
    LOCK="$HOME/Library/Application Support/BlueBubbles/bluebubbles-server.lock"
    LOCK_HELD=0
    if [ -e "$LOCK" ]; then
        if ! python3 - "$LOCK" <<'LOCKPROBE'
import fcntl, sys

try:
    handle = open(sys.argv[1], "r+")
except OSError:
    # Cannot even open it. Not this script's business to guess; let the launch proceed and
    # let the server report whatever is really wrong.
    sys.exit(0)

try:
    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)

# Taken, which means nobody else holds it. Released immediately: holding it here would keep
# the server we are about to launch out.
fcntl.flock(handle, fcntl.LOCK_UN)
sys.exit(0)
LOCKPROBE
        then
            LOCK_HELD=1
        fi
    fi
    if [ "$LOCK_HELD" -eq 1 ]; then
        HOLDER="$(tr -d '[:space:]' < "$LOCK" 2>/dev/null || true)"
        WHO="another process"
        [ -n "$HOLDER" ] && WHO="process $HOLDER"
        echo "error: BlueBubbles Server is already running ($WHO), so it was not launched." >&2
        echo "       Two copies fight over the Private API socket; see SingleInstanceLock." >&2
        echo >&2
        echo "       The bundle IS built and up to date. Quit the running copy, then:" >&2
        echo "         open $APP" >&2
        exit 1
    fi
    echo "==> Launching"
    open "$APP"
fi
