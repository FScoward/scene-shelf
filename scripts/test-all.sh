#!/usr/bin/env bash

set -u -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${REPO_ROOT}/.build"
MODULE_CACHE="${BUILD_ROOT}/module-cache-test-all"
SWIFT_MODULE_CACHE="${BUILD_ROOT}/swift-module-cache-test-all"
SCRATCH_PATH="${REPO_ROOT}/.build-spm-test-all"

RUNNERS=(
    SceneShelfCoreTestRunner
    SceneShelfAXTestRunner
    SceneShelfRoundTripTestRunner
    SceneShelfP0FourTestRunner
    SceneShelfPresentationTestRunner
    SceneShelfPersistenceTestRunner
    SceneShelfManagementTestRunner
    SceneShelfSwitchingTestRunner
)

mkdir -p "${MODULE_CACHE}" "${SWIFT_MODULE_CACHE}" "${SCRATCH_PATH}"
export CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULE_CACHE}"

cd "${REPO_ROOT}"

if ! swift build \
    --disable-sandbox \
    --scratch-path "${SCRATCH_PATH}" \
    -Xswiftc -strict-concurrency=complete; then
    printf 'SceneShelf test-all: build failed\n' >&2
    exit 1
fi

BIN_PATH="$(swift build \
    --disable-sandbox \
    --scratch-path "${SCRATCH_PATH}" \
    --show-bin-path)"

failed=()
for runner in "${RUNNERS[@]}"; do
    printf '\n=== %s ===\n' "${runner}"
    if "${BIN_PATH}/${runner}"; then
        printf 'RESULT: PASS (%s)\n' "${runner}"
    else
        printf 'RESULT: FAIL (%s)\n' "${runner}" >&2
        failed+=("${runner}")
    fi
done

if ((${#failed[@]} == 0)); then
    printf '\nSceneShelf test-all: PASS (%d runners)\n' "${#RUNNERS[@]}"
    exit 0
fi

printf '\nSceneShelf test-all: FAIL (%d/%d runners)\n' "${#failed[@]}" "${#RUNNERS[@]}" >&2
printf 'Failed runners: %s\n' "${failed[*]}" >&2
exit 1
