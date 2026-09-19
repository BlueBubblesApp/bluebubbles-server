#!/bin/bash
#
# Builds the distributable DMG.
#
# Plain `hdiutil` plus one `osascript`, not create-dmg or a similar helper: a build
# dependency that has to be installed on the release runner is a build dependency that
# breaks the release. Everything below is `hdiutil`, `osascript` and `swift`, all of which a
# machine building this project already has.
#
# WHY THE LAYOUT EXISTS. The image used to be `hdiutil create -srcfolder` over an app and an
# /Applications symlink: correct, and it opens as a list view with two rows and no indication
# that one is meant to be dragged onto the other. People copied the app into Downloads and
# then wondered why every update re-downloaded. The window this builds says what to do, once,
# in the only place a person is guaranteed to look.
#
# HOW THE LAYOUT IS APPLIED, and why it is the awkward part. Icon positions, the window size,
# the view mode and the background picture live in a `.DS_Store` at the root of the volume,
# whose format is Apple's and undocumented, and the only supported writer of it is Finder. So
# the image is built READ-WRITE, mounted, arranged by telling Finder what to do, unmounted,
# and then converted to the read-only compressed image that ships. That is the same sequence
# create-dmg uses and there is no shorter one.
#
# It also means the layout depends on a GUI session and on Finder accepting Apple Events from
# whatever is running this script, neither of which is true everywhere: a remote shell has no
# Finder to talk to, and a Mac that has not granted the terminal Automation access refuses.
# A failure there is a NOTE by default (a developer building a local DMG gets a working image
# with a plain window) and an ERROR under `--require-layout`, which the release workflow
# passes. A release that quietly shipped the old plain window would be the bad outcome, and
# the only way to have that be loud is to say which runs care.
#
# Usage:
#   Packaging/make-dmg.sh --app PATH [--output PATH] [--require-layout]

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

APP=""
OUTPUT=""
REQUIRE_LAYOUT=0
REQUIRE_SIGNATURE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --require-layout) REQUIRE_LAYOUT=1; shift ;;
        --require-signature) REQUIRE_SIGNATURE=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$APP" ] || { echo "error: --app is required" >&2; exit 2; }
[ -d "$APP" ] || { echo "error: no bundle at $APP" >&2; exit 1; }

# Whether the bundle handed to us was signed AT ALL, recorded before anything is copied.
# It is what makes the verification at the end meaningful: see there.
SOURCE_SIGNED=0
if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    SOURCE_SIGNED=1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUTPUT="${OUTPUT:-$ROOT/.build/package/BlueBubbles-$VERSION.dmg}"
VOLUME_NAME="BlueBubbles $VERSION"

# THE LAYOUT, in one place. `dmg-background.swift` declares the same numbers and draws the
# arrow into the gap between them; changing one without the other leaves an arrow pointing
# at an app icon.
WINDOW_WIDTH=620
WINDOW_HEIGHT=420
ICON_SIZE=128
ICON_Y=205
APP_ICON_X=165
APPLICATIONS_ICON_X=455

STAGING="$(mktemp -d)"
WORK="$(mktemp -d)"
RW_IMAGE="$WORK/rw.dmg"
MOUNT_POINT=""

cleanup() {
    # Detach first: a mounted image holds the file the conversion reads, and leaving one
    # attached after a failed run is how the NEXT run fails with "resource busy".
    if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
        hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$STAGING" "$WORK"
}
trap cleanup EXIT

echo "==> Staging $VERSION"
cp -R "$APP" "$STAGING/"
# The drag target. Without it people copy the app into their Downloads folder and then
# wonder why it re-downloads every update.
ln -s /Applications "$STAGING/Applications"

# The picture behind the icons, drawn rather than committed; see `dmg-background.swift`.
# A dot directory, so the volume shows two items and not three.
mkdir -p "$STAGING/.background"
if ! swift "$ROOT/Packaging/dmg-background.swift" "$STAGING/.background/background.tiff"; then
    echo "error: could not draw the disk image background" >&2
    exit 1
fi

