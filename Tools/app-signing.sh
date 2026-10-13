#  app-signing.sh
#  Signs an assembled BlueBubbles.app inside-out, with its entitlements and its profile.
#  Sourced, never run.
#
#  ONE implementation for both bundles this repository signs: `Packaging/sign-app.sh` (a
#  release) and `Tools/dev-bundle.sh` (this Mac). A dev bundle signed any other way tests a
#  signature no user runs. `codesign --deep` with no entitlements gives every nested item the
#  outermost item's treatment, no hardened runtime, no `disable-library-validation` and no
#  profile, so a failure that only the release signature produces (a nested item the kernel
#  kills for an entitlement it may not hold, a library the hardened runtime refuses, a secret
#  that lands in the other keychain) surfaces for the first time on a user's machine.
#  `ToolScriptTests` fails the build on `codesign` signing anything in any other script, and
#  on `--deep` signing anywhere.
#
#  ORDER: nested code is signed BEFORE the bundle that contains it. Signing outside-in
#  produces a bundle whose own signature is invalidated the moment an inner item is signed
#  afterwards, and the failure surfaces only at notarization or, worse, on a user's machine as
#  a damaged app.
#
#  THE ONE DIFFERENCE between the two purposes is `keychain-access-groups`. It is a RESTRICTED
#  entitlement: only an embedded provisioning profile authorises it, and the profile
#  authorises one TEAM. A process claiming it without that does not degrade: the kernel kills
#  it at launch, with nothing catchable and nothing in the log. So:
#
#    release      the profile is required, must be unexpired and must name the identity's
#                 team, and the bundle claims the entitlement. Anything else refuses to sign.
#    development  the entitlement and the profile are applied only when the identity belongs
#                 to the profile's team. Ad-hoc (`-`) and a self-signed certificate cannot
#                 carry it, so for those the entitlement is removed from a COPY of the file
#                 and the bundle has no profile. `KeychainSecretStore` then falls back to the
#                 legacy keychain, which is the configuration it was built to survive. The
#                 script says which it did.
#
#  Everything else is identical: the hardened runtime, the same entitlements on the same
#  items, the same order, the same verification. The only other difference is the secure
#  timestamp, which needs Apple's timestamp server and is only ever checked by notarization,
#  so a development signature goes without.

# No shebang: this file is sourced, never executed.
# shellcheck shell=bash

# Resolved once, when sourced, because the entitlements and the profile live beside the
# packaging scripts and a caller may have changed directory since.
BB_SIGNING_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BB_ENTITLEMENTS="$BB_SIGNING_ROOT/Packaging/BlueBubbles.entitlements"
BB_PROFILE="$BB_SIGNING_ROOT/Packaging/BlueBubbles_Server_Developer_ID.provisionprofile"

# bb_identity_team IDENTITY
#
# Prints the team ID an identity NAMES ("Developer ID Application: Name (TEAMID)"), or
# nothing. Read from the name rather than from the keychain: this file never touches the
# keychain, and an identity given as a certificate hash simply names no team.
bb_identity_team() {
    printf '%s\n' "$1" | sed -n 's/.*(\([A-Z0-9]\{10\}\))[[:space:]]*$/\1/p'
}

# bb_sign_app --app PATH --identity ID --purpose release|development
#
# Signs PATH as described above, verifies it, and sets BB_SIGNED_RESTRICTED to 1 when the
# bundle claims `keychain-access-groups` and 0 when it does not.
bb_sign_app() {
    local work status
    work="$(mktemp -d "${TMPDIR:-/tmp}/bb-signing.XXXXXX")" || return 1
    # Every failing step below says `|| return 1` explicitly. This runs inside an `if`, where
    # `set -e` is suspended for everything the function calls, so a bare failing `codesign`
    # would otherwise be skipped over and the bundle reported signed.
    if _bb_sign_app_in "$work" "$@"; then
        status=0
    else
        status=1
    fi
    rm -rf "$work"
    return "$status"
}

