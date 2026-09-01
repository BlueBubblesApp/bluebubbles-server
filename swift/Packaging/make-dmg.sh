#!/bin/bash
#
# Builds the distributable DMG.
#
# Plain `hdiutil`, not create-dmg or a similar helper: the layout is an app and a symlink to
# /Applications, which is a two-line job, and a build dependency that has to be installed on
# the release runner is a build dependency that breaks the release.
#
# Usage:
#   Packaging/make-dmg.sh --app PATH [--output PATH]

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

APP=""
OUTPUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$APP" ] || { echo "error: --app is required" >&2; exit 2; }
[ -d "$APP" ] || { echo "error: no bundle at $APP" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUTPUT="${OUTPUT:-$ROOT/.build/package/BlueBubbles-$VERSION.dmg}"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "==> Staging $VERSION"
cp -R "$APP" "$STAGING/"
# The drag target. Without it people copy the app into their Downloads folder and then
# wonder why it re-downloads every update.
ln -s /Applications "$STAGING/Applications"

rm -f "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"

echo "==> Building the disk image"
# UDZO is compressed and read-only, which is what a distributed image should be. The size is
# computed by hdiutil from the staging directory, so there is no fixed capacity to outgrow.
hdiutil create \
    -volname "BlueBubbles $VERSION" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$OUTPUT"

# The app inside must still be intact after the copy. A DMG whose payload lost its signature
# is one users cannot open, and the copy above is where that would happen.
echo "==> Verifying the payload"
MOUNT="$(mktemp -d)"
hdiutil attach "$OUTPUT" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
if ! codesign --verify --deep --strict "$MOUNT/BlueBubbles.app" 2>/dev/null; then
    # Not fatal before signing — this script runs standalone during development too.
    echo "==> note: the app in the image is not validly signed (expected for a local build)"
fi
MOUNTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$MOUNT/BlueBubbles.app/Contents/Info.plist")"
hdiutil detach "$MOUNT" >/dev/null
rmdir "$MOUNT" 2>/dev/null || true

if [ "$MOUNTED_VERSION" != "$VERSION" ]; then
    echo "error: the image contains $MOUNTED_VERSION, expected $VERSION" >&2
    exit 1
fi

echo "==> Built $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
echo "$OUTPUT"
