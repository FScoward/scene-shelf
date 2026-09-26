import Foundation
import SceneShelfCore

@main
@MainActor
struct SceneShelfP0FourTestRunner {
    private static var failures = 0

    static func main() async {
        await run("unique matcher selects one window from the same bundle") {
            let main = fixtureWindow(id: "main", processID: 101)
            let secondary = fixtureWindow(id: "secondary", processID: 101)
            let decision = SceneMatcher.resolve(
                target: main.identity,
                candidates: [main, secondary]
            )
            guard case let .matched(snapshot) = decision else {
                fail("unique target was not matched")
                return
            }
            expect(snapshot.identity == main.identity)
        }

        await run("ambiguous same-title candidates produce zero write instructions") {
            let main = fixtureWindow(id: "main", processID: 101)
            let duplicate = fixtureWindow(id: "main", processID: 101)
            let scene = SavedScene(id: "scene-ambiguous", name: "曖昧", windows: [main])
            let plan = SceneRestorePlanner.plan(
                for: scene,
                candidates: [main, duplicate],
                action: .display
            )
            expect(plan.instructions.isEmpty)
            expect(plan.preflightFailures.map(\.failureReason) == [.ambiguousMatch])
        }

        await run("PID reuse produces zero write instructions") {
            let saved = fixtureWindow(id: "main", processID: 101)
            let reused = fixtureWindow(id: "main", processID: 202)
            let scene = SavedScene(id: "scene-pid", name: "PID再利用", windows: [saved])
            let plan = SceneRestorePlanner.plan(
                for: scene,
                candidates: [reused],
                action: .hide
            )
            expect(plan.instructions.isEmpty)
            expect(plan.preflightFailures.map(\.failureReason) == [.pidReused])
        }

        await run("unique plus missing is aggregated as a partial restore") {
            let main = fixtureWindow(id: "main", processID: 101)
            let secondary = fixtureWindow(id: "secondary", processID: 101)
            let store = InMemorySceneStore()
            do {
                let saved = try await store.save(
                    name: "部分表示",
                    candidates: [main, secondary],
                    selectedIDs: [main.identity, secondary.identity]
                )
                let recorder = WriteRecorder()
                let outcome = await store.clickDetailed(sceneID: saved.id) { basePlan in
                    let plan = SceneRestorePlanner.resolve(plan: basePlan, candidates: [main])
                    let executed = await recorder.execute(plan.instructions)
                    return SceneRestoreReport.from(plan: plan, executedOutcomes: executed)
                }
                let report = await store.report(sceneID: saved.id)
                let state = await store.state(sceneID: saved.id)
                let currentSceneID = await store.currentSceneID()
                expect(outcome == .partiallyRestored(sceneID: saved.id))
                expect(state == .partiallyRestored)
                expect(currentSceneID == saved.id)
                expect(report?.failureReasons == [.windowMissing])
                let writeCount = await recorder.writeCount()
                expect(writeCount == 3)
            } catch {
                fail("partial restore setup unexpectedly failed: \(error)")
            }
        }

        await run("all failures produce Failed state and clear currentSceneID") {
            let saved = fixtureWindow(id: "main", processID: 101)
            let duplicate = fixtureWindow(id: "main", processID: 101)
            let store = InMemorySceneStore()
            do {
                let scene = try await store.save(
                    name: "全失敗",
                    candidates: [saved],
                    selectedIDs: [saved.identity]
                )
                let recorder = WriteRecorder()
                let outcome = await store.clickDetailed(sceneID: scene.id) { basePlan in
                    let plan = SceneRestorePlanner.resolve(
                        plan: basePlan,
                        candidates: [saved, duplicate]
                    )
                    let executed = await recorder.execute(plan.instructions)
                    return SceneRestoreReport.from(plan: plan, executedOutcomes: executed)
                }
                let report = await store.report(sceneID: scene.id)
                let state = await store.state(sceneID: scene.id)
                let currentSceneID = await store.currentSceneID()
                expect(outcome == .failed(sceneID: scene.id))
                expect(state == .failed)
                expect(currentSceneID == nil)
                expect(report?.failureReasons == [.ambiguousMatch])
                let writeCount = await recorder.writeCount()
                expect(writeCount == 0)
            } catch {
                fail("all failure setup unexpectedly failed: \(error)")
            }
        }

        await run("target-specific failure reason is retained while later targets execute") {
            let main = fixtureWindow(id: "main", processID: 101)
            let secondary = fixtureWindow(id: "secondary", processID: 101)
            let scene = SavedScene(id: "scene-target-failure", name: "対象別失敗", windows: [main, secondary])
            let plan = SceneRestorePlanner.displayPlan(for: scene)
            let recorder = WriteRecorder(failingTarget: secondary.identity)
            let executed = await recorder.execute(plan.instructions)
            let report = SceneRestoreReport.from(
                plan: plan,
                executedOutcomes: executed
            )
            expect(report.state == .partiallyRestored)
            expect(report.currentSceneID == scene.id)
            expect(report.outcomes.map(\.target) == [main.identity, secondary.identity])
            expect(report.outcomes[1].failureReason == .operationFailed)
            let writeCount = await recorder.writeCount()
            expect(writeCount == 3)
        }

        await run("successful restore sets currentSceneID") {
            let main = fixtureWindow(id: "main", processID: 101)
            let scene = SavedScene(id: "scene-current", name: "Current", windows: [main])
            let store = InMemorySceneStore()
            do {
                let saved = try await store.save(
                    name: scene.name,
                    candidates: scene.windows,
                    selectedIDs: [main.identity]
                )
                let outcome = await store.clickDetailed(sceneID: saved.id) { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                expect(outcome == .displayed(sceneID: saved.id))
                let currentSceneID = await store.currentSceneID()
                expect(currentSceneID == saved.id)
            } catch {
                fail("current scene setup unexpectedly failed: \(error)")
            }
        }

        await run("successful hide clears currentSceneID and stashes the card") {
            let main = fixtureWindow(id: "main", processID: 101)
            let store = InMemorySceneStore()
            do {
                let scene = try await store.save(
                    name: "表示と退避",
                    candidates: [main],
                    selectedIDs: [main.identity]
                )
                let displayed = await store.clickDetailed(sceneID: scene.id) { plan in
                    return SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                let displayedCurrentSceneID = await store.currentSceneID()
                expect(displayed == .displayed(sceneID: scene.id))
                expect(displayedCurrentSceneID == scene.id)

                let stashed = await store.clickDetailed(sceneID: scene.id) { plan in
                    return SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                let report = await store.report(sceneID: scene.id)
                let stashedState = await store.state(sceneID: scene.id)
                let stashedCurrentSceneID = await store.currentSceneID()
                expect(stashed == .stashed(sceneID: scene.id))
                expect(stashedState == .stashed)
                expect(stashedCurrentSceneID == nil)
                expect(report?.action == .hide)
                expect(report?.currentSceneID == nil)
            } catch {
                fail("display/hide setup unexpectedly failed: \(error)")
            }
        }

        await run("legacy bool executor failure rolls back state currentSceneID and report") {
            let main = fixtureWindow(id: "main", processID: 101)
            let store = InMemorySceneStore()
            do {
                let scene = try await store.save(
                    name: "互換ロールバック",
                    candidates: [main],
                    selectedIDs: [main.identity]
                )
                let displayed = await store.click(sceneID: scene.id) { _ in true }
                expect(displayed == .displayed(sceneID: scene.id))
                let stateBefore = await store.state(sceneID: scene.id)
                let currentSceneBefore = await store.currentSceneID()
                let reportBefore = await store.report(sceneID: scene.id)

                let failed = await store.click(sceneID: scene.id) { _ in false }
                let stateAfter = await store.state(sceneID: scene.id)
                let currentSceneAfter = await store.currentSceneID()
                let reportAfter = await store.report(sceneID: scene.id)
                expect(failed == .operationFailed(sceneID: scene.id))
                expect(stateAfter == stateBefore)
                expect(currentSceneAfter == currentSceneBefore)
                expect(reportAfter == reportBefore)
            } catch {
                fail("legacy rollback setup unexpectedly failed: \(error)")
            }
        }

        await run("later click is rejected while a target report is busy") {
            let main = fixtureWindow(id: "main", processID: 101)
            let store = InMemorySceneStore()
            do {
                let scene = try await store.save(
                    name: "Busy",
                    candidates: [main],
                    selectedIDs: [main.identity]
                )
                let gate = OperationGate()
                let firstClick = Task {
                    await store.clickDetailed(sceneID: scene.id) { plan in
                        await gate.started()
                        await gate.waitForRelease()
                        return SceneRestoreReport.assuming(plan: plan, succeeded: true)
                    }
                }
                await gate.waitUntilStarted()
                let rejected = await store.clickDetailed(sceneID: scene.id) { plan in
                    SceneRestoreReport.assuming(plan: plan, succeeded: true)
                }
                expect(rejected == .busyRejected(sceneID: scene.id))
                await gate.release()
                let firstOutcome = await firstClick.value
                expect(firstOutcome == .displayed(sceneID: scene.id))
            } catch {
                fail("busy setup unexpectedly failed: \(error)")
            }
        }

        await run("partial card retries display safely and can become displayed") {
            let main = fixtureWindow(id: "main", processID: 101)
            let secondary = fixtureWindow(id: "secondary", processID: 101)
            let store = InMemorySceneStore()
            do {
                let scene = try await store.save(
                    name: "Retry",
                    candidates: [main, secondary],
                    selectedIDs: [main.identity, secondary.identity]
                )
                let first = await store.clickDetailed(sceneID: scene.id) { basePlan in
                    let plan = SceneRestorePlanner.resolve(plan: basePlan, candidates: [main])
                    return SceneRestoreReport.from(
                        plan: plan,
                        executedOutcomes: plan.instructions.map {
                            .succeeded(target: $0.target, appliedOperations: $0.operations)
                        }
                    )
                }
                expect(first == .partiallyRestored(sceneID: scene.id))

                let actions = ActionRecorder()
                let second = await store.clickDetailed(sceneID: scene.id) { basePlan in
                    await actions.record(basePlan.action)
                    return SceneRestoreReport.assuming(plan: basePlan, succeeded: true)
                }
                expect(second == .displayed(sceneID: scene.id))
                let recordedActions = await actions.actions()
                let state = await store.state(sceneID: scene.id)
                expect(recordedActions == [.display])
                expect(state == .displayed)
            } catch {
                fail("retry setup unexpectedly failed: \(error)")
            }
        }

        await run("excluded Secondary is absent from the write plan") {
            let main = fixtureWindow(id: "main", processID: 101)
            let secondary = fixtureWindow(id: "secondary", processID: 101)
            let scene = SavedScene(id: "scene-main-only", name: "Mainのみ", windows: [main])
            let plan = SceneRestorePlanner.plan(
                for: scene,
                candidates: [main, secondary],
                action: .display
            )
            let recorder = WriteRecorder()
            let outcomes = await recorder.execute(plan.instructions)
            expect(plan.instructions.map(\.target) == [main.identity])
            expect(outcomes.map(\.target).contains(secondary.identity) == false)
            let writeCount = await recorder.writeCount()
            expect(writeCount == 3)
        }

        if failures == 0 {
            print("SceneShelfP0FourTestRunner: 12 tests passed")
        } else {
            print("SceneShelfP0FourTestRunner: \(failures) failures")
            Foundation.exit(1)
        }
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

    private static func fixtureWindow(
        id: String,
        processID: Int32,
        title: String? = nil
    ) -> SceneWindowSnapshot {
        SceneWindowSnapshot(
            identity: SceneWindowIdentity(
                bundleIdentifier: SceneMatcher.fixtureBundleIdentifier,
                processID: processID,
                title: title ?? "Scene Shelf AX Fixture - \(id.capitalized)",
                identifier: id
            ),
            frame: SceneFrame(x: 120, y: 140, width: 800, height: 600),
            isMinimized: false
        )
    }
}

private actor WriteRecorder {
    private let failingTarget: SceneWindowIdentity?
    private var writes = 0

    init(failingTarget: SceneWindowIdentity? = nil) {
        self.failingTarget = failingTarget
    }

    func execute(_ instructions: [SceneRestoreInstruction]) -> [SceneTargetRestoreOutcome] {
        instructions.map { instruction in
            if instruction.target == failingTarget {
                return .failed(target: instruction.target, reason: .operationFailed)
            }
            writes += instruction.operations.count
            return .succeeded(
                target: instruction.target,
                appliedOperations: instruction.operations
            )
        }
    }

    func writeCount() -> Int { writes }
}

private actor ActionRecorder {
    private var values: [SceneRestoreAction] = []

    func record(_ action: SceneRestoreAction) {
        values.append(action)
    }

    func actions() -> [SceneRestoreAction] { values }
}

private actor OperationGate {
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func started() {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
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
