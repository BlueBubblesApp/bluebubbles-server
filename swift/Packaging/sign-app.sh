#!/bin/bash
#
# Signs BlueBubbles.app with the hardened runtime and the entitlements.
#
# Order matters and is the usual source of trouble: nested code must be signed BEFORE the
# bundle that contains it. Signing outside-in produces a bundle whose own signature is
# invalidated the moment an inner item is signed afterwards, and the failure surfaces only at
# notarization or, worse, on a user's machine as a damaged app.
#
# Usage:
#   Packaging/sign-app.sh --app PATH --identity "Developer ID Application: ... (TEAMID)"

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

APP=""
IDENTITY="${SIGNING_IDENTITY:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --identity) IDENTITY="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$APP" ] || { echo "error: --app is required" >&2; exit 2; }
[ -d "$APP" ] || { echo "error: no bundle at $APP" >&2; exit 1; }
[ -n "$IDENTITY" ] || { echo "error: --identity or SIGNING_IDENTITY is required" >&2; exit 2; }

ENTITLEMENTS="$ROOT/Packaging/BlueBubbles.entitlements"

echo "==> Signing nested code"
# Inside-out. `find -depth` visits children before their parents, which is exactly the order
# codesign needs.
find "$APP/Contents/Frameworks" -depth -type f \( -name '*.dylib' -o -name '*.framework' \) 2>/dev/null | while read -r item; do
    echo "    $item"
    codesign --force --timestamp --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$IDENTITY" "$item"
done

# Mach-O executables sitting NEXT to the main one in Contents/MacOS.
#
# `codesign` on a bundle signs CFBundleExecutable and treats everything else in MacOS as a
# resource, so the headless `bluebubbles-server` binary was covered by the bundle seal but
# never signed itself. `--deep --strict` catches it and notarization rejects it — which is
# exactly the failure the comment above says signing outside-in produces, in a directory the
# original loop did not look at.
MAIN_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
echo "==> Signing side-by-side executables"
for item in "$APP/Contents/MacOS/"*; do
    [ -f "$item" ] || continue
    [ "$(basename "$item")" != "$MAIN_EXECUTABLE" ] || continue
    file "$item" | grep -q 'Mach-O' || continue
    echo "    $item"
    codesign --force --timestamp --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$IDENTITY" "$item"
done

echo "==> Signing the bundle"
codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"

echo "==> Verifying"
# --strict --deep catches an unsigned nested item that the top-level signature would
# otherwise hide until notarization rejects it.
codesign --verify --deep --strict --verbose=2 "$APP"

# What Gatekeeper will actually do. `spctl` is the closest local approximation to a user's
# first launch, and it fails here rather than on their machine.
echo "==> Gatekeeper assessment"
if ! spctl --assess --type execute --verbose=4 "$APP" 2>&1; then
    echo "==> note: spctl rejected the bundle. Before notarization this is EXPECTED —"
    echo "==> Gatekeeper accepts a Developer ID app only once its notarization ticket exists."
fi

# The entitlements that actually made it in, printed so a mismatch is visible in the log
# rather than discovered when injection silently stops working.
echo "==> Entitlements on the signed bundle"
codesign --display --entitlements - --xml "$APP" 2>/dev/null | \
    plutil -convert xml1 -o - - 2>/dev/null || true

if ! codesign --display --entitlements - --xml "$APP" 2>/dev/null | \
     plutil -convert xml1 -o - - 2>/dev/null | \
     grep -q "com.apple.security.cs.disable-library-validation"; then
    echo "error: disable-library-validation is missing from the signed bundle." >&2
    echo "error: the Private API helper cannot be injected without it, and dyld reports" >&2
    echo "error: nothing when it declines — Messages simply starts without the helper." >&2
    exit 1
fi

echo "==> Signed $APP"
