#!/bin/bash
#
# Builds BlueBubbles.app as a universal binary.
#
# The app bundle exists even though the server is usable headless, and that is not
# ceremony: several macOS APIs the server depends on refuse to work outside a bundle.
# UNUserNotificationCenter.current() TERMINATES the process when Bundle.main has no
# identifier — not an exception, an abort — which is how the first real boot of this server
# died. TCC also keys permission grants on the bundle identifier, so Full Disk Access,
# Automation and Contacts are grantable only to a bundle.
#
# Phase 10's SwiftUI app becomes the CFBundleExecutable and this script stops changing.
#
# Usage:
#   Packaging/build-app.sh [--output DIR] [--configuration release]

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

OUTPUT="$ROOT/.build/package"
CONFIGURATION="release"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --output) OUTPUT="$2"; shift 2 ;;
        --configuration) CONFIGURATION="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

VERSION="$(tr -d '[:space:]' < Packaging/VERSION)"
# A monotonic build number from the commit count. Sparkle compares CFBundleVersion, and it
# must never go backwards — a date would, across a rebuild of an older tag.
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

APP="$OUTPUT/BlueBubbles.app"
echo "==> BlueBubbles $VERSION (build $BUILD), $CONFIGURATION"

# --- Universal binary ---------------------------------------------------------------------
#
# Both slices in one invocation. SwiftPM produces the lipo'd binary itself, which is more
# reliable than building twice and merging by hand — the two builds can otherwise disagree
# about a conditionally-compiled symbol and fail at link time rather than here.
echo "==> Building arm64 + x86_64"
# The SwiftUI app is what the bundle runs. The `bluebubbles-server` CLI is built too and
# placed alongside it, because a genuinely headless install should not need a WindowServer
# connection at all — see BlueBubblesApp.swift on why both exist.
# Both products in one invocation, and note that `swift build` accepts only ONE `--product`
# — passing two silently builds just one of them, which showed up here as lipo failing on a
# binary that was never produced. Building everything is also what the release needs anyway,
# since the helper dylib goes into the bundle too.
swift build \
    --configuration "$CONFIGURATION" \
    --arch arm64 --arch x86_64

BIN_PATH="$(swift build --configuration "$CONFIGURATION" --arch arm64 --arch x86_64 --show-bin-path)"
BINARY="$BIN_PATH/BlueBubblesApp"

# Asserted rather than assumed. A single-architecture build looks completely normal until an
# Intel user downloads it and it will not launch at all.
ARCHS="$(lipo -archs "$BINARY")"
echo "==> Architectures: $ARCHS"
for required in arm64 x86_64; do
    case " $ARCHS " in
        *" $required "*) ;;
        *) echo "error: the binary is missing the $required slice (got: $ARCHS)" >&2; exit 1 ;;
    esac
done

# --- Bundle -------------------------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/BlueBubbles"
chmod +x "$APP/Contents/MacOS/BlueBubbles"

# The headless CLI, inside the bundle so it is covered by the same signature and
# notarization ticket. A launch agent points at this rather than at the app.
if [ -f "$BIN_PATH/bluebubbles-server" ]; then
    cp "$BIN_PATH/bluebubbles-server" "$APP/Contents/MacOS/bluebubbles-server"
    chmod +x "$APP/Contents/MacOS/bluebubbles-server"
fi

# The injected helper travels inside the bundle so its path is stable and inside the signed,
# notarized container. A helper sitting loose in a temp directory is one a user can replace.
HELPER="$BIN_PATH/libBlueBubblesHelper.dylib"
if [ -f "$HELPER" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp "$HELPER" "$APP/Contents/Frameworks/"
    echo "==> Bundled the Private API helper"
else
    echo "==> note: no helper dylib built; the Private API will be unavailable in this build"
fi

# --- SwiftPM resource bundles ---------------------------------------------------------------
#
# Dependencies that ship resources build a `*.bundle` alongside the binary, and they find it
# through `Bundle.main.resourceURL` at RUNTIME. Copying the executable alone produces an app
# that starts, serves requests, and then dies the first time one of them is needed:
# PhoneNumberKit calls `fatalError("unable to find bundle")`, which is not catchable.
#
# That is exactly what happened here — the server came up, bound its port, logged "Server
# started", and then aborted on the first address it tried to format.
# Test bundles are EXCLUDED. `swift build` produces one per test target that has resources,
# and they sit in the same directory as the real ones — so a naive copy ships the conformance
# fixtures and the recorded protocol vectors inside the released app. Small, but it is test
# data in a user-facing artifact, and the recording tooling writes captures from a live
# server into exactly that directory.
BUNDLE_COUNT=0
for resource in "$BIN_PATH"/*.bundle; do
    [ -e "$resource" ] || continue
    case "$(basename "$resource")" in
        *Tests.bundle)
            echo "==> Skipping test bundle $(basename "$resource")"
            continue
            ;;
    esac
    cp -R "$resource" "$APP/Contents/Resources/"
    BUNDLE_COUNT=$((BUNDLE_COUNT + 1))
done
echo "==> Copied $BUNDLE_COUNT resource bundle(s)"

# Asserted, not assumed. A dependency that gains resources later would otherwise reintroduce
# the same crash silently, and it only shows up at runtime on a specific code path.
if [ "$BUNDLE_COUNT" -eq 0 ]; then
    echo "error: no resource bundles were copied. PhoneNumberKit ships one and the app" >&2
    echo "error: aborts without it — check whether the build actually produced them." >&2
    exit 1
fi

sed -e "s|__VERSION__|$VERSION|g" \
    -e "s|__BUILD__|$BUILD|g" \
    -e "s|__SPARKLE_PUBLIC_KEY__|$SPARKLE_PUBLIC_KEY|g" \
    Packaging/Info.plist > "$APP/Contents/Info.plist"

if [ -z "$SPARKLE_PUBLIC_KEY" ]; then
    echo "==> note: SPARKLE_PUBLIC_KEY is unset; this build cannot verify auto-updates"
fi

ICON_SOURCE="$ROOT/../icons/macos/dock-icon.png"
if [ -f "$ICON_SOURCE" ]; then
    ICONSET="$OUTPUT/AppIcon.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    # Every size Finder, the Dock and Spotlight ask for. A bundle missing one falls back to
    # a scaled version of another, which looks visibly wrong at small sizes.
    for size in 16 32 128 256 512; do
        sips -z $size $size "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
        sips -z $((size * 2)) $((size * 2)) "$ICON_SOURCE" \
            --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || \
        echo "==> note: icon conversion failed; the bundle will use the generic icon"
    rm -rf "$ICONSET"
fi

# Proves the plist is well-formed and carries the version we intended. A malformed Info.plist
# produces an app that will not launch, with no useful message.
BUNDLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ "$BUNDLED_VERSION" != "$VERSION" ]; then
    echo "error: the bundle reports $BUNDLED_VERSION but Packaging/VERSION says $VERSION" >&2
    exit 1
fi

echo "==> Built $APP"
