#  sdk-stamp.sh
#  Makes a binary say which SDK it was linked against. Sourced by the packaging scripts.
#
#  Every Mach-O carries an `LC_BUILD_VERSION` with two numbers: the deployment target (`minos`)
#  and the SDK it was linked against (`sdk`). AppKit reads the SECOND one to decide how much of
#  the current design an app gets: an app that says it was built against the macOS 14 SDK is
#  drawn with the macOS 14 sidebar, toolbar and controls, however new the OS. That is the
#  "linked-on-or-after" check, and it is how Liquid Glass is opted into: not a plist key, not
#  a flag, the stamp.
#
#  Xcode 27's SwiftPM stamps it WRONG. Its default build system (`swiftbuild`) writes the
#  deployment target into both fields, so every binary it links claims `sdk 14.0`, and on
#  macOS 26 and later the window chrome falls back to the pre-glass appearance while the
#  explicit `glassEffect` calls inside the window still render. A bare `swiftc` and the
#  deprecated `native` build system both stamp the real SDK. Measured on that toolchain:
#
#    swift build (swiftbuild)           minos 14.0  sdk 14.0
#    swift build --build-system native  minos 14.0  sdk 27.0
#    swiftc -target arm64-apple-macos14 minos 14.0  sdk 27.0
#
#  Corrected AT LINK TIME: `-platform_version` tells the linker both numbers outright, so the
#  binary is never wrong. Both numbers are derived, never typed here. The deployment target is
#  read from `Package.swift` through `swift package dump-package`, so it cannot drift from the
#  one place that declares it; the SDK version is the toolchain's own answer. On a toolchain
#  that stamps correctly the flag changes nothing.
#
#  The assertion is the part that matters. A wrong stamp produces an app that installs,
#  launches and serves, and looks two releases old; nothing else would notice. It is checked
#  on every binary copied into the bundle, which also catches `--no-build` reusing a binary
#  that some plain `swift build` linked without the flag.
#
#  Delete this file, and its two call sites, once `swift build` stamps the SDK correctly.

# bb_sdk_stamp_flags
#
# Fills BB_SDK_STAMP_FLAGS with the `swift build` arguments that make the linker stamp the
# right SDK. An array set by the function rather than lines printed by it, because the system
# /bin/bash is 3.2 and has no `mapfile`. Pass it as "${BB_SDK_STAMP_FLAGS[@]}" to EVERY
# `swift build` that links a shipped binary, the second helper build included.
bb_sdk_stamp_flags() {
    local deploy sdk
    deploy="$(bb_deployment_target)"
    sdk="$(xcrun --show-sdk-version)"
    BB_SDK_STAMP_FLAGS=(-Xlinker -platform_version -Xlinker macos -Xlinker "$deploy" -Xlinker "$sdk")
    echo "==> Linking for macOS $deploy against SDK $sdk"
}

# bb_deployment_target
#
# The macOS deployment target `Package.swift` declares (`.macOS(.v14)` reads as `14.0`).
bb_deployment_target() {
    swift package dump-package 2>/dev/null | python3 -c '
import json, sys
for platform in json.load(sys.stdin).get("platforms", []):
    if platform.get("platformName") == "macos":
        print(platform["version"])
        break
else:
    sys.exit("Package.swift declares no macOS deployment target")
'
}

# bb_assert_sdk_stamp FILE
#
# Fails unless FILE says it was linked against the SDK this toolchain is using. Read-only.
bb_assert_sdk_stamp() {
    local file="$1"
    local want have
    want="$(xcrun --show-sdk-version)"
    have="$(vtool -show-build "$file" | awk '/^ *sdk /{print $2; exit}')"
    if [ "$have" != "$want" ]; then
        echo "error: $(basename "$file") claims SDK ${have:-none}, not $want. macOS would draw it" >&2
        echo "error: with the SDK-${have:-?} appearance. Was it linked without bb_sdk_stamp_flags?" >&2
        echo "error: (A binary from a plain 'swift build' is, so --no-build cannot reuse one.)" >&2
        return 1
    fi
}
