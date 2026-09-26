#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${REPO_ROOT}/.build"
MODULE_CACHE="${BUILD_ROOT}/module-cache"
SCRATCH_PATH="${REPO_ROOT}/.build-spm-app"
APP_PATH="${BUILD_ROOT}/SceneShelf.app"

mkdir -p "${MODULE_CACHE}"
mkdir -p "${SCRATCH_PATH}"

# The installed Command Line Tools do not have a writable shared module cache
# in the sandboxed Codex environment. Keep this build self-contained.
export CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}"

cd "${REPO_ROOT}"
# SwiftPM's subprocess sandbox cannot be applied in the CLT-only Codex
# environment (`sandbox_apply: Operation not permitted`). The build is still
# isolated by its explicit scratch/module-cache paths, so disable only that
# SwiftPM subprocess sandbox boundary.
swift build \
    -c release \
    --disable-sandbox \
    --scratch-path "${SCRATCH_PATH}" \
    -Xswiftc -strict-concurrency=complete
BIN_PATH="$(swift build \
    -c release \
    --disable-sandbox \
    --scratch-path "${SCRATCH_PATH}" \
    --show-bin-path)"

rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/Resources"
cp "${BIN_PATH}/SceneShelf" "${APP_PATH}/Contents/MacOS/SceneShelf"
cp "${REPO_ROOT}/Resources/Info.plist" "${APP_PATH}/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "${APP_PATH}" >/dev/null
fi

printf 'Built %s\n' "${APP_PATH}"
