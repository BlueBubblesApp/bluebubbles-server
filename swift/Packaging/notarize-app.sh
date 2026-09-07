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
# Usage:
#   Packaging/notarize-app.sh --app PATH
# Requires:
#   APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID, APP_STORE_CONNECT_KEY_P8

set -euo pipefail

cd "$(dirname "$0")/.."

APP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$APP" ] || { echo "error: --app is required" >&2; exit 2; }
[ -d "$APP" ] || { echo "error: no bundle at $APP" >&2; exit 1; }

for required in APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_KEY_P8; do
    if [ -z "${!required:-}" ]; then
        echo "error: $required is not set. See CONTRIBUTING.md § 10 for how to create the key." >&2
        exit 2
    fi
done

WORK="$(mktemp -d)"
# The key file is deleted on ANY exit, including a failure partway through. It is a
# credential that can submit builds under the team's identity.
trap 'rm -rf "$WORK"' EXIT

KEY="$WORK/AuthKey.p8"
printf '%s' "$APP_STORE_CONNECT_KEY_P8" > "$KEY"
chmod 600 "$KEY"

# Zipped for submission. `notarytool` does not accept a bare .app directory, and `ditto` with
# --keepParent is the only archiver that preserves the bundle's symlinks and extended
# attributes — a plain `zip` produces an archive that notarizes and then fails to launch.
ARCHIVE="$WORK/BlueBubbles.zip"
echo "==> Archiving for submission"
/usr/bin/ditto -c -k --keepParent "$APP" "$ARCHIVE"

echo "==> Submitting to Apple (this usually takes a few minutes)"
set +e
SUBMISSION="$(xcrun notarytool submit "$ARCHIVE" \
    --key "$KEY" \
    --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
    --wait \
    --output-format json 2>&1)"
STATUS=$?
set -e

echo "$SUBMISSION"

if [ $STATUS -ne 0 ] || ! printf '%s' "$SUBMISSION" | grep -q '"status":"Accepted"'; then
    echo "error: notarization did not succeed." >&2
    # The submission log is the only place Apple says WHY. Without it the failure is a
    # status word and nothing else, and the usual causes — a missing entitlement, an
    # unsigned nested binary — are named explicitly in that log.
    ID="$(printf '%s' "$SUBMISSION" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)"
    if [ -n "$ID" ]; then
        echo "==> Fetching the rejection log for $ID" >&2
        xcrun notarytool log "$ID" \
            --key "$KEY" \
            --key-id "$APP_STORE_CONNECT_KEY_ID" \
            --issuer "$APP_STORE_CONNECT_ISSUER_ID" >&2 || true
    fi
    exit 1
fi

# Stapling attaches the ticket to the bundle so Gatekeeper can verify OFFLINE. Without it a
# user installing on a machine with no network — or while Apple's service is briefly
# unreachable — is told the app is damaged.
echo "==> Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# The real check: this is what Gatekeeper does on a user's machine at first launch.
echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APP"

echo "==> Notarized and stapled $APP"
