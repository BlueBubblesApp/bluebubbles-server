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
# distribution and takes minutes; this one is single-architecture, unsigned beyond ad-hoc, and
# is only good for running on this machine.
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
if [ "$BUILD" -eq 1 ]; then
    echo "==> Building"
    swift build
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

# Same nested-bundle layout the release uses, so a path that works here works there.
#
# This build is ad-hoc signed with NO entitlements, so the CLI cannot reach the
# data-protection keychain either way: `Packaging/sign-app.sh` is what makes that work. The
# layout is mirrored anyway: a dev bundle that put the binary somewhere else would mean every
# path in the docs, the launch-agent plist and any script is only correct for one of the two.
if [ -f "$BIN_PATH/bluebubbles-server" ]; then
    CLI_APP="$APP/Contents/Helpers/bluebubbles-server.app"
    mkdir -p "$CLI_APP/Contents/MacOS"
    cp "$BIN_PATH/bluebubbles-server" "$CLI_APP/Contents/MacOS/bluebubbles-server"
    chmod +x "$CLI_APP/Contents/MacOS/bluebubbles-server"
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
# Built HERE, and for a DIFFERENT architecture from everything above.
#
# **A helper is loaded into somebody else's process, so it must carry the slice THAT process
# runs.** On Apple Silicon, Messages.app and FaceTime.app run `arm64e`, and dyld will not load
# an `arm64` dylib into an `arm64e` process: it skips the insert without reporting anything.
# A plain `swift build` produces `arm64`, so a dev bundle assembled from it had a helper that
# could never load: the server came up, the injector reported the mismatch, and the Private API
# was permanently unavailable in exactly the configuration a contributor develops in.
#
# Single-slice on purpose: this bundle only ever runs on this Mac. `Packaging/build-app.sh`
# builds the released pair `arm64e + x86_64`.
case "$(uname -m)" in
    arm64)  HELPER_ARCH="arm64e" ;;
    x86_64) HELPER_ARCH="x86_64" ;;
    *)      echo "error: unsupported host architecture $(uname -m)" >&2; exit 1 ;;
esac

echo "==> Building the injected helpers for $HELPER_ARCH (the slice Messages runs)"
# One `--product` per invocation: `swift build` honours only the last one and drops the rest.
for product in BlueBubblesHelper BlueBubblesFaceTimeHelper; do
    swift build --arch "$HELPER_ARCH" --product "$product" >/dev/null
done
HELPER_BIN="$(swift build --arch "$HELPER_ARCH" --show-bin-path)"

mkdir -p "$APP/Contents/Frameworks"
# BOTH of them. Only the Messages helper used to be copied, so `Contents/Frameworks/` never
# held `libBlueBubblesFaceTimeHelper.dylib`, which `PrivateAPIGatedService` looks for there
# by name, leaving every FaceTime route unavailable.
for helper in libBlueBubblesHelper libBlueBubblesFaceTimeHelper; do
    built="$HELPER_BIN/$helper.dylib"
    if [ ! -f "$built" ]; then
        echo "error: $built was not produced." >&2
        exit 1
    fi
    # Asserted rather than assumed: a mismatched insert is declined SILENTLY, so the symptom
    # is "the Private API does nothing" with nothing on screen connecting it to a build flag.
    ARCHS="$(lipo -archs "$built")"
    case " $ARCHS " in
        *" $HELPER_ARCH "*) ;;
        *)
            echo "error: $helper.dylib is $ARCHS but Messages runs $HELPER_ARCH." >&2
            exit 1
            ;;
    esac
    cp "$built" "$APP/Contents/Frameworks/"
    echo "==> Bundled $helper.dylib ($ARCHS)"
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
    BUNDLE_COUNT=$((BUNDLE_COUNT + 1))
done
if [ "$BUNDLE_COUNT" -eq 0 ]; then
    echo "error: no resource bundles were copied; the app would abort at runtime." >&2
    exit 1
fi
echo "==> Copied $BUNDLE_COUNT resource bundle(s)"

VERSION="$(tr -d '[:space:]' < Packaging/VERSION)"
sed -e "s|__VERSION__|$VERSION|g" \
    -e "s|__BUILD__|0|g" \
    -e "s|__SPARKLE_PUBLIC_KEY__||g" \
    Packaging/Info.plist > "$APP/Contents/Info.plist"

# Ad-hoc signed, and this is not optional, but understand what it does and does not buy.
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
# To stop it happening on every rebuild, sign with a STABLE identity instead. Make a
# self-signed code-signing certificate once (Keychain Access › Certificate Assistant › Create
# a Certificate, type "Code Signing", self-signed), trust it, then:
#
#     DEV_SIGNING_IDENTITY="My Dev Cert" Tools/dev-bundle.sh
#
# The certificate satisfies the recorded requirement across rebuilds, so the grant sticks.
#
# None of this affects releases: `Packaging/sign-app.sh` signs with a Developer ID
# certificate, whose requirement is stable, so a real user's grant survives app updates.
SIGNING_IDENTITY="${DEV_SIGNING_IDENTITY:--}"
echo "==> Signing with identity: $SIGNING_IDENTITY"
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP" 2>&1 | sed 's/^/    /'

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
