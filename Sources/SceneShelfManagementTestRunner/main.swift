import Foundation
import SceneShelfCore

@main
@MainActor
struct SceneShelfManagementTestRunner {
    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static var failures = 0

    static func main() async {
        await run("rename trims and persists metadata") {
            try await testRenameTrimsAndPersistsMetadata()
        }
        await run("rename rejects blank and missing scenes") {
            try await testRenameRejectsBlankAndMissingScenes()
        }
        await run("overwrite creates a revision without changing targets") {
            try await testOverwriteCreatesRevisionWithoutChangingTargets()
        }
        await run("overwrite rejects an incomplete live snapshot without mutation") {
            try await testOverwriteRejectsIncompleteLiveSnapshotWithoutMutation()
        }
        await run("overwrite updates generic application scenes without changing targets") {
            try await testOverwriteUpdatesGenericApplicationSceneWithoutChangingTargets()
        }
        await run("overwrite rejects an ambiguous generic snapshot without mutation") {
            try await testOverwriteRejectsAmbiguousGenericSnapshotWithoutMutation()
        }
        await run("duplicate gets a unique deep-copied stashed scene") {
            try await testDuplicateGetsUniqueDeepCopiedStashedScene()
        }
        await run("delete requires confirmation and protects active scenes") {
            try await testDeleteRequiresConfirmationAndProtectsActiveScenes()
        }
        await run("partially restored scene cannot be deleted") {
            try await testPartiallyRestoredSceneCannotBeDeleted()
        }
        await run("delete keeps index commit when revision cleanup fails") {
            try await testDeleteKeepsIndexCommitWhenRevisionCleanupFails()
        }
        await run("move persists order and rejects edges") {
            try await testMovePersistsOrderAndRejectsEdges()
        }
        await run("management operations reject while restore is busy") {
            try await testManagementOperationsRejectWhileRestoreIsBusy()
        }
        await run("loadPersisted rejects while restore is busy") {
            try await testLoadPersistedRejectsWhileRestoreIsBusy()
        }
        await run("restart reloads management results") {
            try await testRestartReloadsManagementResults()
        }
        await run("persistence failure leaves memory and index unchanged") {
            try await testPersistenceFailureLeavesMemoryAndIndexUnchanged()
        }
        await run("overwrite skips orphan revisions on retry") {
            try await testOverwriteSkipsOrphanRevisionsOnRetry()
        }

        if failures == 0 {
            print("SceneShelfManagementTestRunner: PASS (16 tests)")
        } else {
            print("SceneShelfManagementTestRunner: \(failures) failures")
            Foundation.exit(1)
        }
    }

    private static func testRenameTrimsAndPersistsMetadata() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try await persistedStore(at: root)
        let scene = try await save(store, name: "元の名前", selected: [0])

        let renamed = try await store.rename(sceneID: scene.id, name: "  新しい名前  ")
        try expect(renamed.name == "新しい名前", "rename should trim surrounding whitespace")
        let renamedScenes = await store.scenes()
        try expect(renamedScenes.first?.name == "新しい名前", "actor memory should update after index commit")