echo "==> Building the writable image"
# HFS+ and read-write for this intermediate one, on purpose. Finder's arrangement has to be
# written INTO the volume, so it cannot be read-only; and `hdiutil create -fs APFS -format
# UDRW` produces a volume whose `.DS_Store` Finder does not reliably persist. The image that
# SHIPS is APFS, and it is converted from this one below, so the format here is invisible to
# anyone who downloads it.
#
# `-size` rather than letting hdiutil compute it: a writable image has to have room for the
# `.DS_Store` Finder is about to write, and a tightly-sized one has none. The slack is
# discarded by the conversion.
STAGED_KB="$(du -sk "$STAGING" | cut -f1)"
IMAGE_MB=$(( STAGED_KB / 1024 + 64 ))
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -fs HFS+ \
    -format UDRW \
    -size "${IMAGE_MB}m" \
    "$RW_IMAGE" >/dev/null

# MOUNTED WHERE macOS PUTS IT, not at a path of our choosing.
#
# `-mountpoint "$WORK/mount"` is the obvious thing to write and it silently breaks the step
# below: Finder addresses a volume through `/Volumes`, so an image mounted anywhere else is
# either invisible to it ("Can't get disk …", -1728) or visible but unable to resolve a file
# reference inside itself ("Can't set file \".background:background.tiff\" …", -10006).
# Both were seen. `--require-layout` is what turned that into a failed build rather than a
# release that quietly shipped the old plain window.
#
# The real mount point comes back from `-plist` rather than being assumed to be
# `/Volumes/$VOLUME_NAME`: mounting a second image with the same volume name gets you
# `/Volumes/NAME 1`, and a release built while an older copy of the same version is mounted
# would otherwise arrange the wrong volume. `-nobrowse` keeps it out of the sidebar and
# leaves it scriptable.
ATTACH_PLIST="$WORK/attach.plist"
hdiutil attach "$RW_IMAGE" -readwrite -noverify -noautoopen -nobrowse -plist > "$ATTACH_PLIST"
MOUNT_POINT="$(/usr/libexec/PlistBuddy -c 'Print :system-entities' "$ATTACH_PLIST" \
    | grep -o '/Volumes/.*' | head -1)"
if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT" ]; then
    echo "error: the writable image did not mount under /Volumes" >&2
    exit 1
fi
# The volume name Finder knows it by, which is the mount point's basename and NOT
# necessarily "$VOLUME_NAME" once macOS has disambiguated a duplicate.
FINDER_VOLUME="$(basename "$MOUNT_POINT")"

echo "==> Arranging the window"
# Finder is addressed by DISK NAME, not by mount path: `tell application "Finder" ... disk
# "BlueBubbles 1.2.3"` is the only handle AppleScript has on a mounted volume, which is why
# the name comes from the mount point rather than from `$VOLUME_NAME` (see above).
#
# `delay 1` before closing is not superstition: Finder writes `.DS_Store` lazily, and closing
# the window (or unmounting) immediately after setting the properties loses them. Everything
# that arranges a disk image does this, and it is the single most common reason a layout
# silently does not stick.
LAYOUT_SCRIPT=$(cat <<APPLESCRIPT
tell application "Finder"
    tell disk "$FINDER_VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 140, $((200 + WINDOW_WIDTH)), $((140 + WINDOW_HEIGHT))}
        set options to the icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to $ICON_SIZE
        set background picture of options to file ".background:background.tiff"
        set position of item "BlueBubbles.app" of container window to {$APP_ICON_X, $ICON_Y}
        set position of item "Applications" of container window to {$APPLICATIONS_ICON_X, $ICON_Y}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
)

LAYOUT_APPLIED=1
if ! osascript -e "$LAYOUT_SCRIPT" >/dev/null 2>"$WORK/osascript.err"; then
    LAYOUT_APPLIED=0
fi

# Believing `osascript`'s exit status alone is not enough: Finder can accept every command
# and persist none of them, which is exactly the failure that is worth catching. The
# `.DS_Store` is the artifact, so that is what is checked.
if [ ! -s "$MOUNT_POINT/.DS_Store" ]; then
    LAYOUT_APPLIED=0
fi

