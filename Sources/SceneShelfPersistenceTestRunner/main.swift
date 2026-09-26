import Foundation
import SceneShelfCore

@main
@MainActor
struct SceneShelfPersistenceTestRunner {
    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static let fileManager = FileManager.default

    static func main() async throws {
        try await testEmptyStoreDoesNotCreateFiles()
        try await testMissingIndexSurfacesOrphanRevision()
        try await testSaveReloadPreservesOrderAndFields()
        try await testReloadAllocatesNonCollidingSceneID()
        try await testCorruptIndexFailsClosedAndPreservesOriginal()
        try await testUnsupportedIndexVersionFailsClosed()
        try await testSaveIsRejectedAfterLoadFailure()
        try await testAtomicCommitLeavesIndexAndRevision()
        try await testCorruptRevisionIsExcludedWithDiagnostic()
        try await testSaveAfterCorruptRevisionPreservesIndexAndAvoidsIDCollision()
        try await testOrphanRevisionSkipsIDsForSaveAndDuplicate()
        try await testMissingRevisionIsExcludedWithDiagnostic()
        try await testUnsupportedRevisionIsExcludedWithDiagnostic()
        try await testEmptyWindowsRevisionIsExcludedWithDiagnostic()
        try await testDuplicateIdentityRevisionIsExcludedWithDiagnostic()
        try await testInvalidIndexEntriesFailClosed()
        try testCleanupMatchesExactRevisionSceneID()
        try testAllocationOverflowFailsClosed()
        try testCommitRejectsInvalidWindowPayloads()
        try await testLoadValidationFailurePreservesExistingState()
        try await testOrphanScanFailureFailsClosed()
        try await testSaveAndDuplicateOverflowFailBeforeCommit()
        try await testRetryLoadAfterExternalRepair()
        try await testPreRenameDurabilityFailurePreservesOldState()
        try await testPostRenameDurabilityFailurePublishesNewState()
        try await testApplicationSupportInitializationFailureFailsClosed()
        try testProcessLockRejectsIndependentSecondAcquisitionAndReleases()
        try await testProcessLockDoesNotInterfereWithPersistenceFiles()
        print("SceneShelfPersistenceTestRunner: PASS (28 tests)")
    }