        let reloaded = try await persistedStore(at: root)
        let reloadedScenes = await reloaded.scenes()
        try expect(reloadedScenes.first?.name == "新しい名前", "renamed metadata should survive reload")
    }

    private static func testRenameRejectsBlankAndMissingScenes() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try await persistedStore(at: root)
        let scene = try await save(store, name: "保持", selected: [0])
        let before = await store.scenes()

        try await expectManagementError(.emptyName) {
            _ = try await store.rename(sceneID: scene.id, name: " \n\t ")
        }
        try await expectManagementError(.sceneNotFound("missing")) {
            _ = try await store.rename(sceneID: "missing", name: "名前")
        }
        let after = await store.scenes()
        try expect(after == before, "rejected rename must not change memory")
    }

    private static func testOverwriteCreatesRevisionWithoutChangingTargets() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try await persistedStore(at: root)
        let candidates = fixtureWindows()
        let scene = try await save(store, name: "上書き", selected: [0, 1])
        let changed = candidates.map {
            SceneWindowSnapshot(
                identity: $0.identity,
                frame: SceneFrame(x: $0.frame.x + 100, y: $0.frame.y + 50, width: $0.frame.width + 20, height: $0.frame.height + 20),
                isMinimized: !$0.isMinimized
            )
        }

        let overwritten = try await store.overwrite(sceneID: scene.id, candidates: changed)
        try expect(overwritten.id == scene.id, "overwrite must keep scene ID")
        try expect(Set(overwritten.windows.map(\.identity)) == Set(scene.windows.map(\.identity)), "overwrite must preserve target identity set")
        try expect(overwritten.windows != scene.windows, "overwrite should capture changed live frames")

        let loaded = try SceneShelfPersistence(rootURL: root).load()
        let entry = loaded.indexEntries.first { $0.sceneID == scene.id }
        try expect(entry?.revision == 2, "overwrite should commit revision plus one")
        try expect(loaded.scenes.first == overwritten, "current revision should be the overwritten scene")
        try expect(loaded.diagnostics.isEmpty, "historical revisions retained after overwrite are not orphans")
    }

    private static func testOverwriteRejectsIncompleteLiveSnapshotWithoutMutation() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try await persistedStore(at: root)
        let candidates = fixtureWindows()
        let scene = try await save(store, name: "上書き失敗", selected: [0, 1])
        let before = await store.scenes()
        let incomplete = [candidates[0]]

        try await expectManagementError(.targetUnavailable(.windowMissing)) {
            _ = try await store.overwrite(sceneID: scene.id, candidates: incomplete)
        }
        let after = await store.scenes()
        try expect(after == before, "failed overwrite must leave memory unchanged")
        let loaded = try SceneShelfPersistence(rootURL: root).load()
        try expect(loaded.indexEntries.first?.revision == 1, "failed overwrite must keep current revision")
    }

    private static func testOverwriteUpdatesGenericApplicationSceneWithoutChangingTargets() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try await persistedStore(at: root)
        let application = SceneWindowSnapshot(
            identity: SceneWindowIdentity(
                bundleIdentifier: "com.example.Editor",
                processID: 701,
                title: "Draft",
                identifier: "draft"
            ),
            frame: SceneFrame(x: 20, y: 30, width: 640, height: 480),
            isMinimized: false
        )
        let scene = try await store.save(
            name: "一般アプリ配置",
            candidates: [application],
            selectedIDs: [application.identity]
        )
        let changed = SceneWindowSnapshot(
            identity: application.identity,
            frame: SceneFrame(x: 120, y: 140, width: 900, height: 700),
            isMinimized: true
        )

        let overwritten = try await store.overwrite(sceneID: scene.id, candidates: [changed])
        try expect(overwritten.id == scene.id, "generic overwrite must keep scene ID")
        try expect(overwritten.name == scene.name, "generic overwrite must keep scene name")
        try expect(overwritten.windows.map(\.identity) == scene.windows.map(\.identity), "generic overwrite must preserve target identity and order")
        try expect(overwritten.windows.first?.frame == changed.frame, "generic overwrite should capture the live frame")
        try expect(overwritten.windows.first?.isMinimized == changed.isMinimized, "generic overwrite should capture minimized state")

        let loaded = try SceneShelfPersistence(rootURL: root).load()
        try expect(loaded.indexEntries.first?.revision == 2, "generic overwrite should commit revision plus one")
        try expect(loaded.scenes.first == overwritten, "generic overwrite should persist the updated scene")
    }

    private static func testOverwriteRejectsAmbiguousGenericSnapshotWithoutMutation() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try await persistedStore(at: root)
        let application = SceneWindowSnapshot(
            identity: SceneWindowIdentity(
                bundleIdentifier: "com.example.Editor",
                processID: 701,
                title: "Draft",
                identifier: "draft"
            ),
            frame: SceneFrame(x: 20, y: 30, width: 640, height: 480),
            isMinimized: false
        )
        let scene = try await store.save(
            name: "一般アプリ配置",
            candidates: [application],
            selectedIDs: [application.identity]
        )
        let before = await store.scenes()
        let beforeIndex = try Data(contentsOf: root.appendingPathComponent("index.json"))
        let duplicate = SceneWindowSnapshot(
            identity: application.identity,
            frame: SceneFrame(x: 120, y: 140, width: 900, height: 700),
            isMinimized: true
        )

        try await expectManagementError(.targetUnavailable(.ambiguousMatch)) {
            _ = try await store.overwrite(sceneID: scene.id, candidates: [application, duplicate])
        }
        let after = await store.scenes()
        try expect(after == before, "ambiguous generic overwrite must preserve scene memory")
        let afterIndex = try Data(contentsOf: root.appendingPathComponent("index.json"))
        try expect(afterIndex == beforeIndex, "ambiguous generic overwrite must preserve persisted scene")
    }

    private static func testDuplicateGetsUniqueDeepCopiedStashedScene() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try await persistedStore(at: root)
        let original = try await save(store, name: "集中", selected: [0, 1])

        let copy = try await store.duplicate(sceneID: original.id)
        try expect(copy.id != original.id, "duplicate must allocate a new scene ID")
        try expect(copy.name == "集中 のコピー", "duplicate should use the defined copy name")
        try expect(copy.windows == original.windows, "duplicate should deep copy all window snapshots")
        let copyState = await store.state(sceneID: copy.id)
        try expect(copyState == .stashed, "duplicate should start stashed")
        let scenes = await store.scenes()
        try expect(scenes.map(\.id) == [original.id, copy.id], "duplicate should append in order")
    }

    private static func testDeleteRequiresConfirmationAndProtectsActiveScenes() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try await persistedStore(at: root)
        let scene = try await save(store, name: "削除対象", selected: [0])

        try await expectManagementError(.confirmationRequired) {
            try await store.delete(sceneID: scene.id, confirmed: false)
        }
        let afterUnconfirmedDelete = await store.scenes()
        try expect(afterUnconfirmedDelete.count == 1, "unconfirmed delete must keep the scene")

        _ = await store.clickDetailed(sceneID: scene.id) { plan in
            .assuming(plan: plan, succeeded: true)
        }
        try await expectManagementError(.sceneActive(scene.id)) {
            try await store.delete(sceneID: scene.id, confirmed: true)
        }
        _ = await store.clickDetailed(sceneID: scene.id) { plan in
            .assuming(plan: plan, succeeded: true)
        }
        try await store.delete(sceneID: scene.id, confirmed: true)
        let afterDelete = await store.scenes()
        try expect(afterDelete.isEmpty, "confirmed stashed delete should remove scene from memory")
        let deletedIndex = try SceneShelfPersistence(rootURL: root).load()
        try expect(deletedIndex.indexEntries.isEmpty, "delete should remove index entry")

        let failedScene = try await save(store, name: "失敗しても削除可能", selected: [0])
        _ = await store.clickDetailed(sceneID: failedScene.id) { plan in
            .assuming(plan: plan, succeeded: false)
        }
        let failedState = await store.state(sceneID: failedScene.id)
        try expect(failedState == .failed, "failed scene should be deletable")
        try await store.delete(sceneID: failedScene.id, confirmed: true)
        let afterFailedDelete = await store.scenes()
        try expect(afterFailedDelete.isEmpty, "failed scene should be removed after confirmation")
    }

    private static func testPartiallyRestoredSceneCannotBeDeleted() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try await persistedStore(at: root)
        let scene = try await save(store, name: "部分復元中", selected: [0, 1])
        let beforeScenes = await store.scenes()
        let beforeIndex = try Data(contentsOf: root.appendingPathComponent("index.json"))

        _ = await store.clickDetailed(sceneID: scene.id) { plan in
            let outcomes = [
                SceneTargetRestoreOutcome.succeeded(
                    target: plan.instructions[0].target,
                    appliedOperations: plan.instructions[0].operations
                ),
                SceneTargetRestoreOutcome.failed(
                    target: plan.instructions[1].target,
                    reason: .windowMissing
                )
            ]
            return SceneRestoreReport.from(plan: plan, executedOutcomes: outcomes)
        }
        let partialState = await store.state(sceneID: scene.id)
        let partialCurrent = await store.currentSceneID()
        try expect(partialState == .partiallyRestored, "setup should keep a partial scene active")
        try expect(partialCurrent == scene.id, "partial scene should remain current")

        try await expectManagementError(.sceneActive(scene.id)) {
            try await store.delete(sceneID: scene.id, confirmed: true)
        }
        let afterScenes = await store.scenes()
        try expect(afterScenes == beforeScenes, "rejected partial delete must preserve memory")
        let afterIndex = try Data(contentsOf: root.appendingPathComponent("index.json"))
        try expect(afterIndex == beforeIndex, "rejected partial delete must preserve index")
        let afterCurrent = await store.currentSceneID()
        try expect(afterCurrent == scene.id, "rejected partial delete must preserve current scene")
    }

    private static func testMovePersistsOrderAndRejectsEdges() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try await persistedStore(at: root)
        let first = try await save(store, name: "一", selected: [0])
        let second = try await save(store, name: "二", selected: [1])
        let third = try await save(store, name: "三", selected: [0])

        try await expectManagementError(.orderBoundary) {
            try await store.move(sceneID: first.id, direction: .up)
        }
        _ = try await store.move(sceneID: first.id, direction: .down)
        let movedScenes = await store.scenes()
        try expect(movedScenes.map(\.id) == [second.id, first.id, third.id], "move should update adjacent order")
        _ = try await store.move(sceneID: second.id, direction: .down)
        let restoredScenes = await store.scenes()
        try expect(restoredScenes.map(\.id) == [first.id, second.id, third.id], "move down should restore order")
        try await expectManagementError(.orderBoundary) {
            try await store.move(sceneID: third.id, direction: .down)
        }

        let reloaded = try await persistedStore(at: root)
        let reloadedScenes = await reloaded.scenes()
        try expect(reloadedScenes.map(\.id) == [first.id, second.id, third.id], "order should survive reload")

        let singleRoot = try makeTemporaryRoot()
        defer { removeTemporaryRoot(singleRoot) }
        let singleStore = try await persistedStore(at: singleRoot)
        let single = try await save(singleStore, name: "単独", selected: [0])
        try await expectManagementError(.orderBoundary) {
            try await singleStore.move(sceneID: single.id, direction: .up)
        }
        try await expectManagementError(.orderBoundary) {
            try await singleStore.move(sceneID: single.id, direction: .down)
        }
    }

    private static func testDeleteKeepsIndexCommitWhenRevisionCleanupFails() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let seed = try await persistedStore(at: root)
        let scene = try await save(seed, name: "孤児を残す", selected: [0])
        let deletingStore = InMemorySceneStore(
            persistence: SceneShelfPersistence(rootURL: root, fault: .cleanup)
        )
        _ = try await deletingStore.loadPersisted()

        do {
            try await deletingStore.delete(sceneID: scene.id, confirmed: true)
            throw TestFailure(description: "cleanup failure unexpectedly reported success")
        } catch let error as SceneManagementError {
            try expect(error == .cleanupFailed(scene.id), "cleanup failure should be visible to the caller")
        }
        let after = try SceneShelfPersistence(rootURL: root).load()
        try expect(after.indexEntries.isEmpty, "cleanup failure must not roll back index deletion")
        let revisionFiles = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("scenes"),
            includingPropertiesForKeys: nil
        )
        try expect(!revisionFiles.isEmpty, "cleanup failure should leave an orphan revision for diagnosis")
    }

    private static func testManagementOperationsRejectWhileRestoreIsBusy() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try await persistedStore(at: root)
        let scene = try await save(store, name: "busy", selected: [0])
        let gate = Gate()
        let clickTask = Task {
            await store.clickDetailed(sceneID: scene.id) { plan in
                await gate.started()
                await gate.waitUntilReleased()
                return .assuming(plan: plan, succeeded: true)
            }
        }
        await gate.waitForStart()

        let cardsBeforeManagement = await store.cards()
        let scenesBeforeManagement = await store.scenes()
        let indexBeforeManagement = try Data(contentsOf: root.appendingPathComponent("index.json"))
        try await expectManagementError(.busy) {
            _ = try await store.rename(sceneID: scene.id, name: "拒否")
        }
        try await expectManagementError(.busy) {
            _ = try await store.overwrite(sceneID: scene.id, candidates: fixtureWindows())
        }
        try await expectManagementError(.busy) {
            _ = try await store.duplicate(sceneID: scene.id)
        }
        try await expectManagementError(.busy) {
            try await store.delete(sceneID: scene.id, confirmed: true)
        }
        try await expectManagementError(.busy) {
            _ = try await store.move(sceneID: scene.id, direction: .up)
        }
        try await expectManagementError(.busy) {
            _ = try await store.save(
                name: "拒否",
                candidates: fixtureWindows(),
                selectedIDs: [fixtureWindows()[0].identity]
            )
        }
        let cardsAfterManagement = await store.cards()
        let scenesAfterManagement = await store.scenes()
        try expect(cardsAfterManagement == cardsBeforeManagement, "busy management must preserve card states")
        try expect(scenesAfterManagement == scenesBeforeManagement, "busy management must preserve scene memory")
        let indexAfterManagement = try Data(contentsOf: root.appendingPathComponent("index.json"))
        try expect(indexAfterManagement == indexBeforeManagement, "busy management must preserve index")
        await gate.release()
        _ = await clickTask.value
    }

    private static func testLoadPersistedRejectsWhileRestoreIsBusy() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try await persistedStore(at: root)
        let scene = try await save(store, name: "reload busy", selected: [0])
        let gate = Gate()
        let clickTask = Task {
            await store.clickDetailed(sceneID: scene.id) { plan in
                await gate.started()
                await gate.waitUntilReleased()
                return SceneRestoreReport.assuming(plan: plan, succeeded: true)
            }
        }
        await gate.waitForStart()
        let cardsBeforeReload = await store.cards()
        let currentBeforeReload = await store.currentSceneID()
        let reportBeforeReload = await store.report(sceneID: scene.id)
        let indexBeforeReload = try Data(contentsOf: root.appendingPathComponent("index.json"))

        try await expectManagementError(.busy) {
            _ = try await store.loadPersisted()
        }
        let cardsAfterReload = await store.cards()
        let currentAfterReload = await store.currentSceneID()
        let reportAfterReload = await store.report(sceneID: scene.id)
        try expect(cardsAfterReload == cardsBeforeReload, "busy load must preserve restore state")
        try expect(currentAfterReload == currentBeforeReload, "busy load must preserve current scene")
        try expect(reportAfterReload == reportBeforeReload, "busy load must preserve restore report")
        let indexAfterReload = try Data(contentsOf: root.appendingPathComponent("index.json"))
        try expect(indexAfterReload == indexBeforeReload, "busy load must preserve index")
        await gate.release()
        _ = await clickTask.value
    }

    private static func testRestartReloadsManagementResults() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try await persistedStore(at: root)
        let first = try await save(store, name: "A", selected: [0])
        let second = try await save(store, name: "B", selected: [1])
        _ = try await store.rename(sceneID: first.id, name: "A renamed")
        _ = try await store.duplicate(sceneID: second.id)
        _ = try await store.move(sceneID: second.id, direction: .up)

        let reloaded = try await persistedStore(at: root)
        let reloadedScenes = await reloaded.scenes()
        try expect(reloadedScenes.map(\.name) == ["B", "A renamed", "B のコピー"], "restart should reload management metadata")
        try expect(reloadedScenes.map(\.id) == [second.id, first.id, "scene-3"], "restart should preserve IDs and order")
    }

    private static func testPersistenceFailureLeavesMemoryAndIndexUnchanged() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let seed = try await persistedStore(at: root)
        let scene = try await save(seed, name: "保持", selected: [0])
        let beforeIndex = try Data(contentsOf: root.appendingPathComponent("index.json"))
        let failingStore = InMemorySceneStore(
            persistence: SceneShelfPersistence(rootURL: root, fault: .indexCommit)
        )
        _ = try await failingStore.loadPersisted()
        let beforeMemory = await failingStore.scenes()

        do {
            _ = try await failingStore.rename(sceneID: scene.id, name: "変更されない")
            throw TestFailure(description: "rename unexpectedly succeeded")
        } catch let error as ScenePersistenceError {
            try expect(error == .atomicWriteFailed, "index commit failure should be reported")
        }
        let afterMemory = await failingStore.scenes()
        try expect(afterMemory == beforeMemory, "failed persistence must leave actor memory unchanged")
        let afterIndex = try Data(contentsOf: root.appendingPathComponent("index.json"))
        try expect(afterIndex == beforeIndex, "failed persistence must leave index bytes unchanged")

        let live = fixtureWindows()
        do {
            _ = try await failingStore.overwrite(sceneID: scene.id, candidates: live)
            throw TestFailure(description: "overwrite unexpectedly succeeded")
        } catch let error as ScenePersistenceError {
            try expect(error == .atomicWriteFailed, "overwrite index failure should be reported")
        }
        let afterOverwriteMemory = await failingStore.scenes()
        try expect(afterOverwriteMemory == beforeMemory, "failed overwrite must leave actor memory unchanged")
        let afterOverwriteIndex = try Data(contentsOf: root.appendingPathComponent("index.json"))
        try expect(afterOverwriteIndex == beforeIndex, "failed overwrite must leave index bytes unchanged")
    }

    private static func testOverwriteSkipsOrphanRevisionsOnRetry() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let seed = try await persistedStore(at: root)
        let scene = try await save(seed, name: "再試行", selected: [0, 1])
        let failingStore = InMemorySceneStore(
            persistence: SceneShelfPersistence(rootURL: root, fault: .indexCommit)
        )
        _ = try await failingStore.loadPersisted()

        do {
            _ = try await failingStore.overwrite(sceneID: scene.id, candidates: fixtureWindows())
            throw TestFailure(description: "faulted overwrite unexpectedly succeeded")
        } catch let error as ScenePersistenceError {
            try expect(error == .atomicWriteFailed, "faulted overwrite should fail at index commit")
        }

        let scenesDirectory = root.appendingPathComponent("scenes", isDirectory: true)
        let misleadingPrefixFile = scenesDirectory.appendingPathComponent("scene-10-99.json")
        try Data("not a scene revision".utf8).write(to: misleadingPrefixFile)

        let afterFailure = try SceneShelfPersistence(rootURL: root).load()
        try expect(afterFailure.indexEntries.first?.revision == 1, "orphan must not become current after failed overwrite")
        try expect(afterFailure.scenes == [scene], "orphan must not be adopted during reload")

        let retryStore = try await persistedStore(at: root)
        let changed = fixtureWindows().map {
            SceneWindowSnapshot(
                identity: $0.identity,
                frame: SceneFrame(
                    x: $0.frame.x + 40,
                    y: $0.frame.y + 20,
                    width: $0.frame.width + 10,
                    height: $0.frame.height + 10
                ),
                isMinimized: !$0.isMinimized
            )
        }
        let overwritten = try await retryStore.overwrite(sceneID: scene.id, candidates: changed)
        let afterRetry = try SceneShelfPersistence(rootURL: root).load()
        try expect(afterRetry.indexEntries.first?.revision == 3, "retry should skip orphan revision 2 and commit revision 3")
        try expect(afterRetry.scenes == [overwritten], "retry should publish the newly captured scene")
        try expect(overwritten.windows == changed, "retry should update the scene from the live snapshot")
    }

    private static func persistedStore(at root: URL) async throws -> InMemorySceneStore {
        let store = InMemorySceneStore(persistence: SceneShelfPersistence(rootURL: root))
        _ = try await store.loadPersisted()
        return store
    }

    private static func save(
        _ store: InMemorySceneStore,
        name: String,
        selected indices: [Int]
    ) async throws -> SavedScene {
        let candidates = fixtureWindows()
        return try await store.save(
            name: name,
            candidates: candidates,
            selectedIDs: Set(indices.map { candidates[$0].identity })
        )
    }

    private static func fixtureWindows() -> [SceneWindowSnapshot] {
        [
            SceneWindowSnapshot(
                identity: SceneWindowIdentity(
                    bundleIdentifier: SceneMatcher.fixtureBundleIdentifier,
                    processID: 2001,
                    title: "Main",
                    identifier: "main"
                ),
                frame: SceneFrame(x: 100, y: 100, width: 800, height: 600),
                isMinimized: false
            ),
            SceneWindowSnapshot(
                identity: SceneWindowIdentity(
                    bundleIdentifier: SceneMatcher.fixtureBundleIdentifier,
                    processID: 2001,
                    title: "Secondary",
                    identifier: "secondary"
                ),
                frame: SceneFrame(x: 960, y: 100, width: 500, height: 400),
                isMinimized: true
            )
        ]
    }

    private static func expectManagementError(
        _ expected: SceneManagementError,
        _ operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
            throw TestFailure(description: "expected management error \(expected)")
        } catch let error as SceneManagementError {
            try expect(error == expected, "unexpected management error: \(error)")
        }
    }

    private static func run(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            print("PASS: \(name)")
        } catch {
            failures += 1
            print("FAIL: \(name): \(error)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw TestFailure(description: message)
        }
    }

    private static func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneShelfManagement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func removeTemporaryRoot(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor Gate {
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func started() {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForStart() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilReleased() async {
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
