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
PROFILE="$ROOT/Packaging/BlueBubbles_Server_Developer_ID.provisionprofile"

# The profile has to be inside the bundle BEFORE anything is signed.
#
# `keychain-access-groups` is a RESTRICTED entitlement: the signature alone cannot grant it,
# and claiming it without a profile that authorises it does not degrade: the kernel kills the
# process at launch, with no error the app can catch and nothing in the log to explain it.
# The profile is what authorises it, and the signature seals the bundle, so a profile copied in
# afterwards is outside the seal and is ignored. That failure looks exactly like success until
# someone tries to run the app.
[ -f "$PROFILE" ] || {
    echo "error: no provisioning profile at $PROFILE" >&2
    echo "       BlueBubbles.entitlements claims keychain-access-groups, which requires one." >&2
    exit 1
}

echo "==> Embedding provisioning profile"
security cms -D -i "$PROFILE" > /tmp/bb-profile.plist 2>/dev/null || {
    echo "error: could not decode $PROFILE" >&2; exit 1
}
PROFILE_EXPIRY="$(plutil -extract ExpirationDate raw -o - /tmp/bb-profile.plist 2>/dev/null)"
echo "    expires: $PROFILE_EXPIRY"
# Printed rather than merely embedded. An expired profile stops authorising the entitlement,
# and the symptom (a server that cannot read its own secrets) points nowhere near signing.
if [ -n "$PROFILE_EXPIRY" ] && [ "$(date -u +%Y-%m-%d)" \> "${PROFILE_EXPIRY%%T*}" ]; then
    echo "error: the provisioning profile expired on $PROFILE_EXPIRY" >&2
    exit 1
fi
rm -f /tmp/bb-profile.plist

# EVERY bundle claiming a restricted entitlement needs its own copy. A nested bundle does not
# inherit the outer one's profile; measured: with the entitlement and no profile of its own,
# the binary is killed at launch.
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
echo "    $APP/Contents/embedded.provisionprofile"
CLI_APP="$APP/Contents/Helpers/bluebubbles-server.app"
if [ -d "$CLI_APP" ]; then
    cp "$PROFILE" "$CLI_APP/Contents/embedded.provisionprofile"
    echo "    $CLI_APP/Contents/embedded.provisionprofile"
fi

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
# never signed itself. `--deep --strict` catches it and notarization rejects it, which is
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

# The nested CLI bundle, before the outer one. Signed as a BUNDLE, not as a loose Mach-O:
# that is what seals its own `embedded.provisionprofile` in, and the profile is what
# authorises `keychain-access-groups`. Signing it as a bare executable (which is what
# happened while it lived in `Contents/MacOS`) produces a binary the kernel kills.
if [ -d "$CLI_APP" ]; then
    echo "==> Signing the headless CLI bundle"
    codesign --force --timestamp --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$IDENTITY" "$CLI_APP"
fi

# The launcher, before the outer bundle, and with NO entitlements, which is deliberate.
#
# It supervises a process and touches one small file; it reads no secret, so it has no business
# holding `keychain-access-groups`. That also keeps it cheap to ship: a restricted entitlement
# would require this bundle to carry its own `embedded.provisionprofile`, because a nested
# bundle does not inherit the containing app's, and a profile it does not need is a profile
# that can expire and break a login item.
LAUNCHER_APP="$APP/Contents/Library/LoginItems/BlueBubblesLauncher.app"
if [ -d "$LAUNCHER_APP" ]; then
    echo "==> Signing the launcher"
    codesign --force --timestamp --options runtime \
        --sign "$IDENTITY" "$LAUNCHER_APP"
else
    echo "error: no launcher at $LAUNCHER_APP. The app would register no login item," >&2
    echo "error: and SMAppService reports a missing helper as .notFound, which is" >&2
    echo "error: indistinguishable from 'not registered yet' at the call site." >&2
    exit 1
fi

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
    echo "==> note: spctl rejected the bundle. Before notarization this is EXPECTED:"
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
    echo "error: nothing when it declines; Messages simply starts without the helper." >&2
    exit 1
fi

# The assertion that cannot be written as a unit test.
#
# `KeychainSecretStore` prefers the data protection keychain and falls back to the legacy one
# when `keychain-access-groups` is absent. The fallback is what keeps `swift build` and
# `Tools/dev-bundle.sh` working, and it is also the risk, because it is SILENT: a release
# build whose provisioning profile did not embed, expired, or was issued for a different App
# ID puts every secret in the weaker store and starts normally. Nothing at runtime complains.
#
# It cannot be caught in the suite. The entitlement comes from a signature and an embedded
# profile, neither of which exists when tests run, so a test could only assert the fallback.
# Here, both exist: this is the first moment in the whole pipeline where the real answer is
# available, which makes it the right place to demand it.
#
# `--check-keychain` writes a probe item, reads it back and deletes it before answering.
# That round-trip is required, not defensive: the store resolves the entitlement lazily, on
# the first call that fails, so a check that merely read the flag would report success on
# exactly the builds this exists to reject.
CLI_BINARY="$CLI_APP/Contents/MacOS/bluebubbles-server"
if [ -x "$CLI_BINARY" ]; then
    echo "==> Verifying the signed build reaches the data protection Keychain"
    if ! "$CLI_BINARY" --check-keychain; then
        echo "error: the signed build fell back to the LEGACY keychain." >&2
        echo "error: secrets would be stored where kSecAttrAccessible is ignored and any" >&2
        echo "error: same-user process can prompt its way in. Check that" >&2
        echo "error: $PROFILE is present, unexpired, and issued for the App ID this bundle" >&2
        echo "error: declares as CFBundleIdentifier." >&2
        exit 1
    fi
else
    echo "error: no nested CLI at $CLI_BINARY, so the keychain assertion cannot run." >&2
    exit 1
fi

echo "==> Signed $APP"
