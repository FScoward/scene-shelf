# DR-020: QG Round2 AX/UI failure boundaries

## Metadata

- Phase: Phase 1 / Mihari Agent Z Round2
- Kind: 品質ゲート修正（Decision D20）
- Scope: `ShelfViewModel` saved-scene deletion, AX fake side effects, runner/evidence counts, Japanese reason presentation
- Reversible: local code, tests, and evidence only; no app launch, TCC change, commit, push, or Issue update

## Decision

1. `SceneManagementError.cleanupFailed` is a non-atomic delete result: the scene record is already gone, while obsolete-file cleanup failed. `ShelfViewModel.confirmDelete` keeps the warning and calls `refresh()` so the deleted card is removed from the list.
2. `FakeAXAdapter.apply` returns a success boolean. `move` and `resize` with an unavailable current frame are `operationFailed`; they do not append an applied operation, increment writes, or mutate the snapshot.
3. `SceneShelfAXTestRunner` derives its summary from the number of `run` invocations. Evidence records the executed count instead of a manually maintained literal.
4. `SceneShelfManagementPresentation` and `SceneShelfAXPresentation` are pure value boundaries. The ViewModel delegates Japanese failure messages and cleanup-refresh policy to them; the executable presentation runner covers discovery, save, overwrite, restore, and cleanup-failure cases.

## TDD sequence

The Round2 executable cases were added at the boundary first: unavailable-frame move/resize, runtime AX count, cleanup-failure refresh policy, and all three discovery reasons across detect/save/overwrite/restore. The implementation then supplied the Bool-returning fake write boundary and the two pure presentation boundaries. The focused AX and Presentation runners now pass with the counts recorded below.

## Why

- Refresh after cleanup failure reflects store truth and prevents a deleted card from remaining visible as stale UI.
- A nil frame cannot support a reliable move/resize write. Reporting success would make the fake weaker than the production safety contract.
- A runtime-derived count prevents adding a test without updating a second hard-coded number and evidence becoming misleading.
- A pure boundary allows the ViewModel’s user-visible contract to be executed without importing the AppKit-heavy executable target into a test target. Async orchestration remains in the ViewModel.

## Why not

- Do not refresh for every management error: `sceneActive`, `busy`, and validation failures do not imply that the store record was removed.
- Do not make an unavailable frame a zero-sized fallback: that would turn missing geometry into a destructive write.
- Do not claim the fake’s read-back as real AX/TCC evidence. Real AX frame read-back remains a separate manual/integration boundary.
- Do not change `SceneRoundTrip.swift` or `ScenePersistence.swift`; the fix is limited to presentation/orchestration and the AX test fake.

## Executable evidence

- `SceneShelfAXTestRunner: 17 tests passed`
- `SceneShelfPresentationTestRunner: 11 tests passed`
- New AX case: `move and resize with unavailable frame perform zero writes`
- New presentation case: cleanup failure keeps its warning and requests a refresh; non-cleanup failure does not

## Follow-up boundary

The app was not launched in this QG turn. TCC, actual AX frame read-back, real Menu popup behavior, and VoiceOver remain manual/integration evidence.
