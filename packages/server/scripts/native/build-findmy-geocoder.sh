#!/bin/bash
# Builds appResources/macos/tools/findmy-geocoder from findmy-geocoder.m.
# Run from the repository root on a Mac with Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"
OUT=../../appResources/macos/tools/findmy-geocoder
FLAGS=(-Os -fobjc-arc -mmacosx-version-min=12.0 -framework Foundation -framework CoreLocation)
clang "${FLAGS[@]}" -arch x86_64 findmy-geocoder.m -o findmy-geocoder-x86_64
clang "${FLAGS[@]}" -arch arm64  findmy-geocoder.m -o findmy-geocoder-arm64
lipo -create findmy-geocoder-x86_64 findmy-geocoder-arm64 -output "$OUT"
codesign -s - --force "$OUT"
rm -f findmy-geocoder-x86_64 findmy-geocoder-arm64
shasum -a 256 "$OUT"
