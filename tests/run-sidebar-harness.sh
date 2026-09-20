#!/bin/bash

set -e
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
DYLIB="${PROJECT_DIR}/build/libSnowLeopardBlueSelection.dylib"
TEST_ROOT="$(/usr/bin/mktemp -d /private/tmp/BlueSelection-sidebar.XXXXXX)"
APP_DIR="${TEST_ROOT}/SidebarHarness.app"
EXECUTABLE="${APP_DIR}/Contents/MacOS/com.apple.WebKit.WebContent"
RESULT="/private/tmp/BlueSelection-sidebar-harness-result.txt"

cleanup() {
    /bin/rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT HUP INT TERM

/bin/mkdir -p "${APP_DIR}/Contents/MacOS" \
    "${APP_DIR}/Contents/Resources"
/bin/cp "${SCRIPT_DIR}/SidebarHarnessInfo.plist" \
    "${APP_DIR}/Contents/Info.plist"
/bin/cp "${DYLIB}" \
    "${APP_DIR}/Contents/Resources/libSnowLeopardBlueSelection.dylib"
CLANG="$(/usr/bin/xcrun --find clang)"
SDKROOT="$(/usr/bin/xcrun --show-sdk-path)"
"${CLANG}" -fobjc-arc -fblocks -arch arm64 -isysroot "${SDKROOT}" \
    -mmacosx-version-min=15.0 -framework Cocoa \
    "${SCRIPT_DIR}/SidebarHarness.m" -o "${EXECUTABLE}"
/usr/bin/codesign --force --deep --sign - "${APP_DIR}"
/bin/rm -f "${RESULT}"
"${EXECUTABLE}"
[[ -f "${RESULT}" ]] || {
    echo "ERROR: the harness produced no result. / el harness no produjo resultado." >&2
    exit 4
}
/bin/cat "${RESULT}"
/usr/bin/grep -Fq 'status=0 SIDEBAR_HARNESS_OK' "${RESULT}"
