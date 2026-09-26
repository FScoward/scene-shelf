import Foundation
import SceneShelfCore

@main
@MainActor
struct SceneShelfRoundTripTestRunner {
    private static var failures = 0

    static func main() async {
        await run("capture stores selected fixture windows only") {
            let store = InMemorySceneStore()
            let main = fixtureWindow(id: "main", title: "Scene Shelf AX Fixture - Main")
            let secondary = fixtureWindow(id: "secondary", title: "Scene Shelf AX Fixture - Secondary")
            do {
                _ = try await store.save(
                    name: "開発配置",
                    candidates: [main, secondary],
                    selectedIDs: [main.identity]
                )
                let scenes = await store.scenes()
                expect(scenes.count == 1)
                expect(scenes[0].windows.map(\.identity.identifier) == ["main"])
            } catch {
                fail("selected capture unexpectedly failed: \(error)")
            }
        }

        await run("empty selection is rejected without storing a scene") {
            let store = InMemorySceneStore()
            do {
                _ = try await store.save(
                    name: "空配置",
                    candidates: [fixtureWindow(id: "main", title: "Scene Shelf AX Fixture - Main")],
                    selectedIDs: []
                )
                fail("empty selection was accepted")
            } catch let error as SceneCaptureError {
                expect(error == .emptySelection)
            } catch {
                fail("unexpected error: \(error)")
            }
            let scenes = await store.scenes()
            expect(scenes.isEmpty)
        }

        await run("blank scene name uses the Fixture default") {
            let store = InMemorySceneStore()
            let main = fixtureWindow(id: "main", title: "Scene Shelf AX Fixture - Main")
            do {
                let saved = try await store.save(
                    name: "  \n",
                    candidates: [main],
                    selectedIDs: [main.identity]
                )
                expect(saved.name == SceneCaptureFlow.defaultName)
            } catch {
                fail("blank name unexpectedly failed: \(error)")
            }
        }

        await run("capture rejects duplicate candidates and unregistered selections") {
            let store = InMemorySceneStore()
            let main = fixtureWindow(id: "main", title: "Scene Shelf AX Fixture - Main")
            let duplicate = fixtureWindow(id: "main", title: "Scene Shelf AX Fixture - Main")
            let unregistered = fixtureWindow(id: "ghost", title: "Scene Shelf AX Fixture - Ghost")

            do {
                _ = try await store.save(
                    name: "重複候補",
                    candidates: [main, duplicate],
                    selectedIDs: [main.identity]
                )
                fail("duplicate candidate was accepted")
            } catch let error as SceneCaptureError {
                expect(error == .duplicateWindow)
            } catch {
                fail("unexpected duplicate candidate error: \(error)")
            }

            do {
                _ = try await store.save(
                    name: "未登録選択",
                    candidates: [main],
                    selectedIDs: [unregistered.identity]
                )
                fail("unregistered selection was accepted")
            } catch let error as SceneCaptureError {
                expect(error == .unregisteredWindow)
            } catch {
                fail("unexpected unregistered selection error: \(error)")
            }

            let scenes = await store.scenes()
            expect(scenes.isEmpty)
        }

        await run("nil identifier matching classes stay unique or ambiguous safely") {
            let targetWithoutIdentifier = SceneWindowIdentity(
                bundleIdentifier: SceneMatcher.fixtureBundleIdentifier,
                processID: 101,
                title: "Untitled",
                identifier: nil
            )
            let uniqueNilIdentifier = SceneWindowSnapshot(
                identity: targetWithoutIdentifier,
                frame: SceneFrame(x: 10, y: 20, width: 300, height: 200),
                isMinimized: false
            )
            let duplicateNilIdentifier = SceneWindowSnapshot(
                identity: targetWithoutIdentifier,
                frame: SceneFrame(x: 30, y: 40, width: 300, height: 200),
                isMinimized: false
            )
            let candidateWithIdentifier = SceneWindowSnapshot(
                identity: SceneWindowIdentity(
                    bundleIdentifier: SceneMatcher.fixtureBundleIdentifier,
                    processID: 101,
                    title: "Untitled",
                    identifier: "window"
                ),
                frame: uniqueNilIdentifier.frame,
                isMinimized: false
            )

            if case .matched = SceneMatcher.resolve(
                target: targetWithoutIdentifier,
                candidates: [uniqueNilIdentifier]
            ) {
                expect(true)
            } else {
                fail("a unique nil identifier candidate should match")
            }
            expect(
                SceneMatcher.resolve(
                    target: targetWithoutIdentifier,
                    candidates: [uniqueNilIdentifier, duplicateNilIdentifier]
                ) == .ambiguous
            )
            expect(
                SceneMatcher.resolve(
                    target: targetWithoutIdentifier,
                    candidates: [candidateWithIdentifier]
                ) == .missing
            )
        }

        await run("display plan restores saved frame after unminimize") {
            let scene = SavedScene(
                id: "scene-display",
                name: "表示配置",
                windows: [fixtureWindow(id: "main", title: "Scene Shelf AX Fixture - Main", minimized: true)]
            )
            let plan = SceneRestorePlanner.displayPlan(for: scene)
            expect(plan.action == .display)
            expect(plan.instructions.count == 1)
            expect(plan.instructions[0].operations == [.unminimize, .move, .resize])
            expect(plan.instructions[0].frame == scene.windows[0].frame)
        }

        await run("hide plan minimizes registered windows only") {
            let registered = fixtureWindow(id: "main", title: "Scene Shelf AX Fixture - Main")
            let scene = SavedScene(id: "scene-hide", name: "退避配置", windows: [registered])
            let plan = SceneRestorePlanner.hidePlan(for: scene)
            expect(plan.action == .hide)
            expect(plan.instructions.map(\.target) == [registered.identity])
            expect(plan.instructions[0].operations == [.minimize])
        }

        await run("excluded and unregistered windows produce zero restore writes") {
            let registered = fixtureWindow(id: "main", title: "Scene Shelf AX Fixture - Main")
            let excluded = fixtureWindow(id: "secondary", title: "Scene Shelf AX Fixture - Secondary")
            let scene = SavedScene(id: "scene-only-main", name: "Mainのみ", windows: [registered])
            let executor = RecordingExecutor()
            let displayResult = await executor.execute(SceneRestorePlanner.displayPlan(for: scene))
            expect(displayResult)
            let displayTargets = await executor.executedTargets()
            let displayWrites = await executor.writeCount()
            expect(displayTargets == [registered.identity])
            expect(displayWrites == 3)
            expect(displayTargets.contains(excluded.identity) == false)
            let hideResult = await executor.execute(SceneRestorePlanner.hidePlan(for: scene))
            let totalWrites = await executor.writeCount()
            expect(hideResult)
            expect(totalWrites == 4)
        }

        await run("roundtrip transitions stashed to displayed and back") {
            let store = InMemorySceneStore()
            let main = fixtureWindow(id: "main", title: "Scene Shelf AX Fixture - Main")
            do {
                let saved = try await store.save(
                    name: "往復",
                    candidates: [main],
                    selectedIDs: [main.identity]
                )
                let executor = RecordingExecutor()
                let displayed = await store.click(sceneID: saved.id) { plan in
                    await executor.execute(plan)
                }
                expect(displayed == .displayed(sceneID: saved.id))
                let displayedState = await store.state(sceneID: saved.id)
                expect(displayedState == .displayed)
                let hidden = await store.click(sceneID: saved.id) { plan in
                    await executor.execute(plan)
                }
                expect(hidden == .stashed(sceneID: saved.id))
                let hiddenState = await store.state(sceneID: saved.id)
                let totalWrites = await executor.writeCount()
                expect(hiddenState == .stashed)
                expect(totalWrites == 4)
            } catch {
                fail("roundtrip setup unexpectedly failed: \(error)")
            }
        }

        await run("failed restore keeps the saved scene stashed") {
            let store = InMemorySceneStore()
            let main = fixtureWindow(id: "main", title: "Scene Shelf AX Fixture - Main")
            do {
                let saved = try await store.save(
                    name: "失敗時配置",
                    candidates: [main],
                    selectedIDs: [main.identity]
                )
                let outcome = await store.click(sceneID: saved.id) { _ in false }
                expect(outcome == .operationFailed(sceneID: saved.id))
                let state = await store.state(sceneID: saved.id)
                expect(state == .stashed)
            } catch {
                fail("failed restore setup unexpectedly failed: \(error)")
            }
        }

        if failures == 0 {
            print("SceneShelfRoundTripTestRunner: 10 tests passed")
        } else {
            print("SceneShelfRoundTripTestRunner: \(failures) failures")
            Foundation.exit(1)
        }
    }

    private static func fixtureWindow(
        id: String,
        title: String,
        minimized: Bool = false
    ) -> SceneWindowSnapshot {
        SceneWindowSnapshot(
            identity: SceneWindowIdentity(
                bundleIdentifier: "com.fscoward.SceneShelfAXFixture",
                processID: 78539,
                title: title,
                identifier: id
            ),
            frame: SceneFrame(x: 120, y: 140, width: 800, height: 600),
            isMinimized: minimized
        )
    }

    private static func run(_ name: String, _ body: () async -> Void) async {
        let before = failures
        await body()
        if failures == before {
            print("PASS: \(name)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool) {
        if !condition() {
            failures += 1
            print("FAIL")
        }
    }

    private static func fail(_ message: String) {
        failures += 1
        print("FAIL: \(message)")
    }
}

private actor RecordingExecutor {
    private var targets: [SceneWindowIdentity] = []
    private var writes = 0

    func execute(_ plan: SceneRestorePlan) -> Bool {
        for instruction in plan.instructions {
            targets.append(instruction.target)
            writes += instruction.operations.count
        }
        return true
    }

    func executedTargets() -> [SceneWindowIdentity] { targets }
    func writeCount() -> Int { writes }
}