if [ "$LAYOUT_APPLIED" -eq 0 ]; then
    if [ "$REQUIRE_LAYOUT" -eq 1 ]; then
        echo "error: the disk image window could not be arranged." >&2
        echo "error: Finder must be scriptable from this session: a GUI login, and" >&2
        echo "error: Automation access for whatever is running this script." >&2
        [ -s "$WORK/osascript.err" ] && sed 's/^/error: osascript: /' "$WORK/osascript.err" >&2
        exit 1
    fi
    echo "==> note: could not arrange the window; the image will open as a plain list."
    echo "==> note: expected when Finder is not scriptable here (a remote shell, or no"
    echo "==> note: Automation access). A release run passes --require-layout and fails."
fi

# Finder leaves a trash directory behind on any volume it has opened, and it travels into the
# shipped image as a mysterious hidden folder.
rm -rf "$MOUNT_POINT/.Trashes" "$MOUNT_POINT/.fseventsd"

sync
hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNT_POINT=""

rm -f "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"

echo "==> Converting to the shipped image"
# APFS with lzfse (ULFO): read-only and compressed, which is what a distributed image should
# be, and the combination Sparkle recommends for decompression speed, because this same file
# is the update artifact and Sparkle mounts it on every install. UDZO (HFS+, zlib) is the
# hdiutil default and mounts noticeably slower. APFS images need macOS 10.13 to mount; the
# deployment floor is 14. Converting from the writable image carries the `.DS_Store` across,
# which is the whole point of building it in two stages.
hdiutil convert "$RW_IMAGE" -format ULFO -o "$OUTPUT" >/dev/null

# The app inside must still be intact after the copy. A DMG whose payload lost its signature
# is one users cannot open, and the copy above is where that would happen.
echo "==> Verifying the payload"
VERIFY_MOUNT="$WORK/verify"
mkdir -p "$VERIFY_MOUNT"
hdiutil attach "$OUTPUT" -nobrowse -readonly -mountpoint "$VERIFY_MOUNT" >/dev/null
# Three outcomes, and only one of them was ever a note.
#
# The check exists because the staging copy and the two hdiutil conversions are where a
# signature gets destroyed, and a DMG whose payload lost its seal is one that users cannot
# open at all. That failure is fatal WHEREVER it happens: a bundle that verified on the way
# in and does not verify on the way out is corruption, not a local-build convenience, and it
# is the exact thing this step was written to catch. Reporting it as a note meant the one
# case the check was for printed a line nobody reads and exited 0.
#
# An UNSIGNED payload is the genuine local case, and stays a note here. `--require-signature`
# makes it fatal, which is what a release passes: shipping an unsigned image is a different
# defect, caught earlier by the signing step, but there is no reason for this script to
# produce one when it has been told it is cutting a release.
SIGNATURE_OK=1
codesign --verify --deep --strict "$VERIFY_MOUNT/BlueBubbles.app" >/dev/null 2>&1 || SIGNATURE_OK=0
MOUNTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$VERIFY_MOUNT/BlueBubbles.app/Contents/Info.plist")"
# The layout has to survive the conversion, not merely have been applied before it. These two
# files ARE the arrangement: without either, the image opens as a plain window again.
SHIPPED_LAYOUT=1
[ -s "$VERIFY_MOUNT/.DS_Store" ] || SHIPPED_LAYOUT=0
[ -f "$VERIFY_MOUNT/.background/background.tiff" ] || SHIPPED_LAYOUT=0
hdiutil detach "$VERIFY_MOUNT" >/dev/null

if [ "$SIGNATURE_OK" -eq 0 ]; then
    if [ "$SOURCE_SIGNED" -eq 1 ]; then
        echo "error: the app was validly signed going in and is not coming out." >&2
        echo "error: packaging destroyed its signature, and the image cannot be opened." >&2
        exit 1
    fi
    if [ "$REQUIRE_SIGNATURE" -eq 1 ]; then
        echo "error: --require-signature was given and the payload is not signed." >&2
        echo "error: sign-app.sh runs before this script on a release." >&2
        exit 1
    fi
    echo "==> note: the app in the image is not signed (expected for a local build)"
fi

if [ "$MOUNTED_VERSION" != "$VERSION" ]; then
    echo "error: the image contains $MOUNTED_VERSION, expected $VERSION" >&2
    exit 1
fi

if [ "$REQUIRE_LAYOUT" -eq 1 ] && [ "$SHIPPED_LAYOUT" -eq 0 ]; then
    echo "error: the shipped image has no window arrangement." >&2
    exit 1
fi

echo "==> Built $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
echo "$OUTPUT"