    private static func testEmptyStoreDoesNotCreateFiles() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }

        let persistence = SceneShelfPersistence(rootURL: root)
        let result = try persistence.load()

        try expect(result.scenes.isEmpty, "empty load should have no scenes")
        try expect(result.indexEntries.isEmpty, "empty load should have no index entries")
        try expect(result.diagnostics.isEmpty, "empty load should have no diagnostics")
        try expect(!fileManager.fileExists(atPath: root.appendingPathComponent("index.json").path), "empty load must not create index.json")
    }

    private static func testMissingIndexSurfacesOrphanRevision() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }

        let store = try await persistedStore(at: root)
        let saved = try await store.save(
            name: "index commit前のrevision",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        let indexURL = root.appendingPathComponent("index.json")
        try fileManager.removeItem(at: indexURL)

        let result = try SceneShelfPersistence(rootURL: root).load()
        try expect(result.scenes.isEmpty, "missing index must not publish orphan scenes")
        try expect(result.indexEntries.isEmpty, "missing index must return no index entries")
        try expect(
            result.diagnostics.contains(where: { diagnostic in
                diagnostic.kind == .orphanRevision && diagnostic.sceneID == saved.id
            }),
            "missing index must diagnose revision files as orphan revisions"
        )
    }

    private static func testSaveReloadPreservesOrderAndFields() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }

        let store = InMemorySceneStore(persistence: SceneShelfPersistence(rootURL: root))
        _ = try await store.loadPersisted()
        let first = try await store.save(
            name: "最初の配置",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        let second = try await store.save(
            name: "二番目の配置",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[1].identity])
        )

        let reloaded = InMemorySceneStore(persistence: SceneShelfPersistence(rootURL: root))
        let result = try await reloaded.loadPersisted()

        try expect(result.scenes == [first, second], "reload should preserve scene order and all fields")
        let reloadedScenes = await reloaded.scenes()
        try expect(reloadedScenes == [first, second], "store should expose reloaded order")
    }

    private static func testReloadAllocatesNonCollidingSceneID() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }

        let firstStore = InMemorySceneStore(persistence: SceneShelfPersistence(rootURL: root))
        _ = try await firstStore.loadPersisted()
        let first = try await firstStore.save(
            name: "再起動前",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )

        let restartedStore = InMemorySceneStore(persistence: SceneShelfPersistence(rootURL: root))
        _ = try await restartedStore.loadPersisted()
        let second = try await restartedStore.save(
            name: "再起動後",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[1].identity])
        )

        try expect(first.id != second.id, "restart save must not reuse scene ID")
        try expect(second.id == "scene-2", "restart save should continue scene numbering")
        let restartedScenes = await restartedStore.scenes()
        try expect(restartedScenes.map { $0.id } == ["scene-1", "scene-2"], "restart order should remain stable")
    }

    private static func testCorruptIndexFailsClosedAndPreservesOriginal() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }

        let store = try await persistedStore(at: root)
        _ = try await store.save(
            name: "保持対象",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        let indexURL = root.appendingPathComponent("index.json")
        let corruptBytes = Data("{not-json".utf8)
        try corruptBytes.write(to: indexURL)

        let before = try Data(contentsOf: indexURL)
        let reloaded = InMemorySceneStore(persistence: SceneShelfPersistence(rootURL: root))
        do {
            _ = try await reloaded.loadPersisted()
            throw TestFailure(description: "corrupt index unexpectedly loaded")
        } catch let error as ScenePersistenceError {
            guard case .corruptIndex = error else {
                throw TestFailure(description: "unexpected corrupt index error: \(error)")
            }
        }
        try expect(try Data(contentsOf: indexURL) == before, "corrupt index must remain untouched")
    }

    private static func testUnsupportedIndexVersionFailsClosed() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }

        let store = try await persistedStore(at: root)
        _ = try await store.save(
            name: "version",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        let indexURL = root.appendingPathComponent("index.json")
        var object = try jsonObject(at: indexURL)
        object["schemaVersion"] = 999
        try writeJSON(object, to: indexURL)

        let reloaded = InMemorySceneStore(persistence: SceneShelfPersistence(rootURL: root))
        do {
            _ = try await reloaded.loadPersisted()
            throw TestFailure(description: "unsupported index version unexpectedly loaded")
        } catch let error as ScenePersistenceError {
            guard case .unsupportedIndexVersion(999) = error else {
                throw TestFailure(description: "unexpected unsupported version error: \(error)")
            }
        }
    }

    private static func testSaveIsRejectedAfterLoadFailure() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }

        let store = try await persistedStore(at: root)
        _ = try await store.save(
            name: "壊れたindex",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        let indexURL = root.appendingPathComponent("index.json")
        try Data("broken".utf8).write(to: indexURL)
        let before = try Data(contentsOf: indexURL)

        let reloaded = InMemorySceneStore(persistence: SceneShelfPersistence(rootURL: root))
        do {
            _ = try await reloaded.loadPersisted()
        } catch {
            // The next save assertion verifies the store remembers this failure.
        }
        do {
            _ = try await reloaded.save(
                name: "保存してはいけない",
                candidates: fixtureWindows(),
                selectedIDs: Set([fixtureWindows()[0].identity])
            )
            throw TestFailure(description: "save unexpectedly succeeded after load failure")
        } catch let error as ScenePersistenceError {
            guard case .saveRejectedAfterLoadFailure = error else {
                throw TestFailure(description: "unexpected post-load-failure error: \(error)")
            }
        }
        try expect(try Data(contentsOf: indexURL) == before, "rejected save must not overwrite index")
    }

    private static func testAtomicCommitLeavesIndexAndRevision() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }

        let store = try await persistedStore(at: root)
        let saved = try await store.save(
            name: "原子的保存",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )

        let indexURL = root.appendingPathComponent("index.json")
        let revisionDirectory = root.appendingPathComponent("scenes", isDirectory: true)
        let revisionFiles = try fileManager.contentsOfDirectory(at: revisionDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let temporaryFiles = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".tmp") }

        try expect(fileManager.fileExists(atPath: indexURL.path), "atomic commit must publish index")
        try expect(revisionFiles.count == 1, "atomic commit must publish one immutable revision")
        try expect(revisionFiles[0].lastPathComponent.contains(saved.id), "revision file should identify scene")
        try expect(temporaryFiles.isEmpty, "atomic commit must not leave temporary files")
    }

    private static func testCorruptRevisionIsExcludedWithDiagnostic() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }

        let store = try await persistedStore(at: root)
        let first = try await store.save(
            name: "壊れる配置",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        let second = try await store.save(
            name: "残る配置",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[1].identity])
        )
        let index = try SceneShelfPersistence(rootURL: root).load()
        guard let brokenEntry = index.indexEntries.first(where: { $0.sceneID == first.id }) else {
            throw TestFailure(description: "missing first index entry")
        }
        let brokenURL = root.appendingPathComponent("scenes", isDirectory: true)
            .appendingPathComponent("\(brokenEntry.sceneID)-\(brokenEntry.revision).json")
        let corruptBytes = Data("{broken-revision".utf8)
        try corruptBytes.write(to: brokenURL)

        let reloaded = InMemorySceneStore(persistence: SceneShelfPersistence(rootURL: root))
        let result = try await reloaded.loadPersisted()

        try expect(result.scenes == [second], "corrupt revision should be excluded while good scenes load")
        try expect(!result.diagnostics.isEmpty, "corrupt revision should produce a diagnostic")
        try expect(try Data(contentsOf: brokenURL) == corruptBytes, "corrupt revision must remain untouched")
    }

    private static func testMissingRevisionIsExcludedWithDiagnostic() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }

        let store = try await persistedStore(at: root)
        let missing = try await store.save(
            name: "欠落する配置",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        let healthy = try await store.save(
            name: "残る配置",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[1].identity])
        )
        let index = try SceneShelfPersistence(rootURL: root).load()
        guard let missingEntry = index.indexEntries.first(where: { $0.sceneID == missing.id }) else {
            throw TestFailure(description: "missing scene index entry")
        }
        let missingURL = root.appendingPathComponent("scenes", isDirectory: true)
            .appendingPathComponent("\(missingEntry.sceneID)-\(missingEntry.revision).json")
        try fileManager.removeItem(at: missingURL)

        let reloaded = InMemorySceneStore(persistence: SceneShelfPersistence(rootURL: root))
        let result = try await reloaded.loadPersisted()

        try expect(result.scenes == [healthy], "missing revision should be excluded while good scenes load")
        try expect(result.diagnostics.contains(where: { $0.kind == .missingRevision && $0.sceneID == missing.id }), "missing revision should produce a diagnostic")
    }

    private static func testSaveAfterCorruptRevisionPreservesIndexAndAvoidsIDCollision() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }

        let store = try await persistedStore(at: root)
        let healthyFirst = try await store.save(
            name: "保存後も健全な配置1",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        let healthySecond = try await store.save(
            name: "保存後も健全な配置2",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[1].identity])
        )
        let corrupt = try await store.save(
            name: "保存後に壊れる配置",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        let before = try SceneShelfPersistence(rootURL: root).load()
        guard let corruptEntry = before.indexEntries.first(where: { $0.sceneID == corrupt.id }) else {
            throw TestFailure(description: "missing corrupt index entry")
        }
        let corruptURL = root.appendingPathComponent("scenes", isDirectory: true)
            .appendingPathComponent("\(corruptEntry.sceneID)-\(corruptEntry.revision).json")
        let corruptBytes = Data("{corrupt-after-load".utf8)
        try corruptBytes.write(to: corruptURL)

        let reloaded = InMemorySceneStore(persistence: SceneShelfPersistence(rootURL: root))
        _ = try await reloaded.loadPersisted()
        let newScene = try await reloaded.save(
            name: "破損後に追加する配置",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        let after = try SceneShelfPersistence(rootURL: root).load()

        try expect(newScene.id == "scene-4", "new scene ID should account for corrupt index entries")
        try expect(after.indexEntries.contains(where: { $0 == corruptEntry }), "corrupt index entry must remain referenced")
        try expect(after.scenes == [healthyFirst, healthySecond, newScene], "healthy and new scenes should reload after corrupt revision")
        try expect(after.diagnostics.contains(where: { $0.sceneID == corrupt.id && $0.kind == .corruptRevision }), "corrupt revision diagnostic should remain visible")
        try expect(try Data(contentsOf: corruptURL) == corruptBytes, "corrupt revision source must remain untouched")
    }

    private static func testOrphanRevisionSkipsIDsForSaveAndDuplicate() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }

        let seed = try await persistedStore(at: root)
        let healthy = try await seed.save(
            name: "孤児作成前",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )

        let failing = InMemorySceneStore(
            persistence: SceneShelfPersistence(rootURL: root, fault: .indexCommit)
        )
        _ = try await failing.loadPersisted()
        do {
            _ = try await failing.save(
                name: "index commit failure",
                candidates: fixtureWindows(),
                selectedIDs: Set([fixtureWindows()[0].identity])
            )
            throw TestFailure(description: "index commit failure unexpectedly succeeded")
        } catch let error as ScenePersistenceError {
            guard case .atomicWriteFailed = error else {
                throw TestFailure(description: "unexpected orphan setup error: \(error)")
            }
        }
        let orphanURL = root.appendingPathComponent("scenes/scene-2-1.json")
        try expect(fileManager.fileExists(atPath: orphanURL.path), "failed index commit must retain orphan revision")

        let restarted = try await persistedStore(at: root)
        let newScene = try await restarted.save(
            name: "孤児後の新規保存",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        let duplicate = try await restarted.duplicate(sceneID: healthy.id)

        try expect(newScene.id == "scene-3", "save must skip orphan scene IDs")
        try expect(duplicate.id == "scene-4", "duplicate must skip orphan scene IDs")
        let loaded = try SceneShelfPersistence(rootURL: root).load()
        try expect(loaded.scenes.map(\.id) == [healthy.id, newScene.id, duplicate.id], "healthy, new, and duplicate scenes must reload")
        try expect(loaded.diagnostics.contains(where: { $0.kind == .orphanRevision && $0.sceneID == "scene-2" }), "orphan revision must remain diagnosable: \(loaded.diagnostics)")
        try expect(fileManager.fileExists(atPath: orphanURL.path), "orphan revision must not be deleted")
    }

    private static func testUnsupportedRevisionIsExcludedWithDiagnostic() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }

        let store = try await persistedStore(at: root)
        let unsupported = try await store.save(
            name: "未知version配置",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        let healthy = try await store.save(
            name: "読み込み可能な配置",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[1].identity])
        )
        let index = try SceneShelfPersistence(rootURL: root).load()
        guard let unsupportedEntry = index.indexEntries.first(where: { $0.sceneID == unsupported.id }) else {
            throw TestFailure(description: "unsupported scene index entry")
        }
        let revisionURL = root.appendingPathComponent("scenes", isDirectory: true)
            .appendingPathComponent("\(unsupportedEntry.sceneID)-\(unsupportedEntry.revision).json")
        var revisionObject = try jsonObject(at: revisionURL)
        revisionObject["schemaVersion"] = 999
        try writeJSON(revisionObject, to: revisionURL)

        let reloaded = InMemorySceneStore(persistence: SceneShelfPersistence(rootURL: root))
        let result = try await reloaded.loadPersisted()

        try expect(result.scenes == [healthy], "unsupported revision should be excluded while good scenes load")
        try expect(result.diagnostics.contains(where: { $0.kind == .unsupportedRevisionVersion && $0.sceneID == unsupported.id }), "unsupported revision should produce a diagnostic")
    }

    private static func testEmptyWindowsRevisionIsExcludedWithDiagnostic() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }

        let store = try await persistedStore(at: root)
        let invalid = try await store.save(
            name: "空のwindows",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        let healthy = try await store.save(
            name: "意味的に有効",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[1].identity])
        )
        let index = try SceneShelfPersistence(rootURL: root).load()
        guard let entry = index.indexEntries.first(where: { $0.sceneID == invalid.id }) else {
            throw TestFailure(description: "missing empty-windows entry")
        }
        let revisionURL = root.appendingPathComponent("scenes", isDirectory: true)
            .appendingPathComponent("\(entry.sceneID)-\(entry.revision).json")
        var object = try jsonObject(at: revisionURL)
        object["windows"] = []
        try writeJSON(object, to: revisionURL)

        let reloaded = InMemorySceneStore(persistence: SceneShelfPersistence(rootURL: root))
        let result = try await reloaded.loadPersisted()
        try expect(result.scenes == [healthy], "empty windows revision must be excluded")
        try expect(result.diagnostics.contains(where: { $0.kind == .invalidRevision && $0.sceneID == invalid.id }), "empty windows must produce invalid revision diagnostic")
    }

    private static func testDuplicateIdentityRevisionIsExcludedWithDiagnostic() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = try await persistedStore(at: root)
        let invalid = try await store.save(
            name: "重複identity",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        let healthy = try await store.save(
            name: "健全identity",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[1].identity])
        )
        let index = try SceneShelfPersistence(rootURL: root).load()
        guard let entry = index.indexEntries.first(where: { $0.sceneID == invalid.id }) else {
            throw TestFailure(description: "missing duplicate-identity entry")
        }
        let revisionURL = root.appendingPathComponent("scenes", isDirectory: true)
            .appendingPathComponent("\(entry.sceneID)-\(entry.revision).json")
        var object = try jsonObject(at: revisionURL)
        guard let windows = object["windows"] as? [[String: Any]], let first = windows.first else {
            throw TestFailure(description: "missing revision windows")
        }
        object["windows"] = [first, first]
        try writeJSON(object, to: revisionURL)

        let reloaded = InMemorySceneStore(persistence: SceneShelfPersistence(rootURL: root))
        let result = try await reloaded.loadPersisted()
        try expect(result.scenes == [healthy], "duplicate identity revision must be excluded")
        try expect(result.diagnostics.contains(where: { $0.kind == .invalidRevision && $0.sceneID == invalid.id }), "duplicate identity must produce invalid revision diagnostic")
        let outcome = await reloaded.clickDetailed(sceneID: invalid.id) { plan in
            SceneRestoreReport.assuming(plan: plan, succeeded: true)
        }
        try expect(outcome == .sceneNotFound(sceneID: invalid.id), "excluded revision must not create a restore write plan")
    }

    private static func testInvalidIndexEntriesFailClosed() async throws {
        let cases: [([[String: Any]], String)] = [
            ([
                ["sceneID": "scene-1", "revision": 1, "name": "A", "order": 0],
                ["sceneID": "scene-1", "revision": 2, "name": "B", "order": 1]
            ], "duplicate scene ID"),
            ([
                ["sceneID": "scene-1", "revision": 1, "name": "A", "order": 0],
                ["sceneID": "scene-2", "revision": 1, "name": "B", "order": 0]
            ], "duplicate order"),
            ([["sceneID": "scene-1", "revision": 0, "name": "A", "order": 0]], "non-positive revision"),
            ([["sceneID": "scene-1", "revision": 1, "name": "A", "order": Int.max]], "maximum order"),
            ([["sceneID": "scene/bad", "revision": 1, "name": "A", "order": 0]], "slash path separator scene ID"),
            ([["sceneID": "scene\\bad", "revision": 1, "name": "A", "order": 0]], "backslash path separator scene ID")
        ]

        for (entries, label) in cases {
            let root = try makeTemporaryRoot()
            defer { removeTemporaryRoot(root) }
            let object: [String: Any] = ["schemaVersion": 1, "entries": entries]
            try writeJSON(object, to: root.appendingPathComponent("index.json"))
            do {
                _ = try SceneShelfPersistence(rootURL: root).load()
                throw TestFailure(description: "invalid index unexpectedly loaded: \(label)")
            } catch let error as ScenePersistenceError {
                guard case .invalidIndex = error else {
                    throw TestFailure(description: "unexpected error for \(label): \(error)")
                }
            }
        }
    }

    private static func testCleanupMatchesExactRevisionSceneID() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let scenesDirectory = root.appendingPathComponent("scenes", isDirectory: true)
        try fileManager.createDirectory(at: scenesDirectory, withIntermediateDirectories: true)
        let exact = scenesDirectory.appendingPathComponent("foo-1.json")
        let prefixed = scenesDirectory.appendingPathComponent("foo-bar-1.json")
        try Data("exact".utf8).write(to: exact)
        try Data("prefixed".utf8).write(to: prefixed)

        try SceneShelfPersistence(rootURL: root).cleanupRevisions(for: "foo")

        try expect(!fileManager.fileExists(atPath: exact.path), "cleanup should remove exact scene revision")
        try expect(fileManager.fileExists(atPath: prefixed.path), "cleanup must not remove a prefixed scene revision")
    }

    private static func testAllocationOverflowFailsClosed() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let persistence = SceneShelfPersistence(rootURL: root)

        try expectThrowsPersistenceError {
            _ = try persistence.nextAvailableRevision(sceneID: "scene-1", after: Int.max)
        }
        let scenesDirectory = root.appendingPathComponent("scenes", isDirectory: true)
        try fileManager.createDirectory(at: scenesDirectory, withIntermediateDirectories: true)
        try Data().write(to: scenesDirectory.appendingPathComponent("scene-1-\(Int.max).json"))
        try expectThrowsPersistenceError {
            _ = try persistence.nextAvailableRevision(sceneID: "scene-1", after: 0)
        }
        try expectThrowsPersistenceError {
            _ = try persistence.nextAvailableSceneNumber(after: Int.max)
        }
    }

    private static func testCommitRejectsInvalidWindowPayloads() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let entry = ScenePersistenceIndexEntry(sceneID: "scene-1", revision: 1, name: "配置", order: 0)
        let persistence = SceneShelfPersistence(rootURL: root)
        let windows = fixtureWindows()
        let empty = SavedScene(id: entry.sceneID, name: entry.name, windows: [])
        let duplicate = SavedScene(id: entry.sceneID, name: entry.name, windows: [windows[0], windows[0]])

        try expectThrowsPersistenceError {
            try persistence.commit(scene: empty, revision: entry.revision, indexEntries: [entry])
        }
        try expectThrowsPersistenceError {
            try persistence.commit(scene: duplicate, revision: entry.revision, indexEntries: [entry])
        }
        try expect(!fileManager.fileExists(atPath: root.appendingPathComponent("index.json").path), "invalid revision payload must not publish index")
    }

    private static func testLoadValidationFailurePreservesExistingState() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let seed = try await persistedStore(at: root)
        let healthy = try await seed.save(
            name: "保持する配置",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        let store = InMemorySceneStore(persistence: SceneShelfPersistence(rootURL: root))
        _ = try await store.loadPersisted()
        let before = await store.scenes()
        try expect(before == [healthy], "validation setup should load healthy scene")

        let indexObject: [String: Any] = [
            "schemaVersion": 1,
            "entries": [[
                "sceneID": "scene-\(Int.max)",
                "revision": 1,
                "name": "overflow",
                "order": 0
            ]]
        ]
        try writeJSON(indexObject, to: root.appendingPathComponent("index.json"))

        do {
            _ = try await store.loadPersisted()
            throw TestFailure(description: "scene number overflow unexpectedly loaded")
        } catch let error as ScenePersistenceError {
            try expect(error == .atomicWriteFailed, "scene number overflow should fail closed")
        }
        let after = await store.scenes()
        try expect(after == before, "load validation failure must preserve actor scenes")
    }

    private static func testOrphanScanFailureFailsClosed() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let seed = try await persistedStore(at: root)
        _ = try await seed.save(
            name: "scan failure",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        do {
            _ = try SceneShelfPersistence(rootURL: root, fault: .orphanScan).load()
            throw TestFailure(description: "orphan scan failure unexpectedly loaded")
        } catch let error as ScenePersistenceError {
            try expect(error == .atomicWriteFailed, "orphan scan failure should fail closed")
        }
    }

    private static func testSaveAndDuplicateOverflowFailBeforeCommit() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let seed = try await persistedStore(at: root)
        let original = try await seed.save(
            name: "最大値直前",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        let indexURL = root.appendingPathComponent("index.json")
        var indexObject = try jsonObject(at: indexURL)
        guard var entries = indexObject["entries"] as? [[String: Any]],
              var entry = entries.first else {
            throw TestFailure(description: "missing overflow setup index entry")
        }
        let oldRevisionURL = root.appendingPathComponent("scenes", isDirectory: true)
            .appendingPathComponent("\(original.id)-1.json")
        var revisionObject = try jsonObject(at: oldRevisionURL)
        let maximumSceneID = "scene-\(Int.max - 1)"
        entry["sceneID"] = maximumSceneID
        revisionObject["sceneID"] = maximumSceneID
        let newRevisionURL = root.appendingPathComponent("scenes", isDirectory: true)
            .appendingPathComponent("\(maximumSceneID)-1.json")
        try writeJSON(revisionObject, to: newRevisionURL)
        try fileManager.removeItem(at: oldRevisionURL)
        entries[0] = entry
        indexObject["entries"] = entries
        try writeJSON(indexObject, to: indexURL)

        let store = InMemorySceneStore(persistence: SceneShelfPersistence(rootURL: root))
        _ = try await store.loadPersisted()
        let beforeIndex = try Data(contentsOf: indexURL)
        do {
            _ = try await store.save(
                name: "保存してはいけない",
                candidates: fixtureWindows(),
                selectedIDs: Set([fixtureWindows()[0].identity])
            )
            throw TestFailure(description: "save overflow unexpectedly succeeded")
        } catch let error as ScenePersistenceError {
            try expect(error == .atomicWriteFailed, "save overflow should fail before commit")
        }
        do {
            _ = try await store.duplicate(sceneID: maximumSceneID)
            throw TestFailure(description: "duplicate overflow unexpectedly succeeded")
        } catch let error as ScenePersistenceError {
            try expect(error == .atomicWriteFailed, "duplicate overflow should fail before commit")
        }
        try expect(try Data(contentsOf: indexURL) == beforeIndex, "overflow rejection must not alter index")
        let scenes = await store.scenes()
        try expect(scenes.count == 1 && scenes[0].id == maximumSceneID, "overflow rejection must not alter memory")
    }

    private static func testRetryLoadAfterExternalRepair() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let seed = try await persistedStore(at: root)
        let saved = try await seed.save(
            name: "修復後に再読込",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        let indexURL = root.appendingPathComponent("index.json")
        let originalIndex = try Data(contentsOf: indexURL)
        try Data("broken".utf8).write(to: indexURL)
        let store = InMemorySceneStore(persistence: SceneShelfPersistence(rootURL: root))
        do {
            _ = try await store.loadPersisted()
            throw TestFailure(description: "broken index unexpectedly loaded")
        } catch let error as ScenePersistenceError {
            try expect(error == .corruptIndex, "broken index should be remembered as transient load failure")
        }
        try originalIndex.write(to: indexURL)
        do {
            _ = try await store.loadPersisted()
            throw TestFailure(description: "normal load should remain fail closed before retry")
        } catch let error as ScenePersistenceError {
            try expect(error == .corruptIndex, "normal load must retain fail-closed state")
        }
        let result = try await store.retryLoadPersisted()
        try expect(result.scenes == [saved], "retry should load externally repaired index")
        let loadedScenes = await store.scenes()
        try expect(loadedScenes == [saved], "retry should publish repaired scene state")
    }

    private static func testPreRenameDurabilityFailurePreservesOldState() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let seed = try await persistedStore(at: root)
        let scene = try await seed.save(
            name: "rename前の配置",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        let indexURL = root.appendingPathComponent("index.json")
        let beforeIndex = try Data(contentsOf: indexURL)

        let failingStore = InMemorySceneStore(
            persistence: SceneShelfPersistence(rootURL: root, fault: .preRenameDurability)
        )
        _ = try await failingStore.loadPersisted()
        let beforeMemory = await failingStore.scenes()

        do {
            _ = try await failingStore.rename(sceneID: scene.id, name: "公開されない名前")
            throw TestFailure(description: "pre-rename durability failure unexpectedly succeeded")
        } catch let error as ScenePersistenceError {
            try expect(error == .atomicWriteFailed, "pre-rename durability failure should throw")
        }

        try expect(
            try Data(contentsOf: indexURL) == beforeIndex,
            "pre-rename durability failure must preserve the old index"
        )
        let afterMemory = await failingStore.scenes()
        try expect(
            afterMemory == beforeMemory,
            "pre-rename durability failure must preserve actor memory"
        )
    }

    private static func testPostRenameDurabilityFailurePublishesNewState() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let seed = try await persistedStore(at: root)
        let scene = try await seed.save(
            name: "rename後の配置",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )
        let indexURL = root.appendingPathComponent("index.json")
        let beforeIndex = try Data(contentsOf: indexURL)

        let publishingStore = InMemorySceneStore(
            persistence: SceneShelfPersistence(rootURL: root, fault: .postRenameDurability)
        )
        _ = try await publishingStore.loadPersisted()

        let renamed = try await publishingStore.rename(sceneID: scene.id, name: "公開された名前")
        try expect(renamed.name == "公開された名前", "post-rename durability failure should publish the new name")
        try expect(
            try Data(contentsOf: indexURL) != beforeIndex,
            "post-rename durability failure should leave the new index on disk"
        )
        let memory = await publishingStore.scenes()
        try expect(memory.first?.name == "公開された名前", "post-rename durability failure should update actor memory")

        let reloaded = InMemorySceneStore(persistence: SceneShelfPersistence(rootURL: root))
        let result = try await reloaded.loadPersisted()
        try expect(result.scenes.first?.name == "公開された名前", "published index should reload with the new name")
    }

    private static func testApplicationSupportInitializationFailureFailsClosed() async throws {
        let store = InMemorySceneStore(
            persistenceInitializationFailure: .applicationSupportUnavailable
        )

        do {
            _ = try await store.loadPersisted()
            throw TestFailure(description: "Application Support initialization failure unexpectedly loaded")
        } catch let error as ScenePersistenceError {
            guard case .applicationSupportUnavailable = error else {
                throw TestFailure(description: "unexpected initialization error: \(error)")
            }
        }

        do {
            _ = try await store.save(
                name: "保存してはいけない",
                candidates: fixtureWindows(),
                selectedIDs: Set([fixtureWindows()[0].identity])
            )
            throw TestFailure(description: "save unexpectedly succeeded after initialization failure")
        } catch let error as ScenePersistenceError {
            guard case .saveRejectedAfterLoadFailure = error else {
                throw TestFailure(description: "unexpected post-initialization save error: \(error)")
            }
        }
        let scenes = await store.scenes()
        try expect(scenes.isEmpty, "failed initialization must not retain an in-memory scene")
    }

    private static func testProcessLockRejectsIndependentSecondAcquisitionAndReleases() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let lockURL = root.appendingPathComponent(".instance.lock", isDirectory: false)

        let firstOwner = try SceneShelfInstanceLock.acquire(at: lockURL)
        defer { firstOwner.release() }
        try expect(
            fileManager.fileExists(atPath: lockURL.path),
            "process lock should create a dedicated lock file"
        )

        do {
            _ = try SceneShelfInstanceLock.acquire(at: lockURL)
            throw TestFailure(description: "independent second process lock unexpectedly succeeded")
        } catch let error as SceneShelfInstanceLockError {
            try expect(
                error == .alreadyRunning,
                "independent second open FD should be rejected as already running"
            )
            try expect(
                error.japaneseLabel.contains("別のScene Shelfが起動中"),
                "already-running failure should provide Japanese startup guidance"
            )
        }

        firstOwner.release()
        let secondOwner = try SceneShelfInstanceLock.acquire(at: lockURL)
        secondOwner.release()
    }

    private static func testProcessLockDoesNotInterfereWithPersistenceFiles() async throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let lockURL = root.appendingPathComponent(".instance.lock", isDirectory: false)
        let owner = try SceneShelfInstanceLock.acquire(at: lockURL)
        defer { owner.release() }

        let store = try await persistedStore(at: root)
        _ = try await store.save(
            name: "ロック中の保存",
            candidates: fixtureWindows(),
            selectedIDs: Set([fixtureWindows()[0].identity])
        )

        let indexURL = root.appendingPathComponent("index.json", isDirectory: false)
        try expect(
            fileManager.fileExists(atPath: indexURL.path),
            "JSON persistence should remain writable while the process lock is held"
        )
        let loaded = try SceneShelfPersistence(rootURL: root).load()
        try expect(
            loaded.scenes.first?.name == "ロック中の保存",
            "JSON persistence should ignore the separate lock file"
        )
    }

    private static func persistedStore(at root: URL) async throws -> InMemorySceneStore {
        let store = InMemorySceneStore(persistence: SceneShelfPersistence(rootURL: root))
        _ = try await store.loadPersisted()
        return store
    }

    private static func fixtureWindows() -> [SceneWindowSnapshot] {
        [
            SceneWindowSnapshot(
                identity: SceneWindowIdentity(
                    bundleIdentifier: "com.example.fixture",
                    processID: 101,
                    title: "Main",
                    identifier: "main"
                ),
                frame: SceneFrame(x: 10, y: 20, width: 800, height: 600),
                isMinimized: false
            ),
            SceneWindowSnapshot(
                identity: SceneWindowIdentity(
                    bundleIdentifier: "com.example.fixture",
                    processID: 101,
                    title: "Secondary",
                    identifier: "secondary"
                ),
                frame: SceneFrame(x: 40, y: 50, width: 500, height: 400),
                isMinimized: true
            )
        ]
    }

    private static func makeTemporaryRoot() throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("scene-shelf-persistence-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func removeTemporaryRoot(_ root: URL) {
        try? fileManager.removeItem(at: root)
    }

    private static func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure(description: "expected JSON object at \(url.path)")
        }
        return object
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url)
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw TestFailure(description: message)
        }
    }

    private static func expectThrowsPersistenceError(
        _ operation: () throws -> Void
    ) throws {
        do {
            try operation()
            throw TestFailure(description: "expected persistence error")
        } catch is ScenePersistenceError {
            return
        }
    }
}
