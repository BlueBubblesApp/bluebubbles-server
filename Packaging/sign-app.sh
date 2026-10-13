#!/bin/bash
#
# Signs BlueBubbles.app for release, then asks the two questions only a release signature
# can answer: what Gatekeeper makes of it, and whether it reaches the data protection keychain.
#
# The signing itself is `bb_sign_app` (Tools/app-signing.sh), shared with `Tools/dev-bundle.sh`
# so a dev bundle is signed the same way. What is HERE is what only a release needs.
#
# Usage:
#   Packaging/sign-app.sh --app PATH --identity "Developer ID Application: ... (TEAMID)"

set -euo pipefail

# `.env` from the CURRENT DIRECTORY, before the `cd` below: the file is chosen by
# where you stand, not by where this script lives or where it is about to go. A
# name already in the environment wins, so a `VAR=… ` prefix still overrides the
# file. See Tools/dotenv.sh.
source "$(cd "$(dirname "$0")/../Tools" && pwd)/dotenv.sh"
bb_load_dotenv
# The signing, shared with the dev bundle; see Tools/app-signing.sh.
# shellcheck source=../Tools/app-signing.sh
source "$(cd "$(dirname "$0")/../Tools" && pwd)/app-signing.sh"

cd "$(dirname "$0")/.."

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

# Embedding the profile, every signature in the bundle, inside-out, and the verification
# that the entitlements made it in: Tools/app-signing.sh, which `Tools/dev-bundle.sh` calls
# too, so a dev bundle carries the signature a release does. `release` is the strict purpose:
# no ad-hoc identity, and a missing, expired or wrong-team profile refuses to sign rather
# than dropping `keychain-access-groups`.
bb_sign_app --app "$APP" --identity "$IDENTITY" --purpose release

# What Gatekeeper will actually do. `spctl` is the closest local approximation to a user's
# first launch, and it fails here rather than on their machine.
echo "==> Gatekeeper assessment"
if ! spctl --assess --type execute --verbose=4 "$APP" 2>&1; then
    echo "==> note: spctl rejected the bundle. Before notarization this is EXPECTED:"
    echo "==> Gatekeeper accepts a Developer ID app only once its notarization ticket exists."
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
CLI_BINARY="$APP/Contents/Helpers/bluebubbles-server.app/Contents/MacOS/bluebubbles-server"
if [ -x "$CLI_BINARY" ]; then
    echo "==> Verifying the signed build reaches the data protection Keychain"
    if ! "$CLI_BINARY" --check-keychain; then
        echo "error: the signed build fell back to the LEGACY keychain." >&2
        echo "error: secrets would be stored where kSecAttrAccessible is ignored and any" >&2
        echo "error: same-user process can prompt its way in. Check that" >&2
        echo "error: $BB_PROFILE is present, unexpired, and issued for the App ID this bundle" >&2
        echo "error: declares as CFBundleIdentifier." >&2
        exit 1
    fi
else
    echo "error: no nested CLI at $CLI_BINARY, so the keychain assertion cannot run." >&2
    exit 1
fi

echo "==> Signed $APP"
