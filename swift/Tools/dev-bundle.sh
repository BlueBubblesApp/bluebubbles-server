#!/bin/bash
#
# Assembles a throwaway BlueBubbles.app from the CURRENT debug build, for testing anything
# that needs a real app bundle.
#
# Why this exists: **TCC keys permission grants on a bundle identifier and a code signature.**
# A bare `swift run` binary has neither, so macOS has nothing to attribute a grant to — it
# never prompts, `CNContactStore.authorizationStatus` answers `.denied`, and the Permissions
# page reports a denial that no amount of clicking in System Settings can fix. Contacts, Full
# Disk Access, Automation and notifications are all only testable from a bundle.
#
# This is NOT `Packaging/build-app.sh`. That one builds a universal release bundle for
# distribution and takes minutes; this reuses whatever `swift build` last produced, is
# single-architecture, unsigned beyond ad-hoc, and is only good for running on this machine.
#
# It uses the SHIPPING bundle identifier deliberately, because TCC grants follow the
# identifier: a dev bundle under its own identifier would be a separate app as far as macOS is
# concerned, and granting it would prove nothing about the real one. The consequence is worth
# knowing — permissions granted to this bundle are granted to anything else carrying that
# identifier, including an installed Electron BlueBubbles.
#
# Usage:
#   Tools/dev-bundle.sh [--output DIR] [--run]

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

OUTPUT="$ROOT/.build/dev"
RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --output) OUTPUT="$2"; shift 2 ;;
        --run) RUN=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

APP="$OUTPUT/BlueBubbles.app"
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
# data-protection keychain either way — `Packaging/sign-app.sh` is what makes that work. The
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

if [ -f "$BIN_PATH/libBlueBubblesHelper.dylib" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp "$BIN_PATH/libBlueBubblesHelper.dylib" "$APP/Contents/Frameworks/"
fi

# Dependencies find these through `Bundle.main.resourceURL` at runtime, so an app assembled
# without them starts, serves requests, and then aborts on the first address it formats —
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

# Ad-hoc signed, and this is not optional — but understand what it does and does not buy.
#
# TCC records a grant as (bundle identifier, code requirement). An UNSIGNED bundle cannot be
# granted anything durable at all. An AD-HOC signed one can be granted, and then loses the
# grant on the next rebuild: ad-hoc signing has no stable certificate, so the recorded
# requirement pins the exact binary and a rebuilt one no longer satisfies it. The symptom is
# confusing enough to be worth naming — `TCC.db` still says `auth_value = 2` (allowed) while
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
    echo "==> Launching"
    open "$APP"
fi
