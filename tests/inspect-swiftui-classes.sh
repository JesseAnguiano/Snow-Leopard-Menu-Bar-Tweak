#!/bin/bash

set -e
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXECUTABLE="$(/usr/bin/mktemp /private/tmp/InspectSwiftUIClasses.XXXXXX)"
cleanup() {
    /bin/rm -f "${EXECUTABLE}"
}
trap cleanup EXIT HUP INT TERM
CLANG="$(/usr/bin/xcrun --find clang)"
SDKROOT="$(/usr/bin/xcrun --show-sdk-path)"
"${CLANG}" -fobjc-arc -arch arm64 -isysroot "${SDKROOT}" \
    -mmacosx-version-min=15.0 -framework Foundation \
    "${SCRIPT_DIR}/InspectSwiftUIClasses.m" -o "${EXECUTABLE}"
"${EXECUTABLE}" | /usr/bin/sort -u
