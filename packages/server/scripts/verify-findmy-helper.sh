#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DYLIB="$ROOT_DIR/appResources/private-api/macos11/BlueBubblesFindMyHelper.dylib"
CHECKSUM_FILE="$DYLIB.md5"

if [[ ! -f "$DYLIB" || ! -f "$CHECKSUM_FILE" ]]; then
    printf 'Missing Find My helper or checksum: %s\n' "$DYLIB" >&2
    exit 1
fi

for tool in lipo md5 otool; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'Required macOS build tool is unavailable: %s\n' "$tool" >&2
        exit 1
    fi
done

EXPECTED_CHECKSUM="$(tr -d '[:space:]' < "$CHECKSUM_FILE")"
ACTUAL_CHECKSUM="$(md5 -q "$DYLIB")"
if [[ "$ACTUAL_CHECKSUM" != "$EXPECTED_CHECKSUM" ]]; then
    printf 'Find My helper checksum mismatch: %s (expected %s)\n' "$ACTUAL_CHECKSUM" "$EXPECTED_CHECKSUM" >&2
    exit 1
fi

lipo "$DYLIB" -verify_arch x86_64 arm64

INSTALL_NAME="$(otool -D "$DYLIB" | tail -n 1 | xargs)"
EXPECTED_INSTALL_NAME="@rpath/BlueBubblesFindMyHelper.dylib"
if [[ "$INSTALL_NAME" != "$EXPECTED_INSTALL_NAME" ]]; then
    printf 'Unexpected Find My helper install name: %s (expected %s)\n' "$INSTALL_NAME" "$EXPECTED_INSTALL_NAME" >&2
    exit 1
fi

printf 'Verified Find My helper (%s, %s)\n' "$(lipo -archs "$DYLIB")" "$INSTALL_NAME"
