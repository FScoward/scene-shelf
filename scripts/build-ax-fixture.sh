#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${REPO_ROOT}/.build"
MODULE_CACHE="${BUILD_ROOT}/module-cache-ax-fixture"
SCRATCH_PATH="${REPO_ROOT}/.build-spm-ax-fixture"
APP_PATH="${BUILD_ROOT}/SceneShelfAXFixture.app"

mkdir -p "${MODULE_CACHE}" "${SCRATCH_PATH}"
export CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}"

cd "${REPO_ROOT}"
swift build \
    -c release \
    --disable-sandbox \
    --scratch-path "${SCRATCH_PATH}" \
    --product SceneShelfAXFixture \
    -Xswiftc -strict-concurrency=complete
BIN_PATH="$(swift build \
    -c release \
    --disable-sandbox \
    --scratch-path "${SCRATCH_PATH}" \
    --product SceneShelfAXFixture \
    --show-bin-path)"

rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/Resources"
cp "${BIN_PATH}/SceneShelfAXFixture" "${APP_PATH}/Contents/MacOS/SceneShelfAXFixture"
cp "${REPO_ROOT}/Resources/AXFixture-Info.plist" "${APP_PATH}/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "${APP_PATH}" >/dev/null
fi

printf 'Built %s\n' "${APP_PATH}"
