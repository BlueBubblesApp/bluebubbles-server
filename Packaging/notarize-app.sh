#!/bin/bash
#
# Notarizes and staples BlueBubbles.app.
#
# Notarization is what stops Gatekeeper telling users the app is damaged. The Electron build
# has this implemented and DISABLED (`"notarize": false`, the afterSign hook commented out),
# which is why installing it requires right-click → Open. The Swift build notarizes from the
# first release.
#
# Uses an App Store Connect API key rather than an Apple ID and app-specific password:
# no coupling to anyone's 2FA, scoped to what it needs, and revocable on its own.
#
# Two ways to supply it:
#
#   CI:     APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID, APP_STORE_CONNECT_KEY_P8
#           in the environment. The key is written to a temp file for the duration of the
#           submission and deleted on any exit.
#
#   Local:  --keychain-profile NAME (or NOTARYTOOL_KEYCHAIN_PROFILE). The key lives in the
#           login keychain, stored once with
#             xcrun notarytool store-credentials NAME --key AuthKey.p8 --key-id … --issuer …
#           and this script never sees it. Prefer this on a developer Mac: nothing to export
#           into a shell history, and any process that can run the script can notarize
#           without also being able to read the key.
#
# Accepts either the .app or the finished .dmg. Both need it: Gatekeeper assesses a signed
# disk image on open exactly as it assesses an app on launch, and a signed-but-unnotarized
# image is refused with the same "damaged" dialog (measured: `spctl --type open` reports
# `Unnotarized Developer ID` for one). Notarize the app first so the copy inside the image
# carries its own stapled ticket, then the image, so the download does too.
#
# Usage:
#   Packaging/notarize-app.sh --app PATH.app|PATH.dmg [--keychain-profile NAME]

set -euo pipefail

cd "$(dirname "$0")/.."

APP=""
PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --keychain-profile) PROFILE="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$APP" ] || { echo "error: --app is required" >&2; exit 2; }
case "$APP" in
    *.dmg) IS_IMAGE=1; [ -f "$APP" ] || { echo "error: no image at $APP" >&2; exit 1; } ;;
    *)     IS_IMAGE=0; [ -d "$APP" ] || { echo "error: no bundle at $APP" >&2; exit 1; } ;;
esac

WORK="$(mktemp -d)"
# The key file, if one is written, is deleted on ANY exit, including a failure partway
# through. It is a credential that can submit builds under the team's identity.
trap 'rm -rf "$WORK"' EXIT

# Every notarytool call takes the same authentication arguments; built once so the submit
# and the log fetch cannot disagree about which credential they used.
AUTH=()
if [ -n "$PROFILE" ]; then
    AUTH=(--keychain-profile "$PROFILE")
    echo "==> Authenticating with keychain profile '$PROFILE'"
else
    for required in APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_KEY_P8; do
        if [ -z "${!required:-}" ]; then
            echo "error: $required is not set and no --keychain-profile was given." >&2
            echo "       See CONTRIBUTING.md § 10 for how to create the key and store it." >&2
            exit 2
        fi
    done
    KEY="$WORK/AuthKey.p8"
    printf '%s' "$APP_STORE_CONNECT_KEY_P8" > "$KEY"
    chmod 600 "$KEY"
    AUTH=(--key "$KEY" --key-id "$APP_STORE_CONNECT_KEY_ID" --issuer "$APP_STORE_CONNECT_ISSUER_ID")
fi

if [ "$IS_IMAGE" = 1 ]; then
    # A disk image is submitted as it is; notarytool reads it directly.
    ARCHIVE="$APP"
else
    # Zipped for submission. `notarytool` does not accept a bare .app directory, and `ditto`
    # with --keepParent is the only archiver that preserves the bundle's symlinks and extended
    # attributes; a plain `zip` produces an archive that notarizes and then fails to launch.
    ARCHIVE="$WORK/BlueBubbles.zip"
    echo "==> Archiving for submission"
    /usr/bin/ditto -c -k --keepParent "$APP" "$ARCHIVE"
fi

echo "==> Submitting to Apple (this usually takes a few minutes)"
set +e
SUBMISSION="$(xcrun notarytool submit "$ARCHIVE" \
    "${AUTH[@]}" \
    --wait \
    --output-format json 2>&1)"
STATUS=$?
set -e

echo "$SUBMISSION"

if [ $STATUS -ne 0 ] || ! printf '%s' "$SUBMISSION" | grep -q '"status":"Accepted"'; then
    echo "error: notarization did not succeed." >&2
    # The submission log is the only place Apple says WHY. Without it the failure is a
    # status word and nothing else, and the usual causes (a missing entitlement, an
    # unsigned nested binary) are named explicitly in that log.
    ID="$(printf '%s' "$SUBMISSION" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)"
    if [ -n "$ID" ]; then
        echo "==> Fetching the rejection log for $ID" >&2
        xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
    fi
    exit 1
fi

# Stapling attaches the ticket to the bundle so Gatekeeper can verify OFFLINE. Without it a
# user installing on a machine with no network, or while Apple's service is briefly
# unreachable, is told the app is damaged.
echo "==> Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# The real check: this is what Gatekeeper does on a user's machine, at first launch for the
# app and on open for the image. The image needs its context named; without it spctl
# assesses the file as a document and reports nothing useful.
echo "==> Gatekeeper assessment"
if [ "$IS_IMAGE" = 1 ]; then
    spctl --assess --type open --context context:primary-signature --verbose=4 "$APP"
else
    spctl --assess --type execute --verbose=4 "$APP"
fi

echo "==> Notarized and stapled $APP"