_bb_sign_app_in() {
    local work="$1"
    shift
    local app="" identity="" purpose=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --app) app="$2"; shift 2 ;;
            --identity) identity="$2"; shift 2 ;;
            --purpose) purpose="$2"; shift 2 ;;
            *) echo "error: bb_sign_app: unknown argument $1" >&2; return 2 ;;
        esac
    done
    [ -d "$app" ] || { echo "error: bb_sign_app: no bundle at '$app'" >&2; return 1; }
    [ -n "$identity" ] || { echo "error: bb_sign_app: --identity is required" >&2; return 2; }
    case "$purpose" in
        release | development) ;;
        *) echo "error: bb_sign_app: --purpose is release or development, not '$purpose'" >&2; return 2 ;;
    esac
    if [ "$purpose" = release ] && [ "$identity" = "-" ]; then
        echo "error: a release cannot be ad-hoc signed; pass a Developer ID identity." >&2
        return 1
    fi

    local cli_app="$app/Contents/Helpers/bluebubbles-server.app"
    local launcher_app="$app/Contents/Library/LoginItems/BlueBubblesLauncher.app"
    local sparkle="$app/Contents/Frameworks/Sparkle.framework"

    # --- Whether this signature may claim the restricted entitlement ----------------------
    local unentitled_because="" profile_team="" profile_expiry=""
    local identity_team
    identity_team="$(bb_identity_team "$identity")"
    if [ "$identity" = "-" ]; then
        unentitled_because="an ad-hoc signature has no team for a profile to authorise"
    elif [ ! -f "$BB_PROFILE" ]; then
        unentitled_because="there is no provisioning profile at $BB_PROFILE"
    elif ! security cms -D -i "$BB_PROFILE" > "$work/profile.plist" 2>/dev/null; then
        unentitled_because="$BB_PROFILE could not be decoded"
    else
        profile_team="$(plutil -extract TeamIdentifier.0 raw -o - "$work/profile.plist" 2>/dev/null || true)"
        profile_expiry="$(plutil -extract ExpirationDate raw -o - "$work/profile.plist" 2>/dev/null || true)"
        if [ -n "$profile_expiry" ] && [ "$(date -u +%Y-%m-%d)" \> "${profile_expiry%%T*}" ]; then
            # Said rather than merely skipped: an expired profile stops authorising the
            # entitlement, and the symptom (a server that cannot read its own secrets)
            # points nowhere near signing.
            unentitled_because="the provisioning profile expired on $profile_expiry"
        elif [ -n "$identity_team" ] && [ "$identity_team" != "$profile_team" ]; then
            unentitled_because="the identity is team $identity_team and the profile authorises ${profile_team:-no team}"
        elif [ -z "$identity_team" ] && [ "$purpose" = development ]; then
            # A release is still signed: its keychain probe (`sign-app.sh`) is the backstop
            # that would catch a mismatch. A development bundle has no such probe, so it
            # takes the safe side rather than guessing.
            unentitled_because="the identity does not name its team; pass it as 'Name (TEAMID)'"
        fi
    fi

    local entitlements="$BB_ENTITLEMENTS"
    BB_SIGNED_RESTRICTED=1
    if [ -n "$unentitled_because" ]; then
        if [ "$purpose" = release ]; then
            echo "error: cannot claim keychain-access-groups: $unentitled_because." >&2
            echo "       BlueBubbles.entitlements claims it, and a release must: without it every" >&2
            echo "       secret goes to the legacy keychain and nothing at runtime complains." >&2
            return 1
        fi
        echo "==> Not claiming keychain-access-groups: $unentitled_because."
        echo "    Secrets will use the legacy keychain, as an unentitled build does."
        entitlements="$work/BlueBubbles.entitlements"
        cp "$BB_ENTITLEMENTS" "$entitlements" || return 1
        plutil -remove keychain-access-groups "$entitlements" || return 1
        # A profile left by an earlier signing of this same bundle would still be sealed in
        # and claim nothing; removed so the bundle says what it is.
        rm -f "$app/Contents/embedded.provisionprofile" "$cli_app/Contents/embedded.provisionprofile"
        BB_SIGNED_RESTRICTED=0
    else
        # The profile has to be inside the bundle BEFORE anything is signed: the signature
        # seals the bundle, so a profile copied in afterwards is outside the seal and ignored.
        # EVERY bundle claiming the entitlement needs its own copy; a nested bundle does not
        # inherit the outer one's (measured: with the entitlement and no profile of its own,
        # the binary is killed at launch).
        echo "==> Embedding provisioning profile (team $profile_team, expires $profile_expiry)"
        cp "$BB_PROFILE" "$app/Contents/embedded.provisionprofile" || return 1
        echo "    $app/Contents/embedded.provisionprofile"
        if [ -d "$cli_app" ]; then
            cp "$BB_PROFILE" "$cli_app/Contents/embedded.provisionprofile" || return 1
            echo "    $cli_app/Contents/embedded.provisionprofile"
        fi
    fi

    # Every signature: forced, hardened runtime, and timestamped only for a release.
    local sign=(codesign --force --options runtime --timestamp)
    if [ "$purpose" = development ]; then
        sign=(codesign --force --options runtime --timestamp=none)
    fi

    # --- The injected helpers ---------------------------------------------------------------
    #
    # ASSERTED BY NAME, not discovered by glob. An unmatched glob in sh stays the literal
    # pattern, which a file test then skips, so a loop over `*.dylib` signed a bundle missing
    # both helpers and every Private API and FaceTime route was absent with no log line.
    echo "==> Signing the injected helpers"
    local helper item
    for helper in libBlueBubblesHelper.dylib libBlueBubblesFaceTimeHelper.dylib; do
        item="$app/Contents/Frameworks/$helper"
        if [ ! -f "$item" ]; then
            echo "error: $helper is missing from $app/Contents/Frameworks." >&2
            echo "error: the bundle scripts build it for the injection slices and copy it;" >&2
            echo "error: without it the Private API is absent at runtime and nothing says so." >&2
            return 1
        fi
        echo "    $item"
        "${sign[@]}" --entitlements "$entitlements" --sign "$identity" "$item" || return 1
    done

    # --- Sparkle ----------------------------------------------------------------------------
    #
    # In the order its documentation gives: the XPC services and the two helpers inside the
    # framework first, then the framework. NO entitlements: an XPC service signed with this
    # app's `keychain-access-groups` and no profile of its own is killed at launch, silently,
    # and Sparkle reports only that the installer could not be reached.
    # `--preserve-metadata=entitlements` on Downloader.xpc, which ships with the entitlements
    # it needs and must keep them.
    if [ ! -d "$sparkle" ]; then
        echo "error: no Sparkle.framework in $app/Contents/Frameworks; the app links it." >&2
        return 1
    fi
    echo "==> Signing Sparkle"
    for item in \
        "$sparkle/Versions/B/XPCServices/Installer.xpc" \
        "$sparkle/Versions/B/Autoupdate" \
        "$sparkle/Versions/B/Updater.app"; do
        echo "    $item"
        "${sign[@]}" --sign "$identity" "$item" || return 1
    done
    echo "    $sparkle/Versions/B/XPCServices/Downloader.xpc"
    "${sign[@]}" --preserve-metadata=entitlements \
        --sign "$identity" "$sparkle/Versions/B/XPCServices/Downloader.xpc" || return 1
    echo "    $sparkle"
    "${sign[@]}" --sign "$identity" "$sparkle" || return 1

    # --- Mach-O executables beside the main one in Contents/MacOS ----------------------------
    #
    # `codesign` on a bundle signs CFBundleExecutable and treats everything else in MacOS as a
    # resource, so a second binary there is sealed but never signed itself, which
    # `--verify --deep --strict` catches and notarization rejects.
    local main_executable
    main_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")" || return 1
    echo "==> Signing side-by-side executables"
    for item in "$app/Contents/MacOS/"*; do
        [ -f "$item" ] || continue
        [ "$(basename "$item")" != "$main_executable" ] || continue
        file "$item" | grep -q 'Mach-O' || continue
        echo "    $item"
        "${sign[@]}" --entitlements "$entitlements" --sign "$identity" "$item" || return 1
    done

    # --- The nested CLI bundle ----------------------------------------------------------------
    #
    # Signed as a BUNDLE, not as a loose Mach-O: that is what seals its own
    # `embedded.provisionprofile` in, and the profile is what authorises
    # `keychain-access-groups`.
    if [ -d "$cli_app" ]; then
        echo "==> Signing the headless CLI bundle"
        "${sign[@]}" --entitlements "$entitlements" --sign "$identity" "$cli_app" || return 1
    fi

    # --- The launcher ---------------------------------------------------------------------------
    #
    # NO entitlements, deliberately. It supervises a process and touches one small file; it
    # reads no secret, so it has no business holding `keychain-access-groups`, and a profile it
    # does not need is a profile that can expire and break a login item.
    if [ ! -d "$launcher_app" ]; then
        echo "error: no launcher at $launcher_app. The app would register no login item," >&2
        echo "error: and SMAppService reports a missing helper as .notFound, which is" >&2
        echo "error: indistinguishable from 'not registered yet' at the call site." >&2
        return 1
    fi
    echo "==> Signing the launcher"
    "${sign[@]}" --sign "$identity" "$launcher_app" || return 1

    echo "==> Signing the bundle"
    "${sign[@]}" --entitlements "$entitlements" --sign "$identity" "$app" || return 1

    # --- Verification ---------------------------------------------------------------------------
    echo "==> Verifying"
    # --strict --deep catches an unsigned nested item that the top-level signature would
    # otherwise hide until notarization rejects it.
    codesign --verify --deep --strict --verbose=2 "$app" || return 1

    # The entitlements that actually made it in, printed so a mismatch is visible in the log
    # rather than discovered when injection silently stops working.
    echo "==> Entitlements on the signed bundle"
    codesign --display --entitlements - --xml "$app" 2>/dev/null |
        plutil -convert xml1 -o "$work/signed.plist" - 2>/dev/null || true
    if [ -f "$work/signed.plist" ]; then
        cat "$work/signed.plist"
    fi

    if ! grep -q "com.apple.security.cs.disable-library-validation" "$work/signed.plist" 2>/dev/null; then
        echo "error: disable-library-validation is missing from the signed bundle." >&2
        echo "error: the Private API helper cannot be injected without it, and dyld reports" >&2
        echo "error: nothing when it declines; Messages simply starts without the helper." >&2
        return 1
    fi
    # Both directions, because both are silent: claimed without a profile, the kernel kills
    # the process at launch; missing on a release, every secret goes to the weaker keychain.
    if grep -q "keychain-access-groups" "$work/signed.plist"; then
        if [ "$BB_SIGNED_RESTRICTED" -eq 0 ]; then
            echo "error: the bundle claims keychain-access-groups with no profile to authorise it;" >&2
            echo "error: the kernel would kill it at launch." >&2
            return 1
        fi
    elif [ "$BB_SIGNED_RESTRICTED" -eq 1 ]; then
        echo "error: keychain-access-groups is missing from the signed bundle." >&2
        return 1
    fi
}
